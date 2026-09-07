import Foundation
import Testing
@testable import StenoKit

@Test("Recorder-shaped growing WAV streams all samples and finalizes after stop patches its headers")
func canonicalWAVRecorderHeaderPatchingPreservesAllSamples() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let empty = makeShortDeclaredCanonicalWAV(physicalPCM: Data(), declaredDataByteCount: 0)
    var bytes = Data("RIFF".utf8)
    appendTruncationLittleEndian(UInt32(4088), to: &bytes)
    bytes.append(Data("WAVE".utf8))
    bytes.append(truncationWAVChunk(identifier: "JUNK", declaredSize: 28, physicalPayload: Data(count: 28)))
    bytes.append(empty.subdata(in: 12..<36))
    bytes.append(truncationWAVChunk(identifier: "FLLR", declaredSize: 4008, physicalPayload: Data(count: 4008)))
    bytes.append(empty.dropFirst(36))
    #expect(bytes.count == 4096)
    try bytes.write(to: url)
    let source = FileCanonicalWAVByteSource(url: url)
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(sessionID: sessionID, source: source)
    #expect(try await streamer.poll(sessionID: sessionID).frames.isEmpty)
    var expectedPCM = Data()
    var emittedPCM = Data()
    for pcm in [Data([1, 2, 3, 4]), Data([5, 6, 7, 8]), Data([9, 10, 11, 12])] {
        expectedPCM.append(pcm)
        bytes.append(pcm)
        try bytes.write(to: url)
        let poll = try await streamer.poll(sessionID: sessionID)
        emittedPCM.append(joinedTruncationFrames(poll.frames))
        #expect(emittedPCM == expectedPCM)
    }
    await #expect(throws: CanonicalWAVFrameStreamerError.inconsistentDataSize) {
        try await CanonicalWAVFrameStreamer.validateFinalizedCapture(source: source)
    }
    var riffSize = Data()
    appendTruncationLittleEndian(UInt32(bytes.count - 8), to: &riffSize)
    bytes.replaceSubrange(4..<8, with: riffSize)
    var dataSize = Data()
    appendTruncationLittleEndian(UInt32(expectedPCM.count), to: &dataSize)
    bytes.replaceSubrange(4092..<4096, with: dataSize)
    try bytes.write(to: url)
    try await CanonicalWAVFrameStreamer.validateFinalizedCapture(source: source)
    let final = try await streamer.finalize(sessionID: sessionID)
    let summary = try #require(finalizedTruncationSummary(from: final.state))
    #expect(final.frames.isEmpty)
    #expect(summary.byteCount == UInt64(expectedPCM.count))
    #expect(summary.sampleCount == UInt64(expectedPCM.count / 2))
    #expect(summary.fnv1a64 == LivePCMDigest.fnv1a64(expectedPCM))
}

@Test("Closed-capture validation rejects a truncated declaration before any decoder can receive the file")
func closedCaptureRejectsTruncatedDeclaration() async {
    let source = FixedCanonicalWAVByteSource(bytes: makeShortDeclaredCanonicalWAV(
        physicalPCM: Data([1, 2, 3, 4, 5, 6, 7, 8]),
        declaredDataByteCount: 4
    ))
    await #expect(throws: CanonicalWAVFrameStreamerError.inconsistentDataSize) {
        try await CanonicalWAVFrameStreamer.validateFinalizedCapture(source: source)
    }
}

@Test("Closed-capture validation checks trailing metadata without reading speech bytes")
func closedCaptureValidationDoesNotReadPCM() async throws {
    let bytes = makeShortDeclaredCanonicalWAV(
        physicalPCM: Data([1, 2, 3, 4]),
        declaredDataByteCount: 4,
        trailingChunks: [("LIST", Data([5, 6, 7]))]
    )
    try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
        source: HeaderOnlyCanonicalWAVByteSource(bytes: bytes, pcmRange: 44..<48)
    )
}

@Test("Closed-capture validation accepts recorder padding and rejects its stale outer RIFF length")
func closedCaptureValidationChecksRecorderContainerBoundary() async throws {
    let simple = makeShortDeclaredCanonicalWAV(
        physicalPCM: Data([1, 2, 3, 4]), declaredDataByteCount: 4
    )
    var body = Data("WAVE".utf8)
    body.append(truncationWAVChunk(identifier: "JUNK", declaredSize: 28, physicalPayload: Data(count: 28)))
    body.append(simple.subdata(in: 12..<36))
    body.append(truncationWAVChunk(identifier: "FLLR", declaredSize: 4008, physicalPayload: Data(count: 4008)))
    body.append(simple.dropFirst(36))
    var padded = Data("RIFF".utf8)
    appendTruncationLittleEndian(UInt32(body.count), to: &padded)
    padded.append(body)
    #expect(padded.count == 4100)
    try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
        source: HeaderOnlyCanonicalWAVByteSource(bytes: padded, pcmRange: 4096..<4100)
    )

    var staleSize = Data()
    appendTruncationLittleEndian(UInt32(4088), to: &staleSize)
    padded.replaceSubrange(4..<8, with: staleSize)
    let staleSource = FixedCanonicalWAVByteSource(bytes: padded)
    await #expect(throws: CanonicalWAVFrameStreamerError.inconsistentDataSize) {
        try await CanonicalWAVFrameStreamer.validateFinalizedCapture(source: staleSource)
    }
}

