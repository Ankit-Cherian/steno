import CryptoKit
import Foundation
import StenoKit

/// Stop-path timing measured through Steno's production session orchestration.
///
/// The transcription engine supplied by the caller is reused for every trial.
/// Audio capture is represented by a private copy of the caller-attested public
/// canonical WAV. Insertion crosses the production `InsertionService` commit
/// boundary using a content-free no-op transport; it does not exercise AX,
/// clipboard, CGEvent, or a real application. History uses an in-memory store.
public enum LiveContextProductionCoordinatorBenchmark {
    public static let definition =
        "Continuous-clock milliseconds from immediately before SessionCoordinator.endPressToTalkCapture through successful return from SessionCoordinator.completePressToTalk, including canonical final transcription, RuleBasedCleanupEngine cleanup, the production InsertionService commit boundary via a content-free no-op transport, and in-memory history append. Capture close is fixture-backed and does not measure AVFoundation or microphone flush latency. The insertion boundary is synthetic and does not measure target application or OS insertion latency."
    public static let enabledReadinessDefinition =
        "first active LiveTranscriptionSnapshot emitted by SessionCoordinator after an exactly correlated, speech-detected hypothesis is accepted by ProvisionalTranscriptReducer for the enabled trial"

    public struct Trial: Sendable, Equatable {
        public let index: Int
        public let livePreviewEnabled: Bool
        public let stopToAuthoritativeInsertionAndHistoryMS: Double
        public let insertionStatus: InsertionStatus
        /// The exact canonical stream summary passed to the live engine's
        /// successful authoritative finish. Disabled trials have no live
        /// finish and therefore report `nil`.
        public let canonicalPCM: LivePCMStreamSummary?

        public init(
            index: Int,
            livePreviewEnabled: Bool,
            stopToAuthoritativeInsertionAndHistoryMS: Double,
            insertionStatus: InsertionStatus,
            canonicalPCM: LivePCMStreamSummary?
        ) {
            self.index = index
            self.livePreviewEnabled = livePreviewEnabled
            self.stopToAuthoritativeInsertionAndHistoryMS = stopToAuthoritativeInsertionAndHistoryMS
            self.insertionStatus = insertionStatus
            self.canonicalPCM = canonicalPCM
        }
    }

    public struct Result: Sendable, Equatable {
        public let definition: String
        public let trials: [Trial]
        public let enabledStopToAuthoritativeInsertionAndHistoryMS: [Double]
        public let disabledStopToAuthoritativeInsertionAndHistoryMS: [Double]
        public let authoritativeFinalOwnershipCount: Int
        public let insertionCommitCount: Int
        public let historyAppendCount: Int
        public let observedLiveRuntimeIdentities: Set<LiveTranscriptionRuntimeIdentity>
        public let languageHints: [String]
        public let trialLivePreviewOrder: [Bool]
        public let publicFixtureSHA256: String
        public let configurationSHA256: String
        public let liveStartTimeout: Duration
        public let enabledReadinessDefinition: String
        public let successfulEnabledReadinessCount: Int
        public let liveFinishAuthoritativeFinalCount: Int
        public let disabledTranscribeAuthoritativeFinalCount: Int
        public let coordinatorFallbackCount: Int

        public init(
            definition: String,
            trials: [Trial],
            enabledStopToAuthoritativeInsertionAndHistoryMS: [Double],
            disabledStopToAuthoritativeInsertionAndHistoryMS: [Double],
            authoritativeFinalOwnershipCount: Int,
            insertionCommitCount: Int,
            historyAppendCount: Int,
            observedLiveRuntimeIdentities: Set<LiveTranscriptionRuntimeIdentity>,
            languageHints: [String],
            trialLivePreviewOrder: [Bool],
            publicFixtureSHA256: String,
            configurationSHA256: String,
            liveStartTimeout: Duration,
            enabledReadinessDefinition: String,
            successfulEnabledReadinessCount: Int,
            liveFinishAuthoritativeFinalCount: Int,
            disabledTranscribeAuthoritativeFinalCount: Int,
            coordinatorFallbackCount: Int
        ) {
            self.definition = definition
            self.trials = trials
            self.enabledStopToAuthoritativeInsertionAndHistoryMS = enabledStopToAuthoritativeInsertionAndHistoryMS
            self.disabledStopToAuthoritativeInsertionAndHistoryMS = disabledStopToAuthoritativeInsertionAndHistoryMS
            self.authoritativeFinalOwnershipCount = authoritativeFinalOwnershipCount
            self.insertionCommitCount = insertionCommitCount
            self.historyAppendCount = historyAppendCount
            self.observedLiveRuntimeIdentities = observedLiveRuntimeIdentities
            self.languageHints = languageHints
            self.trialLivePreviewOrder = trialLivePreviewOrder
            self.publicFixtureSHA256 = publicFixtureSHA256
            self.configurationSHA256 = configurationSHA256
            self.liveStartTimeout = liveStartTimeout
            self.enabledReadinessDefinition = enabledReadinessDefinition
            self.successfulEnabledReadinessCount = successfulEnabledReadinessCount
            self.liveFinishAuthoritativeFinalCount = liveFinishAuthoritativeFinalCount
            self.disabledTranscribeAuthoritativeFinalCount = disabledTranscribeAuthoritativeFinalCount
            self.coordinatorFallbackCount = coordinatorFallbackCount
        }
    }

