import Foundation
import Testing
@testable import StenoKit

@Test("Canonical WAV streaming handles nonstandard chunks and exact final parity")
func canonicalWAVStreamingHandlesNonstandardChunks() async throws {
    let pcm = Data((0..<20_001).map { UInt8(truncatingIfNeeded: $0 &* 17) })
    let evenPCM = Data(pcm.dropLast())
    let wav = makeCanonicalWAV(
        pcm: evenPCM,
        chunksBeforeFormat: [("JUNK", Data([1, 2, 3]))],
        chunksBeforeData: [("LIST", Data(repeating: 7, count: 18))],
        chunksAfterData: [("INFO", Data([8, 9, 10]))]
    )
    let source = MutableWAVByteSource(wav)
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 1_024,
        maximumFramesPerPoll: 3
    )

    var frames: [LivePCMFrame] = []
    var poll = try await streamer.finalize(sessionID: sessionID)
    frames += poll.frames
    while case .draining = poll.state {
        poll = try await streamer.drain(sessionID: sessionID)
        frames += poll.frames
    }

    let summary = try #require(finalizedSummary(from: poll.state))
    let streamed = frames.reduce(into: Data()) { $0.append($1.pcmS16LE) }
    #expect(streamed == evenPCM)
    #expect(summary.byteCount == UInt64(evenPCM.count))
    #expect(summary.sampleCount == UInt64(evenPCM.count / 2))
    #expect(summary.frameCount == UInt64(frames.count))
    #expect(summary.fnv1a64 == referenceFNV1a64(evenPCM))
    #expect(frames.allSatisfy { $0.pcmS16LE.count <= 1_024 })
    #expect(frames.enumerated().allSatisfy { UInt64($0.offset) == $0.element.sequenceNumber })
    #expect(sampleOffsetsAreContiguous(frames))
}

@Test("Canonical WAV streaming waits through incomplete headers and PCM samples")
func canonicalWAVStreamingHandlesIncrementalGrowth() async throws {
    let pcm = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
    let wav = makeCanonicalWAV(pcm: pcm)
    let dataOffset = try #require(wav.range(of: Data("data".utf8))?.lowerBound).advanced(by: 8)
    let source = MutableWAVByteSource(Data())
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 256,
        maximumFramesPerPoll: 32
    )

    source.replace(with: Data(wav.prefix(7)))
    var poll = try await streamer.poll(sessionID: sessionID)
    #expect(poll.frames.isEmpty)
    #expect(poll.state == .waitingForHeader)

    source.replace(with: Data(wav.prefix(dataOffset + 1)))
    poll = try await streamer.poll(sessionID: sessionID)
    #expect(poll.frames.isEmpty)
    #expect(poll.state == .streaming)

    source.replace(with: Data(wav.prefix(dataOffset + 513)))
    poll = try await streamer.poll(sessionID: sessionID)
    #expect(poll.frames.reduce(0) { $0 + $1.pcmS16LE.count } == 512)

    source.replace(with: wav)
    var allFrames = poll.frames
    poll = try await streamer.finalize(sessionID: sessionID)
    allFrames += poll.frames
    while case .draining = poll.state {
        poll = try await streamer.drain(sessionID: sessionID)
        allFrames += poll.frames
    }

    #expect(allFrames.reduce(into: Data()) { $0.append($1.pcmS16LE) } == pcm)
    #expect(finalizedSummary(from: poll.state)?.fnv1a64 == referenceFNV1a64(pcm))
    #expect(sampleOffsetsAreContiguous(allFrames))
}

@Test("Canonical WAV polling is bounded by frame and per-poll limits")
func canonicalWAVPollingIsBounded() async throws {
    let pcm = Data(repeating: 0x5a, count: 40_000)
    let source = MutableWAVByteSource(makeCanonicalWAV(pcm: pcm))
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 2_000,
        maximumFramesPerPoll: 2
    )

    let first = try await streamer.poll(sessionID: sessionID)
    #expect(first.frames.count == 2)
    #expect(first.frames.allSatisfy { $0.pcmS16LE.count <= 2_000 })
    #expect(first.frames.reduce(0) { $0 + $1.pcmS16LE.count } <= 4_000)
    #expect(first.state == .streaming)
}