@Test("Closed-capture validation accepts complete empty recordings with optional trailing metadata", arguments: [false, true])
func closedCaptureValidationAcceptsEmptyPCM(withMetadata: Bool) async throws {
    try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
        source: FixedCanonicalWAVByteSource(bytes: makeShortDeclaredCanonicalWAV(
            physicalPCM: Data(), declaredDataByteCount: 0,
            trailingChunks: withMetadata ? [("LIST", Data([1, 2, 3]))] : []
        ))
    )
}

@Test("Canonical WAV finalization rejects a short declared payload without prior polling")
func canonicalWAVFinalizationRejectsShortDeclaredPayloadWithoutPriorPoll() async throws {
    let physicalPCM = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
    let declaredPCM = Data(physicalPCM.prefix(4))
    let source = FixedCanonicalWAVByteSource(
        bytes: makeShortDeclaredCanonicalWAV(
            physicalPCM: physicalPCM,
            declaredDataByteCount: UInt32(declaredPCM.count)
        )
    )
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 8,
        maximumFramesPerPoll: 8
    )

    await #expect(throws: CanonicalWAVFrameStreamerError.inconsistentDataSize) {
        _ = try await streamer.finalize(sessionID: sessionID)
    }
}

@Test("Canonical WAV finalization rejects a short declaration after active polling emitted the physical tail")
func canonicalWAVFinalizationRejectsShortDeclaredPayloadAfterActivePoll() async throws {
    let physicalPCM = Data([0x91, 0xa2, 0xb3, 0xc4, 0xd5, 0xe6, 0xf7, 0x08])
    let source = FixedCanonicalWAVByteSource(
        bytes: makeShortDeclaredCanonicalWAV(
            physicalPCM: physicalPCM,
            declaredDataByteCount: 4
        )
    )
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 8,
        maximumFramesPerPoll: 8
    )

    let activePoll = try await streamer.poll(sessionID: sessionID)
    let emitted = joinedTruncationFrames(activePoll.frames)
    #expect(activePoll.state == .streaming)
    #expect(emitted == physicalPCM)
    #expect(UInt64(emitted.count / 2) == 4)
    #expect(UInt64(activePoll.frames.count) == 1)
    #expect(LivePCMDigest.fnv1a64(emitted) == LivePCMDigest.fnv1a64(physicalPCM))

    do {
        _ = try await streamer.finalize(sessionID: sessionID)
        Issue.record("Expected finalization to reject the already-emitted physical tail")
    } catch let error as CanonicalWAVFrameStreamerError {
        #expect(error == .inconsistentDataSize)
    } catch {
        Issue.record("Unexpected finalization error: \(error)")
    }
}

@Test("Canonical WAV finalization honors a short declaration with a valid trailing LIST when no prior poll emitted bytes")
func canonicalWAVFinalizationHonorsTrailingLISTWithoutPriorPoll() async throws {
    let pcm = Data([0x21, 0x32, 0x43, 0x54])
    let source = FixedCanonicalWAVByteSource(
        bytes: makeShortDeclaredCanonicalWAV(
            physicalPCM: pcm,
            declaredDataByteCount: UInt32(pcm.count),
            trailingChunks: [("LIST", Data([0x61, 0x62, 0x63]))]
        )
    )
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 8,
        maximumFramesPerPoll: 8
    )

    let finalPoll = try await streamer.finalize(sessionID: sessionID)
    let summary = try #require(finalizedTruncationSummary(from: finalPoll.state))
    let emitted = joinedTruncationFrames(finalPoll.frames)

    #expect(emitted == pcm)
    #expect(UInt64(emitted.count / 2) == 2)
    #expect(summary.byteCount == 4)
    #expect(summary.sampleCount == 2)
    #expect(summary.frameCount == 1)
    #expect(summary.fnv1a64 == LivePCMDigest.fnv1a64(pcm))
}

