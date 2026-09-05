import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Steno
@testable import StenoKit
import StenoBenchmarkCore

@Suite("Live-context hosted evidence", .serialized)
@MainActor
struct LiveContextHostedEvidenceTests {
    @Test("Production components produce aggregate-only hosted evidence")
    func produceHostedEvidence() async throws {
        let environment = HostedEvidenceEnvironment.current
        guard let destination = environment.destination else {
            #expect(throws: HostedEvidenceError.missingDestination) {
                try environment.requireDestination()
            }
            return
        }
        let git = try environment.requireGitState()
        let observation = try HostedWrapperObservation.begin(
            at: environment.requireNetworkControlDirectory()
        )
        do {
            let measurement = try await HostedEvidenceProducer.measure(
                sourceRoot: environment.sourceRoot,
                language: environment.language,
                trialCount: environment.trialCount,
                gitSHA: git.sha,
                hostEnvironment: environment.receiptEnvironment
            )

            #expect(measurement.failures.isEmpty)
            #expect(measurement.receipt.failureCount == measurement.failures.count)
            #expect(measurement.receipt.failureCount == measurement.receipt.failures.count)
            #expect(measurement.receipt.skipCount == 0)
            #expect(measurement.receipt.skips.isEmpty)

            var receipt = measurement.receipt
            receipt.treeIsDirty = git.isDirty
            receipt.configurationIdentitySHA256 = LiveContextReceiptManifest.hostedConfigurationSHA256(
                gitSHA: receipt.gitSHA,
                sourceManifestSHA256: receipt.sourceManifestSHA256,
                language: environment.language,
                trialCount: environment.trialCount
            )
            try HostedEvidenceProducer.write(receipt, to: destination)
            try observation.finish()
        } catch {
            try? observation.finish()
            throw error
        }
    }
}

private enum HostedEvidenceError: Error, Equatable {
    case missingSourceRoot
    case missingDestination
    case invalidDestination
    case invalidTrialCount
    case gitCommandFailed
    case missingNetworkControlDirectory
    case measurementFailed
    case timedOut
}

private struct HostedEvidenceEnvironment {
    var sourceRoot: URL
    var destination: URL?
    var language: String
    var trialCount: Int
    var gitSHA: String?
    var treeIsDirty: Bool?
    var networkControlDirectory: URL?

    var receiptEnvironment: LiveContextHostedReceipt.Environment {
        .init(
            hardwareModelIdentifier: hostedHardwareModelIdentifier(),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: hostedArchitecture(),
            trialCount: trialCount,
            language: language
        )
    }

