import Foundation
import Testing
@testable import StenoKit

private final class CoordinatorTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    func snapshot() -> [String] {
        lock.withLock { entries }
    }
}

private actor LiveCoordinatorCapture: AudioCaptureService {
    let url: URL
    let trace: CoordinatorTrace
    private(set) var cancelled = false

    init(url: URL, trace: CoordinatorTrace) {
        self.url = url
        self.trace = trace
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
        trace.record("capture")
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        _ = sessionID
        return url
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        trace.record("end")
        return url
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
        cancelled = true
    }
}

private enum CaptureStopProbeError: Error {
    case endFailed
}

private actor CaptureStopProbe: AudioCaptureService {
    let url: URL
    let failEnd: Bool
    private(set) var beginCalls = 0
    private(set) var endCalls = 0
    private(set) var cancelCalls = 0

    init(url: URL, failEnd: Bool = false) {
        self.url = url
        self.failEnd = failEnd
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
        beginCalls += 1
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        _ = sessionID
        return url
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        endCalls += 1
        if failEnd {
            throw CaptureStopProbeError.endFailed
        }
        return url
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
        cancelCalls += 1
        try? FileManager.default.removeItem(at: url)
    }
}

private final class CaptureStopCapabilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PressToTalkCaptureStopCapability?

    func record(_ capability: PressToTalkCaptureStopCapability) {
        lock.withLock { stored = capability }
    }

    var value: PressToTalkCaptureStopCapability? {
        lock.withLock { stored }
    }
}

private final class CaptureStopClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock().now
    private var calls = 0

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            defer { calls += 1 }
            switch calls {
            case 0:
                return base
            case 1:
                return base.advanced(by: .milliseconds(25))
            default:
                return base.advanced(by: .seconds(10))
            }
        }
    }
}

private actor LiveCoordinatorEngine: LiveTranscriptionEngine {
    enum Mode: Sendable {
        case normal
        case appendFailure
        case blockedAppend
        case blockedHypothesis
        case blockedCancel
    }

    enum HypothesisResponseMetadata: Sendable {
        case requested
        case wrongSession
        case revisionOffset(UInt64)
        case watermarkOffset(UInt64)
    }

    let mode: Mode
    let trace: CoordinatorTrace
    let provisionalText: String
    let provisionalTextSequence: [String]
    let finalText: String
    let finishShouldThrow: Bool
    let beforeTranscribe: @Sendable () -> Void
    let speechEvidenceSequence: [LiveTranscriptionSpeechEvidence]
    let hypothesisResponseMetadataSequence: [HypothesisResponseMetadata]
    private(set) var appendCalls = 0
    private(set) var hypothesisCalls = 0
    private(set) var hypothesisWatermarks: [UInt64] = []
    private(set) var maximumConcurrentHypothesisCalls = 0
    private(set) var finishCalls = 0
    private(set) var transcribeCalls = 0
    private(set) var cancelCalls = 0
    private(set) var unloadCalls = 0
    private(set) var acceptedSamples: UInt64 = 0
    private(set) var finishedSummary: LivePCMStreamSummary?
    private(set) var acceptedSamplesAtFinish: UInt64?
    private(set) var appendRanges: [Range<UInt64>] = []
    private(set) var maximumConcurrentAppendCalls = 0
    private(set) var requests: [TranscriptionRequest] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedAppendContinuation: CheckedContinuation<Void, Never>?
    private var blockedCancelContinuation: CheckedContinuation<Void, Never>?
    private var didBlockAppend = false
    private var didBlockHypothesis = false
    private var activeHypothesisCalls = 0
    private var activeAppendCalls = 0

    init(
        mode: Mode = .normal,
        trace: CoordinatorTrace,
        provisionalText: String = "provisional words",
        provisionalTextSequence: [String] = [],
        finalText: String = "Authoritative final",
        finishShouldThrow: Bool = false,
        speechEvidenceSequence: [LiveTranscriptionSpeechEvidence] = [.speechDetected],
        hypothesisResponseMetadataSequence: [HypothesisResponseMetadata] = [.requested],
        beforeTranscribe: @escaping @Sendable () -> Void = {}
    ) {
        self.mode = mode
        self.trace = trace
        self.provisionalText = provisionalText
        self.provisionalTextSequence = provisionalTextSequence
        self.finalText = finalText
        self.finishShouldThrow = finishShouldThrow
        self.beforeTranscribe = beforeTranscribe
        self.speechEvidenceSequence = speechEvidenceSequence.isEmpty
            ? [.unknown]
            : speechEvidenceSequence
        self.hypothesisResponseMetadataSequence = hypothesisResponseMetadataSequence.isEmpty
            ? [.requested]
            : hypothesisResponseMetadataSequence
    }

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        requests.append(request)
        trace.record("live")
        return LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: 7,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "test-runtime",
                modelIdentifier: "test-model",
                vadIdentifier: nil,
                currentASRContextCount: 1,
                peakASRContextCount: 1
            )
        )
    }

    func appendLiveAudio(
        _ frame: LivePCMFrame,
        session: LiveTranscriptionSession
    ) async throws {
        _ = frame
        _ = session
        appendCalls += 1
        activeAppendCalls += 1
        maximumConcurrentAppendCalls = max(
            maximumConcurrentAppendCalls,
            activeAppendCalls
        )
        defer { activeAppendCalls -= 1 }
        if mode == .blockedAppend, !didBlockAppend {
            didBlockAppend = true
            await withCheckedContinuation { continuation in
                blockedAppendContinuation = continuation
            }
        }
        if mode == .appendFailure {
            throw NSError(domain: "LiveCoordinatorEngine.append", code: 1)
        }
        acceptedSamples += UInt64(frame.sampleCount)
        appendRanges.append(
            frame.sampleOffset..<(frame.sampleOffset + UInt64(frame.sampleCount))
        )
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        hypothesisCalls += 1
        hypothesisWatermarks.append(decodedAudioWatermark)
        activeHypothesisCalls += 1
        maximumConcurrentHypothesisCalls = max(
            maximumConcurrentHypothesisCalls,
            activeHypothesisCalls
        )
        defer { activeHypothesisCalls -= 1 }
        if mode == .blockedHypothesis, !didBlockHypothesis {
            didBlockHypothesis = true
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        let callIndex = hypothesisCalls - 1
        let evidenceIndex = min(callIndex, speechEvidenceSequence.count - 1)
        let text = provisionalTextSequence.isEmpty
            ? provisionalText
            : provisionalTextSequence[min(callIndex, provisionalTextSequence.count - 1)]
        let responseMetadata = hypothesisResponseMetadataSequence[
            min(callIndex, hypothesisResponseMetadataSequence.count - 1)
        ]
        let responseSession: LiveTranscriptionSession
        let responseRevision: UInt64
        let responseWatermark: UInt64
        switch responseMetadata {
        case .requested:
            responseSession = session
            responseRevision = revision
            responseWatermark = decodedAudioWatermark
        case .wrongSession:
            responseSession = LiveTranscriptionSession(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000BAD")!,
                controllerGeneration: session.controllerGeneration,
                runtimeGeneration: session.runtimeGeneration,
                runtimeIdentity: session.runtimeIdentity
            )
            responseRevision = revision
            responseWatermark = decodedAudioWatermark
        case .revisionOffset(let offset):
            responseSession = session
            responseRevision = revision &+ offset
            responseWatermark = decodedAudioWatermark
        case .watermarkOffset(let offset):
            responseSession = session
            responseRevision = revision
            responseWatermark = decodedAudioWatermark &+ offset
        }
        return LiveTranscriptionEvent(
            session: responseSession,
            revision: responseRevision,
            decodedAudioWatermark: responseWatermark,
            emittedAtMonotonicNanos: revision * 1_000_000_000,
            fullHypothesisText: text,
            speechEvidence: speechEvidenceSequence[evidenceIndex]
        )
    }

    func finishLiveTranscription(
        session: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        _ = session
        _ = canonicalAudioURL
        requests.append(request)
        finishCalls += 1
        finishedSummary = streamSummary
        acceptedSamplesAtFinish = acceptedSamples
        blockedContinuation?.resume()
        blockedContinuation = nil
        blockedAppendContinuation?.resume()
        blockedAppendContinuation = nil
        if finishShouldThrow {
            throw NSError(domain: "LiveCoordinatorEngine.finish", code: 2)
        }
        return RawTranscript(text: finalText)
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        _ = session
        cancelCalls += 1
        if mode == .blockedCancel {
            await withCheckedContinuation { continuation in
                blockedCancelContinuation = continuation
            }
        }
    }

    func unloadRetainedResources() async {
        unloadCalls += 1
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        beforeTranscribe()
        _ = audioURL
        requests.append(request)
        transcribeCalls += 1
        return RawTranscript(text: finalText)
    }

    func releaseBlockedHypothesis() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func releaseBlockedAppend() {
        blockedAppendContinuation?.resume()
        blockedAppendContinuation = nil
    }

    func releaseBlockedCancel() {
        blockedCancelContinuation?.resume()
        blockedCancelContinuation = nil
    }
}

