#if os(macOS)
import CoreAudio
import Darwin
import Dispatch
import Foundation

@MainActor
public final class MacMediaInterruptionService: MediaInterruptionService {
    private static let logger = StenoKitDiagnostics.logger
    private static let defaultVerificationDelays: [UInt64] = [
        80_000_000,
        120_000_000,
        200_000_000,
        400_000_000,
        800_000_000,
    ]
    private static let defaultResumeVerificationDelays: [UInt64] = [
        80_000_000,
        120_000_000,
        200_000_000,
        400_000_000,
        800_000_000,
        800_000_000,
    ]
    private static let defaultResumeLineageGraceDuration: TimeInterval = 3

    private let driver: any MediaInterruptionDriving
    private let verificationDelays: [UInt64]
    private let resumeVerificationDelays: [UInt64]
    private let resumeLineageGraceDuration: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: @Sendable (UInt64) async -> Void
    private let beforeOwnerResumeFinalization: @MainActor @Sendable () async -> Void
    private var activeInterruption: ActiveInterruption?
    private var pauseTransition: PauseTransition?
    private var resumeTransition: ResumeTransition?
    private var pendingResumeLineage: PendingResumeLineage?

    public init() {
        let bridge = MediaRemoteBridge()
        self.driver = MacMediaInterruptionDriver(
            bridge: bridge,
            playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
            audioOutputMonitor: CoreAudioOutputMonitor()
        )
        self.verificationDelays = Self.defaultVerificationDelays
        self.resumeVerificationDelays = Self.defaultResumeVerificationDelays
        self.resumeLineageGraceDuration = Self.defaultResumeLineageGraceDuration
        self.now = { ProcessInfo.processInfo.systemUptime }
        self.sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        self.beforeOwnerResumeFinalization = {}
    }

    init(
        driver: any MediaInterruptionDriving,
        verificationDelays: [UInt64] = [],
        resumeVerificationDelays: [UInt64] = [],
        resumeLineageGraceDuration: TimeInterval = 3,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        beforeOwnerResumeFinalization: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.driver = driver
        self.verificationDelays = verificationDelays
        self.resumeVerificationDelays = resumeVerificationDelays
        self.resumeLineageGraceDuration = resumeLineageGraceDuration
        self.now = now
        self.sleep = sleep
        self.beforeOwnerResumeFinalization = beforeOwnerResumeFinalization
    }