    public enum BenchmarkError: Error, LocalizedError, Equatable {
        case publicFixtureAttestationRequired
        case invalidTrialCount
        case invalidLanguageHints
        case invalidLiveStartTimeout
        case canonicalWAVUnavailable
        case livePreviewDidNotStart(trialIndex: Int)
        case canonicalFinishSummaryMissingOrDuplicate(trialIndex: Int)
        case canonicalFinishSummaryMismatch(trialIndex: Int)
        case nonCommittingInsertion(trialIndex: Int, status: InsertionStatus)
        case ownershipCountMismatch(finals: Int, insertions: Int, history: Int, trials: Int)
        case finalPathCountMismatch(liveFinishes: Int, transcribes: Int, enabledTrials: Int, disabledTrials: Int)
        case runtimeIdentityCountMismatch(observed: Int)

        public var errorDescription: String? {
            switch self {
            case .publicFixtureAttestationRequired:
                return "The production coordinator benchmark requires an explicit public-audio fixture attestation."
            case .invalidTrialCount:
                return "The alternating trial count must be a positive even number."
            case .invalidLanguageHints:
                return "At least one non-empty language hint is required."
            case .invalidLiveStartTimeout:
                return "The live-readiness timeout must be greater than zero."
            case .canonicalWAVUnavailable:
                return "The public canonical WAV fixture is not a readable regular file."
            case .livePreviewDidNotStart(let trialIndex):
                return "Live preview did not start for enabled trial \(trialIndex)."
            case .canonicalFinishSummaryMissingOrDuplicate(let trialIndex):
                return "Enabled trial \(trialIndex) did not produce exactly one observed canonical finish summary."
            case .canonicalFinishSummaryMismatch(let trialIndex):
                return "Enabled trial \(trialIndex) canonical finish summary did not match the independently parsed public fixture PCM."
            case .nonCommittingInsertion(let trialIndex, let status):
                return "Trial \(trialIndex) did not cross the insertion commit boundary (\(status.rawValue))."
            case .ownershipCountMismatch(let finals, let insertions, let history, let trials):
                return "Production-path ownership mismatch: finals=\(finals), insertions=\(insertions), history=\(history), trials=\(trials)."
            case .finalPathCountMismatch(let liveFinishes, let transcribes, let enabledTrials, let disabledTrials):
                return "Authoritative path mismatch: live finishes=\(liveFinishes)/\(enabledTrials), transcribes=\(transcribes)/\(disabledTrials)."
            case .runtimeIdentityCountMismatch(let observed):
                return "The alternating retained-engine run must observe exactly one runtime identity; observed \(observed)."
            }
        }
    }