private actor CoordinatorCleanup: CleanupEngine {
    private(set) var calls = 0
    private(set) var rawTexts: [String] = []
    let capitalizeFirst: Bool

    init(capitalizeFirst: Bool = false) {
        self.capitalizeFirst = capitalizeFirst
    }

    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        _ = profile
        _ = lexicon
        calls += 1
        rawTexts.append(raw.text)
        guard capitalizeFirst, let first = raw.text.first else {
            return CleanTranscript(text: raw.text)
        }
        return CleanTranscript(text: String(first).uppercased() + raw.text.dropFirst())
    }
}

private actor CoordinatorInsertion: InsertionServiceProtocol {
    private(set) var texts: [String] = []
    private(set) var attemptedTexts: [String] = []
    private(set) var recoveryTexts: [String] = []
    private(set) var receivedHandle = false
    private let driftBeforeCommit: CoordinatorAXClient?
    private let beforeCommitGate: CoordinatorAsyncGate?
    private let afterCommitGate: CoordinatorAsyncGate?

    init(
        driftBeforeCommit: CoordinatorAXClient? = nil,
        beforeCommitGate: CoordinatorAsyncGate? = nil,
        afterCommitGate: CoordinatorAsyncGate? = nil
    ) {
        self.driftBeforeCommit = driftBeforeCommit
        self.beforeCommitGate = beforeCommitGate
        self.afterCommitGate = afterCommitGate
    }

    func insert(text: String, target: AppContext) async -> InsertResult {
        _ = target
        texts.append(text)
        return InsertResult(status: .inserted, method: .direct, insertedText: text)
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?
    ) async -> InsertResult {
        await insert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: text
        )
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String
    ) async -> InsertResult {
        await performInsert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: nil
        )
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        await performInsert(
            text: text,
            target: target,
            editorTarget: editorTarget,
            clipboardRecoveryText: clipboardRecoveryText,
            commitAuthorization: commitAuthorization
        )
    }

    private func performInsert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization?
    ) async -> InsertResult {
        _ = target
        attemptedTexts.append(text)
        recoveryTexts.append(clipboardRecoveryText)
        receivedHandle = editorTarget != nil
        driftBeforeCommit?.driftSelection()
        let commitLease = commitAuthorization.map { _ in InsertionCommitLease() }
        if let editorTarget, case .failure = await editorTarget.revalidate() {
            await beforeCommitGate?.block()
            guard commitAuthorization == nil
                    || (commitLease.map { commitAuthorization?.acquire($0) == true } ?? false) else {
                return InsertResult(
                    status: .failed,
                    method: .none,
                    insertedText: text,
                    errorMessage: "Insertion canceled."
                )
            }
            await afterCommitGate?.block()
            texts.append(clipboardRecoveryText)
            if let commitAuthorization, let commitLease {
                commitAuthorization.seal(commitLease)
            }
            return InsertResult(
                status: .copiedOnly,
                method: .clipboardPaste,
                insertedText: clipboardRecoveryText,
                errorMessage: "Target changed; copied instead."
            )
        }
        await beforeCommitGate?.block()
        guard commitAuthorization == nil
                || (commitLease.map { commitAuthorization?.acquire($0) == true } ?? false) else {
            return InsertResult(
                status: .failed,
                method: .none,
                insertedText: text,
                errorMessage: "Insertion canceled."
            )
        }
        await afterCommitGate?.block()
        texts.append(text)
        if let commitAuthorization, let commitLease {
            commitAuthorization.seal(commitLease)
        }
        return InsertResult(status: .inserted, method: .accessibility, insertedText: text)
    }
}

private actor CoordinatorHistory: HistoryStoreProtocol {
    private(set) var entries: [TranscriptEntry] = []

    func append(entry: TranscriptEntry) async throws { entries.append(entry) }
    func delete(entryID: UUID) async throws { entries.removeAll { $0.id == entryID } }
    func recent(limit: Int) async -> [TranscriptEntry] { Array(entries.suffix(limit)) }
    func search(query: String) async -> [TranscriptEntry] { entries.filter { $0.cleanText.contains(query) } }
    func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        _ = entryID
        _ = cleanupEngine
        _ = profile
        _ = lexicon
        throw NSError(domain: "CoordinatorHistory.retry", code: 1)
    }
    func pasteLast() async throws -> TranscriptEntry? { entries.last }
}

private actor SnapshotRecorder {
    private(set) var snapshots: [LiveTranscriptionSnapshot] = []
    func append(_ snapshot: LiveTranscriptionSnapshot) { snapshots.append(snapshot) }
}

private actor LiveUnavailableRecorder {
    private(set) var reasons: [LiveTranscriptUnavailableReason] = []
    func append(_ reason: LiveTranscriptUnavailableReason) { reasons.append(reason) }
}

private actor CoordinatorAsyncGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CoordinatorBlockingClipboard: ClipboardService {
    private(set) var copiedTexts: [String] = []
    private let firstCopyGate: CoordinatorAsyncGate

    init(firstCopyGate: CoordinatorAsyncGate) {
        self.firstCopyGate = firstCopyGate
    }

    func setString(_ text: String) async throws {
        copiedTexts.append(text)
        if copiedTexts.count == 1 {
            await firstCopyGate.block()
        }
    }
}

private actor CoordinatorPasteRecorder {
    private(set) var calls = 0

    func paste() -> AutoPasteOutcome {
        calls += 1
        return .attempted
    }
}

private actor CoordinatorUsage: UsageAnalyticsRecording {
    private(set) var calls = 0
    private(set) var events: [UsageEvent] = []
    func record(event: UsageEvent) async throws {
        calls += 1
        events.append(event)
    }
}

private final class CoordinatorAXClient: MacAccessibilityClient, @unchecked Sendable {
    private struct State {
        var document: String
        var selection: EditorTextSelection
        var captureCount = 0
        var stringReadCount = 0
        var contextReadError: EditorTargetUnavailableReason?
    }

    private let lock = NSLock()
    private let captureCondition = NSCondition()
    private var shouldBlockNextCapture = false
    private var captureIsBlocked = false
    private var releaseBlockedCapture = false
    private var state: State
    private let bundleIdentifier: String
    private let role: String
    private let subrole: String?
    private let window = MacAXElementReference(testIdentifier: "coordinator-window")
    private let element = MacAXElementReference(testIdentifier: "coordinator-editor")

    init(
        document: String,
        cursor: Int,
        bundleIdentifier: String,
        role: String = "AXTextArea",
        subrole: String? = nil,
        contextReadError: EditorTargetUnavailableReason? = nil
    ) {
        state = State(
            document: document,
            selection: EditorTextSelection(location: cursor, length: 0),
            contextReadError: contextReadError
        )
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
    }

    func isProcessTrusted() -> Bool { true }

    func captureFocusedTarget(expectedBundleIdentifier: String) throws -> MacAXTargetSnapshot {
        let snapshot = try lock.withLock {
            guard expectedBundleIdentifier == bundleIdentifier else {
                throw EditorTargetUnavailableReason.bundleIdentifierMismatch
            }
            state.captureCount += 1
            return MacAXTargetSnapshot(
                process: EditorTargetProcessIdentity(
                    processIdentifier: 42,
                    launchMarker: 99,
                    bundleIdentifier: bundleIdentifier
                ),
                window: window,
                element: element,
                role: role,
                subrole: subrole,
                isProtected: false,
                selection: state.selection,
                characterCount: state.document.utf16.count
            )
        }
        captureCondition.lock()
        if shouldBlockNextCapture {
            shouldBlockNextCapture = false
            captureIsBlocked = true
            captureCondition.broadcast()
            while !releaseBlockedCapture {
                captureCondition.wait()
            }
            captureIsBlocked = false
            releaseBlockedCapture = false
        }
        captureCondition.unlock()
        return snapshot
    }

    func string(for range: EditorTextSelection, in element: MacAXElementReference) throws -> String {
        _ = element
        return try lock.withLock {
            state.stringReadCount += 1
            if let contextReadError = state.contextReadError { throw contextReadError }
            let text = state.document as NSString
            guard range.location >= 0,
                  range.length >= 0,
                  range.location + range.length <= text.length else {
                throw EditorTargetUnavailableReason.parameterizedTextUnavailable
            }
            return text.substring(with: NSRange(location: range.location, length: range.length))
        }
    }

    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool {
        _ = element
        return true
    }