    public func beginInterruption() async -> MediaInterruptionToken? {
        if var activeInterruption {
            let token = MediaInterruptionToken()
            activeInterruption.tokenIDs.insert(token.id)
            self.activeInterruption = activeInterruption
            Self.logger.info(
                "Media interruption joined. Active tokens: \(activeInterruption.tokenIDs.count, privacy: .public)"
            )
            return token
        }

        let token = MediaInterruptionToken()
        return await withTaskCancellationHandler {
            if resumeTransition != nil {
                return await joinResumeTransition(with: token)
            }
            if let receipt = takePendingResumeLineage() {
                return await joinPauseTransition(
                    with: token,
                    resumeLineageReceipt: receipt
                )
            }
            return await joinPauseTransition(with: token)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingBegin(tokenID: token.id)
            }
        }
    }

    public func endInterruption(token: MediaInterruptionToken) async {
        guard var activeInterruption, activeInterruption.tokenIDs.remove(token.id) != nil else {
            Self.logger.info("Ignoring endInterruption for unknown token.")
            return
        }

        self.activeInterruption = activeInterruption
        guard activeInterruption.tokenIDs.isEmpty else {
            Self.logger.info(
                "Media interruption retained. Active tokens: \(activeInterruption.tokenIDs.count, privacy: .public)"
            )
            return
        }

        await finishInterruptionIfUnowned()
    }

    private func joinPauseTransition(
        with token: MediaInterruptionToken,
        resumeLineageReceipt: MediaPauseReceipt? = nil
    ) async -> MediaInterruptionToken? {
        let transition: PauseTransition
        if var current = pauseTransition {
            current.tokenIDs.insert(token.id)
            pauseTransition = current
            transition = current
        } else {
            let transitionID = UUID()
            let task = Task { @MainActor [weak self] () -> MediaPauseReceipt? in
                guard let self else { return nil }
                if let resumeLineageReceipt {
                    return await self.performResumeLineagePauseTransition(
                        id: transitionID,
                        receipt: resumeLineageReceipt
                    )
                }
                return await self.performPauseTransition(id: transitionID)
            }
            transition = PauseTransition(
                id: transitionID,
                task: task,
                tokenIDs: [token.id]
            )
            pauseTransition = transition
        }

        let receipt = await transition.task.value
        if let current = pauseTransition, current.id == transition.id {
            pauseTransition = nil
            if let receipt {
                activeInterruption = ActiveInterruption(
                    receipt: receipt,
                    tokenIDs: current.tokenIDs
                )
                Self.logger.info(
                    "Media interruption verified. Active tokens: \(current.tokenIDs.count, privacy: .public)"
                )
                if current.tokenIDs.isEmpty {
                    await finishInterruptionIfUnowned()
                }
            }
        }

        if Task.isCancelled {
            if activeInterruption?.tokenIDs.contains(token.id) == true {
                await endInterruption(token: token)
            }
            return nil
        }

        guard activeInterruption?.tokenIDs.contains(token.id) == true else { return nil }
        return token
    }

    private func cancelPendingBegin(tokenID: UUID) {
        if var transition = pauseTransition,
           transition.tokenIDs.remove(tokenID) != nil
        {
            pauseTransition = transition
            if transition.tokenIDs.isEmpty {
                transition.task.cancel()
            }
        }
        if var transition = resumeTransition,
           transition.joiningTokenIDs.remove(tokenID) != nil
        {
            resumeTransition = transition
        }
    }

    private func performPauseTransition(id: UUID) async -> MediaPauseReceipt? {
        let before = await driver.snapshot()
        guard pauseTransition?.id == id,
              pauseTransition?.tokenIDs.isEmpty == false,
              let destination = before.pauseDestination
        else {
            Self.logger.info(
                "Media interruption skipped. Evidence: \(before.logValue, privacy: .public)"
            )
            return nil
        }

        let dispatch = await driver.sendPause(to: destination)
        let requestedApplications = Set(destination.applicationBundleIdentifiers)
        let acceptedApplications = Set(
            dispatch.acceptedApplicationBundleIdentifiers
        ).intersection(requestedApplications)
        Self.logger.info(
            "Semantic media Pause attempted: accepted=\(acceptedApplications.sorted().joined(separator: ","), privacy: .public) destination=\(destination.logValue, privacy: .public) evidence=\(before.logValue, privacy: .public)"
        )
        guard !acceptedApplications.isEmpty else { return nil }

        for (index, delay) in verificationDelays.enumerated() {
            await sleep(delay)
            guard pauseTransition?.id == id,
                  pauseTransition?.tokenIDs.isEmpty == false,
                  !Task.isCancelled
            else {
                await compensateAcceptedPause(for: acceptedApplications)
                return nil
            }
            let after = await driver.snapshot()
            Self.logger.info(
                "Media Pause verification pass \(index + 1, privacy: .public): \(after.logValue, privacy: .public)"
            )
            let verifiedApplications = after.confirmedPausedApplicationBundleIdentifiers(
                from: before,
                among: acceptedApplications
            )
            if verifiedApplications == acceptedApplications {
                return MediaPauseReceipt(
                    resumeDestination: VerifiedMediaResumeDestination(
                        applicationBundleIdentifiers: verifiedApplications.sorted()
                    )
                )
            }
            guard index < verificationDelays.index(before: verificationDelays.endIndex),
                  pauseTransition?.id == id,
                  pauseTransition?.tokenIDs.isEmpty == false,
                  !Task.isCancelled
            else { continue }
            let stillActiveApplications = acceptedApplications.subtracting(verifiedApplications)
            if !stillActiveApplications.isEmpty {
                _ = await driver.sendPause(
                    to: .observedApplications(stillActiveApplications.sorted())
                )
            }
        }

        await compensateAcceptedPause(for: acceptedApplications)
        Self.logger.info(
            "Semantic media Pause was not fully verified; accepted commands were compensated and no interruption token was created."
        )
        return nil
    }

    private func performResumeLineagePauseTransition(
        id: UUID,
        receipt: MediaPauseReceipt
    ) async -> MediaPauseReceipt? {
        guard pauseTransition?.id == id,
              pauseTransition?.tokenIDs.isEmpty == false
        else { return nil }

        let expectedApplications = Set(
            receipt.resumeDestination.applicationBundleIdentifiers
        )
        let dispatch = await driver.sendPause(
            to: .observedApplications(expectedApplications.sorted())
        )
        let acceptedApplications = Set(
            dispatch.acceptedApplicationBundleIdentifiers
        ).intersection(expectedApplications)
        guard !acceptedApplications.isEmpty else {
            Self.logger.info(
                "Pending media resume lineage Pause was rejected; ownership was not retained."
            )
            return nil
        }

        let acceptedReceipt = MediaPauseReceipt(
            resumeDestination: VerifiedMediaResumeDestination(
                applicationBundleIdentifiers: acceptedApplications.sorted()
            )
        )
        var observedStillActive = false
        var observedReliableState = false

        for (index, delay) in verificationDelays.enumerated() {
            await sleep(delay)
            guard pauseTransition?.id == id,
                  pauseTransition?.tokenIDs.isEmpty == false,
                  !Task.isCancelled
            else {
                _ = await driver.sendPlay(to: acceptedReceipt.resumeDestination)
                return nil
            }

            let snapshot = await driver.snapshot()
            guard pauseTransition?.id == id,
                  pauseTransition?.tokenIDs.isEmpty == false,
                  !Task.isCancelled
            else {
                _ = await driver.sendPlay(to: acceptedReceipt.resumeDestination)
                return nil
            }

            if let observation = snapshot.audioOutputObservation,
               observation.unresolvedProcessCount == 0
            {
                observedReliableState = true
                let stillActive = acceptedApplications.intersection(
                    observation.applicationBundleIdentifiers
                )
                if stillActive.isEmpty {
                    Self.logger.info(
                        "Pending media resume lineage was re-paused and verified."
                    )
                    return acceptedReceipt
                }
                observedStillActive = true
                guard index < verificationDelays.index(before: verificationDelays.endIndex)
                else { continue }
                _ = await driver.sendPause(
                    to: .observedApplications(stillActive.sorted())
                )
            } else if index < verificationDelays.index(before: verificationDelays.endIndex) {
                _ = await driver.sendPause(
                    to: .observedApplications(acceptedApplications.sorted())
                )
            }
        }

        if observedStillActive {
            _ = await driver.sendPlay(to: acceptedReceipt.resumeDestination)
            Self.logger.info(
                "Pending media resume lineage remained active after Pause; ownership was not retained."
            )
            return nil
        }
        guard !observedReliableState else { return nil }

        Self.logger.info(
            "Pending media resume lineage re-Pause was accepted while output observation was unavailable; retaining bounded exact-app ownership."
        )
        return acceptedReceipt
    }

    private func compensateAcceptedPause(for applicationBundleIdentifiers: Set<String>) async {
        guard !applicationBundleIdentifiers.isEmpty else { return }
        let destination = VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: applicationBundleIdentifiers.sorted()
        )
        _ = await driver.sendPlay(to: destination)
        for delay in resumeVerificationDelays.prefix(2) {
            await sleep(delay)
            _ = await driver.sendPlay(to: destination)
        }
        Self.logger.info(
            "Compensating targeted Play sent after an unverified Pause destination=\(destination.logValue, privacy: .public)"
        )
    }

    private func joinResumeTransition(
        with token: MediaInterruptionToken
    ) async -> MediaInterruptionToken? {
        guard var transition = resumeTransition else {
            return await joinPauseTransition(with: token)
        }

        transition.joiningTokenIDs.insert(token.id)
        resumeTransition = transition
        transition.task.cancel()
        let outcome = await transition.task.value
        await finalizeResumeTransition(id: transition.id, outcome: outcome)

        if Task.isCancelled {
            if activeInterruption?.tokenIDs.contains(token.id) == true {
                await endInterruption(token: token)
            }
            return nil
        }
        if activeInterruption?.tokenIDs.contains(token.id) == true {
            return token
        }
        if let receipt = takePendingResumeLineage() {
            return await joinPauseTransition(
                with: token,
                resumeLineageReceipt: receipt
            )
        }
        return await joinPauseTransition(with: token)
    }

    private func finishInterruptionIfUnowned() async {
        guard let currentInterruption = activeInterruption,
              currentInterruption.tokenIDs.isEmpty
        else { return }
        activeInterruption = nil
        let transitionID = UUID()
        let receipt = currentInterruption.receipt
        let task = Task { @MainActor [weak self] () -> ResumeTransitionOutcome in
            guard let self else { return .resumed }
            return await self.performResumeTransition(id: transitionID, receipt: receipt)
        }
        let transition = ResumeTransition(
            id: transitionID,
            receipt: receipt,
            task: task,
            joiningTokenIDs: []
        )
        resumeTransition = transition
        let outcome = await task.value
        await beforeOwnerResumeFinalization()
        await finalizeResumeTransition(id: transitionID, outcome: outcome)
    }

    private func performResumeTransition(
        id: UUID,
        receipt: MediaPauseReceipt
    ) async -> ResumeTransitionOutcome {
        let destination = receipt.resumeDestination
        let initialDispatch = await driver.sendPlay(to: destination)
        var acceptedPlayApplications = Set(
            initialDispatch.acceptedApplicationBundleIdentifiers
        )
        Self.logger.info(
            "Semantic media Play attempted destination=\(destination.logValue, privacy: .public)"
        )

        if hasJoiningResumeTokens(id: id) {
            return await retainInterruptionDuringResumeJoin(id: id, receipt: receipt)
        }

        guard !resumeVerificationDelays.isEmpty else { return .resumed }
        var lastObservedActiveApplications: Set<String>?
        let expectedApplications = Set(destination.applicationBundleIdentifiers)

        for (index, delay) in resumeVerificationDelays.enumerated() {
            await sleep(delay)
            if hasJoiningResumeTokens(id: id) {
                return await retainInterruptionDuringResumeJoin(id: id, receipt: receipt)
            }

            let snapshot = await driver.snapshot()
            if hasJoiningResumeTokens(id: id) {
                return await retainInterruptionDuringResumeJoin(id: id, receipt: receipt)
            }

            if let activeApplications = snapshot.observedActiveApplicationBundleIdentifiers {
                lastObservedActiveApplications = activeApplications
                if expectedApplications.isSubset(of: activeApplications) {
                    Self.logger.info(
                        "Semantic media Play verified destination=\(destination.logValue, privacy: .public)"
                    )
                    return .resumed
                }
            }

            guard index < resumeVerificationDelays.index(before: resumeVerificationDelays.endIndex)
            else { continue }
            let missingApplications = expectedApplications.subtracting(
                lastObservedActiveApplications ?? []
            )
            if !missingApplications.isEmpty {
                let retryDispatch = await driver.sendPlay(
                    to: VerifiedMediaResumeDestination(
                        applicationBundleIdentifiers: missingApplications.sorted()
                    )
                )
                acceptedPlayApplications.formUnion(
                    retryDispatch.acceptedApplicationBundleIdentifiers
                )
            }
        }

        if hasJoiningResumeTokens(id: id) {
            return await retainInterruptionDuringResumeJoin(id: id, receipt: receipt)
        }
        let unconfirmedApplications = expectedApplications
            .subtracting(lastObservedActiveApplications ?? [])
            .intersection(acceptedPlayApplications)
        if !unconfirmedApplications.isEmpty {
            let pendingReceipt = MediaPauseReceipt(
                resumeDestination: VerifiedMediaResumeDestination(
                    applicationBundleIdentifiers: unconfirmedApplications.sorted()
                )
            )
            Self.logger.info(
                "Semantic media Play remained unverified; preserving bounded exact-app resume lineage destination=\(pendingReceipt.resumeDestination.logValue, privacy: .public)"
            )
            return .resumedWithPendingLineage(pendingReceipt)
        }
        Self.logger.info(
            "Semantic media Play verification exhausted destination=\(destination.logValue, privacy: .public)"
        )
        return .resumed
    }

    private func retainInterruptionDuringResumeJoin(
        id: UUID,
        receipt: MediaPauseReceipt
    ) async -> ResumeTransitionOutcome {
        let applications = receipt.resumeDestination.applicationBundleIdentifiers
        let expectedApplications = Set(applications)
        let initialDispatch = await driver.sendPause(
            to: .observedApplications(applications)
        )
        var acceptedPauseApplications = Set(
            initialDispatch.acceptedApplicationBundleIdentifiers
        ).intersection(expectedApplications)
        Self.logger.info(
            "In-flight media resume was re-paused for a new dictation owner destination=\(receipt.resumeDestination.logValue, privacy: .public)"
        )

        for (index, delay) in verificationDelays.enumerated() {
            await sleep(delay)
            guard hasJoiningResumeTokens(id: id) else { break }
            let snapshot = await driver.snapshot()
            guard hasJoiningResumeTokens(id: id) else { break }

            if let observation = snapshot.audioOutputObservation,
               observation.unresolvedProcessCount == 0
            {
                let stillActive = expectedApplications.intersection(
                    observation.applicationBundleIdentifiers
                )
                if stillActive.isEmpty {
                    guard !acceptedPauseApplications.isEmpty else {
                        Self.logger.info(
                            "In-flight media resume became silent without accepting re-Pause; ownership was not retained."
                        )
                        return .resumed
                    }
                    let acceptedReceipt = MediaPauseReceipt(
                        resumeDestination: VerifiedMediaResumeDestination(
                            applicationBundleIdentifiers: acceptedPauseApplications.sorted()
                        )
                    )
                    return .retained(acceptedReceipt)
                }
                guard index < verificationDelays.index(before: verificationDelays.endIndex)
                else { continue }
                let retryDispatch = await driver.sendPause(
                    to: .observedApplications(stillActive.sorted())
                )
                acceptedPauseApplications.formUnion(
                    Set(retryDispatch.acceptedApplicationBundleIdentifiers)
                        .intersection(stillActive)
                )
            } else if index < verificationDelays.index(before: verificationDelays.endIndex) {
                let retryDispatch = await driver.sendPause(
                    to: .observedApplications(applications)
                )
                acceptedPauseApplications.formUnion(
                    Set(retryDispatch.acceptedApplicationBundleIdentifiers)
                        .intersection(expectedApplications)
                )
            }
        }

        if !acceptedPauseApplications.isEmpty {
            await compensateAcceptedPause(for: acceptedPauseApplications)
        }
        Self.logger.info(
            "In-flight media resume could not be verified as re-paused; ownership was not retained."
        )
        return .resumed
    }

    private func hasJoiningResumeTokens(id: UUID) -> Bool {
        guard let transition = resumeTransition, transition.id == id else { return false }
        return !transition.joiningTokenIDs.isEmpty
    }

    private func takePendingResumeLineage() -> MediaPauseReceipt? {
        guard let pendingResumeLineage else { return nil }
        self.pendingResumeLineage = nil
        guard now() <= pendingResumeLineage.expiresAtUptime else {
            Self.logger.info("Pending media resume lineage expired without authorizing a command.")
            return nil
        }
        return pendingResumeLineage.receipt
    }

    private func finalizeResumeTransition(
        id: UUID,
        outcome: ResumeTransitionOutcome
    ) async {
        guard let transition = resumeTransition, transition.id == id else { return }
        resumeTransition = nil
        switch outcome {
        case .resumed:
            return
        case .resumedWithPendingLineage(let receipt):
            guard resumeLineageGraceDuration > 0 else { return }
            pendingResumeLineage = PendingResumeLineage(
                receipt: receipt,
                expiresAtUptime: now() + resumeLineageGraceDuration
            )
        case .retained(let receipt):
            activeInterruption = ActiveInterruption(
                receipt: receipt,
                tokenIDs: transition.joiningTokenIDs
            )
            if transition.joiningTokenIDs.isEmpty {
                await finishInterruptionIfUnowned()
            }
        }
    }

    private struct ActiveInterruption {
        let receipt: MediaPauseReceipt
        var tokenIDs: Set<UUID>
    }

    private struct PauseTransition {
        let id: UUID
        let task: Task<MediaPauseReceipt?, Never>
        var tokenIDs: Set<UUID>
    }

    private struct ResumeTransition {
        let id: UUID
        let receipt: MediaPauseReceipt
        let task: Task<ResumeTransitionOutcome, Never>
        var joiningTokenIDs: Set<UUID>
    }

    private struct PendingResumeLineage {
        let receipt: MediaPauseReceipt
        let expiresAtUptime: TimeInterval
    }

    private enum ResumeTransitionOutcome {
        case resumed
        case resumedWithPendingLineage(MediaPauseReceipt)
        case retained(MediaPauseReceipt)
    }
}