    /// Runs alternating enabled/disabled trials against one retained engine.
    ///
    /// `publicFixtureAttested` is deliberately explicit: this benchmark must
    /// never be pointed at a user's private dictation. The source fixture is
    /// opened only for copying and is never returned to `SessionCoordinator`,
    /// which owns and deletes only the per-trial copies.
    public static func run(
        engine: any LiveTranscriptionEngine,
        publicCanonicalWAVURL: URL,
        publicFixtureAttested: Bool,
        alternatingTrialCount: Int,
        languageHints: [String] = ["en-US"],
        liveStartTimeout: Duration = .seconds(5)
    ) async throws -> Result {
        guard publicFixtureAttested else {
            throw BenchmarkError.publicFixtureAttestationRequired
        }
        guard alternatingTrialCount > 0, alternatingTrialCount.isMultiple(of: 2) else {
            throw BenchmarkError.invalidTrialCount
        }
        guard languageHints.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw BenchmarkError.invalidLanguageHints
        }
        guard liveStartTimeout > .zero else {
            throw BenchmarkError.invalidLiveStartTimeout
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: publicCanonicalWAVURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue,
        FileManager.default.isReadableFile(atPath: publicCanonicalWAVURL.path) else {
            throw BenchmarkError.canonicalWAVUnavailable
        }

        let fixture = try await canonicalFixtureIdentity(at: publicCanonicalWAVURL)
        let trialOrder = (0..<alternatingTrialCount).map { $0.isMultiple(of: 2) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-production-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let ledger = ProductionBenchmarkLedger()
        let observedEngine = ProductionBenchmarkObservedEngine(base: engine, ledger: ledger)
        let readiness = ProductionBenchmarkReadinessObserver(ledger: ledger)
        let capture = ProductionBenchmarkFixtureCapture(
            sourceURL: publicCanonicalWAVURL,
            scratchDirectory: scratch
        )
        let history = ProductionBenchmarkHistoryStore(ledger: ledger)
        let insertion = InsertionService(transports: [
            ProductionBenchmarkNoOpTransport(ledger: ledger),
        ])
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: observedEngine,
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: insertion,
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            snippetService: SnippetService(snippets: []),
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            usageRecorder: nil,
            liveSnapshotHandler: { snapshot in
                await readiness.observeAcceptedSnapshot(snapshot)
            },
            liveUnavailableHandler: { _, _ in },
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )

        let appContext = AppContext(
            bundleIdentifier: "com.steno.benchmark.synthetic-target",
            appName: "Production Coordinator Benchmark"
        )
        let clock = ContinuousClock()
        var trials: [Trial] = []

        for index in 0..<alternatingTrialCount {
            let enabled = index.isMultiple(of: 2)
            let sessionID = try await coordinator.startPressToTalk(
                appContext: appContext,
                options: SessionStartOptions(
                    livePreviewEnabled: enabled,
                    nearbyContextEnabled: false,
                    languageHints: languageHints
                )
            )
            if enabled {
                guard await readiness.waitForAcceptedSnapshot(
                    sessionID: sessionID,
                    timeout: liveStartTimeout
                ) else {
                    await coordinator.cancel(sessionID: sessionID)
                    throw BenchmarkError.livePreviewDidNotStart(trialIndex: index)
                }
            }

            let started = clock.now
            try await coordinator.endPressToTalkCapture(sessionID: sessionID)
            let insertionResult = try await coordinator.completePressToTalk(
                sessionID: sessionID,
                languageHints: languageHints
            )
            let elapsed = started.duration(to: clock.now)
            guard insertionResult.status == .inserted else {
                throw BenchmarkError.nonCommittingInsertion(
                    trialIndex: index,
                    status: insertionResult.status
                )
            }
            let observedCanonicalPCM: LivePCMStreamSummary?
            if enabled {
                guard let exactSummary = await observedEngine.consumeSingleFinishSummary(
                    sessionID: sessionID
                ) else {
                    throw BenchmarkError.canonicalFinishSummaryMissingOrDuplicate(trialIndex: index)
                }
                guard exactSummary == fixture.summary else {
                    throw BenchmarkError.canonicalFinishSummaryMismatch(trialIndex: index)
                }
                observedCanonicalPCM = exactSummary
            } else {
                observedCanonicalPCM = nil
            }
            trials.append(Trial(
                index: index,
                livePreviewEnabled: enabled,
                stopToAuthoritativeInsertionAndHistoryMS: milliseconds(elapsed),
                insertionStatus: insertionResult.status,
                canonicalPCM: observedCanonicalPCM
            ))
        }

        let counts = await ledger.snapshot()
        guard counts.authoritativeFinals == alternatingTrialCount,
              counts.insertionCommits == alternatingTrialCount,
              counts.historyAppends == alternatingTrialCount,
              counts.successfulEnabledReadiness == alternatingTrialCount / 2 else {
            throw BenchmarkError.ownershipCountMismatch(
                finals: counts.authoritativeFinals,
                insertions: counts.insertionCommits,
                history: counts.historyAppends,
                trials: alternatingTrialCount
            )
        }
        let enabledTrialCount = alternatingTrialCount / 2
        let disabledTrialCount = alternatingTrialCount / 2
        guard counts.liveFinishFinals == enabledTrialCount,
              counts.transcribeFinals == disabledTrialCount else {
            throw BenchmarkError.finalPathCountMismatch(
                liveFinishes: counts.liveFinishFinals,
                transcribes: counts.transcribeFinals,
                enabledTrials: enabledTrialCount,
                disabledTrials: disabledTrialCount
            )
        }
        guard counts.runtimeIdentities.count == 1 else {
            throw BenchmarkError.runtimeIdentityCountMismatch(
                observed: counts.runtimeIdentities.count
            )
        }
        let configurationSHA256 = try configurationFingerprint(
            fixtureSHA256: fixture.sha256,
            canonicalPCM: fixture.summary,
            trialOrder: trialOrder,
            languageHints: languageHints,
            liveStartTimeout: liveStartTimeout,
            runtimeIdentities: counts.runtimeIdentities
        )

        return Result(
            definition: definition,
            trials: trials,
            enabledStopToAuthoritativeInsertionAndHistoryMS: trials.compactMap {
                $0.livePreviewEnabled ? $0.stopToAuthoritativeInsertionAndHistoryMS : nil
            },
            disabledStopToAuthoritativeInsertionAndHistoryMS: trials.compactMap {
                $0.livePreviewEnabled ? nil : $0.stopToAuthoritativeInsertionAndHistoryMS
            },
            authoritativeFinalOwnershipCount: counts.authoritativeFinals,
            insertionCommitCount: counts.insertionCommits,
            historyAppendCount: counts.historyAppends,
            observedLiveRuntimeIdentities: counts.runtimeIdentities,
            languageHints: languageHints,
            trialLivePreviewOrder: trialOrder,
            publicFixtureSHA256: fixture.sha256,
            configurationSHA256: configurationSHA256,
            liveStartTimeout: liveStartTimeout,
            enabledReadinessDefinition: enabledReadinessDefinition,
            successfulEnabledReadinessCount: counts.successfulEnabledReadiness,
            liveFinishAuthoritativeFinalCount: counts.liveFinishFinals,
            disabledTranscribeAuthoritativeFinalCount: counts.transcribeFinals,
            coordinatorFallbackCount: max(0, counts.transcribeFinals - disabledTrialCount)
        )
    }