    func setSelectedText(_ text: String, in element: MacAXElementReference) -> MacAXSetTextResult {
        _ = text
        _ = element
        return .inserted
    }

    func driftSelection(by delta: Int = 1) {
        lock.withLock {
            state.selection = EditorTextSelection(
                location: min(state.document.utf16.count, state.selection.location + delta),
                length: 0
            )
        }
    }

    func setContextReadError(_ error: EditorTargetUnavailableReason?) {
        lock.withLock { state.contextReadError = error }
    }

    func counts() -> (capture: Int, reads: Int) {
        lock.withLock { (state.captureCount, state.stringReadCount) }
    }

    func blockNextCapture() {
        captureCondition.withLock {
            shouldBlockNextCapture = true
            releaseBlockedCapture = false
        }
    }

    var isCaptureBlocked: Bool {
        captureCondition.withLock { captureIsBlocked }
    }

    // Called by the independent blocking-test executor. The held AX call may
    // occupy the cooperative pool, so readiness cannot depend on Task.sleep.
    func waitUntilCaptureBlocked(timeout: TimeInterval = 1) -> Bool {
        captureCondition.lock()
        defer { captureCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !captureIsBlocked {
            if !captureCondition.wait(until: deadline) {
                return captureIsBlocked
            }
        }
        return true
    }

    func releaseCapture() {
        captureCondition.withLock {
            releaseBlockedCapture = true
            captureCondition.broadcast()
        }
    }
}

private func makeCoordinatorWAV(
    silent: Bool = false,
    sampleCount: Int = 8_000,
    silentAfterSample: Int? = nil
) throws -> URL {
    var pcm = Data(capacity: sampleCount * 2)
    for index in 0..<sampleCount {
        let isSilent = silent || (silentAfterSample.map { index >= $0 } ?? false)
        let sample: Int16 = isSilent ? 0 : (index.isMultiple(of: 2) ? 2_400 : -2_400)
        var little = sample.littleEndian
        withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
    }

    var wav = Data()
    func appendASCII(_ value: String) { wav.append(contentsOf: value.utf8) }
    func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    appendASCII("RIFF")
    appendUInt32(UInt32(36 + pcm.count))
    appendASCII("WAVEfmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(1)
    appendUInt32(16_000)
    appendUInt32(32_000)
    appendUInt16(2)
    appendUInt16(16)
    appendASCII("data")
    appendUInt32(UInt32(pcm.count))
    wav.append(pcm)

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("coordinator-live-\(UUID().uuidString).wav")
    try wav.write(to: url)
    return url
}

private func waitUntil(
    attempts: Int = 200,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test("Cumulative hypothesis assembler stitches a strong rolling-window overlap")
func cumulativeHypothesisAssemblerStitchesWindowSlide() {
    var assembler = LiveCumulativeHypothesisAssembler()
    let first = "Alpha beta gamma delta epsilon zeta eta theta iota kappa"
    #expect(assembler.assemble(rollingText: first, stablePrefix: "") == .accepted(first))
    let rolling = "epsilon zeta eta theta iota kappa lambda mu"
    let expected = "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
    #expect(
        assembler.assemble(
            rollingText: rolling,
            stablePrefix: "Alpha beta gamma delta "
        ) == .accepted(expected)
    )
}

@Test("Cumulative hypothesis assembler preserves ordinary tail revisions")
func cumulativeHypothesisAssemblerAcceptsTailRevision() {
    var assembler = LiveCumulativeHypothesisAssembler()
    _ = assembler.assemble(
        rollingText: "Alpha beta gamma tentative ending",
        stablePrefix: ""
    )
    let revised = "Alpha beta gamma corrected ending"
    #expect(
        assembler.assemble(
            rollingText: revised,
            stablePrefix: "Alpha beta "
        ) == .accepted(revised)
    )
}

@Test("Cumulative hypothesis assembler uses exact grapheme and punctuation boundaries")
func cumulativeHypothesisAssemblerHandlesUnicodeAndPunctuation() {
    var assembler = LiveCumulativeHypothesisAssembler()
    let first = "Start here. Café teams 👩🏽‍💻 review exact punctuation, every single day"
    _ = assembler.assemble(rollingText: first, stablePrefix: "")
    let rolling = "Café teams 👩🏽‍💻 review exact punctuation, every single day without guessing"
    let expected = "Start here. Café teams 👩🏽‍💻 review exact punctuation, every single day without guessing"
    #expect(
        assembler.assemble(
            rollingText: rolling,
            stablePrefix: "Start here. "
        ) == .accepted(expected)
    )
}

@Test("Cumulative hypothesis assembler starts a replacement window when overlap is unprovable")
func cumulativeHypothesisAssemblerReplacesNoOverlap() {
    var assembler = LiveCumulativeHypothesisAssembler()
    _ = assembler.assemble(
        rollingText: "Alpha beta gamma delta epsilon zeta eta theta",
        stablePrefix: ""
    )
    let replacement = "Completely unrelated rolling decoder output"
    #expect(
        assembler.assemble(
            rollingText: replacement,
            stablePrefix: "Alpha beta gamma "
        ) == .replacementWindow(
            text: replacement,
            reason: .noProvableOverlap
        )
    )
    #expect(assembler.cumulativeText == replacement)
}

@Test("Cumulative hypothesis assembler rolls over before cumulative text exceeds its bound")
func cumulativeHypothesisAssemblerReplacesAtCumulativeBound() {
    var assembler = LiveCumulativeHypothesisAssembler()
    let overlap = "alpha beta gamma delta epsilon"
    let headByteCount = LiveCumulativeHypothesisAssembler.maximumUTF8Bytes
        - overlap.utf8.count
        - 1
    let first = String(repeating: "x", count: headByteCount) + " " + overlap
    #expect(first.utf8.count == LiveCumulativeHypothesisAssembler.maximumUTF8Bytes)
    #expect(assembler.assemble(rollingText: first, stablePrefix: "") == .accepted(first))

    let rolling = overlap + " " + String(repeating: "y", count: 128)
    #expect(
        assembler.assemble(
            rollingText: rolling,
            stablePrefix: String(first.prefix(32))
        ) == .replacementWindow(
            text: rolling,
            reason: .cumulativeLimitReached
        )
    )
    #expect(assembler.cumulativeText == rolling)
}

@Test("Rolling decoder revisions clear older preview text and keep the live session flowing")
func liveCoordinatorRollsPreviewWindowWithoutBecomingUnavailable() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 120_000)
    defer { try? FileManager.default.removeItem(at: url) }

    let trace = CoordinatorTrace()
    let firstWindow = "The launch plan is ready, and the design team will review the latest build before the meeting."
    let revisedWindow = "Design teams will review this latest build before Monday's meeting, then we will share the final notes."
    let nextWindow = "After lunch, customer research will shape the revised onboarding sequence and the release checklist."
    let newestWindow = "Tomorrow morning, the team will publish the polished build and confirm every remaining acceptance item."
    let finalText = "The launch plan is ready, and the design team will review the latest build before Monday's meeting, then we will share the final notes."
    let engine = LiveCoordinatorEngine(
        trace: trace,
        provisionalTextSequence: [
            firstWindow,
            firstWindow,
            revisedWindow,
            revisedWindow,
            nextWindow,
            nextWindow,
            newestWindow,
        ],
        finalText: finalText
    )
    let snapshots = SnapshotRecorder()
    let unavailable = LiveUnavailableRecorder()
    let insertion = CoordinatorInsertion()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) },
        liveUnavailableHandler: { _, reason in await unavailable.append(reason) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )

    #expect(await waitUntil {
        await snapshots.snapshots.contains { $0.displayText == newestWindow }
    })
    #expect(await unavailable.reasons.isEmpty)
    let emittedSnapshots = await snapshots.snapshots
    let firstRollover = try #require(
        emittedSnapshots.first { $0.displayText == revisedWindow }
    )
    let secondRollover = try #require(
        emittedSnapshots.first { $0.displayText == nextWindow }
    )
    let thirdRollover = try #require(
        emittedSnapshots.first { $0.displayText == newestWindow }
    )
    #expect(firstRollover.continuityEpoch == 1)
    #expect(firstRollover.counters.continuityWindowResets == 1)
    #expect(secondRollover.continuityEpoch == 2)
    #expect(secondRollover.counters.continuityWindowResets == 2)
    #expect(thirdRollover.continuityEpoch == 3)
    #expect(thirdRollover.counters.continuityWindowResets == 3)

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(result.status == .inserted)
    #expect(await insertion.texts == [finalText])
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await unavailable.reasons.isEmpty)
}