    static var current: HostedEvidenceEnvironment {
        let values = ProcessInfo.processInfo.environment
        let sourcePath = values["STENO_LIVE_CONTEXT_SOURCE_ROOT"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        let destination = values["STENO_LIVE_CONTEXT_HOSTED_RECEIPT"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let trialCount = Int(values["STENO_LIVE_CONTEXT_TRIAL_COUNT"] ?? "10") ?? 0
        let gitSHA = values["STENO_LIVE_CONTEXT_GIT_SHA"]
        let networkControlDirectory = values["STENO_LIVE_CONTEXT_NETWORK_CONTROL_DIR"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let treeIsDirty: Bool?
        switch values["STENO_LIVE_CONTEXT_TREE_DIRTY"] {
        case "true": treeIsDirty = true
        case "false": treeIsDirty = false
        default: treeIsDirty = nil
        }
        return HostedEvidenceEnvironment(
            sourceRoot: URL(fileURLWithPath: sourcePath).standardizedFileURL,
            destination: destination,
            language: values["STENO_LIVE_CONTEXT_LANGUAGE"] ?? "en",
            trialCount: trialCount,
            gitSHA: gitSHA,
            treeIsDirty: treeIsDirty,
            networkControlDirectory: networkControlDirectory
        )
    }

    func requireDestination() throws -> URL {
        guard let destination else { throw HostedEvidenceError.missingDestination }
        return destination
    }

    func requireGitState() throws -> (sha: String, isDirty: Bool) {
        guard let gitSHA,
              gitSHA.count == 40,
              gitSHA.allSatisfy(\.isHexDigit),
              let treeIsDirty else {
            throw HostedEvidenceError.gitCommandFailed
        }
        return (gitSHA.lowercased(), treeIsDirty)
    }

    func requireNetworkControlDirectory() throws -> URL {
        guard let networkControlDirectory else {
            throw HostedEvidenceError.missingNetworkControlDirectory
        }
        let path = networkControlDirectory.path
        guard path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            throw HostedEvidenceError.invalidDestination
        }
        return networkControlDirectory
    }
}

private struct HostedWrapperObservation {
    static let testIdentifier =
        "StenoTests.LiveContextHostedEvidenceTests.produceHostedEvidence"

    let directory: URL
    let processID: Int32
    let startMilliseconds: Int64

    static func begin(at directory: URL) throws -> HostedWrapperObservation {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw HostedEvidenceError.missingNetworkControlDirectory
        }
        let observation = HostedWrapperObservation(
            directory: directory,
            processID: getpid(),
            startMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        )
        try observation.writeMarker(
            named: "observation-start.json",
            endMilliseconds: nil
        )
        return observation
    }

    func finish() throws {
        try writeMarker(
            named: "observation-end.json",
            endMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        )
    }

    private func writeMarker(named name: String, endMilliseconds: Int64?) throws {
        var payload: [String: Any] = [
            "testIdentifier": Self.testIdentifier,
            "hostedTestProcessID": processID,
            "observationStartUnixMilliseconds": startMilliseconds,
        ]
        if let endMilliseconds {
            payload["observationEndUnixMilliseconds"] = endMilliseconds
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

@MainActor
private enum HostedEvidenceProducer {
    struct Measurement {
        var receipt: LiveContextHostedReceipt
        var failures: [String]
    }

    static func measure(
        sourceRoot: URL,
        language: String,
        trialCount: Int,
        gitSHA: String,
        hostEnvironment: LiveContextHostedReceipt.Environment
    ) async throws -> Measurement {
        guard FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent(".git").path) else {
            throw HostedEvidenceError.missingSourceRoot
        }
        guard trialCount >= 10,
              trialCount.isMultiple(of: 2),
              !language.isEmpty else {
            throw HostedEvidenceError.invalidTrialCount
        }

        try await HostedURLLoadingSpy.begin()
        defer { HostedURLLoadingSpy.end() }

        let sourceManifest = try LiveContextReceiptManifest.hostedSourceSHA256(
            sourceRootPath: sourceRoot.path
        )
        let sentinels = HostedSentinels(gitSHA: gitSHA)
        let controllerListening = try await measureControllerListening(
            trialCount: trialCount
        )
        let overlay = try await measureOverlay(sentinels: sentinels)
        let lifecycle = measureReducerLifecycle()
        let ax = try await measureAccessibility(sentinels: sentinels)
        let coordinator = try await measureCoordinator(
            trialCount: trialCount,
            language: language,
            sentinels: sentinels
        )
        let staticAudit = try measureStaticAudit(
            sourceRoot: sourceRoot,
            sourceManifest: sourceManifest
        )
        let urlLoading = HostedURLLoadingSpy.snapshot()

        let privacySnapshot = await coordinator.ledger.snapshot()
        let overlayMainActorWork = LiveLatencyDistribution.summarize(overlay.renderMS)
        let overlayThresholds = LiveContextHostedReceipt.Thresholds()
        let overlayMaximumUpdatesPerSecond = hostedMaximumBurstUpdatesPerSecond(
            overlay.renderedTimestampsMS
        )
        var failures: [String] = []
        if overlay.acceptedCount != overlay.renderedCount + overlay.coalescedCount {
            failures.append("overlay-accounting")
        }
        if controllerListening.elapsedMilliseconds.count != trialCount
            || controllerListening.presentationViolations != 0
            || controllerListening.coordinatorStartCount != trialCount {
            failures.append("controller-listening-acknowledgement")
        }
        if overlay.renderedTimestampsMS.count < 2 || overlay.maximumQueueDepth != 1 {
            failures.append("overlay-measurement")
        }
        if overlayMainActorWork.count < 5
            || (overlayMainActorWork.p99MS ?? .infinity)
                > overlayThresholds.overlayMainActorP99MS {
            failures.append("overlay-mainactor-work")
        }
        if overlayMainActorWork.count != overlay.renderedCount {
            failures.append("overlay-work-render-binding")
        }
        if overlay.acceptedCount <= overlay.renderedCount
            || overlay.renderedCount != overlay.renderedTimestampsMS.count
            || overlay.coalescedCount <= 0 {
            failures.append("overlay-render-accounting")
        }
        if !overlayMaximumUpdatesPerSecond.isFinite
            || overlayMaximumUpdatesPerSecond
                > overlayThresholds.maximumVisibleUpdatesPerSecond {
            failures.append("overlay-visible-cadence")
        }
        if overlay.retainedTextLeaks != 0 { failures.append("overlay-retention") }
        if overlay.controlLifecycleViolations != 0 { failures.append("overlay-lifecycle") }
        if lifecycle.randomizedSessions != 1_000
            || lifecycle.rapidRestarts != 250
            || lifecycle.staleAccepted != 0 {
            failures.append("reducer-lifecycle")
        }
        if ax.targetTransitions != 10_000 || ax.staleTargetsAccepted != 0 {
            failures.append("target-lifecycle")
        }
        if coordinator.provisionalSideEffects != 0
            || coordinator.duplicateFinalInsertions != 0
            || coordinator.speechPreviewRenderedControlCount == 0
            || coordinator.noSpeechFalseDisplays != 0
            || coordinator.contractViolations != 0
            || coordinator.maximumFinishCallsPerSession != 1
            || coordinator.secondFinalInferenceAttempts != 0 {
            failures.append("coordinator-correctness")
        }
        if privacySnapshot.totalLeaks != 0
            || privacySnapshot.liveCallbackProvisionalObservations == 0
            || privacySnapshot.unavailableCallbackObservations == 0 {
            failures.append("privacy-sinks")
        }
        if staticAudit.totalFindings != 0 { failures.append("static-audit") }
        if urlLoading.selfTestHits != 1 || urlLoading.productionPathHits != 0 {
            failures.append("url-loading-network-observation")
        }
        if hostEnvironment.hardwareModelIdentifier == "unavailable"
            || hostEnvironment.architecture == "unsupported" {
            failures.append("host-environment-identity")
        }

        let failureRows = failures.map {
            LiveContextFailureRow(id: $0, reasonCode: $0)
        }
        let receipt = LiveContextHostedReceipt(
            generatedAt: ISO8601DateFormatter.hosted.string(from: Date()),
            gitSHA: gitSHA,
            treeIsDirty: true,
            sourceManifestSHA256: sourceManifest,
            failureCount: failureRows.count,
            skipCount: 0,
            failures: failureRows,
            skips: [],
            environment: hostEnvironment,
            environmentIdentitySHA256: LiveContextReceiptManifest.hostedEnvironmentSHA256(
                hostEnvironment
            ),
            syntheticCoordinatorListeningAcknowledgementDiagnostic: .summarize(
                controllerListening.elapsedMilliseconds
            ),
            overlayMainActorWork: overlayMainActorWork,
            renderedUpdateTimestampsMS: overlay.renderedTimestampsMS,
            syntheticCoordinatorStopToInsertionEnabledDiagnostic: .summarize(
                coordinator.enabledStopMS
            ),
            syntheticCoordinatorStopToInsertionDisabledControlDiagnostic: .summarize(
                coordinator.disabledStopMS
            ),
            acceptedPreviewCount: overlay.acceptedCount,
            renderedPreviewCount: overlay.renderedCount,
            maximumQueueDepth: overlay.maximumQueueDepth,
            coalescedPreviewCount: overlay.coalescedCount,
            trialOrder: coordinator.trialOrder,
            configurationIdentitySHA256: String(repeating: "0", count: 64),
            lifecycle: .init(
                randomizedSessions: lifecycle.randomizedSessions,
                rapidCancelRestartCases: lifecycle.rapidRestarts,
                targetTransitions: ax.targetTransitions,
                authoritativeFinishCalls: coordinator.finishCalls,
                maximumAuthoritativeFinishCallsPerSession: coordinator.maximumFinishCallsPerSession,
                coordinatorSecondFinalInferenceAttempts: coordinator.secondFinalInferenceAttempts,
                finalInsertionCount: coordinator.finalInsertions,
                expectedFinalInsertionCount: trialCount
            ),
            correctness: .init(
                provisionalSideEffects: coordinator.provisionalSideEffects,
                duplicateFinalInsertions: coordinator.duplicateFinalInsertions,
                staleEventsAccepted: lifecycle.staleAccepted,
                speechPreviewRenderedControlCount: coordinator.speechPreviewRenderedControlCount,
                noSpeechFalseDisplays: coordinator.noSpeechFalseDisplays
            ),
            privacy: .init(
                canaryDerivationDefinition:
                    LiveContextReceiptManifest.hostedPrivacyCanaryDerivationDefinition,
                baseCanarySHA256: hostedSHA256(Data(sentinels.base.utf8)),
                provisionalCanarySHA256: hostedSHA256(Data(sentinels.provisional.utf8)),
                contextCanarySHA256: hostedSHA256(Data(sentinels.context.utf8)),
                snippetExpansionCanarySHA256: hostedSHA256(
                    Data(sentinels.snippetExpansion.utf8)
                ),
                provisionalCanaryInjectionCount: coordinator.provisionalCanaryInjectionCount,
                contextCanaryInjectionCount: coordinator.contextCanaryInjectionCount,
                snippetCanaryInjectionCount: coordinator.snippetCanaryInjectionCount,
                scannedSurfaceCount: privacySnapshot.scannedSurfaceCount,
                requestLeaks: privacySnapshot.requestLeaks,
                cleanupLeaks: privacySnapshot.cleanupLeaks,
                historyLeaks: privacySnapshot.historyLeaks,
                insertionLeaks: privacySnapshot.insertionLeaks,
                clipboardRecoveryLeaks: privacySnapshot.clipboardRecoveryLeaks,
                analyticsLeaks: privacySnapshot.analyticsLeaks,
                configuredSnippetTrapCount: coordinator.configuredSnippetTrapCount,
                snippetTrapActivations: privacySnapshot.snippetTrapActivations,
                liveCallbackProvisionalObservations: privacySnapshot.liveCallbackProvisionalObservations,
                liveCallbackUnexpectedContextLeaks: privacySnapshot.liveCallbackUnexpectedContextLeaks,
                unavailableCallbackObservations: privacySnapshot.unavailableCallbackObservations,
                overlayRetainedTextLeaks: overlay.retainedTextLeaks,
                injectedURLProtocolSelfTestHits: urlLoading.selfTestHits,
                injectedURLProtocolProductionPathHits: urlLoading.productionPathHits,
                secureFieldContextReadRequests: ax.secureFieldContextReadRequests,
                maximumAXUTF16ReadPerSide: ax.maximumUTF16ReadPerSide,
                maximumAXGraphemesPerSide: ax.maximumGraphemesPerSide,
                maximumAXContextBytes: ax.maximumContextBytes
            ),
            staticAudit: staticAudit
        )
        return Measurement(receipt: receipt, failures: failures)
    }

    static func write(_ receipt: LiveContextHostedReceipt, to destination: URL) throws {
        let path = destination.standardizedFileURL.path
        guard path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else {
            throw HostedEvidenceError.invalidDestination
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        guard try LiveContextArtifactIO.validatePrivacy(of: data) else {
            throw HostedEvidenceError.measurementFailed
        }
        try data.write(to: destination, options: .atomic)
    }
}

private func hostedSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension ISO8601DateFormatter {
    @MainActor
    static let hosted: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct HostedSentinels: Sendable {
    let base: String
    let provisional: String
    let context: String
    let snippetExpansion: String

    init(gitSHA: String) {
        let canaries = LiveContextReceiptManifest.hostedPrivacyCanaries(gitSHA: gitSHA)
        precondition(canaries.count == 4)
        base = canaries[0]
        provisional = canaries[1]
        context = canaries[2]
        snippetExpansion = canaries[3]
    }

    var all: [String] { [base, provisional, context, snippetExpansion] }

    /// Counts distinct injected-canary occurrences. Longer derived canaries
    /// claim their byte range first so their shared base is not double-counted.
    func leakCount(in data: Data) -> Int {
        var claimedRanges: [Range<Data.Index>] = []
        var count = 0
        for sentinel in all.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            let needle = Data(sentinel.utf8)
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let range = data.range(
                      of: needle,
                      options: [],
                      in: searchStart..<data.endIndex
                  ) {
                if !claimedRanges.contains(where: { $0.overlaps(range) }) {
                    claimedRanges.append(range)
                    count += 1
                }
                searchStart = range.upperBound
            }
        }
        return count
    }
}

private func hostedArchitecture() -> String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "unsupported"
    #endif
}

private func hostedHardwareModelIdentifier() -> String {
    var byteCount = 0
    guard sysctlbyname("hw.model", nil, &byteCount, nil, 0) == 0,
          byteCount > 1 else {
        return "unavailable"
    }
    var bytes = [CChar](repeating: 0, count: byteCount)
    let result = bytes.withUnsafeMutableBufferPointer { buffer in
        sysctlbyname("hw.model", buffer.baseAddress, &byteCount, nil, 0)
    }
    guard result == 0 else {
        return "unavailable"
    }
    let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: utf8, as: UTF8.self)
}

private final class HostedURLLoadingSpy: URLProtocol, @unchecked Sendable {
    struct Snapshot {
        var selfTestHits: Int
        var productionPathHits: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var selfTestHits = 0
    nonisolated(unsafe) private static var productionPathHits = 0
    private static let selfTestHost = "steno-hosted-self-test.invalid"

    static func begin() async throws {
        reset()
        guard URLProtocol.registerClass(Self.self) else {
            throw HostedEvidenceError.measurementFailed
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://\(selfTestHost)/positive-control") else {
            throw HostedEvidenceError.measurementFailed
        }
        let (_, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 204,
              snapshot().selfTestHits == 1 else {
            throw HostedEvidenceError.measurementFailed
        }
    }

    private static func reset() {
        lock.lock()
        selfTestHits = 0
        productionPathHits = 0
        lock.unlock()
    }

    static func end() {
        URLProtocol.unregisterClass(Self.self)
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            selfTestHits: selfTestHits,
            productionPathHits: productionPathHits
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        if request.url?.host == Self.selfTestHost {
            Self.selfTestHits += 1
        } else {
            Self.productionPathHits += 1
        }
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 204,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "0"]
              ) else {
            client?.urlProtocol(self, didFailWithError: HostedEvidenceError.measurementFailed)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct HostedControllerListeningMeasurement {
    var elapsedMilliseconds: [Double]
    var presentationViolations: Int
    var coordinatorStartCount: Int
}

@MainActor
private func measureControllerListening(
    trialCount: Int
) async throws -> HostedControllerListeningMeasurement {
    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    presenter.prepareWindow()
    let coordinator = HostedControllerCoordinator()
    let controller = makeTestDictationController(
        hotkey: HostedControllerHotkeyService(),
        overlay: presenter,
        mediaInterruption: HostedControllerMediaInterruptionService(),
        coordinator: coordinator
    )
    controller.preferences.dictation.showLiveTranscriptWhileRecording = true
    controller.preferences.media.pauseDuringPressToTalk = false

    var startedAt: TimeInterval?
    var elapsedMilliseconds: [Double] = []
    var presentationViolations = 0
    presenter.setHostedEvidenceHandler { event in
        guard case .listeningPresented = event else { return }
        guard let start = startedAt else {
            presentationViolations += 1
            return
        }
        elapsedMilliseconds.append(max(
            0,
            (ProcessInfo.processInfo.systemUptime - start) * 1_000
        ))
        startedAt = nil
    }

    do {
        for trial in 0..<trialCount {
            startedAt = ProcessInfo.processInfo.systemUptime
            controller.pressToTalkStart()
            try await waitForHostedCondition {
                elapsedMilliseconds.count == trial + 1
            }
            if startedAt != nil { presentationViolations += 1 }
            try await waitForHostedCondition {
                await coordinator.startCount() == trial + 1
            }
            controller.cancelActiveRecording()
            try await waitForHostedCondition {
                controller.recordingLifecycleState == .idle
                    && !controller.lifecycleDiagnostics.isCleanupInProgress
            }
        }
    } catch {
        presenter.setHostedEvidenceHandler(nil)
        await controller.teardownAndWait()
        throw error
    }

    presenter.setHostedEvidenceHandler(nil)
    await controller.teardownAndWait()
    return HostedControllerListeningMeasurement(
        elapsedMilliseconds: elapsedMilliseconds,
        presentationViolations: presentationViolations,
        coordinatorStartCount: await coordinator.startCount()
    )
}

private actor HostedControllerCoordinator: DictationSessionCoordinating {
    private var starts = 0

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        _ = appContext
        starts += 1
        return SessionID()
    }

    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions
    ) async throws -> SessionID {
        _ = appContext
        _ = options
        starts += 1
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        _ = sessionID
    }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        _ = sessionID
        _ = languageHints
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {
        _ = sessionID
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {
        _ = enabled
    }

    func startCount() -> Int {
        starts
    }
}

@MainActor
private final class HostedControllerHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16? = 79

    func start() {}
    func stop() {}
}

@MainActor
private final class HostedControllerMediaInterruptionService: MediaInterruptionService {
    func beginInterruption() async -> MediaInterruptionToken? { nil }
    func endInterruption(token: MediaInterruptionToken) async {
        _ = token
    }
}

@MainActor
private final class HostedOverlayRecorder {
    var listeningMS: [Double] = []
    var renderMS: [Double] = []
    var renderTimestampsMS: [Double] = []
    var acceptedCount = 0
    var renderedCount = 0
    var maximumQueueDepth = 0
    var coalescedCount = 0

    func record(_ event: WaveformOverlayHostedEvidenceEvent) {
        switch event {
        case .listeningPresented(let elapsed):
            listeningMS.append(elapsed)
        case .previewAccepted(let depth, let totalCoalesced):
            acceptedCount += 1
            maximumQueueDepth = max(maximumQueueDepth, depth)
            coalescedCount = Int(totalCoalesced)
        case .previewRendered(let elapsed, let timestamp, _, _):
            renderedCount += 1
            renderMS.append(elapsed)
            renderTimestampsMS.append(timestamp)
        case .previewCleared:
            break
        }
    }
}

private struct HostedOverlayMeasurement {
    var listeningMS: [Double]
    var renderMS: [Double]
    var renderedTimestampsMS: [Double]
    var acceptedCount: Int
    var renderedCount: Int
    var maximumQueueDepth: Int
    var coalescedCount: Int
    var retainedTextLeaks: Int
    var controlLifecycleViolations: Int
}

private func hostedMaximumBurstUpdatesPerSecond(_ timestampsMS: [Double]) -> Double {
    guard timestampsMS.count >= 2 else { return .infinity }
    return zip(timestampsMS, timestampsMS.dropFirst()).reduce(0) { maximum, pair in
        let gap = pair.1 - pair.0
        guard gap > 0, gap.isFinite else { return .infinity }
        return max(maximum, 1_000 / gap)
    }
}

@MainActor
private func measureOverlay(sentinels: HostedSentinels) async throws -> HostedOverlayMeasurement {
    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    let recorder = HostedOverlayRecorder()
    presenter.setHostedEvidenceHandler { recorder.record($0) }
    presenter.setLiveTranscriptEnabled(true)

    for _ in 0..<5 {
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        presenter.hide()
        try await Task.sleep(for: .milliseconds(10))
    }

    presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
    let session = LiveTranscriptionSession(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        runtimeGeneration: 1,
        runtimeIdentity: .init(
            protocolVersion: 2,
            runtimeIdentifier: "hosted-runtime",
            modelIdentifier: "hosted-model",
            vadIdentifier: nil,
            currentASRContextCount: 1,
            peakASRContextCount: 1
        )
    )
    var revision = 0
    for expectedRenderCount in 1...5 {
        for _ in 0..<4 {
            revision += 1
            presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                session: session,
                stablePrefix: revision == 20 ? sentinels.provisional : "",
                revisableTail: revision == 20 ? "" : "draft",
                lastAcceptedRevision: UInt64(revision),
                decodedAudioWatermark: UInt64(revision * 4_000),
                emittedAtMonotonicNanos: UInt64(revision) * 1_000_000
            ))
        }
        try await waitForHostedCondition {
            recorder.renderedCount >= expectedRenderCount
        }
    }
    let firstTimestamp = recorder.renderTimestampsMS.first ?? 0
    let relativeTimestamps = recorder.renderTimestampsMS.map { max(0, $0 - firstTimestamp) }
    presenter.show(state: .transcribing)
    let terminalIsEmpty = presenter.hostedEvidenceTextSurfacesAreEmpty()
    presenter.hide()
    let hiddenIsEmpty = presenter.hostedEvidenceTextSurfacesAreEmpty()
    presenter.setHostedEvidenceHandler(nil)
    let lifecycle = try await measureOverlayLifecycleRegression(sentinels: sentinels)

    return HostedOverlayMeasurement(
        listeningMS: Array(recorder.listeningMS.prefix(5)),
        renderMS: recorder.renderMS,
        renderedTimestampsMS: relativeTimestamps,
        acceptedCount: recorder.acceptedCount,
        renderedCount: recorder.renderedCount,
        maximumQueueDepth: recorder.maximumQueueDepth,
        coalescedCount: recorder.coalescedCount,
        retainedTextLeaks: (terminalIsEmpty && hiddenIsEmpty ? 0 : 1)
            + lifecycle.retainedTextLeaks,
        controlLifecycleViolations: lifecycle.controlViolations
    )
}

@MainActor
private final class HostedOverlayEpochRecorder {
    private(set) var rendered: [(sessionID: UUID, revision: UInt64?)] = []