enum SemanticMediaCommand: Int32, Sendable, Equatable {
    case play = 0
    case pause = 1
}

enum MediaPauseDestination: Sendable, Equatable {
    case observedApplications([String])

    var applicationBundleIdentifiers: [String] {
        switch self {
        case .observedApplications(let bundleIdentifiers):
            Array(Set(bundleIdentifiers)).sorted()
        }
    }

    var logValue: String {
        "observed-applications=\(applicationBundleIdentifiers.joined(separator: ","))"
    }
}

struct VerifiedMediaResumeDestination: Sendable, Equatable {
    let applicationBundleIdentifiers: [String]

    init(applicationBundleIdentifiers: [String]) {
        self.applicationBundleIdentifiers = Array(Set(applicationBundleIdentifiers)).sorted()
    }

    var logValue: String {
        "observed-applications=\(applicationBundleIdentifiers.joined(separator: ","))"
    }
}

struct MediaPlaybackTarget: Sendable, Equatable {
    let processID: Int32
    let bundleIdentifier: String
}

struct MediaAudioOutputTarget: Sendable, Equatable, Hashable {
    let processID: Int32
    let applicationBundleIdentifier: String
}

struct MediaAudioOutputObservation: Sendable, Equatable {
    let targets: [MediaAudioOutputTarget]
    let unresolvedProcessCount: Int