    private struct ConfigurationFingerprint: Codable {
        struct Runtime: Codable {
            var protocolVersion: UInt16
            var runtimeIdentifier: String
            var modelIdentifier: String
            var vadIdentifier: String?
        }

        var schemaVersion: Int
        var fixtureSHA256: String
        var sampleCount: UInt64
        var byteCount: UInt64
        var frameCount: UInt64
        var fnv1a64: UInt64
        var trialLivePreviewOrder: [Bool]
        var languageHints: [String]
        var liveStartTimeoutSeconds: Int64
        var liveStartTimeoutAttoseconds: Int64
        var enabledReadinessDefinition: String
        var runtimeIdentities: [Runtime]
        var measurementDefinition: String
    }

    private static func canonicalFixtureIdentity(
        at url: URL
    ) async throws -> (summary: LivePCMStreamSummary, sha256: String) {
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let sessionID = SessionID()
        let streamer = try CanonicalWAVFrameStreamer(
            sessionID: sessionID,
            audioURL: url,
            maximumFramesPerPoll: 64
        )
        var poll = try await streamer.finalize(sessionID: sessionID)
        for _ in 0..<4_096 {
            if case .finalized(let summary) = poll.state {
                return (summary, sha256)
            }
            poll = try await streamer.drain(sessionID: sessionID)
        }
        throw BenchmarkError.canonicalWAVUnavailable
    }

