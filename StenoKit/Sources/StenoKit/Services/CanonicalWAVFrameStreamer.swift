import Foundation

public protocol CanonicalWAVByteSource: Sendable {
    func byteCount() throws -> UInt64
    func read(offset: UInt64, count: Int) throws -> Data
}

public struct FileCanonicalWAVByteSource: CanonicalWAVByteSource {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func byteCount() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CanonicalWAVFrameStreamerError.unreadableSource
        }
        return size.uint64Value
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else {
            throw CanonicalWAVFrameStreamerError.invalidRead
        }
        guard count > 0 else { return Data() }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
}

public enum CanonicalWAVFrameStreamerError: Error, LocalizedError, Equatable {
    case invalidConfiguration
    case unreadableSource
    case invalidRead
    case invalidContainer
    case unsupportedFormat
    case invalidChunkLayout
    case headerScanLimitExceeded
    case inconsistentDataSize

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid canonical WAV streaming configuration"
        case .unreadableSource:
            return "Canonical WAV capture could not be read"
        case .invalidRead:
            return "Canonical WAV capture returned an invalid read"
        case .invalidContainer:
            return "Capture is not a RIFF/WAVE file"
        case .unsupportedFormat:
            return "Capture is not 16 kHz mono signed 16-bit PCM"
        case .invalidChunkLayout:
            return "Capture has an invalid WAV chunk layout"
        case .headerScanLimitExceeded:
            return "Capture WAV metadata exceeds the safe scan limit"
        case .inconsistentDataSize:
            return "Capture WAV data size does not match its PCM payload"
        }
    }
}