    var applicationBundleIdentifiers: Set<String> {
        Set(targets.map(\.applicationBundleIdentifier))
    }

    var hasActiveOutput: Bool {
        !targets.isEmpty || unresolvedProcessCount > 0
    }
}

struct MediaPauseReceipt: Sendable, Equatable {
    let resumeDestination: VerifiedMediaResumeDestination
}

struct MediaCommandDispatchResult: Sendable, Equatable {
    let acceptedApplicationBundleIdentifiers: [String]

    init(acceptedApplicationBundleIdentifiers: [String]) {
        self.acceptedApplicationBundleIdentifiers = Array(
            Set(acceptedApplicationBundleIdentifiers)
        ).sorted()
    }
}

struct MediaInterruptionSnapshot: Sendable, Equatable {
    let target: MediaPlaybackTarget?
    let contentIdentifier: String?
    let detection: PlaybackDetectionResult
    let nowPlayingIsPlaying: Bool?
    let playbackState: Int?
    let audioOutputObservation: MediaAudioOutputObservation?

    var pauseDestination: MediaPauseDestination? {
        guard let audioOutputObservation,
              audioOutputObservation.unresolvedProcessCount == 0
        else { return nil }
        let observedApplications = audioOutputObservation.applicationBundleIdentifiers.sorted()
        guard !observedApplications.isEmpty else { return nil }
        return .observedApplications(observedApplications)
    }

    var observedActiveApplicationBundleIdentifiers: Set<String>? {
        audioOutputObservation.map(\.applicationBundleIdentifiers)
    }

    func confirmedPausedApplicationBundleIdentifiers(
        from before: MediaInterruptionSnapshot,
        among candidates: Set<String>
    ) -> Set<String> {
        guard before.audioOutputObservation?.unresolvedProcessCount == 0,
              audioOutputObservation?.unresolvedProcessCount == 0,
              let beforeApplications = before.observedActiveApplicationBundleIdentifiers,
              let afterApplications = observedActiveApplicationBundleIdentifiers
        else { return [] }
        return candidates
            .intersection(beforeApplications)
            .subtracting(afterApplications)
    }

    var logValue: String {
        let targetValue = target.map { "\($0.bundleIdentifier):\($0.processID)" } ?? "none"
        let outputValue = audioOutputObservation.map { observation in
            let targets = observation.targets
                .map { "\($0.applicationBundleIdentifier):\($0.processID)" }
                .joined(separator: ",")
            return "targets=[\(targets)] unresolved=\(observation.unresolvedProcessCount)"
        } ?? "unavailable"
        let playingValue = nowPlayingIsPlaying.map(String.init) ?? "nil"
        let stateValue = playbackState.map(String.init) ?? "nil"
        return "target=\(targetValue) detection=\(detection.logValue) electedPlaying=\(playingValue) state=\(stateValue) activeOutput=\(outputValue)"
    }

}

@MainActor
protocol MediaInterruptionDriving: AnyObject {
    func snapshot() async -> MediaInterruptionSnapshot
    func sendPause(to destination: MediaPauseDestination) async -> MediaCommandDispatchResult
    func sendPlay(to destination: VerifiedMediaResumeDestination) async -> MediaCommandDispatchResult
}

enum PlaybackDetectionResult: Sendable, Equatable {
    case playing
    case likelyPlaying
    case notPlaying
    case unknown

    var logValue: String {
        switch self {
        case .playing:
            "playing"
        case .likelyPlaying:
            "likelyPlaying"
        case .notPlaying:
            "notPlaying"
        case .unknown:
            "unknown"
        }
    }
}

@MainActor
protocol MediaPlaybackStateDetector {
    func detect() async -> PlaybackDetectionResult
}

struct PlaybackDetectionEvidence: Sendable, Equatable {
    let result: PlaybackDetectionResult
    let nowPlayingIsPlaying: Bool?
    let playbackState: Int?
}

@MainActor
protocol MediaRemoteBridging: Sendable {
    func activate()
    func deactivate()
    func anyApplicationIsPlaying() async -> Bool?
    func nowPlayingApplicationIsPlaying() async -> Bool?
    func nowPlayingPlaybackState() async -> Int?
    func nowPlayingPlaybackRate() async -> Double?
    func nowPlayingApplicationPID() async -> Int32?
    func nowPlayingApplicationDisplayID() async -> String?
    func nowPlayingContentIdentifier() async -> String?
    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool?
    func send(
        _ command: SemanticMediaCommand,
        toApplicationBundleIdentifier applicationBundleIdentifier: String
    ) async -> Bool
}

final class MultiSignalMediaPlaybackStateDetector: MediaPlaybackStateDetector {
    private static let logger = StenoKitDiagnostics.logger
    private static let weakPositiveConfirmationDelayNanoseconds: UInt64 = 80_000_000
    private let bridge: any MediaRemoteBridging