    private static func configurationFingerprint(
        fixtureSHA256: String,
        canonicalPCM: LivePCMStreamSummary,
        trialOrder: [Bool],
        languageHints: [String],
        liveStartTimeout: Duration,
        runtimeIdentities: Set<LiveTranscriptionRuntimeIdentity>
    ) throws -> String {
        let timeoutComponents = liveStartTimeout.components
        let identity = ConfigurationFingerprint(
            schemaVersion: 2,
            fixtureSHA256: fixtureSHA256,
            sampleCount: canonicalPCM.sampleCount,
            byteCount: canonicalPCM.byteCount,
            frameCount: canonicalPCM.frameCount,
            fnv1a64: canonicalPCM.fnv1a64,
            trialLivePreviewOrder: trialOrder,
            languageHints: languageHints,
            liveStartTimeoutSeconds: timeoutComponents.seconds,
            liveStartTimeoutAttoseconds: timeoutComponents.attoseconds,
            enabledReadinessDefinition: enabledReadinessDefinition,
            runtimeIdentities: runtimeIdentities
                .sorted {
                    ($0.protocolVersion, $0.runtimeIdentifier, $0.modelIdentifier, $0.vadIdentifier ?? "")
                        < ($1.protocolVersion, $1.runtimeIdentifier, $1.modelIdentifier, $1.vadIdentifier ?? "")
                }
                .map {
                    ConfigurationFingerprint.Runtime(
                        protocolVersion: $0.protocolVersion,
                        runtimeIdentifier: $0.runtimeIdentifier,
                        modelIdentifier: $0.modelIdentifier,
                        vadIdentifier: $0.vadIdentifier
                    )
                },
            measurementDefinition: definition
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private actor ProductionBenchmarkLedger {
    struct Snapshot: Sendable {
        var authoritativeFinals: Int
        var insertionCommits: Int
        var historyAppends: Int
        var successfulEnabledReadiness: Int
        var liveFinishFinals: Int
        var transcribeFinals: Int
        var runtimeIdentities: Set<LiveTranscriptionRuntimeIdentity>
    }

    private var authoritativeFinals = 0
    private var insertionCommits = 0
    private var historyAppends = 0
    private var successfulEnabledReadiness = 0
    private var liveFinishFinals = 0
    private var transcribeFinals = 0
    private var runtimeIdentities: Set<LiveTranscriptionRuntimeIdentity> = []

    func recordInsertionCommit() { insertionCommits += 1 }
    func recordHistoryAppend() { historyAppends += 1 }
    func recordEnabledReadiness() { successfulEnabledReadiness += 1 }
    func recordLiveFinishFinal() {
        liveFinishFinals += 1
        authoritativeFinals += 1
    }
    func recordTranscribeFinal() {
        transcribeFinals += 1
        authoritativeFinals += 1
    }
    func recordRuntimeIdentity(_ identity: LiveTranscriptionRuntimeIdentity) {
        runtimeIdentities.insert(identity)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            authoritativeFinals: authoritativeFinals,
            insertionCommits: insertionCommits,
            historyAppends: historyAppends,
            successfulEnabledReadiness: successfulEnabledReadiness,
            liveFinishFinals: liveFinishFinals,
            transcribeFinals: transcribeFinals,
            runtimeIdentities: runtimeIdentities
        )
    }
}

private actor ProductionBenchmarkObservedEngine: LiveTranscriptionEngine {
    private let base: any LiveTranscriptionEngine
    private let ledger: ProductionBenchmarkLedger
    private var successfulFinishSummaries: [SessionID: [LivePCMStreamSummary]] = [:]

    init(base: any LiveTranscriptionEngine, ledger: ProductionBenchmarkLedger) {
        self.base = base
        self.ledger = ledger
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        let result = try await base.transcribe(audioURL: audioURL, request: request)
        await ledger.recordTranscribeFinal()
        return result
    }

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        do {
            let session = try await base.startLiveTranscription(
                sessionID: sessionID,
                controllerGeneration: controllerGeneration,
                request: request
            )
            await ledger.recordRuntimeIdentity(session.runtimeIdentity)
            return session
        } catch {
            throw error
        }
    }

    func appendLiveAudio(
        _ frame: LivePCMFrame,
        session: LiveTranscriptionSession
    ) async throws {
        try await base.appendLiveAudio(frame, session: session)
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        try await base.requestLiveHypothesis(
            session: session,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark
        )
    }

    func finishLiveTranscription(
        session: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        let result = try await base.finishLiveTranscription(
            session: session,
            canonicalAudioURL: canonicalAudioURL,
            streamSummary: streamSummary,
            request: request
        )
        successfulFinishSummaries[session.sessionID, default: []].append(streamSummary)
        await ledger.recordLiveFinishFinal()
        return result
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        await base.cancelLiveTranscription(session: session)
    }

    func shutdown() async { await base.shutdown() }
    func unloadRetainedResources() async { await base.unloadRetainedResources() }

    func consumeSingleFinishSummary(sessionID: SessionID) -> LivePCMStreamSummary? {
        guard let summaries = successfulFinishSummaries.removeValue(forKey: sessionID),
              summaries.count == 1 else {
            return nil
        }
        return summaries[0]
    }
}

private actor ProductionBenchmarkReadinessObserver {
    private enum State: Equatable { case ready, timedOut }

    private let ledger: ProductionBenchmarkLedger
    private var states: [SessionID: State] = [:]
    private var waiters: [SessionID: CheckedContinuation<Bool, Never>] = [:]

    init(ledger: ProductionBenchmarkLedger) {
        self.ledger = ledger
    }

    func observeAcceptedSnapshot(_ snapshot: LiveTranscriptionSnapshot) async {
        let sessionID = snapshot.session.sessionID
        guard states[sessionID] == nil,
              snapshot.phase == .active,
              snapshot.lastAcceptedRevision != nil,
              snapshot.counters.acceptedHypotheses > 0,
              !snapshot.provisionalText.isEmpty else {
            return
        }
        states[sessionID] = .ready
        waiters.removeValue(forKey: sessionID)?.resume(returning: true)
        await ledger.recordEnabledReadiness()
    }

    func waitForAcceptedSnapshot(sessionID: SessionID, timeout: Duration) async -> Bool {
        if let state = states[sessionID] {
            if case .ready = state { return true }
            return false
        }
        return await withCheckedContinuation { continuation in
            waiters[sessionID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolveTimeout(sessionID: sessionID)
            }
        }
    }

    private func resolveTimeout(sessionID: SessionID) {
        guard states[sessionID] == nil else { return }
        states[sessionID] = .timedOut
        waiters.removeValue(forKey: sessionID)?.resume(returning: false)
    }
}

private actor ProductionBenchmarkFixtureCapture: AudioCaptureService {
    private let sourceURL: URL
    private let scratchDirectory: URL
    private var copies: [SessionID: URL] = [:]

    init(sourceURL: URL, scratchDirectory: URL) {
        self.sourceURL = sourceURL
        self.scratchDirectory = scratchDirectory
    }

    func beginCapture(sessionID: SessionID) async throws {
        let copyURL = scratchDirectory.appendingPathComponent("\(sessionID.uuidString).wav")
        try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        copies[sessionID] = copyURL
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        copies[sessionID]
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        guard let copyURL = copies.removeValue(forKey: sessionID) else {
            throw LiveContextProductionCoordinatorBenchmark.BenchmarkError.canonicalWAVUnavailable
        }
        return copyURL
    }

    func cancelCapture(sessionID: SessionID) async {
        guard let copyURL = copies.removeValue(forKey: sessionID) else { return }
        try? FileManager.default.removeItem(at: copyURL)
    }
}

private struct ProductionBenchmarkNoOpTransport: InsertionTransport {
    let ledger: ProductionBenchmarkLedger
    let method: InsertionMethod = .direct