    func record(_ event: WaveformOverlayHostedEvidenceEvent) {
        guard case .previewRendered(_, _, let sessionID, let revision) = event else {
            return
        }
        rendered.append((sessionID, revision))
    }
}

private struct HostedOverlayLifecycleMeasurement {
    var retainedTextLeaks: Int
    var controlViolations: Int
}

@MainActor
private func measureOverlayLifecycleRegression(
    sentinels: HostedSentinels
) async throws -> HostedOverlayLifecycleMeasurement {
    let terminalStates: [OverlayState] = [
        .transcribing,
        .inserted,
        .copiedOnly,
        .failure(message: "Hosted failure"),
        .noSpeechDetected,
    ]
    var retainedTextLeaks = 0
    var controlViolations = 0
    for (index, terminal) in terminalStates.enumerated() {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        let recorder = HostedOverlayEpochRecorder()
        presenter.setHostedEvidenceHandler { recorder.record($0) }
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        if !presenter.hostedEvidenceHasOneTranscriptSurface()
            || !presenter.hostedEvidenceUsesPreferredTypography()
            || !presenter.hostedEvidenceRecordingPresentationIsImmediateAndStatic()
            || !presenter.hostedEvidenceTextSurfacesAreEmpty() {
            controlViolations += 1
        }
        let session = makeHostedLiveSession(runtimeGeneration: UInt64(index + 100))
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: session,
            stablePrefix: sentinels.provisional,
            revisableTail: "",
            lastAcceptedRevision: 1,
            decodedAudioWatermark: 4_000,
            emittedAtMonotonicNanos: 1_000_000
        ))
        try await waitForHostedCondition { !recorder.rendered.isEmpty }
        presenter.show(state: terminal)
        if !presenter.hostedEvidenceTextSurfacesAreEmpty() {
            retainedTextLeaks += 1
        }
        if !presenter.hostedEvidenceTerminalPresentationIsCompact() {
            controlViolations += 1
        }
        presenter.hide()
        if !presenter.hostedEvidenceTextSurfacesAreEmpty() {
            retainedTextLeaks += 1
        }
        presenter.setHostedEvidenceHandler(nil)
    }

    do {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        let session = makeHostedLiveSession(runtimeGeneration: 900)
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: session,
            stablePrefix: "These words ",
            revisableTail: "flow as one sentence.",
            lastAcceptedRevision: 1,
            decodedAudioWatermark: 4_000,
            emittedAtMonotonicNanos: 1_000_000
        ))
        if presenter.hostedEvidenceVisibleTranscript() != "These words flow as one sentence." {
            controlViolations += 1
        }
        presenter.showLiveTranscriptUnavailable()
        let forbiddenCopy = [
            "Live preview will appear here",
            "Listening locally",
            "Draft",
            "Live preview unavailable",
            "Recording continues",
            "final transcript remains authoritative",
        ]
        if !presenter.hostedEvidenceUsesCompactUnavailableShell()
            || forbiddenCopy.contains(where: { forbidden in
                presenter.hostedEvidenceUserFacingStrings().contains(where: {
                    $0.localizedCaseInsensitiveContains(forbidden)
                })
            }) {
            controlViolations += 1
        }
        presenter.hide()
    }

    do {
        let preferredBodyPointSize: CGFloat = 52
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.setLiveTranscriptEnabled(true)
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: true,
            preferredBodyPointSize: preferredBodyPointSize
        ))
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        let provisional = Array(repeating: "Earlier context stays exact. ", count: 12)
            .joined()
            + "The newest sentence remains completely visible."
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: makeHostedLiveSession(runtimeGeneration: 901),
            stablePrefix: provisional,
            revisableTail: "",
            lastAcceptedRevision: 1,
            decodedAudioWatermark: 4_000,
            emittedAtMonotonicNanos: 1_000_000
        ))
        let visible = presenter.hostedEvidenceVisibleTranscript()
        if visible.isEmpty
            || !provisional.hasSuffix(visible)
            || !presenter.hostedEvidenceLargeTextTranscriptIsFullyVisible(
                preferredBodyPointSize: preferredBodyPointSize
            )
            || !presenter.hostedEvidenceAccessibilityAppearanceMatchesPreferences() {
            controlViolations += 1
        }

        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false,
            preferredBodyPointSize: 13
        ))
        if !presenter.hostedEvidenceAccessibilityAppearanceMatchesPreferences() {
            controlViolations += 1
        }
        presenter.hide()
    }

    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    let recorder = HostedOverlayEpochRecorder()
    presenter.setHostedEvidenceHandler { recorder.record($0) }
    presenter.setLiveTranscriptEnabled(true)
    presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
    let oldSession = makeHostedLiveSession(runtimeGeneration: 1_000)
    presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
        session: oldSession,
        stablePrefix: "old",
        revisableTail: "",
        lastAcceptedRevision: 1,
        decodedAudioWatermark: 4_000,
        emittedAtMonotonicNanos: 1_000_000
    ))
    presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
        session: oldSession,
        stablePrefix: "old pending",
        revisableTail: "",
        lastAcceptedRevision: 2,
        decodedAudioWatermark: 8_000,
        emittedAtMonotonicNanos: 2_000_000
    ))
    presenter.show(state: .inserted)

    presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
    let newSession = makeHostedLiveSession(runtimeGeneration: 1_001)
    presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
        session: newSession,
        stablePrefix: sentinels.provisional,
        revisableTail: "new",
        lastAcceptedRevision: 1,
        decodedAudioWatermark: 4_000,
        emittedAtMonotonicNanos: 3_000_000
    ))
    presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
        session: newSession,
        stablePrefix: sentinels.provisional,
        revisableTail: "newest",
        lastAcceptedRevision: 2,
        decodedAudioWatermark: 8_000,
        emittedAtMonotonicNanos: 4_000_000
    ))
    try await waitForHostedCondition {
        recorder.rendered.contains {
            $0.sessionID == newSession.sessionID && $0.revision == 2
        }
    }
    try await Task.sleep(for: .milliseconds(500))
    if !presenter.hostedEvidenceControlsMatchListeningState() {
        controlViolations += 1
    }
    if recorder.rendered.contains(where: {
        $0.sessionID == oldSession.sessionID && $0.revision == 2
    }) {
        controlViolations += 1
    }
    presenter.hide()
    if !presenter.hostedEvidenceTextSurfacesAreEmpty() {
        retainedTextLeaks += 1
    }
    presenter.setHostedEvidenceHandler(nil)
    return HostedOverlayLifecycleMeasurement(
        retainedTextLeaks: retainedTextLeaks,
        controlViolations: controlViolations
    )
}