@Test("Cumulative hypothesis assembler hard-fails invalid or oversized raw windows")
func cumulativeHypothesisAssemblerRejectsInvalidRawWindows() {
    var assembler = LiveCumulativeHypothesisAssembler()
    let oversized = String(repeating: "x", count: LiveCumulativeHypothesisAssembler.maximumUTF8Bytes + 1)
    #expect(
        assembler.assemble(rollingText: " \n\t", stablePrefix: "")
            == .unavailable(reason: .invalidRollingWindow)
    )
    #expect(
        assembler.assemble(rollingText: oversized, stablePrefix: "")
            == .unavailable(reason: .oversizedRollingWindow)
    )
}

@Test("Oversized live hypotheses still fail preview and preserve exactly-once final insertion")
func liveCoordinatorHardFailsOversizedRawWindow() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 120_000)
    defer { try? FileManager.default.removeItem(at: url) }

    let trace = CoordinatorTrace()
    let finalText = "Authoritative final after preview failure"
    let engine = LiveCoordinatorEngine(
        trace: trace,
        provisionalText: String(
            repeating: "x",
            count: LiveCumulativeHypothesisAssembler.maximumUTF8Bytes + 1
        ),
        finalText: finalText
    )
    let unavailable = LiveUnavailableRecorder()
    let insertion = CoordinatorInsertion()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveUnavailableHandler: { _, reason in await unavailable.append(reason) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await unavailable.reasons == [.streamFailed] })

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(result.status == .inserted)
    #expect(await unavailable.reasons == [.streamFailed])
    #expect(await insertion.texts == [finalText])
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
}

@Test("Live coordinator captures first, isolates partials, and finishes exactly once")
func liveCoordinatorIsolationAndExactlyOnceFinal() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let capture = LiveCoordinatorCapture(url: url, trace: trace)
    let engine = LiveCoordinatorEngine(trace: trace)
    let cleanup = CoordinatorCleanup()
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: engine,
        cleanupEngine: cleanup,
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await snapshots.snapshots.count == 1 })
    #expect(trace.snapshot().prefix(2) == ["capture", "live"])
    #expect(await cleanup.calls == 0)
    #expect(await insertion.texts.isEmpty)
    #expect(await history.entries.isEmpty)

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(result.insertedText == "Authoritative final")
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await cleanup.calls == 1)
    #expect(await insertion.texts == ["Authoritative final"])
    #expect(await history.entries.count == 1)
}

@Test("Live coordinator requests its first hypothesis at the 200 millisecond watermark")
func liveCoordinatorRequestsFirstHypothesisAtTwoHundredMilliseconds() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 3_200)
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls == 1 })
    #expect(await engine.hypothesisWatermarks == [3_200])
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test("Live coordinator does not request a hypothesis below 200 milliseconds")
func liveCoordinatorDoesNotRequestHypothesisBelowTwoHundredMilliseconds() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 3_199)
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil {
        await coordinator.liveHypothesisSchedulingEvaluationWatermark(
            sessionID: sessionID
        ) == 3_199
    })
    #expect(await engine.hypothesisCalls == 0)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    _ = try await coordinator.completePressToTalk(sessionID: sessionID)
}

@Test("Capture acknowledgement precedes exact target binding without blocking it")
func captureAcknowledgementOrdering() async throws {
    let url = try makeCoordinatorWAV()
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { _ in
            trace.record("target")
            return .failure(.applicationUnavailable)
        }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(nearbyContextEnabled: true),
        captureStarted: { _ in
            trace.record("acknowledged")
        }
    )

    #expect(trace.snapshot().prefix(3) == ["capture", "acknowledged", "target"])
    await coordinator.cancel(sessionID: sessionID)
}

// These fixtures deliberately block synchronous AX calls while another task
// stops or cancels the session. Their driver must have an independent executor.
@available(macOS 15.0, *)
private final class BlockingAXTestExecutor: TaskExecutor {
    static let shared = BlockingAXTestExecutor()

    private let queue = DispatchQueue(
        label: "StenoKitTests.blockingAX",
        attributes: .concurrent
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

private func runBlockingAXScenario(
    _ operation: @Sendable () async throws -> Void
) async throws {
    if #available(macOS 15.0, *) {
        try await withTaskExecutorPreference(
            BlockingAXTestExecutor.shared,
            operation: operation
        )
    } else {
        try await operation()
    }
}

private func blockingAXTask<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) -> Task<Value, Error> {
    if #available(macOS 15.0, *) {
        return Task(executorPreference: BlockingAXTestExecutor.shared, operation: operation)
    } else {
        return Task(operation: operation)
    }
}

private func capabilityStopsBlockedExactTargetCaptureExactlyOnceScenario() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let capture = CaptureStopProbe(url: url)
    let engine = LiveCoordinatorEngine(trace: trace, finalText: "This works")
    let insertion = CoordinatorInsertion()
    let usage = CoordinatorUsage()
    let capabilityRecorder = CaptureStopCapabilityRecorder()
    let clock = CaptureStopClock()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(
        document: "field A",
        cursor: 3,
        bundleIdentifier: app.bundleIdentifier
    )
    ax.blockNextCapture()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage,
        monotonicNow: { clock.now() },
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )

    let start = blockingAXTask {
        try await coordinator.startPressToTalkWithCaptureStopCapability(
            appContext: app,
            options: SessionStartOptions(
                livePreviewEnabled: true,
                nearbyContextEnabled: true
            ),
            captureStarted: { capabilityRecorder.record($0) }
        )
    }
    #expect(await waitUntil {
        capabilityRecorder.value != nil && ax.isCaptureBlocked
    })
    guard let capability = capabilityRecorder.value else {
        Issue.record("Capture stop capability was not published")
        ax.releaseCapture()
        _ = try? await start.value
        return
    }

    capability.markStopRequested()
    let firstStop = blockingAXTask { try await capability.stopCapture() }
    let secondStop = blockingAXTask { try await capability.stopCapture() }
    #expect(await waitUntil { await capture.endCalls == 1 })
    #expect(ax.isCaptureBlocked)
    #expect(!trace.snapshot().contains("live"))

    // The handle has already captured field A. Drifting focus/selection while
    // the synchronous AX call is held must not rebind the session to field B.
    ax.driftSelection()
    ax.releaseCapture()
    let sessionID = try await start.value
    try await firstStop.value
    try await secondStop.value
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    #expect(await capture.endCalls == 1)
    #expect(!trace.snapshot().contains("live"))

    let result = try await coordinator.completePressToTalk(sessionID: sessionID)
    #expect(result.status == .copiedOnly)
    #expect(await insertion.receivedHandle)
    #expect(await usage.events.first?.durationMS == 25)
}

@Test("Stopped capability is disposed and sealed by cancellation")
func stoppedCapabilityCancelDisposesOnceAndRejectsLateStop() async throws {
    let url = try makeCoordinatorWAV()
    let capture = CaptureStopProbe(url: url)
    let recorder = CaptureStopCapabilityRecorder()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: LiveCoordinatorEngine(trace: CoordinatorTrace()),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalkWithCaptureStopCapability(
        appContext: .unknown,
        options: .disabled,
        captureStarted: { recorder.record($0) }
    )
    guard let capability = recorder.value else {
        Issue.record("Capture stop capability was not published")
        return
    }

    try await capability.stopCapture()
    #expect(await capture.endCalls == 1)
    #expect(FileManager.default.fileExists(atPath: url.path))
    await capability.cancelCapture()
    await capability.cancelCapture()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(await capture.endCalls == 1)
    #expect(await capture.cancelCalls == 0)
    await #expect(throws: CancellationError.self) {
        try await capability.stopCapture()
    }
    await coordinator.cancel(sessionID: sessionID)
    #expect(await capture.endCalls == 1)
    #expect(await capture.cancelCalls == 0)
}

@Test("Cancelled capability closes once and cannot later stop")
func cancelledCapabilityRejectsLateStopWithoutDoubleClose() async throws {
    let url = try makeCoordinatorWAV()
    let capture = CaptureStopProbe(url: url)
    let recorder = CaptureStopCapabilityRecorder()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: LiveCoordinatorEngine(trace: CoordinatorTrace()),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalkWithCaptureStopCapability(
        appContext: .unknown,
        options: .disabled,
        captureStarted: { recorder.record($0) }
    )
    guard let capability = recorder.value else {
        Issue.record("Capture stop capability was not published")
        return
    }

    await capability.cancelCapture()
    await capability.cancelCapture()
    #expect(await capture.cancelCalls == 1)
    #expect(await capture.endCalls == 0)
    await #expect(throws: CancellationError.self) {
        try await capability.stopCapture()
    }
    await coordinator.cancel(sessionID: sessionID)
    #expect(await capture.cancelCalls == 1)
}