    init(bridge: any MediaRemoteBridging = MediaRemoteBridge()) {
        self.bridge = bridge
    }

    func detect() async -> PlaybackDetectionResult {
        await evidence().result
    }

    func evidence(managesActivation: Bool = true) async -> PlaybackDetectionEvidence {
        if managesActivation {
            bridge.activate()
        }
        defer {
            if managesActivation {
                bridge.deactivate()
            }
        }

        let firstSnapshot = await captureSnapshot()
        let firstDecision = classify(firstSnapshot)
        logSnapshot(pass: 1, snapshot: firstSnapshot, decision: firstDecision)

        let secondDecision: DetectionDecision?
        let result: PlaybackDetectionResult
        var finalSnapshot = firstSnapshot

        switch firstDecision {
        case .playing:
            secondDecision = nil
            result = .playing
        case .notPlaying:
            secondDecision = nil
            result = .notPlaying
        case .unknown:
            secondDecision = nil
            result = .unknown
        case .weakPositivePending:
            if Task.isCancelled {
                secondDecision = nil
                result = .unknown
                break
            }

            try? await Task.sleep(nanoseconds: Self.weakPositiveConfirmationDelayNanoseconds)
            if Task.isCancelled {
                secondDecision = nil
                result = .unknown
                break
            }

            let secondSnapshot = await captureSnapshot()
            let confirmedDecision = classify(secondSnapshot)
            finalSnapshot = secondSnapshot
            secondDecision = confirmedDecision
            logSnapshot(pass: 2, snapshot: secondSnapshot, decision: confirmedDecision)

            switch confirmedDecision {
            case .playing:
                result = .playing
            case .weakPositivePending:
                result = .likelyPlaying
            case .notPlaying:
                result = .notPlaying
            case .unknown:
                result = .unknown
            }
        }

        Self.logger.debug(
            """
            Media detection final result=\(result.logValue, privacy: .public) \
            pass1=\(firstDecision.logValue, privacy: .public) \
            pass2=\(secondDecision?.logValue ?? "none", privacy: .public)
            """
        )
        return PlaybackDetectionEvidence(
            result: result,
            nowPlayingIsPlaying: finalSnapshot.nowPlaying,
            playbackState: finalSnapshot.playbackState
        )
    }

    private func captureSnapshot() async -> ProbeSnapshot {
        async let anyApplicationIsPlaying = bridge.anyApplicationIsPlaying()
        async let nowPlayingApplicationIsPlaying = bridge.nowPlayingApplicationIsPlaying()
        async let nowPlayingPlaybackState = bridge.nowPlayingPlaybackState()
        async let nowPlayingPlaybackRate = bridge.nowPlayingPlaybackRate()

        let anyPlaying = await anyApplicationIsPlaying
        let nowPlaying = await nowPlayingApplicationIsPlaying
        let playbackState = await nowPlayingPlaybackState
        let playbackRate = await nowPlayingPlaybackRate

        let trust = Self.playbackStateTrust(
            playbackState: playbackState,
            playbackRate: playbackRate,
            nowPlaying: nowPlaying
        )

        let playbackStateIsAdvancing: Bool?
        if trust.trusted, let playbackState {
            playbackStateIsAdvancing = bridge.isPlaybackStateAdvancing(playbackState)
        } else {
            playbackStateIsAdvancing = nil
        }

        let hasStrongPositive =
            (playbackRate.map { $0 > 0 } ?? false)
            || (playbackStateIsAdvancing == true)

        let hasStrongNegative =
            (playbackRate.map { $0 == 0 } ?? false)
            || (playbackStateIsAdvancing == false)

        let hasWeakPositive = (anyPlaying == true) || (nowPlaying == true)

        return ProbeSnapshot(
            anyPlaying: anyPlaying,
            nowPlaying: nowPlaying,
            playbackState: playbackState,
            playbackRate: playbackRate,
            playbackStateIsAdvancing: playbackStateIsAdvancing,
            stateSignalTrusted: trust.trusted,
            stateTrustReason: trust.reason,
            hasStrongPositive: hasStrongPositive,
            hasStrongNegative: hasStrongNegative,
            hasWeakPositive: hasWeakPositive
        )
    }

    private func classify(_ snapshot: ProbeSnapshot) -> DetectionDecision {
        if snapshot.hasStrongPositive && !snapshot.hasStrongNegative {
            return .playing
        }
        if snapshot.hasStrongPositive && snapshot.hasStrongNegative {
            return .unknown
        }
        if snapshot.hasStrongNegative {
            return .notPlaying
        }
        if snapshot.hasWeakPositive {
            return .weakPositivePending
        }
        return .unknown
    }

    private func logSnapshot(pass: Int, snapshot: ProbeSnapshot, decision: DetectionDecision) {
        Self.logger.debug(
            """
            Media detection pass=\(pass, privacy: .public) \
            any=\(Self.describe(snapshot.anyPlaying), privacy: .public) \
            nowPlaying=\(Self.describe(snapshot.nowPlaying), privacy: .public) \
            state=\(Self.describe(snapshot.playbackState), privacy: .public) \
            stateAdvancing=\(Self.describe(snapshot.playbackStateIsAdvancing), privacy: .public) \
            rate=\(Self.describe(snapshot.playbackRate), privacy: .public) \
            stateTrusted=\(snapshot.stateSignalTrusted, privacy: .public) \
            trustReason=\(snapshot.stateTrustReason, privacy: .public) \
            decision=\(decision.logValue, privacy: .public)
            """
        )
    }

    private static func playbackStateTrust(
        playbackState: Int?,
        playbackRate: Double?,
        nowPlaying: Bool?
    ) -> (trusted: Bool, reason: String) {
        guard let playbackState else {
            return (false, "missing-state")
        }
        if playbackRate != nil {
            return (true, "trusted-with-rate")
        }
        if nowPlaying == true {
            return (true, "trusted-with-now-playing")
        }
        if playbackState == 0 {
            return (false, "error-default-state")
        }
        return (false, "uncorroborated-state")
    }

    private struct ProbeSnapshot {
        let anyPlaying: Bool?
        let nowPlaying: Bool?
        let playbackState: Int?
        let playbackRate: Double?
        let playbackStateIsAdvancing: Bool?
        let stateSignalTrusted: Bool
        let stateTrustReason: String
        let hasStrongPositive: Bool
        let hasStrongNegative: Bool
        let hasWeakPositive: Bool
    }

    private enum DetectionDecision {
        case playing
        case weakPositivePending
        case notPlaying
        case unknown

        var logValue: String {
            switch self {
            case .playing:
                "playing"
            case .weakPositivePending:
                "weakPositivePending"
            case .notPlaying:
                "notPlaying"
            case .unknown:
                "unknown"
            }
        }
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.4f", value)
    }
}