private struct HostedReducerMeasurement {
    var randomizedSessions: Int
    var rapidRestarts: Int
    var staleAccepted: Int
}

private func measureReducerLifecycle() -> HostedReducerMeasurement {
    var random = HostedLCG(seed: 0x5EED_CAFE)
    var staleAccepted = 0
    for _ in 0..<1_000 {
        let session = makeHostedLiveSession(runtimeGeneration: random.next())
        var reducer = ProvisionalTranscriptReducer(session: session)
        for revision in 1...3 {
            _ = reducer.reduce(makeHostedEvent(
                session: session,
                revision: UInt64(revision),
                watermark: UInt64(revision * 4_000),
                timestamp: UInt64(revision) * 600_000_000,
                text: "stable words draft \(random.next() % 17)"
            ))
        }
        let terminalKind: LiveTranscriptionEventKind = switch random.next() % 3 {
        case 0: .authoritativeFinal
        case 1: .cancelled
        default: .runtimeUnloaded
        }
        _ = reducer.reduce(makeHostedEvent(
            kind: terminalKind,
            session: session,
            revision: 4,
            watermark: 16_000,
            timestamp: 2_400_000_000,
            text: terminalKind == .authoritativeFinal ? "final" : ""
        ))
        if reducer.reduce(makeHostedEvent(
            session: session,
            revision: 5,
            watermark: 20_000,
            timestamp: 3_000_000_000,
            text: "late"
        )).outcome == .accepted {
            staleAccepted += 1
        }
    }

    for _ in 0..<250 {
        let oldSession = makeHostedLiveSession(runtimeGeneration: random.next())
        var oldReducer = ProvisionalTranscriptReducer(session: oldSession)
        _ = oldReducer.reduce(makeHostedEvent(
            kind: .cancelled,
            session: oldSession,
            revision: 1,
            watermark: 0,
            timestamp: 1,
            text: ""
        ))
        let newSession = makeHostedLiveSession(runtimeGeneration: random.next())
        var newReducer = ProvisionalTranscriptReducer(session: newSession)
        if newReducer.reduce(makeHostedEvent(
            session: oldSession,
            revision: 2,
            watermark: 4_000,
            timestamp: 2,
            text: "stale restart"
        )).outcome == .accepted {
            staleAccepted += 1
        }
    }
    return HostedReducerMeasurement(
        randomizedSessions: 1_000,
        rapidRestarts: 250,
        staleAccepted: staleAccepted
    )
}

private struct HostedLCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func makeHostedLiveSession(runtimeGeneration: UInt64) -> LiveTranscriptionSession {
    LiveTranscriptionSession(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        runtimeGeneration: runtimeGeneration,
        runtimeIdentity: .init(
            protocolVersion: 2,
            runtimeIdentifier: "hosted-runtime",
            modelIdentifier: "hosted-model",
            vadIdentifier: nil,
            currentASRContextCount: 1,
            peakASRContextCount: 1
        )
    )
}

private func makeHostedEvent(
    kind: LiveTranscriptionEventKind = .hypothesis,
    session: LiveTranscriptionSession,
    revision: UInt64,
    watermark: UInt64,
    timestamp: UInt64,
    text: String
) -> LiveTranscriptionEvent {
    LiveTranscriptionEvent(
        kind: kind,
        session: session,
        revision: revision,
        decodedAudioWatermark: watermark,
        emittedAtMonotonicNanos: timestamp,
        fullHypothesisText: text,
        speechEvidence: .speechDetected
    )
}

private enum HostedPrivacySurface: Sendable, Equatable {
    case request
    case cleanup
    case history
    case insertion
    case clipboardRecovery
    case analytics
}

private struct HostedPrivacySnapshot: Sendable {
    var scannedSurfaceCount = 0
    var requestLeaks = 0
    var cleanupLeaks = 0
    var historyLeaks = 0
    var insertionLeaks = 0
    var clipboardRecoveryLeaks = 0
    var analyticsLeaks = 0
    var snippetTrapActivations = 0
    var liveCallbackProvisionalObservations = 0
    var liveCallbackUnexpectedContextLeaks = 0
    var unavailableCallbackObservations = 0

    var totalLeaks: Int {
        requestLeaks + cleanupLeaks + historyLeaks + insertionLeaks
            + clipboardRecoveryLeaks + analyticsLeaks + snippetTrapActivations
            + liveCallbackUnexpectedContextLeaks
    }
}