@Test("Stop failure is cached and cancellation falls back exactly once")
func failedCapabilityStopIsCachedBeforeCancelFallback() async throws {
    let url = try makeCoordinatorWAV()
    let capture = CaptureStopProbe(url: url, failEnd: true)
    let recorder = CaptureStopCapabilityRecorder()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: LiveCoordinatorEngine(trace: CoordinatorTrace()),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalkWithCaptureStopCapability(
        appContext: .unknown,
        options: .disabled,
        captureStarted: { recorder.record($0) }
    )
    guard let capability = recorder.value else {
        Issue.record("Capture stop capability was not published")
        return
    }

    await #expect(throws: (any Error).self) {
        try await capability.stopCapture()
    }
    await #expect(throws: (any Error).self) {
        try await capability.stopCapture()
    }
    #expect(await capture.endCalls == 1)
    await capability.cancelCapture()
    #expect(await capture.cancelCalls == 1)
    await #expect(throws: CancellationError.self) {
        try await capability.stopCapture()
    }
    await coordinator.cancel(sessionID: sessionID)
    #expect(await capture.endCalls == 1)
    #expect(await capture.cancelCalls == 1)
}

@Test("Coordinator suppresses nonempty hypotheses when runtime VAD reports no speech")
func liveCoordinatorSuppressesSilencePreview() async throws {
    let url = try makeCoordinatorWAV(silent: true)
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(
        trace: trace,
        finalText: "",
        speechEvidenceSequence: [.noSpeechDetected]
    )
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls == 1 })
    #expect(await snapshots.snapshots.isEmpty)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(result.status == .noSpeech)
    #expect(await snapshots.snapshots.isEmpty)
}

@Test("Uncorrelated hypothesis metadata cannot poison cumulative rolling state")
func liveCoordinatorRejectsMetadataBeforeAssemblerMutation() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 120_000)
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let first = "Alpha beta gamma delta epsilon zeta eta theta iota kappa tentative path"
    let second = "Alpha beta gamma delta epsilon zeta eta theta iota kappa approved path"
    let poison = "Alpha beta gamma delta epsilon zeta eta theta POISON corridor branch"
    let rolling = "epsilon zeta eta theta iota kappa approved path continues safely"
    let expected = "Alpha beta gamma delta epsilon zeta eta theta iota kappa approved path continues safely"
    let engine = LiveCoordinatorEngine(
        trace: trace,
        provisionalTextSequence: [first, second, poison, poison, poison, rolling],
        hypothesisResponseMetadataSequence: [
            .requested,
            .requested,
            .wrongSession,
            .revisionOffset(1),
            .watermarkOffset(1),
            .requested,
        ]
    )
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil {
        await snapshots.snapshots.contains { $0.displayText == expected }
    })
    let accepted = await snapshots.snapshots
    #expect(!accepted.contains { $0.displayText.contains("POISON") })
    let recovered = accepted.first { $0.displayText == expected }
    #expect(recovered?.lastAcceptedRevision == 6)
    #expect(recovered?.counters.rejectedEvents == 1)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test("No-speech hallucination advances ordering without poisoning cumulative rolling state")
func liveCoordinatorSuppressesNoSpeechBeforeAssemblerMutation() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 120_000)
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let first = "Alpha beta gamma delta epsilon zeta eta theta iota kappa tentative path"
    let second = "Alpha beta gamma delta epsilon zeta eta theta iota kappa approved path"
    let poison = "Alpha beta gamma delta epsilon zeta eta theta POISON corridor branch"
    let rolling = "epsilon zeta eta theta iota kappa approved path continues safely"
    let expected = "Alpha beta gamma delta epsilon zeta eta theta iota kappa approved path continues safely"
    let engine = LiveCoordinatorEngine(
        trace: trace,
        provisionalTextSequence: [first, second, poison, rolling],
        speechEvidenceSequence: [
            .speechDetected,
            .speechDetected,
            .noSpeechDetected,
            .speechDetected,
        ]
    )
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil {
        await snapshots.snapshots.contains { $0.displayText == expected }
    })
    let accepted = await snapshots.snapshots
    #expect(!accepted.contains { $0.displayText.contains("POISON") })
    let recovered = accepted.first { $0.displayText == expected }
    #expect(recovered?.lastAcceptedRevision == 4)
    #expect(recovered?.counters.suppressedNoSpeechHypotheses == 1)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test("Coordinator trusts decode-scoped runtime VAD over energetic PCM amplitude")
func liveCoordinatorTrustsRuntimeVADOverEnergeticPCM() async throws {
    // Keep every frame energetic: the helper's configured local VAD result,
    // not a raw amplitude threshold, owns display admission.
    let url = try makeCoordinatorWAV(sampleCount: 50_000)
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(
        trace: trace,
        speechEvidenceSequence: [.speechDetected, .noSpeechDetected]
    )
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls >= 3 })
    #expect(await snapshots.snapshots.count == 1)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test("Preview failure preserves live finish for authoritative fallback")
func liveCoordinatorPreviewFailurePreservesFinish() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .appendFailure, trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.appendCalls > 0 })
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await engine.cancelCalls == 0)
}

@Test("Authoritative finish failure never starts a second final inference")
func liveCoordinatorFinishFailureDoesNotDoubleInfer() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace, finishShouldThrow: true)
    let cleanup = CoordinatorCleanup()
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: cleanup,
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.appendCalls > 0 })
    await #expect(throws: (any Error).self) {
        _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
    }
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await cleanup.calls == 0)
    #expect(await insertion.texts.isEmpty)
    #expect(await history.entries.isEmpty)
    #expect(await usage.calls == 0)
}

@Test("Provisional and nearby-context canaries never reach authoritative sinks")
func liveCoordinatorPrivacyCanariesStayEphemeral() async throws {
    let provisionalCanary = "PROVISIONAL_CANARY_7F31"
    let contextCanary = "CONTEXT_CANARY_9D42"
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(
        trace: trace,
        provisionalText: provisionalCanary,
        finalText: "finaltrigger"
    )
    let cleanup = CoordinatorCleanup()
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let snapshots = SnapshotRecorder()
    let snippets = SnippetService(snippets: [
        Snippet(trigger: provisionalCanary, expansion: "PROVISIONAL_SNIPPET_LEAK"),
        Snippet(trigger: contextCanary, expansion: "CONTEXT_SNIPPET_LEAK"),
        Snippet(trigger: "finaltrigger", expansion: "This final content"),
    ])
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let nearbyText = "\(contextCanary) "
    let ax = CoordinatorAXClient(
        document: nearbyText,
        cursor: nearbyText.utf16.count,
        bundleIdentifier: app.bundleIdentifier
    )
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: cleanup,
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        snippetService: snippets,
        usageRecorder: usage,
        liveSnapshotHandler: { await snapshots.append($0) },
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(
            livePreviewEnabled: true,
            nearbyContextEnabled: true
        )
    )
    #expect(await waitUntil { await snapshots.snapshots.first?.displayText == provisionalCanary })
    #expect(await waitUntil { ax.counts().reads > 0 })
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    // The all-caps underscore canary is intentionally not ordinary prose, so
    // continuation shaping must fail closed while the privacy assertions below
    // still prove that neither canary reaches an authoritative sink.
    #expect(result.insertedText == "This final content")
    #expect(await cleanup.rawTexts == ["This final content"])
    #expect(await insertion.texts == ["This final content"])
    #expect(await history.entries.first?.rawText == "This final content")
    #expect(await history.entries.first?.cleanText == "This final content")
    #expect(await usage.calls == 1)

    let requestData = try JSONEncoder().encode(await engine.requests)
    let requestJSON = String(decoding: requestData, as: UTF8.self)
    #expect(!requestJSON.contains(provisionalCanary))
    #expect(!requestJSON.contains(contextCanary))
    #expect(!requestJSON.contains("This final content"))

    let usageData = try JSONEncoder().encode(await usage.events)
    let usageJSON = String(decoding: usageData, as: UTF8.self)
    #expect(!usageJSON.contains(provisionalCanary))
    #expect(!usageJSON.contains(contextCanary))
    #expect(!usageJSON.contains("This final content"))

    let capturedCleanupTexts = await cleanup.rawTexts
    let capturedInsertionTexts = await insertion.texts
    let capturedHistoryEntries = await history.entries
    let authoritativeSinkText = [
        capturedCleanupTexts.joined(separator: " "),
        capturedInsertionTexts.joined(separator: " "),
        capturedHistoryEntries.map(\.rawText).joined(separator: " "),
        capturedHistoryEntries.map(\.cleanText).joined(separator: " "),
    ].joined(separator: " ")
    #expect(!authoritativeSinkText.contains(provisionalCanary))
    #expect(!authoritativeSinkText.contains(contextCanary))
    #expect(!authoritativeSinkText.contains("SNIPPET_LEAK"))
}