@Test("Active polling never treats complete trailing RIFF chunks as PCM")
func canonicalWAVActivePollingStopsAtDeclaredDataBeforeTrailingChunks() async throws {
    let pcm = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 11) })
    let wav = makeCanonicalWAV(
        pcm: pcm,
        chunksAfterData: [
            ("LIST", Data([1, 2, 3])),
            ("INFO", Data(repeating: 0x5a, count: 18)),
        ]
    )
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: MutableWAVByteSource(wav),
        maximumFrameBytes: 512,
        maximumFramesPerPoll: 32
    )

    let activePoll = try await streamer.poll(sessionID: sessionID)
    let activeBytes = activePoll.frames.reduce(into: Data()) { $0.append($1.pcmS16LE) }
    #expect(activeBytes == pcm)
    #expect(activePoll.state == .streaming)

    let finalPoll = try await streamer.finalize(sessionID: sessionID)
    let summary = try #require(finalizedSummary(from: finalPoll.state))
    #expect(finalPoll.frames.isEmpty)
    #expect(summary.byteCount == UInt64(pcm.count))
    #expect(summary.sampleCount == UInt64(pcm.count / 2))
    #expect(summary.fnv1a64 == referenceFNV1a64(pcm))
}

@Test("Active polling follows physical PCM growth until the recorder patches its stale length")
func canonicalWAVStreamingHandlesStaleGrowingDataLength() async throws {
    let pcm = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 29) })
    let finalizedWAV = makeCanonicalWAV(pcm: pcm)
    let dataIdentifierOffset = try #require(finalizedWAV.range(of: Data("data".utf8))?.lowerBound)
    var growingWAV = finalizedWAV
    growingWAV.replaceSubrange(
        (dataIdentifierOffset + 4)..<(dataIdentifierOffset + 8),
        with: Data(repeating: 0, count: 4)
    )

    let source = MutableWAVByteSource(growingWAV)
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 512,
        maximumFramesPerPoll: 32
    )

    let activePoll = try await streamer.poll(sessionID: sessionID)
    #expect(activePoll.frames.reduce(0) { $0 + $1.pcmS16LE.count } == pcm.count)
    #expect(activePoll.state == .streaming)

    source.replace(with: finalizedWAV)
    let finalPoll = try await streamer.finalize(sessionID: sessionID)
    let summary = try #require(finalizedSummary(from: finalPoll.state))
    #expect(finalPoll.frames.isEmpty)
    #expect(summary.byteCount == UInt64(pcm.count))
    #expect(summary.fnv1a64 == referenceFNV1a64(pcm))
}

@Test("Stale and cancelled canonical WAV operations never emit capture data")
func canonicalWAVStreamingRejectsStaleAndCancelledOperations() async throws {
    let pcm = Data(repeating: 0x2a, count: 2_048)
    let source = MutableWAVByteSource(makeCanonicalWAV(pcm: pcm))
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(sessionID: sessionID, source: source)

    let stalePoll = try await streamer.poll(sessionID: UUID())
    #expect(stalePoll == CanonicalWAVPoll(frames: [], state: .staleSession))
    #expect(await streamer.cancel(sessionID: UUID()) == false)

    let validPoll = try await streamer.poll(sessionID: sessionID)
    #expect(validPoll.frames.reduce(0) { $0 + $1.pcmS16LE.count } == pcm.count)
    #expect(await streamer.cancel(sessionID: sessionID))

    let cancelledPoll = try await streamer.poll(sessionID: sessionID)
    #expect(cancelledPoll == CanonicalWAVPoll(frames: [], state: .cancelled))
    let cancelledFinal = try await streamer.finalize(sessionID: sessionID)
    #expect(cancelledFinal == CanonicalWAVPoll(frames: [], state: .cancelled))
}

@Test("Randomized file growth preserves exact ordered PCM bytes")
func randomizedCanonicalWAVGrowthPreservesParity() async throws {
    var random = DeterministicRandom(seed: 0x5eed_cafe_f00d_beef)

    for iteration in 0..<40 {
        let sampleCount = random.nextInt(in: 0...12_000)
        let pcm = Data((0..<(sampleCount * 2)).map { _ in random.nextByte() })
        let wav = makeCanonicalWAV(
            pcm: pcm,
            chunksBeforeFormat: [("JUNK", random.data(count: random.nextInt(in: 0...31)))],
            chunksBeforeData: [("LIST", random.data(count: random.nextInt(in: 0...31)))]
        )
        let source = MutableWAVByteSource(Data())
        let sessionID = UUID()
        let frameBytes = random.nextInt(in: 1...128) * 2
        let streamer = try CanonicalWAVFrameStreamer(
            sessionID: sessionID,
            source: source,
            maximumFrameBytes: frameBytes,
            maximumFramesPerPoll: 5
        )

        var visibleByteCount = 0
        var frames: [LivePCMFrame] = []
        while visibleByteCount < wav.count {
            visibleByteCount = min(
                wav.count,
                visibleByteCount + random.nextInt(in: 1...257)
            )
            source.replace(with: Data(wav.prefix(visibleByteCount)))
            let poll = try await streamer.poll(sessionID: sessionID)
            frames += poll.frames
        }

        var finalPoll = try await streamer.finalize(sessionID: sessionID)
        frames += finalPoll.frames
        while case .draining = finalPoll.state {
            finalPoll = try await streamer.drain(sessionID: sessionID)
            frames += finalPoll.frames
        }

        let streamed = frames.reduce(into: Data()) { $0.append($1.pcmS16LE) }
        #expect(streamed == pcm, "PCM mismatch in iteration \(iteration)")
        #expect(sampleOffsetsAreContiguous(frames))
        #expect(frames.allSatisfy { $0.pcmS16LE.count <= frameBytes })
        #expect(finalizedSummary(from: finalPoll.state)?.fnv1a64 == referenceFNV1a64(pcm))
    }
}