private actor HostedPrivacyLedger {
    private let sentinels: HostedSentinels
    private var state = HostedPrivacySnapshot()

    init(sentinels: HostedSentinels) {
        self.sentinels = sentinels
    }

    func record(_ surface: HostedPrivacySurface, data: Data) {
        state.scannedSurfaceCount += 1
        let leaks = sentinels.leakCount(in: data)
        switch surface {
        case .request: state.requestLeaks += leaks
        case .cleanup: state.cleanupLeaks += leaks
        case .history: state.historyLeaks += leaks
        case .insertion: state.insertionLeaks += leaks
        case .clipboardRecovery: state.clipboardRecoveryLeaks += leaks
        case .analytics: state.analyticsLeaks += leaks
        }
        if surface == .cleanup {
            state.snippetTrapActivations += LiveContextSentinelScanner.leakCount(
                sentinel: sentinels.snippetExpansion,
                surfaces: [data]
            )
        }
    }

    func recordRequest(_ request: TranscriptionRequest) throws {
        record(.request, data: try JSONEncoder().encode(request))
    }

    func recordLiveCallback(_ snapshot: LiveTranscriptionSnapshot) {
        state.scannedSurfaceCount += 1
        let data = Data(snapshot.displayText.utf8)
        state.liveCallbackProvisionalObservations += LiveContextSentinelScanner.leakCount(
            sentinel: sentinels.provisional,
            surfaces: [data]
        )
        for unexpected in [sentinels.context, sentinels.snippetExpansion] {
            state.liveCallbackUnexpectedContextLeaks += LiveContextSentinelScanner.leakCount(
                sentinel: unexpected,
                surfaces: [data]
            )
        }
    }

    func recordUnavailableCallback() {
        state.unavailableCallbackObservations += 1
    }

    func snapshot() -> HostedPrivacySnapshot { state }
}

private struct HostedAXMeasurement {
    var targetTransitions: Int
    var staleTargetsAccepted: Int
    var secureFieldContextReadRequests: Int
    var maximumUTF16ReadPerSide: Int
    var maximumGraphemesPerSide: Int
    var maximumContextBytes: Int
}

private final class HostedAXClient: MacAccessibilityClient, @unchecked Sendable {
    struct Metrics: Sendable {
        var captureCount: Int
        var stringReadCount: Int
        var maximumUTF16Read: Int
        var contextCanaryReadSurfaces: Int
    }

    private struct State {
        var document: String
        var selection: EditorTextSelection
        var elementIdentifier: String
        var isProtected: Bool
        var captureCount = 0
        var stringReadCount = 0
        var maximumUTF16Read = 0
        var contextCanaryReadSurfaces = 0
    }

    private let lock = NSLock()
    private let bundleIdentifier: String
    private let contextCanary: String
    private let window = MacAXElementReference(testIdentifier: "hosted-window")
    private var state: State

    init(
        bundleIdentifier: String,
        document: String,
        cursor: Int,
        elementIdentifier: String = "hosted-editor",
        isProtected: Bool = false,
        contextCanary: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.contextCanary = contextCanary
        state = State(
            document: document,
            selection: EditorTextSelection(location: cursor, length: 0),
            elementIdentifier: elementIdentifier,
            isProtected: isProtected
        )
    }

    func isProcessTrusted() -> Bool { true }

    func captureFocusedTarget(
        expectedBundleIdentifier: String
    ) throws -> MacAXTargetSnapshot {
        try lock.withLock {
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
                element: MacAXElementReference(testIdentifier: state.elementIdentifier),
                role: "AXTextArea",
                subrole: state.isProtected ? "AXSecureTextField" : nil,
                isProtected: state.isProtected,
                selection: state.selection,
                characterCount: (state.document as NSString).length
            )
        }
    }

    func string(
        for range: EditorTextSelection,
        in element: MacAXElementReference
    ) throws -> String {
        _ = element
        return try lock.withLock {
            let document = state.document as NSString
            guard range.location >= 0,
                  range.length >= 0,
                  range.location + range.length <= document.length else {
                throw EditorTargetUnavailableReason.parameterizedTextUnavailable
            }
            state.stringReadCount += 1
            state.maximumUTF16Read = max(state.maximumUTF16Read, range.length)
            let value = document.substring(
                with: NSRange(location: range.location, length: range.length)
            )
            if value.contains(contextCanary) {
                state.contextCanaryReadSurfaces += 1
            }
            return value
        }
    }

    func isSelectedTextSettable(in element: MacAXElementReference) throws -> Bool {
        _ = element
        return true
    }

    func setSelectedText(
        _ text: String,
        in element: MacAXElementReference
    ) -> MacAXSetTextResult {
        _ = text
        _ = element
        return .inserted
    }

    func setElementIdentifier(_ identifier: String) {
        lock.withLock { state.elementIdentifier = identifier }
    }

    func metrics() -> Metrics {
        lock.withLock {
            Metrics(
                captureCount: state.captureCount,
                stringReadCount: state.stringReadCount,
                maximumUTF16Read: state.maximumUTF16Read,
                contextCanaryReadSurfaces: state.contextCanaryReadSurfaces
            )
        }
    }
}

private func makeHostedAXDocument(
    contextCanary: String
) -> (text: String, cursor: Int) {
    let prefix = String(repeating: "p", count: 600)
        + contextCanary
        + String(repeating: "q", count: 50)
    let text = prefix + String(repeating: "s", count: 700)
    return (text, (prefix as NSString).length)
}

private func measureAccessibility(
    sentinels: HostedSentinels
) async throws -> HostedAXMeasurement {
    let app = AppContext(
        bundleIdentifier: "com.steno.hosted-evidence",
        appName: "Hosted Evidence"
    )
    let document = makeHostedAXDocument(contextCanary: sentinels.context)
    let boundsClient = HostedAXClient(
        bundleIdentifier: app.bundleIdentifier,
        document: document.text,
        cursor: document.cursor,
        contextCanary: sentinels.context
    )
    let boundsHandle = try EditorTargetHandle.capture(
        target: app,
        client: boundsClient
    ).get()
    let contextResult = await boundsHandle.context()
    guard case .available(let context) = contextResult else {
        throw HostedEvidenceError.measurementFailed
    }
    let serializedContext = try JSONSerialization.data(withJSONObject: [
        "leadingText": context.prefix,
        "trailingText": context.suffix,
    ])

    let secureClient = HostedAXClient(
        bundleIdentifier: app.bundleIdentifier,
        document: sentinels.context,
        cursor: 0,
        isProtected: true,
        contextCanary: sentinels.context
    )
    let secureReadsBefore = secureClient.metrics().stringReadCount
    let secureResult = EditorTargetHandle.capture(target: app, client: secureClient)
    guard case .failure(.secureOrProtectedElement) = secureResult else {
        throw HostedEvidenceError.measurementFailed
    }
    let secureReads = secureClient.metrics().stringReadCount - secureReadsBefore

    let transitionClient = HostedAXClient(
        bundleIdentifier: app.bundleIdentifier,
        document: "hosted",
        cursor: 6,
        contextCanary: sentinels.context
    )
    var transitions = 0
    var staleAccepted = 0
    for index in 0..<10_000 {
        transitionClient.setElementIdentifier("editor-\(index)")
        let handle = try EditorTargetHandle.capture(
            target: app,
            client: transitionClient
        ).get()
        transitionClient.setElementIdentifier("editor-\(index + 1)")
        if case .success = await handle.revalidate() {
            staleAccepted += 1
        }

        let authorization = InsertionCommitAuthorization()
        let owner = InsertionCommitLease()
        let rejectedOwner = InsertionCommitLease()
        guard authorization.acquire(owner) else {
            throw HostedEvidenceError.measurementFailed
        }
        authorization.seal(owner)
        if authorization.acquire(rejectedOwner) {
            staleAccepted += 1
        }
        transitions += 1
    }

    let boundsMetrics = boundsClient.metrics()
    return HostedAXMeasurement(
        targetTransitions: transitions,
        staleTargetsAccepted: staleAccepted,
        secureFieldContextReadRequests: secureReads,
        maximumUTF16ReadPerSide: boundsMetrics.maximumUTF16Read,
        maximumGraphemesPerSide: max(context.prefix.count, context.suffix.count),
        maximumContextBytes: serializedContext.count
    )
}

private actor HostedSyntheticCapture: AudioCaptureService {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        _ = sessionID
        return url
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        return url
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
        try? FileManager.default.removeItem(at: url)
    }
}

private struct HostedEngineMetrics: Sendable {
    var successfulLiveStarts: Int
    var appendedFrames: Int
    var hypothesisCalls: Int
    var provisionalEmissions: Int
    var finishCalls: Int
    var transcribeCalls: Int
    var secondFinalInferenceAttempts: Int
}