@Test("Cancellation rejects a hypothesis returned after session ownership ended")
func liveCoordinatorRejectsLateHypothesisAfterCancel() async throws {
    let url = try makeCoordinatorWAV()
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .blockedHypothesis, trace: trace)
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls == 1 })
    await coordinator.cancel(sessionID: sessionID)
    await engine.releaseBlockedHypothesis()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await snapshots.snapshots.isEmpty)
    #expect(await engine.finishCalls == 0)
    #expect(await engine.cancelCalls == 1)
}

@Test("Runtime unload cancels live ownership and rejects its late hypothesis")
func liveCoordinatorUnloadRejectsLateHypothesis() async throws {
    let url = try makeCoordinatorWAV()
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let capture = LiveCoordinatorCapture(url: url, trace: trace)
    let engine = LiveCoordinatorEngine(mode: .blockedHypothesis, trace: trace)
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )
    _ = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls == 1 })
    await coordinator.unloadTranscriptionRuntime()
    await engine.releaseBlockedHypothesis()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await snapshots.snapshots.isEmpty)
    #expect(await engine.cancelCalls == 1)
    #expect(await engine.unloadCalls == 1)
    #expect(await capture.cancelled)
}

@Test("Runtime unload removes captured ownership before helper cancellation can suspend")
func liveCoordinatorUnloadRejectsCompletionDuringBlockedCancel() async throws {
    let url = try makeCoordinatorWAV()
    defer { try? FileManager.default.removeItem(at: url) }
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .blockedCancel, trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.appendCalls > 0 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let unload = Task { await coordinator.unloadTranscriptionRuntime() }
    #expect(await waitUntil { await engine.cancelCalls == 1 })
    await #expect(throws: SessionCoordinatorError.sessionNotFound) {
        _ = try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    #expect(await engine.finishCalls == 0)
    #expect(await engine.transcribeCalls == 0)

    await engine.releaseBlockedCancel()
    await unload.value
    #expect(await engine.unloadCalls == 1)
}

@Test("Normal stop does not await a blocked provisional hypothesis")
func liveCoordinatorStopSupersedesBlockedHypothesis() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 50_000)
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .blockedHypothesis, trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls == 1 })
    #expect(await waitUntil { await engine.appendCalls >= 3 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    #expect(trace.snapshot().contains("end"))
    _ = try await coordinator.completePressToTalk(sessionID: sessionID)
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await engine.cancelCalls == 0)
    #expect(await engine.finishedSummary?.sampleCount == 50_000)
    #expect(await waitUntil { await engine.acceptedSamples == 50_000 })
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await engine.hypothesisCalls == 1)
}

@Test("Blocked preview coalesces tail audio into one newest nonconcurrent decode")
func liveCoordinatorCoalescesLatestPendingHypothesis() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 50_000)
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .blockedHypothesis, trace: trace)
    let snapshots = SnapshotRecorder()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { await snapshots.append($0) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.hypothesisCalls == 1 })
    #expect(await waitUntil { await engine.acceptedSamples == 50_000 })
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await engine.hypothesisCalls == 1)

    await engine.releaseBlockedHypothesis()

    #expect(await waitUntil { await engine.hypothesisCalls == 2 })
    #expect(await waitUntil { await snapshots.snapshots.count == 2 })
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await engine.hypothesisCalls == 2)
    #expect(await engine.maximumConcurrentHypothesisCalls == 1)
    let watermarks = await engine.hypothesisWatermarks
    #expect(watermarks.count == 2)
    #expect(watermarks.first.map { $0 < 50_000 } == true)
    #expect(watermarks.last == 50_000)
    #expect(await snapshots.snapshots.count == 2)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test("Stop serializes a delayed pump append before draining every tail frame")
func liveCoordinatorStopSerializesDelayedAppendBeforeTail() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 50_000)
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .blockedAppend, trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.appendCalls == 1 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    #if DEBUG
    let appendWaitGate = CoordinatorAsyncGate()
    await coordinator.setLiveAppendWaitObserver {
        trace.record("append-wait")
        await appendWaitGate.block()
    }
    #endif
    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    #if DEBUG
    #expect(await waitUntil { trace.snapshot().contains("append-wait") })
    #else
    try? await Task.sleep(for: .milliseconds(30))
    #endif
    #expect(await engine.finishCalls == 0)
    #expect(await engine.appendCalls == 1)
    await engine.releaseBlockedAppend()
    #if DEBUG
    #expect(await waitUntil { await engine.acceptedSamples > 0 })
    await appendWaitGate.release()
    #endif

    _ = try await completion.value
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await engine.cancelCalls == 0)
    #expect(await engine.finishedSummary?.sampleCount == 50_000)
    #expect(await engine.acceptedSamplesAtFinish == 50_000)
    #expect(await engine.acceptedSamples == 50_000)
    #expect(await engine.maximumConcurrentAppendCalls == 1)
    let ranges = await engine.appendRanges
    #expect(ranges.count > 1)
    #expect(ranges.first?.lowerBound == 0)
    #expect(ranges.last?.upperBound == 50_000)
    #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
}

@Test("Normal stop bounds a permanently blocked provisional append")
func liveCoordinatorStopSupersedesBlockedAppend() async throws {
    let url = try makeCoordinatorWAV(sampleCount: 50_000)
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(mode: .blockedAppend, trace: trace)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    #expect(await waitUntil { await engine.appendCalls == 1 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    #expect(trace.snapshot().contains("end"))
    let started = ContinuousClock().now
    _ = try await coordinator.completePressToTalk(sessionID: sessionID)
    let elapsed = ContinuousClock().now - started
    #expect(await engine.finishCalls == 1)
    #expect(await engine.transcribeCalls == 0)
    #expect(await engine.cancelCalls == 0)
    #expect(await engine.finishedSummary?.sampleCount == 50_000)
    #expect(await waitUntil { await engine.acceptedSamples > 0 })
    #expect(await engine.acceptedSamples < 50_000)
    #expect(await engine.acceptedSamplesAtFinish == 0)
    #expect(await engine.appendCalls == 1)
    #expect(await engine.maximumConcurrentAppendCalls == 1)
    #expect(elapsed < .seconds(1))
}

@Test("Automatic continuation changes only exact-target insertion payload")
func coordinatorAutomaticContinuationIsInsertionOnly() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace, finalText: "This works")
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage,
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(ax.counts().capture >= 1)
    #expect(await waitUntil { ax.counts().reads > 0 })
    try? await Task.sleep(for: .milliseconds(10))
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(result.insertedText == " this works")
    #expect(await insertion.texts == [" this works"])
    #expect(await insertion.receivedHandle)
    #expect(await history.entries.first?.rawText == "This works")
    #expect(await history.entries.first?.cleanText == "This works")
    #expect(await usage.events.first?.cleanupChanges.commandTransforms == 0)
}

@Test("Coordinator boundary classification is conservative across scripts")
func coordinatorBoundaryStyleClassification() {
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "I think ",
        trailingText: " is right"
    ) == .usesInterwordSpacing)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "café.",
        trailingText: "Next"
    ) == .usesInterwordSpacing)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "前",
        trailingText: "後"
    ) == .doesNotUseInterwordSpacing)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "ไทย",
        trailingText: "ครับ"
    ) == .doesNotUseInterwordSpacing)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "hello",
        trailingText: "界"
    ) == .unknown)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "界",
        trailingText: "world"
    ) == .unknown)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "界",
        trailingText: ""
    ) == .unknown)
    #expect(SessionCoordinator.continuationBoundaryStyle(
        leadingText: "🙂",
        trailingText: "world"
    ) == .unknown)
}