@Test("Finalization rejects incomplete or misaligned declared PCM")
func canonicalWAVFinalizationRejectsIncompletePCM() async throws {
    let complete = makeCanonicalWAV(pcm: Data([1, 2, 3, 4]))
    let truncated = Data(complete.dropLast())
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: MutableWAVByteSource(truncated)
    )

    let first = try await streamer.finalize(sessionID: sessionID)
    #expect(first.state == .draining)
    #expect(first.frames.reduce(0) { $0 + $1.pcmS16LE.count } == 2)
}

private final class MutableWAVByteSource: CanonicalWAVByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    func replace(with bytes: Data) {
        lock.withLock {
            self.bytes = bytes
        }
    }

    func byteCount() throws -> UInt64 {
        lock.withLock { UInt64(bytes.count) }
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        lock.withLock {
            guard offset <= UInt64(bytes.count), count >= 0 else { return Data() }
            let lowerBound = Int(offset)
            let upperBound = min(bytes.count, lowerBound + count)
            return bytes.subdata(in: lowerBound..<upperBound)
        }
    }
}

private func makeCanonicalWAV(
    pcm: Data,
    chunksBeforeFormat: [(String, Data)] = [],
    chunksBeforeData: [(String, Data)] = [],
    chunksAfterData: [(String, Data)] = []
) -> Data {
    var body = Data("WAVE".utf8)
    for chunk in chunksBeforeFormat {
        body.append(wavChunk(identifier: chunk.0, payload: chunk.1))
    }

    var format = Data()
    format.appendLittleEndian(UInt16(1))
    format.appendLittleEndian(UInt16(1))
    format.appendLittleEndian(UInt32(16_000))
    format.appendLittleEndian(UInt32(32_000))
    format.appendLittleEndian(UInt16(2))
    format.appendLittleEndian(UInt16(16))
    body.append(wavChunk(identifier: "fmt ", payload: format))

    for chunk in chunksBeforeData {
        body.append(wavChunk(identifier: chunk.0, payload: chunk.1))
    }
    body.append(wavChunk(identifier: "data", payload: pcm))
    for chunk in chunksAfterData {
        body.append(wavChunk(identifier: chunk.0, payload: chunk.1))
    }

    var wav = Data("RIFF".utf8)
    wav.appendLittleEndian(UInt32(body.count))
    wav.append(body)
    return wav
}

private func wavChunk(identifier: String, payload: Data) -> Data {
    precondition(identifier.utf8.count == 4)
    var chunk = Data(identifier.utf8)
    chunk.appendLittleEndian(UInt32(payload.count))
    chunk.append(payload)
    if payload.count % 2 == 1 {
        chunk.append(0)
    }
    return chunk
}

private func finalizedSummary(from state: CanonicalWAVPollState) -> LivePCMStreamSummary? {
    guard case .finalized(let summary) = state else { return nil }
    return summary
}

private func sampleOffsetsAreContiguous(_ frames: [LivePCMFrame]) -> Bool {
    var expectedOffset: UInt64 = 0
    for frame in frames {
        guard frame.sampleOffset == expectedOffset else { return false }
        expectedOffset += UInt64(frame.sampleCount)
    }
    return true
}

private func referenceFNV1a64(_ bytes: Data) -> UInt64 {
    var digest: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        digest ^= UInt64(byte)
        digest &*= 0x0000_0100_0000_01b3
    }
    return digest
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func data(count: Int) -> Data {
        Data((0..<count).map { _ in nextByte() })
    }

    private mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