private actor HostedLiveEngine: LiveTranscriptionEngine {
    private let ledger: HostedPrivacyLedger
    private let provisionalText: String
    private let finalText: String
    private let speechEvidence: LiveTranscriptionSpeechEvidence
    private let failStart: Bool
    private let finishShouldThrow: Bool
    private var successfulLiveStarts = 0
    private var appendedFrames = 0
    private var hypothesisCalls = 0
    private var provisionalEmissions = 0
    private var finishCalls = 0
    private var transcribeCalls = 0
    private var secondFinalInferenceAttempts = 0

    init(
        ledger: HostedPrivacyLedger,
        provisionalText: String,
        finalText: String = "Hosted authoritative final",
        speechEvidence: LiveTranscriptionSpeechEvidence = .speechDetected,
        failStart: Bool = false,
        finishShouldThrow: Bool = false
    ) {
        self.ledger = ledger
        self.provisionalText = provisionalText
        self.finalText = finalText
        self.speechEvidence = speechEvidence
        self.failStart = failStart
        self.finishShouldThrow = finishShouldThrow
    }

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        try await ledger.recordRequest(request)
        if failStart {
            throw HostedEvidenceError.measurementFailed
        }
        successfulLiveStarts += 1
        return LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: UInt64(successfulLiveStarts),
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "hosted-synthetic-engine",
                modelIdentifier: "hosted-synthetic-model",
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
        appendedFrames += 1
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        hypothesisCalls += 1
        provisionalEmissions += 1
        return LiveTranscriptionEvent(
            session: session,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark,
            emittedAtMonotonicNanos: revision * 1_000_000,
            fullHypothesisText: provisionalText,
            speechEvidence: speechEvidence
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
        _ = streamSummary
        try await ledger.recordRequest(request)
        finishCalls += 1
        if finishShouldThrow {
            throw HostedEvidenceError.measurementFailed
        }
        return RawTranscript(text: finalText, durationMS: 500)
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        _ = session
    }

    func transcribe(
        audioURL: URL,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        _ = audioURL
        try await ledger.recordRequest(request)
        transcribeCalls += 1
        if successfulLiveStarts > 0 {
            secondFinalInferenceAttempts += 1
        }
        return RawTranscript(text: finalText, durationMS: 500)
    }

    func metrics() -> HostedEngineMetrics {
        HostedEngineMetrics(
            successfulLiveStarts: successfulLiveStarts,
            appendedFrames: appendedFrames,
            hypothesisCalls: hypothesisCalls,
            provisionalEmissions: provisionalEmissions,
            finishCalls: finishCalls,
            transcribeCalls: transcribeCalls,
            secondFinalInferenceAttempts: secondFinalInferenceAttempts
        )
    }
}

private actor HostedCleanup: CleanupEngine {
    private let ledger: HostedPrivacyLedger
    private var callCount = 0

    init(ledger: HostedPrivacyLedger) {
        self.ledger = ledger
    }

    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        _ = profile
        _ = lexicon
        callCount += 1
        await ledger.record(.cleanup, data: Data(raw.text.utf8))
        return CleanTranscript(text: raw.text)
    }

    func calls() -> Int { callCount }
}

private struct HostedInsertionCounts: Sendable {
    var attempts: Int
    var committed: Int
}

private actor HostedInsertion: InsertionServiceProtocol {
    private let ledger: HostedPrivacyLedger
    private var attempts = 0
    private var committed = 0

    init(ledger: HostedPrivacyLedger) {
        self.ledger = ledger
    }

    func insert(text: String, target: AppContext) async -> InsertResult {
        _ = target
        attempts += 1
        await ledger.record(.insertion, data: Data(text.utf8))
        committed += 1
        return InsertResult(status: .inserted, method: .direct, insertedText: text)
    }

    func insert(
        text: String,
        target: AppContext,
        editorTarget: EditorTargetHandle?,
        clipboardRecoveryText: String,
        commitAuthorization: InsertionCommitAuthorization
    ) async -> InsertResult {
        _ = target
        attempts += 1
        if let editorTarget, case .failure = await editorTarget.revalidate() {
            return InsertResult(
                status: .failed,
                method: .none,
                insertedText: text,
                errorMessage: "Hosted target changed."
            )
        }
        let lease = InsertionCommitLease()
        guard commitAuthorization.acquire(lease) else {
            return InsertResult(
                status: .failed,
                method: .none,
                insertedText: text,
                errorMessage: "Hosted insertion authorization rejected."
            )
        }
        await ledger.record(.insertion, data: Data(text.utf8))
        await ledger.record(
            .clipboardRecovery,
            data: Data(clipboardRecoveryText.utf8)
        )
        committed += 1
        commitAuthorization.seal(lease)
        return InsertResult(
            status: .inserted,
            method: .accessibility,
            insertedText: text
        )
    }

    func counts() -> HostedInsertionCounts {
        HostedInsertionCounts(attempts: attempts, committed: committed)
    }
}

private actor HostedHistory: HistoryStoreProtocol {
    private let ledger: HostedPrivacyLedger
    private var entries: [TranscriptEntry] = []

    init(ledger: HostedPrivacyLedger) {
        self.ledger = ledger
    }

    func append(entry: TranscriptEntry) async throws {
        await ledger.record(.history, data: try JSONEncoder().encode(entry))
        entries.append(entry)
    }

    func delete(entryID: UUID) async throws {
        entries.removeAll { $0.id == entryID }
    }

    func recent(limit: Int) async -> [TranscriptEntry] {
        Array(entries.suffix(max(0, limit)))
    }

    func search(query: String) async -> [TranscriptEntry] {
        entries.filter { $0.cleanText.contains(query) }
    }

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
        throw HostedEvidenceError.measurementFailed
    }

    func pasteLast() async throws -> TranscriptEntry? { entries.last }
    func count() -> Int { entries.count }
}

private actor HostedUsageRecorder: UsageAnalyticsRecording {
    private let ledger: HostedPrivacyLedger
    private var events: [UsageEvent] = []

    init(ledger: HostedPrivacyLedger) {
        self.ledger = ledger
    }

    func record(event: UsageEvent) async throws {
        await ledger.record(.analytics, data: try JSONEncoder().encode(event))
        events.append(event)
    }

    func count() -> Int { events.count }
}

private actor HostedClipboard: ClipboardService {
    private let ledger: HostedPrivacyLedger
    private var writes = 0

    init(ledger: HostedPrivacyLedger) {
        self.ledger = ledger
    }

    func setString(_ text: String) async throws {
        await ledger.record(.clipboardRecovery, data: Data(text.utf8))
        writes += 1
    }

    func count() -> Int { writes }
}

private struct HostedCoordinatorMeasurement {
    var ledger: HostedPrivacyLedger
    var enabledStopMS: [Double]
    var disabledStopMS: [Double]
    var trialOrder: [LiveContextTrialMode]
    var provisionalSideEffects: Int
    var duplicateFinalInsertions: Int
    var speechPreviewRenderedControlCount: Int
    var noSpeechFalseDisplays: Int
    var contractViolations: Int
    var finishCalls: Int
    var maximumFinishCallsPerSession: Int
    var secondFinalInferenceAttempts: Int
    var finalInsertions: Int
    var provisionalCanaryInjectionCount: Int
    var contextCanaryInjectionCount: Int
    var snippetCanaryInjectionCount: Int
    var configuredSnippetTrapCount: Int
}

private func hostedSinkCount(
    cleanup: HostedCleanup,
    insertion: HostedInsertion,
    history: HostedHistory,
    usage: HostedUsageRecorder
) async -> Int {
    let cleanupCount = await cleanup.calls()
    let insertionCount = await insertion.counts().committed
    let historyCount = await history.count()
    let usageCount = await usage.count()
    return cleanupCount + insertionCount + historyCount + usageCount
}