    func insert(text: String, target: AppContext) async throws {
        // Deliberately do not retain, hash, log, or inspect either content value.
        _ = text
        _ = target
        await ledger.recordInsertionCommit()
    }
}

private actor ProductionBenchmarkHistoryStore: HistoryStoreProtocol {
    private let ledger: ProductionBenchmarkLedger
    private var entries: [TranscriptEntry] = []

    init(ledger: ProductionBenchmarkLedger) {
        self.ledger = ledger
    }

    func append(entry: TranscriptEntry) async throws {
        entries.insert(entry, at: 0)
        await ledger.recordHistoryAppend()
    }

    func delete(entryID: UUID) async throws {
        entries.removeAll { $0.id == entryID }
    }

    func recent(limit: Int) async -> [TranscriptEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    func search(query: String) async -> [TranscriptEntry] {
        entries.filter {
            $0.rawText.localizedCaseInsensitiveContains(query)
                || $0.cleanText.localizedCaseInsensitiveContains(query)
        }
    }

    func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw HistoryStoreError.missingEntry
        }
        return try await cleanupEngine.cleanup(
            raw: RawTranscript(text: entry.rawText, durationMS: entry.durationMS),
            profile: profile,
            lexicon: lexicon
        )
    }

    func pasteLast() async throws -> TranscriptEntry? { entries.first }
}