@Test("Canonical WAV active polling honors a short declaration with a valid trailing LIST")
func canonicalWAVFinalizationHonorsTrailingLISTAfterActivePoll() async throws {
    let pcm = Data([0x71, 0x82, 0x93, 0xa4])
    let source = FixedCanonicalWAVByteSource(
        bytes: makeShortDeclaredCanonicalWAV(
            physicalPCM: pcm,
            declaredDataByteCount: UInt32(pcm.count),
            trailingChunks: [("LIST", Data([0x65, 0x66, 0x67]))]
        )
    )
    let sessionID = UUID()
    let streamer = try CanonicalWAVFrameStreamer(
        sessionID: sessionID,
        source: source,
        maximumFrameBytes: 8,
        maximumFramesPerPoll: 8
    )

    let activePoll = try await streamer.poll(sessionID: sessionID)
    let activeBytes = joinedTruncationFrames(activePoll.frames)
    #expect(activePoll.state == .streaming)
    #expect(activeBytes == pcm)
    #expect(UInt64(activeBytes.count / 2) == 2)
    #expect(UInt64(activePoll.frames.count) == 1)
    #expect(LivePCMDigest.fnv1a64(activeBytes) == LivePCMDigest.fnv1a64(pcm))

    let finalPoll = try await streamer.finalize(sessionID: sessionID)
    let summary = try #require(finalizedTruncationSummary(from: finalPoll.state))
    #expect(finalPoll.frames.isEmpty)
    #expect(summary.byteCount == 4)
    #expect(summary.sampleCount == 2)
    #expect(summary.frameCount == 1)
    #expect(summary.fnv1a64 == LivePCMDigest.fnv1a64(pcm))
}

private struct FixedCanonicalWAVByteSource: CanonicalWAVByteSource, Sendable {
    let bytes: Data

    func byteCount() throws -> UInt64 {
        UInt64(bytes.count)
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= UInt64(bytes.count) else { return Data() }
        let lowerBound = Int(offset)
        let upperBound = min(bytes.count, lowerBound + count)
        return bytes.subdata(in: lowerBound..<upperBound)
    }
}

private struct HeaderOnlyCanonicalWAVByteSource: CanonicalWAVByteSource, Sendable {
    let bytes: Data
    let pcmRange: Range<Int>

    func byteCount() throws -> UInt64 { UInt64(bytes.count) }

    func read(offset: UInt64, count: Int) throws -> Data {
        let requested = Int(offset)..<(Int(offset) + count)
        guard !requested.overlaps(pcmRange) else {
            throw CanonicalWAVFrameStreamerError.invalidRead
        }
        return try FixedCanonicalWAVByteSource(bytes: bytes).read(offset: offset, count: count)
    }
}

private func makeShortDeclaredCanonicalWAV(
    physicalPCM: Data,
    declaredDataByteCount: UInt32,
    trailingChunks: [(String, Data)] = []
) -> Data {
    var body = Data("WAVE".utf8)

    var format = Data()
    appendTruncationLittleEndian(UInt16(1), to: &format)
    appendTruncationLittleEndian(UInt16(1), to: &format)
    appendTruncationLittleEndian(UInt32(16_000), to: &format)
    appendTruncationLittleEndian(UInt32(32_000), to: &format)
    appendTruncationLittleEndian(UInt16(2), to: &format)
    appendTruncationLittleEndian(UInt16(16), to: &format)
    body.append(truncationWAVChunk(identifier: "fmt ", declaredSize: 16, physicalPayload: format))
    body.append(
        truncationWAVChunk(
            identifier: "data",
            declaredSize: declaredDataByteCount,
            physicalPayload: physicalPCM
        )
    )
    for (identifier, payload) in trailingChunks {
        body.append(
            truncationWAVChunk(
                identifier: identifier,
                declaredSize: UInt32(payload.count),
                physicalPayload: payload
            )
        )
    }

    var wav = Data("RIFF".utf8)
    appendTruncationLittleEndian(UInt32(body.count), to: &wav)
    wav.append(body)
    return wav
}

private func truncationWAVChunk(
    identifier: String,
    declaredSize: UInt32,
    physicalPayload: Data
) -> Data {
    precondition(identifier.utf8.count == 4)
    var chunk = Data(identifier.utf8)
    appendTruncationLittleEndian(declaredSize, to: &chunk)
    chunk.append(physicalPayload)
    if physicalPayload.count.isMultiple(of: 2) == false {
        chunk.append(0)
    }
    return chunk
}

private func appendTruncationLittleEndian(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendTruncationLittleEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func finalizedTruncationSummary(from state: CanonicalWAVPollState) -> LivePCMStreamSummary? {
    guard case .finalized(let summary) = state else { return nil }
    return summary
}

private func joinedTruncationFrames(_ frames: [LivePCMFrame]) -> Data {
    frames.reduce(into: Data()) { result, frame in
        result.append(frame.pcmS16LE)
    }
}