@MainActor
private func measureCoordinator(
    trialCount: Int,
    language: String,
    sentinels: HostedSentinels
) async throws -> HostedCoordinatorMeasurement {
    let ledger = HostedPrivacyLedger(sentinels: sentinels)
    // Exercise automatic continuation through a production-allowlisted
    // ordinary-prose surface. The injected AX client supplies matching
    // TextEdit metadata; unsupported and protected surfaces are measured
    // separately by measureAccessibility.
    let app = AppContext(
        bundleIdentifier: "com.apple.TextEdit",
        appName: "TextEdit"
    )
    var enabledStopMS: [Double] = []
    var disabledStopMS: [Double] = []
    var trialOrder: [LiveContextTrialMode] = []
    var provisionalSideEffects = 0
    var duplicateFinalInsertions = 0
    var speechPreviewRenderedControlCount = 0
    var noSpeechFalseDisplays = 0
    var contractViolations = 0
    var finishCalls = 0
    var maximumFinishCallsPerSession = 0
    var secondFinalInferenceAttempts = 0
    var finalInsertions = 0
    var provisionalCanaryInjectionCount = 0
    var contextCanaryInjectionCount = 0
    var snippetCanaryInjectionCount = 0
    var configuredSnippetTrapCount = 0

    for index in 0..<trialCount {
        let mode: LiveContextTrialMode = index.isMultiple(of: 2) ? .enabled : .disabled
        trialOrder.append(mode)
        let audioURL = try makeHostedWAV(silent: false)
        let capture = HostedSyntheticCapture(url: audioURL)
        let engine = HostedLiveEngine(
            ledger: ledger,
            provisionalText: sentinels.provisional
        )
        let cleanup = HostedCleanup(ledger: ledger)
        let insertion = HostedInsertion(ledger: ledger)
        let history = HostedHistory(ledger: ledger)
        let usage = HostedUsageRecorder(ledger: ledger)
        let snippets = SnippetService(snippets: [
            Snippet(trigger: sentinels.base, expansion: sentinels.snippetExpansion),
        ])
        let snippetCount = await snippets.list().count
        configuredSnippetTrapCount += snippetCount
        let document = makeHostedAXDocument(contextCanary: sentinels.context)
        let ax = HostedAXClient(
            bundleIdentifier: app.bundleIdentifier,
            document: document.text,
            cursor: document.cursor,
            contextCanary: sentinels.context
        )
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: engine,
            cleanupEngine: cleanup,
            insertionService: insertion,
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            snippetService: snippets,
            usageRecorder: usage,
            liveSnapshotHandler: { snapshot in
                await ledger.recordLiveCallback(snapshot)
            },
            liveUnavailableHandler: { _, _ in
                await ledger.recordUnavailableCallback()
            },
            editorTargetCapture: { target in
                EditorTargetHandle.capture(target: target, client: ax)
            }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(
                controllerGeneration: UUID(),
                livePreviewEnabled: mode == .enabled,
                nearbyContextEnabled: true,
                languageHints: [language]
            )
        )
        if mode == .enabled {
            try await waitForHostedCondition {
                await engine.metrics().hypothesisCalls > 0
            }
        }
        provisionalSideEffects += await hostedSinkCount(
            cleanup: cleanup,
            insertion: insertion,
            history: history,
            usage: usage
        )

        let stopStart = ProcessInfo.processInfo.systemUptime
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        let result = try await coordinator.completePressToTalk(
            sessionID: sessionID,
            languageHints: [language]
        )
        let stopElapsed = max(
            0,
            (ProcessInfo.processInfo.systemUptime - stopStart) * 1_000
        )
        if mode == .enabled {
            enabledStopMS.append(stopElapsed)
        } else {
            disabledStopMS.append(stopElapsed)
        }

        let engineMetrics = await engine.metrics()
        let insertionCounts = await insertion.counts()
        let historyCount = await history.count()
        let usageCount = await usage.count()
        finishCalls += engineMetrics.finishCalls
        maximumFinishCallsPerSession = max(
            maximumFinishCallsPerSession,
            engineMetrics.finishCalls
        )
        secondFinalInferenceAttempts += engineMetrics.secondFinalInferenceAttempts
        finalInsertions += insertionCounts.committed
        duplicateFinalInsertions += max(0, insertionCounts.committed - 1)
        let axMetrics = ax.metrics()
        provisionalCanaryInjectionCount += engineMetrics.provisionalEmissions
        contextCanaryInjectionCount += axMetrics.contextCanaryReadSurfaces
        snippetCanaryInjectionCount += snippetCount

        if result.status != .inserted
            || insertionCounts.attempts != 1
            || insertionCounts.committed != 1
            || historyCount != 1
            || usageCount != 1 {
            contractViolations += 1
        }
        if mode == .enabled {
            if engineMetrics.finishCalls != 1 || engineMetrics.transcribeCalls != 0 {
                contractViolations += 1
            }
        } else if engineMetrics.finishCalls != 0 || engineMetrics.transcribeCalls != 1 {
            contractViolations += 1
        }
    }

    // Positive control: a speech-authorized coordinator callback must pass
    // through the production presenter and reach the actual render observer.
    do {
        let audioURL = try makeHostedWAV(silent: false)
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        let recorder = HostedOverlayEpochRecorder()
        presenter.setHostedEvidenceHandler { recorder.record($0) }
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        let engine = HostedLiveEngine(
            ledger: ledger,
            provisionalText: sentinels.provisional,
            finalText: "",
            speechEvidence: .speechDetected
        )
        let coordinator = SessionCoordinator(
            captureService: HostedSyntheticCapture(url: audioURL),
            transcriptionEngine: engine,
            cleanupEngine: HostedCleanup(ledger: ledger),
            insertionService: HostedInsertion(ledger: ledger),
            historyStore: HostedHistory(ledger: ledger),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            usageRecorder: HostedUsageRecorder(ledger: ledger),
            liveSnapshotHandler: { snapshot in
                await ledger.recordLiveCallback(snapshot)
                await presenter.updateLiveTranscript(snapshot)
            }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(
                livePreviewEnabled: true,
                nearbyContextEnabled: false,
                languageHints: [language]
            )
        )
        try await waitForHostedCondition {
            await engine.metrics().hypothesisCalls > 0
        }
        try await waitForHostedCondition { !recorder.rendered.isEmpty }
        speechPreviewRenderedControlCount += recorder.rendered.count
        let metrics = await engine.metrics()
        provisionalCanaryInjectionCount += metrics.provisionalEmissions
        await coordinator.cancel(sessionID: sessionID)
        presenter.hide()
        presenter.setHostedEvidenceHandler(nil)
    }

    // A digital-silence capture must produce zero actual production-presenter
    // render callbacks, and its empty authoritative result must reach no sink.
    do {
        let audioURL = try makeHostedWAV(silent: true)
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        let recorder = HostedOverlayEpochRecorder()
        presenter.setHostedEvidenceHandler { recorder.record($0) }
        presenter.setLiveTranscriptEnabled(true)
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        let engine = HostedLiveEngine(
            ledger: ledger,
            provisionalText: sentinels.provisional,
            finalText: "",
            speechEvidence: .noSpeechDetected
        )
        let cleanup = HostedCleanup(ledger: ledger)
        let insertion = HostedInsertion(ledger: ledger)
        let history = HostedHistory(ledger: ledger)
        let usage = HostedUsageRecorder(ledger: ledger)
        let snippets = SnippetService(snippets: [
            Snippet(trigger: sentinels.base, expansion: sentinels.snippetExpansion),
        ])
        let snippetCount = await snippets.list().count
        configuredSnippetTrapCount += snippetCount
        let coordinator = SessionCoordinator(
            captureService: HostedSyntheticCapture(url: audioURL),
            transcriptionEngine: engine,
            cleanupEngine: cleanup,
            insertionService: insertion,
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            snippetService: snippets,
            usageRecorder: usage,
            liveSnapshotHandler: { snapshot in
                await ledger.recordLiveCallback(snapshot)
                await presenter.updateLiveTranscript(snapshot)
            }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(
                livePreviewEnabled: true,
                nearbyContextEnabled: false,
                languageHints: [language]
            )
        )
        try await waitForHostedCondition {
            await engine.metrics().hypothesisCalls > 0
        }
        try await Task.sleep(for: .milliseconds(400))
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        let result = try await coordinator.completePressToTalk(
            sessionID: sessionID,
            languageHints: [language]
        )
        noSpeechFalseDisplays += recorder.rendered.count
        let metrics = await engine.metrics()
        finishCalls += metrics.finishCalls
        maximumFinishCallsPerSession = max(maximumFinishCallsPerSession, metrics.finishCalls)
        secondFinalInferenceAttempts += metrics.secondFinalInferenceAttempts
        provisionalCanaryInjectionCount += metrics.provisionalEmissions
        snippetCanaryInjectionCount += snippetCount
        let noSpeechSinkCount = await hostedSinkCount(
            cleanup: cleanup,
            insertion: insertion,
            history: history,
            usage: usage
        )
        if result.status != .noSpeech || noSpeechSinkCount != 0 {
            contractViolations += 1
        }
        presenter.hide()
        presenter.setHostedEvidenceHandler(nil)
    }

    // Live setup failure must be reported explicitly while capture remains
    // cancellable and no final/sink work is fabricated.
    do {
        let audioURL = try makeHostedWAV(silent: false)
        let engine = HostedLiveEngine(
            ledger: ledger,
            provisionalText: sentinels.provisional,
            failStart: true
        )
        let snippets = SnippetService(snippets: [
            Snippet(trigger: sentinels.base, expansion: sentinels.snippetExpansion),
        ])
        let snippetCount = await snippets.list().count
        configuredSnippetTrapCount += snippetCount
        let unavailableBefore = await ledger.snapshot().unavailableCallbackObservations
        let coordinator = SessionCoordinator(
            captureService: HostedSyntheticCapture(url: audioURL),
            transcriptionEngine: engine,
            cleanupEngine: HostedCleanup(ledger: ledger),
            insertionService: HostedInsertion(ledger: ledger),
            historyStore: HostedHistory(ledger: ledger),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            snippetService: snippets,
            usageRecorder: HostedUsageRecorder(ledger: ledger),
            liveUnavailableHandler: { _, _ in
                await ledger.recordUnavailableCallback()
            }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(
                livePreviewEnabled: true,
                nearbyContextEnabled: false,
                languageHints: [language]
            )
        )
        try await waitForHostedCondition {
            await ledger.snapshot().unavailableCallbackObservations > unavailableBefore
        }
        await coordinator.cancel(sessionID: sessionID)
        snippetCanaryInjectionCount += snippetCount
    }

    // Once a live session owns authoritative finish, a thrown finish cannot
    // cause the coordinator to start a second final transcription.
    do {
        let audioURL = try makeHostedWAV(silent: false)
        let engine = HostedLiveEngine(
            ledger: ledger,
            provisionalText: sentinels.provisional,
            finishShouldThrow: true
        )
        let cleanup = HostedCleanup(ledger: ledger)
        let insertion = HostedInsertion(ledger: ledger)
        let history = HostedHistory(ledger: ledger)
        let usage = HostedUsageRecorder(ledger: ledger)
        let snippets = SnippetService(snippets: [
            Snippet(trigger: sentinels.base, expansion: sentinels.snippetExpansion),
        ])
        let snippetCount = await snippets.list().count
        configuredSnippetTrapCount += snippetCount
        let coordinator = SessionCoordinator(
            captureService: HostedSyntheticCapture(url: audioURL),
            transcriptionEngine: engine,
            cleanupEngine: cleanup,
            insertionService: insertion,
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            snippetService: snippets,
            usageRecorder: usage
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: app,
            options: SessionStartOptions(
                livePreviewEnabled: true,
                nearbyContextEnabled: false,
                languageHints: [language]
            )
        )
        try await waitForHostedCondition {
            await engine.metrics().appendedFrames > 0
        }
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        do {
            _ = try await coordinator.completePressToTalk(
                sessionID: sessionID,
                languageHints: [language]
            )
            contractViolations += 1
        } catch {
            // Expected: the measurement is the absence of a second inference.
        }
        let metrics = await engine.metrics()
        finishCalls += metrics.finishCalls
        maximumFinishCallsPerSession = max(maximumFinishCallsPerSession, metrics.finishCalls)
        secondFinalInferenceAttempts += metrics.secondFinalInferenceAttempts
        provisionalCanaryInjectionCount += metrics.provisionalEmissions
        snippetCanaryInjectionCount += snippetCount
        let failedFinishSinkCount = await hostedSinkCount(
            cleanup: cleanup,
            insertion: insertion,
            history: history,
            usage: usage
        )
        if metrics.finishCalls != 1
            || metrics.transcribeCalls != 0
            || failedFinishSinkCount != 0 {
            contractViolations += 1
        }
    }

    // Exercise the production clipboard recovery transport without activation
    // or paste callbacks; the only external boundary is the injected spy.
    do {
        let clipboard = HostedClipboard(ledger: ledger)
        let service = InsertionService(transports: [
            ClipboardInsertionTransport(clipboard: clipboard),
        ])
        let result = await service.insert(
            text: "Hosted authoritative final",
            target: app,
            editorTarget: nil,
            clipboardRecoveryText: "Hosted authoritative final",
            commitAuthorization: InsertionCommitAuthorization()
        )
        let clipboardWriteCount = await clipboard.count()
        if result.status != .copiedOnly || clipboardWriteCount != 1 {
            contractViolations += 1
        }
    }

    guard contextCanaryInjectionCount > 0 else {
        throw HostedEvidenceError.measurementFailed
    }

    return HostedCoordinatorMeasurement(
        ledger: ledger,
        enabledStopMS: enabledStopMS,
        disabledStopMS: disabledStopMS,
        trialOrder: trialOrder,
        provisionalSideEffects: provisionalSideEffects,
        duplicateFinalInsertions: duplicateFinalInsertions,
        speechPreviewRenderedControlCount: speechPreviewRenderedControlCount,
        noSpeechFalseDisplays: noSpeechFalseDisplays,
        contractViolations: contractViolations,
        finishCalls: finishCalls,
        maximumFinishCallsPerSession: maximumFinishCallsPerSession,
        secondFinalInferenceAttempts: secondFinalInferenceAttempts,
        finalInsertions: finalInsertions,
        provisionalCanaryInjectionCount: provisionalCanaryInjectionCount,
        contextCanaryInjectionCount: contextCanaryInjectionCount,
        snippetCanaryInjectionCount: snippetCanaryInjectionCount,
        configuredSnippetTrapCount: configuredSnippetTrapCount
    )
}