@Test("Eligible non-Latin and mixed boundaries never receive automatic shaping")
func coordinatorNonLatinBoundariesRemainUnshaped() async throws {
    let cases: [(AppContext, String, String)] = [
        (AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"), "前", "後"),
        (AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit"), "ไทย", "ครับ"),
        (AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"), "hello", "界"),
        (AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit"), "界", "world"),
    ]

    for (app, prefix, suffix) in cases {
        let url = try makeCoordinatorWAV()
        let trace = CoordinatorTrace()
        let insertion = CoordinatorInsertion()
        let ax = CoordinatorAXClient(
            document: prefix + suffix,
            cursor: prefix.utf16.count,
            bundleIdentifier: app.bundleIdentifier
        )
        let coordinator = SessionCoordinator(
            captureService: LiveCoordinatorCapture(url: url, trace: trace),
            transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
            cleanupEngine: CoordinatorCleanup(),
            insertionService: insertion,
            historyStore: CoordinatorHistory(),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(nearbyContextEnabled: true)
        )
        #expect(await waitUntil { ax.counts().reads > 0 })

        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

        #expect(result.status == .inserted)
        #expect(result.insertedText == "This works")
        #expect(await insertion.receivedHandle)
        #expect(await insertion.texts == ["This works"])
    }
}

@Test("Eligible Latin TextEdit boundaries retain automatic shaping")
func coordinatorLatinTextEditBoundaryStillShapes() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let insertion = CoordinatorInsertion()
    let app = AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    let ax = CoordinatorAXClient(
        document: "helloworld",
        cursor: 5,
        bundleIdentifier: app.bundleIdentifier
    )
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.insertedText == " this works ")
    #expect(await insertion.texts == [" this works "])
}

@Test("Explicit lowercase remains active at an eligible non-Latin boundary")
func coordinatorLowercaseDirectiveAtNonLatinBoundary() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let insertion = CoordinatorInsertion()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(
        document: "前後",
        cursor: 1,
        bundleIdentifier: app.bundleIdentifier
    )
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "lowercase NASA works"),
        cleanupEngine: CoordinatorCleanup(capitalizeFirst: true),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.insertedText == "nASA works")
    #expect(await insertion.texts == ["nASA works"])
}

@Test("Unavailable nearby text never blocks exact-target direct insertion")
func coordinatorContextReadFailurePreservesDirectInsertion() async throws {
    for reason in [
        EditorTargetUnavailableReason.parameterizedTextUnavailable,
        .timedOut,
        .accessibilityError,
    ] {
        let url = try makeCoordinatorWAV()
        let trace = CoordinatorTrace()
        let insertion = CoordinatorInsertion()
        let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        let ax = CoordinatorAXClient(
            document: "private nearby text",
            cursor: 7,
            bundleIdentifier: app.bundleIdentifier,
            contextReadError: reason
        )
        let coordinator = SessionCoordinator(
            captureService: LiveCoordinatorCapture(url: url, trace: trace),
            transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
            cleanupEngine: CoordinatorCleanup(),
            insertionService: insertion,
            historyStore: CoordinatorHistory(),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(nearbyContextEnabled: true)
        )
        #expect(await waitUntil { ax.counts().reads > 0 })

        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

        #expect(result.status == .inserted)
        #expect(result.insertedText == "This works")
        #expect(await insertion.receivedHandle)
        #expect(await insertion.texts == ["This works"])
    }
}

@Test("Lost installed context proof fails closed without poisoning target identity")
func coordinatorLaterContextReadFailurePreservesMandatoryBaseline() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let insertion = CoordinatorInsertion()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(
        document: "hello",
        cursor: 5,
        bundleIdentifier: app.bundleIdentifier
    )
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })
    ax.setContextReadError(.parameterizedTextUnavailable)

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "This works")
    #expect(await insertion.attemptedTexts == ["This works"])
    #expect(await insertion.recoveryTexts == ["This works"])
    #expect(await insertion.receivedHandle)
}

@Test("Literal lowercase escape survives cleanup while context remains ephemeral")
func coordinatorLiteralLowercaseEscapeAfterCleanup() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace, finalText: "literal lowercase Foo Bar")
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let cleanup = CoordinatorCleanup(capitalizeFirst: true)
    let usage = CoordinatorUsage()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: cleanup,
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage,
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(ax.counts().capture >= 1)
    #expect(await waitUntil { ax.counts().reads > 0 })
    try? await Task.sleep(for: .milliseconds(10))
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(await insertion.texts == [" lowercase Foo Bar"])
    #expect(await cleanup.rawTexts == ["lowercase Foo Bar"])
    #expect(await history.entries.first?.rawText == "literal lowercase Foo Bar")
    #expect(await history.entries.first?.cleanText == "lowercase Foo Bar")
    #expect(await usage.events.first?.cleanupChanges.commandTransforms == 1)
}

@Test("Explicit lowercase directive is applied after ordinary cleanup")
func coordinatorLowercaseDirectiveAfterCleanup() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let cleanup = CoordinatorCleanup(capitalizeFirst: true)
    let usage = CoordinatorUsage()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(
            trace: trace,
            finalText: "lowercase NASA works"
        ),
        cleanupEngine: cleanup,
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(await insertion.texts == ["nASA works"])
    #expect(await cleanup.rawTexts == ["NASA works"])
    #expect(await history.entries.first?.rawText == "lowercase NASA works")
    #expect(await history.entries.first?.cleanText == "nASA works")
    #expect(await usage.events.first?.cleanupChanges.commandTransforms == 1)
}

@Test("Target drift disables continuation and routes final text to copied recovery")
func coordinatorTargetDriftCopiesUnshapedFinal() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace, finalText: "This works")
    let insertion = CoordinatorInsertion()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello!", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(ax.counts().capture >= 1)
    #expect(await waitUntil { ax.counts().reads > 0 })
    try? await Task.sleep(for: .milliseconds(10))
    ax.driftSelection()
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "This works")
    #expect(await insertion.texts == ["This works"])
}

@Test("Late target drift copies canonical clean text instead of shaped continuation")
func coordinatorLateTargetDriftCopiesCanonicalRecovery() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let engine = LiveCoordinatorEngine(trace: trace, finalText: "This works")
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello!", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let insertion = CoordinatorInsertion(driftBeforeCommit: ax)
    let history = CoordinatorHistory()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: engine,
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })
    try? await Task.sleep(for: .milliseconds(10))

    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "This works")
    #expect(await insertion.attemptedTexts == [" this works"])
    #expect(await insertion.recoveryTexts == ["This works"])
    #expect(await insertion.texts == ["This works"])
    #expect(await history.entries.first?.cleanText == "This works")
}

private func coordinatorCancelDuringFinalTargetRevalidationPreventsCommitScenario() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello!", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let insertion = CoordinatorInsertion()
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(
            trace: trace,
            finalText: "This works",
            // Setup has finished before final transcription begins. Block only
            // the final revalidation, never a trailing setup capture.
            beforeTranscribe: { ax.blockNextCapture() }
        ),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage,
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = blockingAXTask {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    #expect(await waitUntil { ax.isCaptureBlocked })
    await coordinator.cancel(sessionID: sessionID)
    ax.releaseCapture()

    await #expect(throws: CancellationError.self) {
        _ = try await completion.value
    }
    #expect(await insertion.texts.isEmpty)
    #expect(await history.entries.isEmpty)
    #expect(await usage.calls == 0)
}

private func coordinatorCancelDuringInitialEditorSetupPreventsContextReadScenario() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let recorder = CaptureStopCapabilityRecorder()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "private nearby text", cursor: 19, bundleIdentifier: app.bundleIdentifier)
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: CoordinatorInsertion(),
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: {
            let result = EditorTargetHandle.capture(target: $0, client: ax)
            // The first capture binds the exact target synchronously. Hold the
            // setup task at its metadata revalidation before any range read.
            ax.blockNextCapture()
            return result
        }
    )

    defer { ax.releaseCapture() }
    let start = blockingAXTask {
        try await coordinator.startPressToTalkWithCaptureStopCapability(
            appContext: app,
            options: SessionStartOptions(nearbyContextEnabled: true),
            captureStarted: { recorder.record($0) }
        )
    }
    #expect(ax.waitUntilCaptureBlocked())
    guard let capability = recorder.value else {
        Issue.record("Capture stop capability was not published")
        ax.releaseCapture()
        _ = try? await start.value
        return
    }
    let sessionID = capability.sessionID
    await coordinator.cancel(sessionID: sessionID)
    ax.releaseCapture()
    #expect(try await start.value == sessionID)

    #expect(await waitUntil { ax.counts().capture >= 2 })
    try? await Task.sleep(for: .milliseconds(20))
    #expect(ax.counts().reads == 0)
    await #expect(throws: SessionCoordinatorError.sessionNotFound) {
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    }
}

@Suite(.serialized)
struct BlockingAXCoordinatorTests {
    @Test("Capability closes capture during exact target binding without live setup or focus drift")
    func capabilityStopsBlockedExactTargetCaptureExactlyOnce() async throws {
        try await runBlockingAXScenario {
            try await capabilityStopsBlockedExactTargetCaptureExactlyOnceScenario()
        }
    }

    @Test("Cancel during final target revalidation prevents every authoritative sink")
    func coordinatorCancelDuringFinalTargetRevalidationPreventsCommit() async throws {
        try await runBlockingAXScenario {
            try await coordinatorCancelDuringFinalTargetRevalidationPreventsCommitScenario()
        }
    }