@MainActor
protocol AudioOutputMonitoring: AnyObject {
    func observeActiveAudioOutputs(
        excludingProcessID: Int32
    ) -> MediaAudioOutputObservation?
}

struct AudioProcessApplicationResolver {
    private let processPath: (Int32) -> String?
    private let bundleIdentifierAtURL: (URL) -> String?

    init(
        processPath: @escaping (Int32) -> String? = Self.runningProcessPath,
        bundleIdentifierAtURL: @escaping (URL) -> String? = {
            Bundle(url: $0)?.bundleIdentifier
        }
    ) {
        self.processPath = processPath
        self.bundleIdentifierAtURL = bundleIdentifierAtURL
    }

    func applicationBundleIdentifier(
        for processID: Int32,
        fallback: String?
    ) -> String? {
        guard let processPath = processPath(processID) else { return fallback }

        var candidate = URL(fileURLWithPath: processPath)
        var applicationBundles: [URL] = []
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                applicationBundles.append(candidate)
            }
            candidate.deleteLastPathComponent()
        }

        for applicationBundle in applicationBundles.reversed() {
            if let bundleIdentifier = bundleIdentifierAtURL(applicationBundle),
               !bundleIdentifier.isEmpty
            {
                return bundleIdentifier
            }
        }
        return fallback
    }

    private static func runningProcessPath(processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let pathBytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }
}

struct ActiveAudioProcessRecord: Sendable, Equatable {
    let processID: Int32?
    let fallbackBundleIdentifier: String?
}

struct ActiveAudioProcessObservationBuilder {
    let applicationResolver: AudioProcessApplicationResolver

    func makeObservation(
        from activeProcesses: [ActiveAudioProcessRecord],
        excludingProcessID: Int32
    ) -> MediaAudioOutputObservation {
        var targets: [MediaAudioOutputTarget] = []
        var unresolvedProcessCount = 0

        for process in activeProcesses {
            guard let processID = process.processID, processID > 0 else {
                unresolvedProcessCount += 1
                continue
            }
            guard processID != excludingProcessID else { continue }
            guard let applicationBundleIdentifier = applicationResolver
                    .applicationBundleIdentifier(
                        for: processID,
                        fallback: process.fallbackBundleIdentifier
                    ),
                  !applicationBundleIdentifier.isEmpty
            else {
                unresolvedProcessCount += 1
                continue
            }

            targets.append(
                MediaAudioOutputTarget(
                    processID: processID,
                    applicationBundleIdentifier: applicationBundleIdentifier
                )
            )
        }

        let sortedTargets = targets.sorted {
            if $0.applicationBundleIdentifier == $1.applicationBundleIdentifier {
                return $0.processID < $1.processID
            }
            return $0.applicationBundleIdentifier < $1.applicationBundleIdentifier
        }
        return MediaAudioOutputObservation(
            targets: sortedTargets,
            unresolvedProcessCount: unresolvedProcessCount
        )
    }
}

@MainActor
final class CoreAudioOutputMonitor: AudioOutputMonitoring {
    private static let logger = StenoKitDiagnostics.logger
    private let applicationResolver: AudioProcessApplicationResolver

    init(applicationResolver: AudioProcessApplicationResolver = AudioProcessApplicationResolver()) {
        self.applicationResolver = applicationResolver
    }

    func observeActiveAudioOutputs(
        excludingProcessID: Int32
    ) -> MediaAudioOutputObservation? {
        guard #available(macOS 15.0, *) else { return nil }
        let processes: [AudioHardwareProcess]
        do {
            processes = try AudioHardwareSystem.shared.processes
        } catch {
            Self.logger.debug(
                "Core Audio output discovery unavailable: \(String(describing: error), privacy: .public)"
            )
            return nil
        }

        var activeProcesses: [ActiveAudioProcessRecord] = []
        var activeProcessCount = 0
        for process in processes {
            guard (try? process.isRunningOutput) == true else { continue }
            activeProcessCount += 1

            let fallbackBundleIdentifier: String?
            do {
                fallbackBundleIdentifier = try process.bundleID
            } catch {
                fallbackBundleIdentifier = nil
            }
            activeProcesses.append(
                ActiveAudioProcessRecord(
                    processID: try? process.pid,
                    fallbackBundleIdentifier: fallbackBundleIdentifier
                )
            )
        }
        let observation = ActiveAudioProcessObservationBuilder(
            applicationResolver: applicationResolver
        ).makeObservation(
            from: activeProcesses,
            excludingProcessID: excludingProcessID
        )
        Self.logger.debug(
            "Core Audio output discovery processes=\(processes.count, privacy: .public) active=\(activeProcessCount, privacy: .public) targets=\(observation.targets.count, privacy: .public) unresolved=\(observation.unresolvedProcessCount, privacy: .public)"
        )
        return observation
    }
}

@MainActor
final class MacMediaInterruptionDriver: MediaInterruptionDriving {
    private let bridge: any MediaRemoteBridging
    private let playbackDetector: MultiSignalMediaPlaybackStateDetector
    private let audioOutputMonitor: any AudioOutputMonitoring

    init(
        bridge: any MediaRemoteBridging,
        playbackDetector: MultiSignalMediaPlaybackStateDetector,
        audioOutputMonitor: any AudioOutputMonitoring
    ) {
        self.bridge = bridge
        self.playbackDetector = playbackDetector
        self.audioOutputMonitor = audioOutputMonitor
    }

    func snapshot() async -> MediaInterruptionSnapshot {
        bridge.activate()
        defer { bridge.deactivate() }

        async let evidence = playbackDetector.evidence(managesActivation: false)
        async let initialTarget = resolvedTarget()
        async let contentIdentifier = bridge.nowPlayingContentIdentifier()

        let resolvedEvidence = await evidence
        let resolvedInitialTarget = await initialTarget
        let resolvedContentIdentifier = await contentIdentifier
        let resolvedFinalTarget = await resolvedTarget()

        let target = resolvedInitialTarget == resolvedFinalTarget
            ? resolvedInitialTarget
            : nil
        let audioOutputObservation = audioOutputMonitor.observeActiveAudioOutputs(
            excludingProcessID: getpid()
        )

        return MediaInterruptionSnapshot(
            target: target,
            contentIdentifier: target == nil ? nil : resolvedContentIdentifier,
            detection: resolvedEvidence.result,
            nowPlayingIsPlaying: resolvedEvidence.nowPlayingIsPlaying,
            playbackState: resolvedEvidence.playbackState,
            audioOutputObservation: audioOutputObservation
        )
    }

    func sendPause(to destination: MediaPauseDestination) async -> MediaCommandDispatchResult {
        await send(
            .pause,
            toApplicationBundleIdentifiers: destination.applicationBundleIdentifiers
        )
    }

    func sendPlay(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        await send(.play, toApplicationBundleIdentifiers: destination.applicationBundleIdentifiers)
    }