private extension LiveContextHostedReceipt.StaticAudit {
    var totalFindings: Int {
        featureLogInvocationSourceFindings
            + crashMetadataSinkReferenceSourceFindings
            + ephemeralPersistenceSourceFindings
            + ephemeralFilenameDiagnosticSourceFindings
            + prohibitedNetworkAPISourceFindings
    }
}

private func measureStaticAudit(
    sourceRoot: URL,
    sourceManifest: String
) throws -> LiveContextHostedReceipt.StaticAudit {
    var sources: [(path: String, text: String)] = []
    for relativePath in LiveContextReceiptManifest.hostedProductionRelativePaths {
        let url = sourceRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostedEvidenceError.measurementFailed
        }
        sources.append((relativePath, text))
    }

    var featureLogInvocationSourceFindings = 0
    var crashMetadataSinkReferenceSourceFindings = 0
    var ephemeralPersistenceSourceFindings = 0
    var ephemeralFilenameDiagnosticSourceFindings = 0
    var prohibitedNetworkAPISourceFindings = 0

    let crashSinkTokens = [
        "SentrySDK", "Crashlytics", "MXCrashDiagnostic", "MetricKit",
        "NSExceptionHandler", "crashMetadata",
    ]
    let prohibitedNetworkTokens = [
        "import Network", "NWListener", "NWConnection", "URLSession",
        "URLRequest", "Darwin.socket", "getaddrinfo", "WebSocket",
        "http://", "https://",
    ]
    let ephemeralNames = [
        "fullHypothesisText", "stablePrefix", "revisableTail",
        "EditorContextSnapshot", "ContinuationContextSnapshot",
    ]
    let persistenceTokens = [
        "UserDefaults", "JSONEncoder", "PropertyListEncoder", "write(to:",
        "append(entry:", "record(event:", "storageURL",
    ]
    let filenameDiagnosticTokens = [
        "lastPathComponent", "deletingPathExtension", "appendingPathComponent",
        "metadata", "diagnostic", "errorDescription", "localizedDescription",
    ]

    for source in sources {
        featureLogInvocationSourceFindings += featureLogInvocationSourceFindingCount(in: source.text)
        for token in crashSinkTokens {
            crashMetadataSinkReferenceSourceFindings += exactOccurrenceCount(
                token,
                in: source.text
            )
        }
        for token in prohibitedNetworkTokens {
            prohibitedNetworkAPISourceFindings += exactOccurrenceCount(
                token,
                in: source.text
            )
        }

        for rawLine in source.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { continue }
            let mentionsEphemeral = ephemeralNames.contains { line.contains($0) }
            if mentionsEphemeral, persistenceTokens.contains(where: { line.contains($0) }) {
                ephemeralPersistenceSourceFindings += 1
            }
            if mentionsEphemeral, filenameDiagnosticTokens.contains(where: { line.contains($0) }) {
                ephemeralFilenameDiagnosticSourceFindings += 1
            }
        }

        if source.path.hasSuffix("Models/LiveTranscription.swift") {
            for typeName in [
                "LiveTranscriptionSession", "LiveTranscriptionEvent",
                "LiveTranscriptionSnapshot",
            ] where declarationConformsToCodable(typeName, in: source.text) {
                ephemeralPersistenceSourceFindings += 1
            }
        }
        if source.path.hasSuffix("Models/EditorTarget.swift"),
           declarationConformsToCodable("EditorContextSnapshot", in: source.text) {
            ephemeralPersistenceSourceFindings += 1
        }
    }

    let coordinatorSource = sources.first {
        $0.path.hasSuffix("Services/SessionCoordinator.swift")
    }?.text ?? ""
    if !coordinatorSource.contains("audioURL: nil") {
        ephemeralFilenameDiagnosticSourceFindings += 1
    }

    return LiveContextHostedReceipt.StaticAudit(
        boundHostedSourceManifestSHA256: sourceManifest,
        auditedFileCount: sources.count,
        featureLogInvocationSourceAuditPerformed: true,
        featureLogInvocationSourceFindings: featureLogInvocationSourceFindings,
        crashMetadataSinkReferenceSourceAuditPerformed: true,
        crashMetadataSinkReferenceSourceFindings: crashMetadataSinkReferenceSourceFindings,
        ephemeralPersistenceSourceAuditPerformed: true,
        ephemeralPersistenceSourceFindings: ephemeralPersistenceSourceFindings,
        ephemeralFilenameDiagnosticSourceAuditPerformed: true,
        ephemeralFilenameDiagnosticSourceFindings: ephemeralFilenameDiagnosticSourceFindings,
        prohibitedNetworkAPISourceAuditPerformed: true,
        prohibitedNetworkAPISourceFindings: prohibitedNetworkAPISourceFindings
    )
}

private func declarationConformsToCodable(
    _ typeName: String,
    in source: String
) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: typeName)
    let pattern = #"(?:struct|enum|class)\s+"# + escaped + #"[^\{\n]*\bCodable\b"#
    return source.range(of: pattern, options: .regularExpression) != nil
}

private func featureLogInvocationSourceFindingCount(in source: String) -> Int {
    let pattern = #"(?:StenoKitDiagnostics|Self)\.logger\.(?:debug|info|notice|warning|error|fault)\s*\("#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 1 }
    let range = NSRange(source.startIndex..., in: source)
    return regex.matches(in: source, range: range).reduce(into: 0) { count, match in
        guard let start = Range(match.range, in: source)?.upperBound,
              let argument = balancedInvocationArgument(in: source, after: start) else {
            count += 1
            return
        }
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("\"") || argument.contains("\\(") {
            count += 1
        }
    }
}

private func balancedInvocationArgument(
    in source: String,
    after start: String.Index
) -> String? {
    var index = start
    var depth = 1
    var inString = false
    var escaping = false
    while index < source.endIndex {
        let character = source[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
        } else if character == "\"" {
            inString = true
        } else if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 {
                return String(source[start..<index])
            }
        }
        index = source.index(after: index)
    }
    return nil
}

private func exactOccurrenceCount(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while searchStart < haystack.endIndex,
          let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

private func makeHostedWAV(
    silent: Bool,
    sampleCount: Int = 8_000
) throws -> URL {
    var pcm = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
    for index in 0..<sampleCount {
        let sample: Int16 = silent ? 0 : (index.isMultiple(of: 2) ? 2_400 : -2_400)
        var littleEndian = sample.littleEndian
        withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
    }

    var wav = Data()
    func appendASCII(_ value: String) { wav.append(contentsOf: value.utf8) }
    func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
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
        .appendingPathComponent("steno-hosted-evidence-\(UUID().uuidString).wav")
    try wav.write(to: url, options: .atomic)
    return url
}

@MainActor
private func waitForHostedCondition(
    attempts: Int = 400,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw HostedEvidenceError.timedOut
}