/// Incrementally tails the PCM payload of the canonical WAV written by the
/// recorder. Each poll performs bounded reads and returns a bounded number of
/// frames, so a long recording is never accumulated in memory.
public actor CanonicalWAVFrameStreamer {
    public static let maximumSupportedFrameBytes = 32 * 1_024

    private struct DataLayout {
        var sizeFieldOffset: UInt64
        var payloadOffset: UInt64
    }

    private struct ReadablePCMWindow {
        var endOffset: UInt64
        var isFinalPayloadComplete: Bool
    }

    private enum TerminalState {
        case active
        case cancelled
        case finalized(LivePCMStreamSummary)
    }

    private let sessionID: SessionID
    private let source: any CanonicalWAVByteSource
    private let maximumFrameBytes: Int
    private let maximumFramesPerPoll: Int
    private let maximumHeaderOffset: UInt64

    private var validatedContainer = false
    private var validatedFormat = false
    private var headerScanOffset: UInt64 = 12
    private var dataLayout: DataLayout?
    private var nextPCMByteOffset: UInt64?
    private var nextSequenceNumber: UInt64 = 0
    private var emittedSampleCount: UInt64 = 0
    private var emittedByteCount: UInt64 = 0
    private var digest = LivePCMDigest.fnv1a64OffsetBasis
    private var isFinalizing = false
    private var terminalState: TerminalState = .active

    public init(
        sessionID: SessionID,
        audioURL: URL,
        maximumFrameBytes: Int = CanonicalWAVFrameStreamer.maximumSupportedFrameBytes,
        maximumFramesPerPoll: Int = 8,
        maximumHeaderOffset: UInt64 = 64 * 1_024 * 1_024
    ) throws {
        try Self.validateConfiguration(
            maximumFrameBytes: maximumFrameBytes,
            maximumFramesPerPoll: maximumFramesPerPoll,
            maximumHeaderOffset: maximumHeaderOffset
        )
        self.sessionID = sessionID
        self.source = FileCanonicalWAVByteSource(url: audioURL)
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumFramesPerPoll = maximumFramesPerPoll
        self.maximumHeaderOffset = maximumHeaderOffset
    }

    public init(
        sessionID: SessionID,
        source: any CanonicalWAVByteSource,
        maximumFrameBytes: Int = CanonicalWAVFrameStreamer.maximumSupportedFrameBytes,
        maximumFramesPerPoll: Int = 8,
        maximumHeaderOffset: UInt64 = 64 * 1_024 * 1_024
    ) throws {
        try Self.validateConfiguration(
            maximumFrameBytes: maximumFrameBytes,
            maximumFramesPerPoll: maximumFramesPerPoll,
            maximumHeaderOffset: maximumHeaderOffset
        )
        self.sessionID = sessionID
        self.source = source
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumFramesPerPoll = maximumFramesPerPoll
        self.maximumHeaderOffset = maximumHeaderOffset
    }

    /// Reads newly available PCM without waiting for more bytes.
    public func poll(sessionID requestedSessionID: SessionID) throws -> CanonicalWAVPoll {
        try produceFrames(sessionID: requestedSessionID)
    }

    /// Marks the source complete and starts a bounded final drain. Call
    /// `drain` until the returned state is `.finalized`.
    public func finalize(sessionID requestedSessionID: SessionID) throws -> CanonicalWAVPoll {
        guard requestedSessionID == sessionID else {
            return CanonicalWAVPoll(frames: [], state: .staleSession)
        }
        guard case .active = terminalState else {
            return terminalPoll()
        }
        isFinalizing = true
        return try produceFrames(sessionID: requestedSessionID)
    }

    /// Continues a bounded drain after `finalize`.
    public func drain(sessionID requestedSessionID: SessionID) throws -> CanonicalWAVPoll {
        try produceFrames(sessionID: requestedSessionID)
    }

    /// Cancels only the matching capture. Stale cancellation cannot affect a
    /// newer streamer instance.
    @discardableResult
    public func cancel(sessionID requestedSessionID: SessionID) -> Bool {
        guard requestedSessionID == sessionID else { return false }
        guard case .active = terminalState else { return false }
        terminalState = .cancelled
        return true
    }

    private static func validateConfiguration(
        maximumFrameBytes: Int,
        maximumFramesPerPoll: Int,
        maximumHeaderOffset: UInt64
    ) throws {
        guard maximumFrameBytes >= 2,
              maximumFrameBytes <= maximumSupportedFrameBytes,
              maximumFrameBytes.isMultiple(of: 2),
              maximumFramesPerPoll > 0,
              maximumHeaderOffset >= 20
        else {
            throw CanonicalWAVFrameStreamerError.invalidConfiguration
        }
    }

    private func produceFrames(sessionID requestedSessionID: SessionID) throws -> CanonicalWAVPoll {
        guard requestedSessionID == sessionID else {
            return CanonicalWAVPoll(frames: [], state: .staleSession)
        }
        guard case .active = terminalState else {
            return terminalPoll()
        }

        let fileByteCount = try source.byteCount()
        guard try discoverDataLayout(fileByteCount: fileByteCount) else {
            return CanonicalWAVPoll(
                frames: [],
                state: isFinalizing ? .draining : .waitingForHeader
            )
        }
        guard let dataLayout, var nextPCMByteOffset else {
            throw CanonicalWAVFrameStreamerError.invalidChunkLayout
        }

        let readableWindow = try readablePCMWindow(
            layout: dataLayout,
            fileByteCount: fileByteCount
        )
        let readableEnd = readableWindow.endOffset
        var frames: [LivePCMFrame] = []
        frames.reserveCapacity(maximumFramesPerPoll)

        while nextPCMByteOffset < readableEnd, frames.count < maximumFramesPerPoll {
            let remaining = readableEnd - nextPCMByteOffset
            let requestedByteCount = Int(min(UInt64(maximumFrameBytes), remaining))
            let bytes = try source.read(offset: nextPCMByteOffset, count: requestedByteCount)
            guard bytes.count <= requestedByteCount else {
                throw CanonicalWAVFrameStreamerError.invalidRead
            }

            let completeByteCount = bytes.count - (bytes.count % MemoryLayout<Int16>.size)
            guard completeByteCount > 0 else { break }
            let completeBytes = bytes.prefix(completeByteCount)
            let frameData = Data(completeBytes)
            let frame = LivePCMFrame(
                sequenceNumber: nextSequenceNumber,
                sampleOffset: emittedSampleCount,
                pcmS16LE: frameData
            )
            frames.append(frame)

            nextSequenceNumber &+= 1
            let emittedNow = UInt64(frameData.count)
            nextPCMByteOffset += emittedNow
            emittedByteCount += emittedNow
            emittedSampleCount += emittedNow / UInt64(MemoryLayout<Int16>.size)
            digest = LivePCMDigest.updateFNV1a64(digest, with: frameData)
        }
        self.nextPCMByteOffset = nextPCMByteOffset

        if isFinalizing,
           readableWindow.isFinalPayloadComplete,
           nextPCMByteOffset == readableEnd {
            let summary = LivePCMStreamSummary(
                sampleCount: emittedSampleCount,
                byteCount: emittedByteCount,
                frameCount: nextSequenceNumber,
                fnv1a64: digest
            )
            terminalState = .finalized(summary)
            return CanonicalWAVPoll(frames: frames, state: .finalized(summary))
        }

        return CanonicalWAVPoll(
            frames: frames,
            state: isFinalizing ? .draining : .streaming
        )
    }

    private func terminalPoll() -> CanonicalWAVPoll {
        switch terminalState {
        case .active:
            return CanonicalWAVPoll(
                frames: [],
                state: isFinalizing ? .draining : .streaming
            )
        case .cancelled:
            return CanonicalWAVPoll(frames: [], state: .cancelled)
        case .finalized(let summary):
            return CanonicalWAVPoll(frames: [], state: .finalized(summary))
        }
    }

    private func discoverDataLayout(fileByteCount: UInt64) throws -> Bool {
        if dataLayout != nil { return true }

        if !validatedContainer {
            guard fileByteCount >= 12 else { return false }
            let container = try source.read(offset: 0, count: 12)
            guard container.count == 12 else { return false }
            guard container.prefix(4) == Data("RIFF".utf8),
                  container.subdata(in: 8..<12) == Data("WAVE".utf8)
            else {
                throw CanonicalWAVFrameStreamerError.invalidContainer
            }
            validatedContainer = true
        }

        while headerScanOffset <= fileByteCount {
            guard headerScanOffset <= maximumHeaderOffset,
                  headerScanOffset <= UInt64.max - 8
            else {
                throw CanonicalWAVFrameStreamerError.headerScanLimitExceeded
            }
            guard fileByteCount >= headerScanOffset + 8 else { return false }

            let chunkHeader = try source.read(offset: headerScanOffset, count: 8)
            guard chunkHeader.count == 8 else { return false }
            let identifier = chunkHeader.prefix(4)
            let payloadByteCount = UInt64(Self.littleEndianUInt32(chunkHeader, at: 4))
            let payloadOffset = headerScanOffset + 8

            if identifier == Data("fmt ".utf8) {
                guard payloadByteCount >= 16 else {
                    throw CanonicalWAVFrameStreamerError.invalidChunkLayout
                }
                guard fileByteCount >= payloadOffset + 16 else { return false }
                let format = try source.read(offset: payloadOffset, count: 16)
                guard format.count == 16 else { return false }
                try Self.validateCanonicalPCMFormat(format)
                validatedFormat = true
            } else if identifier == Data("data".utf8) {
                guard validatedFormat else {
                    throw CanonicalWAVFrameStreamerError.invalidChunkLayout
                }
                dataLayout = DataLayout(
                    sizeFieldOffset: headerScanOffset + 4,
                    payloadOffset: payloadOffset
                )
                nextPCMByteOffset = payloadOffset
                return true
            }

            let paddedPayloadByteCount = payloadByteCount + (payloadByteCount % 2)
            guard payloadOffset <= UInt64.max - paddedPayloadByteCount else {
                throw CanonicalWAVFrameStreamerError.invalidChunkLayout
            }
            let nextOffset = payloadOffset + paddedPayloadByteCount
            guard nextOffset > headerScanOffset else {
                throw CanonicalWAVFrameStreamerError.invalidChunkLayout
            }
            guard nextOffset <= maximumHeaderOffset else {
                throw CanonicalWAVFrameStreamerError.headerScanLimitExceeded
            }
            headerScanOffset = nextOffset
        }
        return false
    }

    private func readablePCMWindow(
        layout: DataLayout,
        fileByteCount: UInt64
    ) throws -> ReadablePCMWindow {
        guard fileByteCount >= layout.payloadOffset else {
            return ReadablePCMWindow(
                endOffset: layout.payloadOffset,
                isFinalPayloadComplete: false
            )
        }
        let sizeBytes = try source.read(offset: layout.sizeFieldOffset, count: 4)
        guard sizeBytes.count == 4 else {
            return ReadablePCMWindow(
                endOffset: layout.payloadOffset,
                isFinalPayloadComplete: false
            )
        }
        let declaredByteCount = UInt64(Self.littleEndianUInt32(sizeBytes, at: 0))
        let availableByteCount = fileByteCount - layout.payloadOffset

        let readableByteCount: UInt64
        let isFinalPayloadComplete: Bool
        if !isFinalizing {
            // AVAudioRecorder can leave this header field at zero or at an
            // earlier length until stop. The growing canonical file is the
            // source of truth during capture; only complete Int16 samples are
            // exposed. Finalization below switches to the patched declaration.
            // A completed RIFF can contain metadata chunks after `data`. If a
            // caller polls that file before marking the streamer final, those
            // bytes must not be mistaken for newly appended PCM. Honor the
            // declared data boundary only when the outer RIFF length is exact
            // and every byte after the padded data payload is a complete,
            // structurally valid chunk chain. A growing recorder file with a
            // stale length continues to use its physical even-byte frontier.
            readableByteCount = try activeDeclaredDataByteCount(
                layout: layout,
                declaredByteCount: declaredByteCount,
                fileByteCount: fileByteCount
            ) ?? availableByteCount
            isFinalPayloadComplete = false
        } else if declaredByteCount == 0 {
            guard availableByteCount == 0 else {
                throw CanonicalWAVFrameStreamerError.inconsistentDataSize
            }
            readableByteCount = 0
            isFinalPayloadComplete = true
        } else if declaredByteCount == UInt64(UInt32.max) {
            throw CanonicalWAVFrameStreamerError.inconsistentDataSize
        } else {
            readableByteCount = min(availableByteCount, declaredByteCount)
            isFinalPayloadComplete = availableByteCount >= declaredByteCount
        }

        if isFinalizing, declaredByteCount.isMultiple(of: 2) == false {
            throw CanonicalWAVFrameStreamerError.inconsistentDataSize
        }

        let completeReadableByteCount = readableByteCount - (readableByteCount % 2)
        let end = layout.payloadOffset + completeReadableByteCount
        if let nextPCMByteOffset, nextPCMByteOffset > end {
            throw CanonicalWAVFrameStreamerError.inconsistentDataSize
        }
        return ReadablePCMWindow(
            endOffset: end,
            isFinalPayloadComplete: isFinalPayloadComplete
        )
    }

    private func activeDeclaredDataByteCount(
        layout: DataLayout,
        declaredByteCount: UInt64,
        fileByteCount: UInt64
    ) throws -> UInt64? {
        guard declaredByteCount != UInt64(UInt32.max),
              let declaredEnd = Self.adding(layout.payloadOffset, declaredByteCount),
              let paddedEnd = Self.adding(declaredEnd, declaredByteCount % 2),
              paddedEnd <= fileByteCount else {
            return nil
        }

        let riffSizeBytes = try source.read(offset: 4, count: 4)
        guard riffSizeBytes.count == 4 else { return nil }
        let declaredRIFFPayloadBytes = UInt64(Self.littleEndianUInt32(riffSizeBytes, at: 0))
        guard let declaredFileEnd = Self.adding(8, declaredRIFFPayloadBytes),
              declaredFileEnd == fileByteCount else {
            return nil
        }

        if paddedEnd == fileByteCount {
            return declaredByteCount
        }
        guard try hasCompleteTrailingChunkChain(
            from: paddedEnd,
            through: fileByteCount
        ) else {
            return nil
        }
        return declaredByteCount
    }

    private func hasCompleteTrailingChunkChain(
        from startOffset: UInt64,
        through endOffset: UInt64
    ) throws -> Bool {
        guard startOffset < endOffset else { return false }
        var offset = startOffset
        var chunkCount = 0
        while offset < endOffset {
            guard chunkCount < 4_096,
                  let headerEnd = Self.adding(offset, 8),
                  headerEnd <= endOffset else {
                return false
            }
            let header = try source.read(offset: offset, count: 8)
            guard header.count == 8,
                  header.prefix(4).allSatisfy({ (0x20...0x7e).contains($0) }) else {
                return false
            }
            let payloadByteCount = UInt64(Self.littleEndianUInt32(header, at: 4))
            let paddedPayloadByteCount = payloadByteCount + (payloadByteCount % 2)
            guard let nextOffset = Self.adding(headerEnd, paddedPayloadByteCount),
                  nextOffset <= endOffset,
                  nextOffset > offset else {
                return false
            }
            offset = nextOffset
            chunkCount += 1
        }
        return chunkCount > 0 && offset == endOffset
    }

    private static func adding(_ left: UInt64, _ right: UInt64) -> UInt64? {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? nil : value
    }

    private static func validateCanonicalPCMFormat(_ format: Data) throws {
        let formatTag = littleEndianUInt16(format, at: 0)
        let channelCount = littleEndianUInt16(format, at: 2)
        let sampleRate = littleEndianUInt32(format, at: 4)
        let byteRate = littleEndianUInt32(format, at: 8)
        let blockAlignment = littleEndianUInt16(format, at: 12)
        let bitsPerSample = littleEndianUInt16(format, at: 14)
        guard formatTag == 1,
              channelCount == 1,
              sampleRate == 16_000,
              byteRate == 32_000,
              blockAlignment == 2,
              bitsPerSample == 16
        else {
            throw CanonicalWAVFrameStreamerError.unsupportedFormat
        }
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }
}