    private func send(
        _ command: SemanticMediaCommand,
        toApplicationBundleIdentifiers applicationBundleIdentifiers: [String]
    ) async -> MediaCommandDispatchResult {

        guard !applicationBundleIdentifiers.isEmpty else {
            return MediaCommandDispatchResult(acceptedApplicationBundleIdentifiers: [])
        }
        let bridge = self.bridge
        let tasks = applicationBundleIdentifiers.map { applicationBundleIdentifier in
            Task { @MainActor () -> (String, Bool) in
                let accepted = await bridge.send(
                    command,
                    toApplicationBundleIdentifier: applicationBundleIdentifier
                )
                return (applicationBundleIdentifier, accepted)
            }
        }
        var acceptedApplicationBundleIdentifiers: [String] = []
        for task in tasks {
            let (applicationBundleIdentifier, accepted) = await task.value
            if accepted {
                acceptedApplicationBundleIdentifiers.append(applicationBundleIdentifier)
            }
        }
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: acceptedApplicationBundleIdentifiers
        )
    }

    private func resolvedTarget() async -> MediaPlaybackTarget? {
        async let processID = bridge.nowPlayingApplicationPID()
        async let displayID = bridge.nowPlayingApplicationDisplayID()

        guard let resolvedProcessID = await processID,
              resolvedProcessID > 0,
              let resolvedDisplayID = await displayID,
              !resolvedDisplayID.isEmpty
        else {
            return nil
        }

        return MediaPlaybackTarget(
            processID: resolvedProcessID,
            bundleIdentifier: resolvedDisplayID
        )
    }
}

@MainActor
final class MediaRemoteBridge: MediaRemoteBridging {
    private typealias SetWantsNowPlayingNotificationsFn = @convention(c) (Bool) -> Void
    private typealias RegisterForNowPlayingNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterForNowPlayingNotificationsFn = @convention(c) () -> Void
    private typealias BoolProbeFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias PlaybackStateProbeFn = @convention(c) (DispatchQueue, @escaping (Int) -> Void) -> Void
    private typealias PIDProbeFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias DisplayIDProbeFn = @convention(c) (DispatchQueue, @escaping (CFString?) -> Void) -> Void
    private typealias PlaybackStateIsAdvancingFn = @convention(c) (Int) -> Bool
    private typealias NowPlayingInfoProbeFn = @convention(c) (DispatchQueue, @escaping ([AnyHashable: Any]?) -> Void) -> Void
    private typealias GetLocalOriginFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias SendCommandToAppFn = @convention(c) (
        UInt32,
        CFDictionary?,
        UnsafeMutableRawPointer?,
        CFString?,
        UInt32,
        DispatchQueue,
        @escaping (UInt32, CFArray?) -> Void
    ) -> DarwinBoolean
    private static let logger = StenoKitDiagnostics.logger

    private nonisolated(unsafe) let handle: UnsafeMutableRawPointer?
    private let callbackQueue: DispatchQueue
    private let probeRunner: MediaRemoteAsyncProbeRunner

    private let setWantsNowPlayingNotifications: SetWantsNowPlayingNotificationsFn?
    private let registerForNowPlayingNotifications: RegisterForNowPlayingNotificationsFn?
    private let unregisterForNowPlayingNotifications: UnregisterForNowPlayingNotificationsFn?
    private let getAnyApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationPlaybackState: PlaybackStateProbeFn?
    private let getNowPlayingApplicationPID: PIDProbeFn?
    private let getNowPlayingApplicationDisplayID: DisplayIDProbeFn?
    private let playbackStateIsAdvancingFn: PlaybackStateIsAdvancingFn?
    private let getNowPlayingInfo: NowPlayingInfoProbeFn?
    private let getLocalOriginFn: GetLocalOriginFn?
    private let sendCommandToAppFn: SendCommandToAppFn?
    private let sendCommandOverride: ((SemanticMediaCommand, String) -> Bool)?
    private let playbackRateInfoKey: String?
    private let contentIdentifierInfoKeys: [String]
    private let disableImplicitAppLaunchOptionKey: String?