    @Test("Cancel during deferred editor setup prevents bounded AX text reads")
    func coordinatorCancelDuringInitialEditorSetupPreventsContextRead() async throws {
        try await runBlockingAXScenario {
            try await coordinatorCancelDuringInitialEditorSetupPreventsContextReadScenario()
        }
    }
}

@Test("Cancel in the insertion handoff gap is rejected at the commit boundary")
func coordinatorCommitAuthorizationRejectsCancellationBeforeCommit() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let gate = CoordinatorAsyncGate()
    let insertion = CoordinatorInsertion(beforeCommitGate: gate)
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    await gate.waitUntilStarted()
    await coordinator.cancel(sessionID: sessionID)
    await gate.release()

    await #expect(throws: CancellationError.self) {
        _ = try await completion.value
    }
    #expect(await insertion.texts.isEmpty)
    #expect(await history.entries.isEmpty)
    #expect(await usage.calls == 0)
}

@Test("Completion task cancellation invalidates insertion authorization before commit")
func coordinatorTaskCancellationRejectsInsertionBeforeCommit() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let gate = CoordinatorAsyncGate()
    let insertion = CoordinatorInsertion(beforeCommitGate: gate)
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    await gate.waitUntilStarted()
    completion.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) {
        _ = try await completion.value
    }
    #expect(await insertion.texts.isEmpty)
    #expect(await history.entries.isEmpty)
    #expect(await usage.calls == 0)
}

@Test("Cancel after insertion commit preserves one acknowledged final")
func coordinatorCancellationAfterCommitDoesNotDuplicateOrEraseFinal() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let gate = CoordinatorAsyncGate()
    let insertion = CoordinatorInsertion(afterCommitGate: gate)
    let history = CoordinatorHistory()
    let usage = CoordinatorUsage()
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usage
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    await gate.waitUntilStarted()
    await coordinator.cancel(sessionID: sessionID)
    await gate.release()

    let result = try await completion.value
    #expect(result.status == .inserted)
    #expect(await insertion.texts == ["This works"])
    #expect(await history.entries.count == 1)
    #expect(await usage.calls == 1)
}

@Test("Coordinator cancel after shaped clipboard copy restores canonical text and suppresses paste")
func coordinatorCancelAfterClipboardCopyRestoresCanonicalWithoutPaste() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let copyGate = CoordinatorAsyncGate()
    let clipboard = CoordinatorBlockingClipboard(firstCopyGate: copyGate)
    let pasteRecorder = CoordinatorPasteRecorder()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello!", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let insertion = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, _, _ in await pasteRecorder.paste() }
        )
    ])
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    await copyGate.waitUntilStarted()
    await coordinator.cancel(sessionID: sessionID)
    await copyGate.release()

    let result = try await completion.value
    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "This works")
    #expect(await clipboard.copiedTexts == [" this works", "This works"])
    #expect(await pasteRecorder.calls == 0)
}

@Test("Coordinator cancellation during exact-target paste revalidation denies the paste boundary")
func coordinatorCancelBeforeAuthorizedPasteBoundarySuppressesPaste() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let pasteGate = CoordinatorAsyncGate()
    let clipboard = MemoryClipboardService()
    let pasteRecorder = CoordinatorPasteRecorder()
    let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ax = CoordinatorAXClient(document: "hello!", cursor: 5, bundleIdentifier: app.bundleIdentifier)
    let insertion = InsertionService(transports: [
        ClipboardInsertionTransport(
            clipboard: clipboard,
            exactTargetAutoPaste: { _, _, permit in
                await pasteGate.block()
                guard let permit,
                      permit.performIfAuthorized({ true }) == true else {
                    return .skipped(reason: "Auto-paste canceled.")
                }
                return await pasteRecorder.paste()
            }
        )
    ])
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
        cleanupEngine: CoordinatorCleanup(),
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    #expect(await waitUntil { ax.counts().reads > 0 })
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    await pasteGate.waitUntilStarted()
    await coordinator.cancel(sessionID: sessionID)
    await pasteGate.release()

    let result = try await completion.value
    #expect(result.status == .copiedOnly)
    #expect(result.insertedText == "This works")
    #expect(result.errorMessage == "Auto-paste canceled.")
    #expect(await clipboard.latestValue == "This works")
    #expect(await pasteRecorder.calls == 0)
}

@Test("Excluded targets keep exact binding without nearby text reads or shaping")
func coordinatorExcludedTargetsBindWithoutContextRead() async throws {
    let cases: [(AppContext, [String])] = [
        (.unknown, ["en-US"]),
        (AppContext(bundleIdentifier: "com.apple.Terminal", appName: "Terminal"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2"), ["en-US"]),
        (AppContext(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", isIDE: true), ["en-US"]),
        (AppContext(bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.microsoft.rdc.macos", appName: "Remote Desktop", isRemoteDesktop: true), ["en-US"]),
        (AppContext(bundleIdentifier: "com.apple.Safari", appName: "Safari"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.microsoft.Excel", appName: "Microsoft Excel"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.example.Writer", appName: "Unknown Writer"), ["en-US"]),
        (AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"), ["fr-FR"]),
    ]

    for (app, languages) in cases {
        let url = try makeCoordinatorWAV()
        let trace = CoordinatorTrace()
        let engine = LiveCoordinatorEngine(trace: trace, finalText: "This works")
        let insertion = CoordinatorInsertion()
        let ax = CoordinatorAXClient(
            document: "secret nearby text",
            cursor: 6,
            bundleIdentifier: app.bundleIdentifier
        )
        let coordinator = SessionCoordinator(
            captureService: LiveCoordinatorCapture(url: url, trace: trace),
            transcriptionEngine: engine,
            cleanupEngine: CoordinatorCleanup(),
            insertionService: insertion,
            historyStore: CoordinatorHistory(),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(
                nearbyContextEnabled: true,
                languageHints: languages
            )
        )
        #expect(await waitUntil { ax.counts().capture > 0 })
        try? await Task.sleep(for: .milliseconds(10))
        _ = try await coordinator.stopPressToTalk(
            sessionID: sessionID,
            languageHints: languages
        )
        #expect(ax.counts().reads == 0)
        #expect(await insertion.receivedHandle)
        #expect(await insertion.texts == ["This works"])
    }
}

@Test("Unapproved AX surfaces never read nearby text even in an approved prose app")
func coordinatorExcludedAXSurfacesBindWithoutContextRead() async throws {
    let surfaces: [(String, String?)] = [
        ("AXWebArea", nil),
        ("AXTable", nil),
        ("AXStaticText", nil),
        ("AXTextArea", "AXSearchField"),
        ("AXTextField", "AXSearchField"),
    ]

    for (role, subrole) in surfaces {
        let url = try makeCoordinatorWAV()
        let trace = CoordinatorTrace()
        let insertion = CoordinatorInsertion()
        let app = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        let ax = CoordinatorAXClient(
            document: "private nearby text",
            cursor: 7,
            bundleIdentifier: app.bundleIdentifier,
            role: role,
            subrole: subrole
        )
        let coordinator = SessionCoordinator(
            captureService: LiveCoordinatorCapture(url: url, trace: trace),
            transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "This works"),
            cleanupEngine: CoordinatorCleanup(),
            insertionService: insertion,
            historyStore: CoordinatorHistory(),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(nearbyContextEnabled: true)
        )
        _ = try await coordinator.stopPressToTalk(sessionID: sessionID)

        #expect(ax.counts().reads == 0)
        #expect(await insertion.receivedHandle)
        #expect(await insertion.texts == ["This works"])
    }
}

@Test("Explicit lowercase remains independent from automatic-continuation eligibility")
func coordinatorLowercaseDirectiveOnExcludedSurface() async throws {
    let url = try makeCoordinatorWAV()
    let trace = CoordinatorTrace()
    let insertion = CoordinatorInsertion()
    let cleanup = CoordinatorCleanup(capitalizeFirst: true)
    let app = AppContext(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    let ax = CoordinatorAXClient(
        document: "private nearby text",
        cursor: 7,
        bundleIdentifier: app.bundleIdentifier
    )
    let coordinator = SessionCoordinator(
        captureService: LiveCoordinatorCapture(url: url, trace: trace),
        transcriptionEngine: LiveCoordinatorEngine(trace: trace, finalText: "lowercase NASA works"),
        cleanupEngine: cleanup,
        insertionService: insertion,
        historyStore: CoordinatorHistory(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        editorTargetCapture: { EditorTargetHandle.capture(target: $0, client: ax) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: app,
        options: SessionStartOptions(nearbyContextEnabled: true)
    )
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(ax.counts().reads == 0)
    #expect(result.insertedText == "nASA works")
    #expect(await insertion.receivedHandle)
    #expect(await insertion.texts == ["nASA works"])
}