    init(
        frameworkPath: String = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        callbackQueue: DispatchQueue = DispatchQueue(label: "Steno.MediaRemote.Callback", qos: .userInitiated),
        probeRunner: MediaRemoteAsyncProbeRunner = MediaRemoteAsyncProbeRunner(),
        sendCommandOverride: ((SemanticMediaCommand, String) -> Bool)? = nil
    ) {
        self.callbackQueue = callbackQueue
        self.probeRunner = probeRunner
        self.sendCommandOverride = sendCommandOverride

        let handle = dlopen(frameworkPath, RTLD_LAZY)
        self.handle = handle

        self.setWantsNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteSetWantsNowPlayingNotifications",
            as: SetWantsNowPlayingNotificationsFn.self
        )
        self.registerForNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteRegisterForNowPlayingNotifications",
            as: RegisterForNowPlayingNotificationsFn.self
        )
        self.unregisterForNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteUnregisterForNowPlayingNotifications",
            as: UnregisterForNowPlayingNotificationsFn.self
        )
        self.getAnyApplicationIsPlaying = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetAnyApplicationIsPlaying",
            as: BoolProbeFn.self
        )
        self.getNowPlayingApplicationIsPlaying = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            as: BoolProbeFn.self
        )
        self.getNowPlayingApplicationPlaybackState = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationPlaybackState",
            as: PlaybackStateProbeFn.self
        )
        self.getNowPlayingApplicationPID = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationPID",
            as: PIDProbeFn.self
        )
        self.getNowPlayingApplicationDisplayID = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationDisplayID",
            as: DisplayIDProbeFn.self
        )
        self.playbackStateIsAdvancingFn = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemotePlaybackStateIsAdvancing",
            as: PlaybackStateIsAdvancingFn.self
        )
        self.getNowPlayingInfo = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingInfo",
            as: NowPlayingInfoProbeFn.self
        )
        self.getLocalOriginFn = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetLocalOrigin",
            as: GetLocalOriginFn.self
        )
        self.sendCommandToAppFn = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteSendCommandToApp",
            as: SendCommandToAppFn.self
        )
        self.playbackRateInfoKey = Self.loadCFStringConstant(
            handle: handle,
            named: "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        )
        self.contentIdentifierInfoKeys = [
            "kMRMediaRemoteNowPlayingInfoContentItemIdentifier",
            "kMRMediaRemoteNowPlayingInfoUniqueIdentifier",
            "kMRMediaRemoteNowPlayingInfoExternalContentIdentifier",
        ].compactMap { Self.loadCFStringConstant(handle: handle, named: $0) }
        self.disableImplicitAppLaunchOptionKey = Self.loadCFStringConstant(
            handle: handle,
            named: "kMRMediaRemoteOptionDisableImplicitAppLaunchBehaviors"
        )
    }

    private var activationCount = 0

    func activate() {
        activationCount += 1
        Self.logger.debug("MediaRemote activate. Count: \(self.activationCount, privacy: .public)")
        if activationCount == 1 {
            setWantsNowPlayingNotifications?(true)
            registerForNowPlayingNotifications?(callbackQueue)
            Self.logger.debug("MediaRemote now playing notifications enabled and registered.")
        }
    }

    func deactivate() {
        guard activationCount > 0 else {
            Self.logger.debug("MediaRemote deactivate ignored because count is already zero.")
            return
        }

        activationCount -= 1
        Self.logger.debug("MediaRemote deactivate. Count: \(self.activationCount, privacy: .public)")
        if activationCount == 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
            Self.logger.debug("MediaRemote now playing notifications unregistered and disabled.")
        }
    }

    deinit {
        if activationCount > 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
            StenoKitDiagnostics.logger.debug("MediaRemote bridge deinit forced unregister cleanup.")
        }
        // Defer dlclose to after the serial callbackQueue drains, avoiding
        // a sync-on-self deadlock if deinit runs on the callbackQueue thread.
        let handleAddress = self.handle.map { Int(bitPattern: $0) }
        callbackQueue.async {
            guard let handleAddress else { return }
            Self.closeHandle(address: handleAddress)
        }
    }

    func anyApplicationIsPlaying() async -> Bool? {
        guard let getAnyApplicationIsPlaying else { return nil }
        return await probeRunner.run { callback in
            getAnyApplicationIsPlaying(callbackQueue) { isPlaying in
                callback(isPlaying)
            }
        }
    }

    func nowPlayingApplicationIsPlaying() async -> Bool? {
        guard let getNowPlayingApplicationIsPlaying else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationIsPlaying(callbackQueue) { isPlaying in
                callback(isPlaying)
            }
        }
    }

    func nowPlayingPlaybackState() async -> Int? {
        guard let getNowPlayingApplicationPlaybackState else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationPlaybackState(callbackQueue) { playbackState in
                callback(playbackState)
            }
        }
    }

    func nowPlayingPlaybackRate() async -> Double? {
        guard let getNowPlayingInfo, let playbackRateInfoKey else { return nil }
        let playbackRateResult: Double?? = await probeRunner.run { callback in
            getNowPlayingInfo(callbackQueue) { info in
                guard let info else {
                    callback(nil)
                    return
                }
                if let rate = info[playbackRateInfoKey] as? Double {
                    callback(rate)
                    return
                }
                if let rate = info[playbackRateInfoKey] as? NSNumber {
                    callback(rate.doubleValue)
                    return
                }
                if let rate = info[NSString(string: playbackRateInfoKey)] as? NSNumber {
                    callback(rate.doubleValue)
                    return
                }
                callback(nil)
            }
        }
        return playbackRateResult ?? nil
    }

    func nowPlayingApplicationPID() async -> Int32? {
        guard let getNowPlayingApplicationPID else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationPID(callbackQueue) { processID in
                callback(processID)
            }
        }
    }

    func nowPlayingApplicationDisplayID() async -> String? {
        guard let getNowPlayingApplicationDisplayID else { return nil }
        let displayIDResult: String?? = await probeRunner.run { callback in
            getNowPlayingApplicationDisplayID(callbackQueue) { displayID in
                callback(displayID as String?)
            }
        }
        return displayIDResult ?? nil
    }

    func nowPlayingContentIdentifier() async -> String? {
        guard let getNowPlayingInfo, !contentIdentifierInfoKeys.isEmpty else { return nil }
        let identifierResult: String?? = await probeRunner.run { callback in
            getNowPlayingInfo(callbackQueue) { [contentIdentifierInfoKeys] info in
                guard let info else {
                    callback(nil)
                    return
                }

                for key in contentIdentifierInfoKeys {
                    if let value = info[key] as? String, !value.isEmpty {
                        callback(value)
                        return
                    }
                    if let value = info[NSString(string: key)] as? String, !value.isEmpty {
                        callback(value)
                        return
                    }
                    if let value = info[key] as? NSNumber {
                        callback(value.stringValue)
                        return
                    }
                }
                callback(nil)
            }
        }
        return identifierResult ?? nil
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        guard let playbackStateIsAdvancingFn else { return nil }
        return playbackStateIsAdvancingFn(playbackState)
    }

    func send(
        _ command: SemanticMediaCommand,
        toApplicationBundleIdentifier applicationBundleIdentifier: String
    ) async -> Bool {
        if let sendCommandOverride {
            return sendCommandOverride(command, applicationBundleIdentifier)
        }
        guard let sendCommandToAppFn,
              let disableImplicitAppLaunchOptionKey,
              !applicationBundleIdentifier.isEmpty
        else { return false }

        let options = [disableImplicitAppLaunchOptionKey: true] as CFDictionary
        let accepted = sendCommandToAppFn(
            UInt32(command.rawValue),
            options,
            getLocalOriginFn?(),
            applicationBundleIdentifier as CFString,
            0,
            callbackQueue
        ) { error, _ in
            if error != 0 {
                StenoKitDiagnostics.logger.debug(
                    "Targeted semantic media command callback error=\(error, privacy: .public) application=\(applicationBundleIdentifier, privacy: .public)"
                )
            }
        }
        return accepted.boolValue
    }

    private static func loadSymbol<Symbol>(
        handle: UnsafeMutableRawPointer?,
        named symbolName: String,
        as _: Symbol.Type
    ) -> Symbol? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        return unsafeBitCast(symbol, to: Symbol.self)
    }

    private static func loadCFStringConstant(
        handle: UnsafeMutableRawPointer?,
        named symbolName: String
    ) -> String? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        let pointer = symbol.assumingMemoryBound(to: CFString?.self)
        guard let value = pointer.pointee else { return nil }
        return value as String
    }

    nonisolated private static func closeHandle(address: Int) {
        guard let handle = UnsafeMutableRawPointer(bitPattern: address) else { return }
        dlclose(handle)
    }
}

struct MediaRemoteAsyncProbeRunner {
    let timeout: DispatchTimeInterval
    let timeoutQueue: DispatchQueue

    init(
        timeout: DispatchTimeInterval = .milliseconds(250),
        timeoutQueue: DispatchQueue = DispatchQueue(label: "Steno.MediaRemote.Timeout", qos: .userInitiated)
    ) {
        self.timeout = timeout
        self.timeoutQueue = timeoutQueue
    }

    @MainActor
    func run<Value: Sendable>(
        _ register: (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = ProbeContinuationGate(continuation: continuation)
            timeoutQueue.asyncAfter(deadline: .now() + timeout) {
                gate.resumeOnce(nil)
            }
            register { value in
                gate.resumeOnce(value)
            }
        }
    }
}

private final class ProbeContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: Value?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        // Never resume while holding the lock. Cancellation handlers may run concurrently.
        continuation.resume(returning: value)
    }
}

#endif
