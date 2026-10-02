#if os(macOS)
import CoreAudio
import Darwin
import Dispatch
import Foundation
import IOKit.pwr_mgt
import ObjectiveC

@MainActor
public final class MacMediaInterruptionService: MediaInterruptionService {
    private static let logger = StenoKitDiagnostics.logger
    static let defaultVerificationDelays: [UInt64] = [
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

    /// Pausing needs Core Audio's per-process output state to confirm which
    /// application is producing audio. That API exists from macOS 15; on
    /// earlier systems no application can be confirmed, so the feature is
    /// unavailable rather than guessing.
    public nonisolated static var isSupportedOnCurrentSystem: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    private let driver: any MediaInterruptionDriving
    private let systemSupportsMediaPausing: Bool
    private let verificationDelays: [UInt64]
    private let resumeVerificationDelays: [UInt64]
    private let resumeLineageGraceDuration: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: @Sendable (UInt64) async -> Void
    private let beforePublishedCustodyReturn: @MainActor @Sendable () async -> Void
    private let afterPauseTransitionCancellation: @MainActor @Sendable () async -> Void
    private let afterPauseTransitionFinalization: @MainActor @Sendable () async -> Void
    private let beforeInitialResumeDispatch: @MainActor @Sendable () async -> Void
    private let beforeOwnerResumeFinalization: @MainActor @Sendable () async -> Void
    private var activeInterruption: ActiveInterruption?
    private var pauseTransition: PauseTransition?
    private var resumeTransition: ResumeTransition?
    private var pendingResumeLineage: PendingResumeLineage?
    private var pendingReleaseVerificationID: UUID?

    public init() {
        let bridge = MediaRemoteBridge()
        self.driver = MacMediaInterruptionDriver(
            bridge: bridge,
            playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
            audioOutputMonitor: CoreAudioOutputMonitor(),
            playbackActivityMonitor: PowerAssertionPlaybackActivityMonitor()
        )
        self.systemSupportsMediaPausing = Self.isSupportedOnCurrentSystem
        self.verificationDelays = Self.defaultVerificationDelays
        self.resumeVerificationDelays = Self.defaultResumeVerificationDelays
        self.resumeLineageGraceDuration = Self.defaultResumeLineageGraceDuration
        self.now = { ProcessInfo.processInfo.systemUptime }
        self.sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        self.beforePublishedCustodyReturn = {}
        self.afterPauseTransitionCancellation = {}
        self.afterPauseTransitionFinalization = {}
        self.beforeInitialResumeDispatch = {}
        self.beforeOwnerResumeFinalization = {}
    }

    init(
        driver: any MediaInterruptionDriving,
        verificationDelays: [UInt64] = [],
        resumeVerificationDelays: [UInt64] = [],
        resumeLineageGraceDuration: TimeInterval = 3,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        beforePublishedCustodyReturn: @escaping @MainActor @Sendable () async -> Void = {},
        afterPauseTransitionCancellation: @escaping @MainActor @Sendable () async -> Void = {},
        afterPauseTransitionFinalization: @escaping @MainActor @Sendable () async -> Void = {},
        beforeInitialResumeDispatch: @escaping @MainActor @Sendable () async -> Void = {},
        beforeOwnerResumeFinalization: @escaping @MainActor @Sendable () async -> Void = {},
        systemSupportsMediaPausing: Bool = true
    ) {
        self.driver = driver
        self.systemSupportsMediaPausing = systemSupportsMediaPausing
        self.verificationDelays = verificationDelays
        self.resumeVerificationDelays = resumeVerificationDelays
        self.resumeLineageGraceDuration = resumeLineageGraceDuration
        self.now = now
        self.sleep = sleep
        self.beforePublishedCustodyReturn = beforePublishedCustodyReturn
        self.afterPauseTransitionCancellation = afterPauseTransitionCancellation
        self.afterPauseTransitionFinalization = afterPauseTransitionFinalization
        self.beforeInitialResumeDispatch = beforeInitialResumeDispatch
        self.beforeOwnerResumeFinalization = beforeOwnerResumeFinalization
    }

    public func beginInterruption() async -> MediaInterruptionToken? {
        guard systemSupportsMediaPausing else { return nil }
        let token = MediaInterruptionToken()
        let result: MediaInterruptionToken? = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            if var activeInterruption {
                activeInterruption.tokenIDs.insert(token.id)
                self.activeInterruption = activeInterruption
                Self.logger.info(
                    "Media interruption joined. Active tokens: \(activeInterruption.tokenIDs.count, privacy: .public)"
                )
                return token
            }
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
                await self?.cancelBegin(tokenID: token.id)
            }
        }
        if Task.isCancelled {
            await cancelBegin(tokenID: token.id)
            return nil
        }
        return result
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
            let custodyGate = PauseCustodyGate()
            let releaseControl = LadderReleaseControl()
            let task = Task { @MainActor [weak self] () -> PauseTransitionOutcome in
                guard let self else {
                    custodyGate.open()
                    return .noOwnership
                }
                let outcome: PauseTransitionOutcome
                if let resumeLineageReceipt {
                    outcome = await self.performResumeLineagePauseTransition(
                        id: transitionID,
                        receipt: resumeLineageReceipt,
                        releaseControl: releaseControl
                    )
                } else {
                    outcome = await self.performPauseTransition(
                        id: transitionID,
                        releaseControl: releaseControl
                    )
                }
                await self.finalizePauseTransition(id: transitionID, outcome: outcome)
                custodyGate.open()
                return outcome
            }
            transition = PauseTransition(
                id: transitionID,
                task: task,
                tokenIDs: [token.id],
                custodyGate: custodyGate,
                releaseControl: releaseControl
            )
            pauseTransition = transition
        }

        // Wait only until the transition has published a custody decision, not
        // until its opportunistic verification ladder finishes.
        await transition.custodyGate.wait()
        await beforePublishedCustodyReturn()

        if Task.isCancelled {
            if activeInterruption?.tokenIDs.contains(token.id) == true {
                await endInterruption(token: token)
            }
            return nil
        }

        guard activeInterruption?.tokenIDs.contains(token.id) == true else { return nil }
        return token
    }

    private func cancelBegin(tokenID: UUID) async {
        if var transition = pauseTransition,
           transition.tokenIDs.remove(tokenID) != nil
        {
            pauseTransition = transition
            if !pauseTransitionHasOwner(id: transition.id) {
                transition.task.cancel()
                await afterPauseTransitionCancellation()
            }
        }
        if var transition = resumeTransition,
           transition.joiningTokenIDs.remove(tokenID) != nil
        {
            resumeTransition = transition
        }
        if var activeInterruption,
           activeInterruption.tokenIDs.remove(tokenID) != nil
        {
            self.activeInterruption = activeInterruption
            if activeInterruption.tokenIDs.isEmpty {
                await finishInterruptionIfUnowned()
            }
        }
    }

    private func performPauseTransition(
        id: UUID,
        releaseControl: LadderReleaseControl
    ) async -> PauseTransitionOutcome {
        let before = await driver.snapshot()
        guard pauseTransition?.id == id,
              pauseTransition?.tokenIDs.isEmpty == false,
              let destination = before.pauseDestination
        else {
            Self.logger.info(
                "Media interruption skipped. Evidence: \(before.logValue, privacy: .private)"
            )
            return .noOwnership
        }

        let requestedApplications = Set(destination.applicationBundleIdentifiers)
        let expectedProcessTargets = before.audioOutputObservation?.targets.filter {
            requestedApplications.contains($0.applicationBundleIdentifier)
        } ?? []
        let verifiedDestination = VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: destination.applicationBundleIdentifiers,
            expectedProcessTargets: expectedProcessTargets
        )
        // Revalidate the exact Core Audio producer immediately before the
        // bundle-targeted command. A process can exit and be replaced by a new
        // same-bundle instance after the snapshot was captured.
        let dispatch = await driver.sendPause(to: verifiedDestination)
        let acceptedApplications = Set(
            dispatch.acceptedApplicationBundleIdentifiers
        ).intersection(requestedApplications)
        Self.logger.info(
            "Semantic media Pause attempted: accepted=\(acceptedApplications.sorted().joined(separator: ","), privacy: .private) destination=\(verifiedDestination.logValue, privacy: .private) evidence=\(before.logValue, privacy: .private)"
        )
        guard !acceptedApplications.isEmpty else { return .noOwnership }

        // An accepted, application-targeted Pause of an application that was
        // confirmed playing takes provisional custody immediately, so the caller
        // is not held up. That custody authorizes nothing by itself: a Play is
        // owed only once the Pause is observed to have stopped playback, by the
        // ladder below or at release.
        guard let acceptedReceipt = PendingPauseReceipt.make(
            before: before,
            acceptedApplications: acceptedApplications
        ) else {
            Self.logger.info(
                "Semantic media Pause was accepted without verified active output; no ownership was created."
            )
            return .noOwnership
        }
        // Custody exists now, so release the caller. The controller awaits
        // beginInterruption inline and the stop path awaits the start task, so
        // blocking on the ladder below would delay capture teardown for every
        // press shorter than the verification window.
        publishInitialCustody(id: id, receipt: acceptedReceipt)

        let acceptedDestination = acceptedReceipt.makeVerifiedReceipt().resumeDestination
        var pendingReceipt: PendingPauseReceipt? = acceptedReceipt
        var verifiedApplications: Set<String> = []
        for (index, delay) in verificationDelays.enumerated() {
            await ladderSleep(delay)
            guard pauseTransition?.id == id else { return .noOwnership }
            let after = await driver.snapshot(
                observing: acceptedReceipt.acceptedApplications
            )
            guard pauseTransition?.id == id else { return .noOwnership }
            Self.logger.info(
                "Media Pause verification pass \(index + 1, privacy: .public): \(after.logValue, privacy: .private)"
            )
            // Each application is verified on its own evidence, and one reading
            // can miss an application another reading saw. What has been seen
            // stopped is kept across passes instead of being required again.
            verifiedApplications.formUnion(
                acceptedReceipt.verifiedApplicationBundleIdentifiers(atRelease: after)
            )
            if verifiedApplications == acceptedReceipt.acceptedApplications {
                return .verified(acceptedReceipt.makeVerifiedReceipt())
            }
            let hasOwner = pauseTransitionHasOwner(id: id)
            let releasing = releaseControl.releaseRequested && !hasOwner
            pendingReceipt = pendingReceipt?
                .recordingVerified(verifiedApplications)
                .retainingCustody(
                    after: after,
                    allowingAcceptedPauseToSettle: releasing
                )
            if !hasOwner { continue }
            guard index < verificationDelays.index(before: verificationDelays.endIndex),
                  pauseTransition?.id == id
            else { continue }
            let stillActiveApplications = acceptedReceipt.acceptedApplications
                .subtracting(verifiedApplications)
            if !stillActiveApplications.isEmpty {
                let retryDestination = acceptedDestination.narrowed(
                    to: stillActiveApplications
                )
                guard after.preservesExactProcessLineage(retryDestination) else {
                    continue
                }
                _ = await driver.sendPause(
                    to: retryDestination
                )
            }
        }

        if let pendingReceipt {
            Self.logger.info(
                "Semantic media Pause has not yet been observed to stop playback; resume authorization is deferred to release."
            )
            return .pending(pendingReceipt)
        }

        // A release adjudicates contradicted custody itself and never plays into
        // fresh contrary evidence; only a cancelled or abandoned transition
        // compensates here, and only for playback this Pause verifiably stopped.
        let hasOwner = pauseTransitionHasOwner(id: id)
        let releasing = releaseControl.releaseRequested && !hasOwner
        if !verifiedApplications.isEmpty, !hasOwner, !releasing {
            _ = await driver.sendPlay(
                to: acceptedDestination.narrowed(to: verifiedApplications)
            )
            Self.logger.info(
                "Cancelled media Pause transition was compensated with exact-lineage Play."
            )
        }
        Self.logger.info(
            "Semantic media Pause custody was contradicted; no resume ownership was authorized."
        )
        return .noOwnership
    }

    private func performResumeLineagePauseTransition(
        id: UUID,
        receipt: MediaPauseReceipt,
        releaseControl: LadderReleaseControl
    ) async -> PauseTransitionOutcome {
        guard pauseTransition?.id == id,
              pauseTransition?.tokenIDs.isEmpty == false
        else { return .noOwnership }

        let lineageSnapshot = await driver.snapshot(
            observing: Set(receipt.resumeDestination.applicationBundleIdentifiers)
        )
        guard pauseTransition?.id == id,
              pauseTransition?.tokenIDs.isEmpty == false,
              lineageSnapshot.detection == .playing
                || lineageSnapshot.detection == .likelyPlaying,
              lineageSnapshot.preservesExactProcessLineage(
                receipt.resumeDestination
              )
        else {
            Self.logger.info(
                "Pending media resume lineage changed before re-Pause; no command was sent."
            )
            return .noOwnership
        }

        let expectedApplications = Set(
            receipt.resumeDestination.applicationBundleIdentifiers
        )
        let dispatch = await driver.sendPause(
            to: receipt.resumeDestination
        )
        let acceptedApplications = Set(
            dispatch.acceptedApplicationBundleIdentifiers
        ).intersection(expectedApplications)
        guard !acceptedApplications.isEmpty else {
            Self.logger.info(
                "Pending media resume lineage Pause was rejected; ownership was not retained."
            )
            return .noOwnership
        }

        let acceptedDestination = receipt.resumeDestination.narrowed(
            to: acceptedApplications
        )
        let acceptedReceipt = MediaPauseReceipt(resumeDestination: acceptedDestination)
        var pendingReceipt = PendingPauseReceipt.makeForAcceptedRePause(
            before: lineageSnapshot,
            destination: acceptedDestination
        )
        if let pendingReceipt {
            // The accepted exact-lineage re-Pause restores custody immediately;
            // the ladder below is opportunistic verification, so the caller is
            // released now instead of after the full window.
            publishInitialCustody(id: id, receipt: pendingReceipt)
        }
        for (index, delay) in verificationDelays.enumerated() {
            await ladderSleep(delay)
            guard pauseTransition?.id == id else { return .noOwnership }

            let snapshot = await driver.snapshot(observing: acceptedApplications)
            guard pauseTransition?.id == id else { return .noOwnership }
            let hasOwner = pauseTransitionHasOwner(id: id)
            let releasing = releaseControl.releaseRequested && !hasOwner

            if snapshot.confirmsPausedProcessLineage(
                acceptedReceipt.resumeDestination
            ) {
                Self.logger.info(
                    "Pending media resume lineage was re-paused and verified."
                )
                return .verified(acceptedReceipt)
            }

            pendingReceipt = pendingReceipt?.retainingCustody(
                after: snapshot,
                allowingAcceptedPauseToSettle: releasing
            )

            if let observation = snapshot.audioOutputObservation,
               observation.unresolvedProcessCount == 0
            {
                let stillActive = acceptedApplications.intersection(
                    observation.applicationBundleIdentifiers
                )
                if stillActive.isEmpty {
                    continue
                }
                guard hasOwner,
                      index < verificationDelays.index(before: verificationDelays.endIndex)
                else { continue }
                let retryDestination = acceptedReceipt.resumeDestination.narrowed(
                    to: stillActive
                )
                guard snapshot.preservesExactProcessLineage(retryDestination) else {
                    continue
                }
                _ = await driver.sendPause(
                    to: retryDestination
                )
            }
        }

        let hasOwner = pauseTransitionHasOwner(id: id)
        let releasing = releaseControl.releaseRequested && !hasOwner
        if let pendingReceipt, hasOwner || releasing {
            Self.logger.info(
                "Media resume-lineage re-Pause remains exact but unverified; retaining pending custody until release."
            )
            return .pending(pendingReceipt)
        }
        if !hasOwner, !releasing {
            _ = await driver.sendPlay(to: acceptedDestination)
            Self.logger.info(
                "Cancelled media resume-lineage re-Pause was compensated with exact-lineage Play."
            )
        }

        Self.logger.info(
            "Media resume-lineage re-Pause remained unverified; no Play command was authorized."
        )
        return .noOwnership
    }

    /// Hands custody to `activeInterruption` as soon as an application-targeted
    /// Pause is accepted for a verified-active application, so
    /// `beginInterruption` can return while the opportunistic verification
    /// ladder keeps running.
    private func publishInitialCustody(id: UUID, receipt: PendingPauseReceipt) {
        guard let transition = pauseTransition,
              transition.id == id,
              activeInterruption == nil
        else { return }
        activeInterruption = ActiveInterruption(
            id: id,
            custody: .pending(receipt),
            tokenIDs: transition.tokenIDs
        )
        Self.logger.info(
            "Media interruption took pending custody. Active tokens: \(transition.tokenIDs.count, privacy: .public)"
        )
        transition.custodyGate.open()
    }

    /// Owner tracking moves to `activeInterruption` once custody is published;
    /// before that the pause transition still holds the tokens.
    private func pauseTransitionHasOwner(id: UUID) -> Bool {
        if let activeInterruption, activeInterruption.id == id {
            return !activeInterruption.tokenIDs.isEmpty
        }
        return pauseTransition?.id == id && pauseTransition?.tokenIDs.isEmpty == false
    }

    /// Records the ladder's final custody decision once its verification task
    /// completes. Runs inside the transition task, so a release that drained the
    /// ladder observes the finalized custody as soon as the await returns.
    private func finalizePauseTransition(
        id: UUID,
        outcome: PauseTransitionOutcome
    ) async {
        guard let transition = pauseTransition, transition.id == id else { return }
        pauseTransition = nil
        let tokenIDs = activeInterruption?.id == id
            ? (activeInterruption?.tokenIDs ?? [])
            : transition.tokenIDs
        switch outcome {
        case .noOwnership:
            if activeInterruption?.id == id {
                activeInterruption = nil
            }
        case .verified(let receipt):
            activeInterruption = ActiveInterruption(
                id: id,
                custody: .verified(receipt),
                tokenIDs: tokenIDs
            )
            Self.logger.info(
                "Media interruption verified. Active tokens: \(tokenIDs.count, privacy: .public)"
            )
        case .pending(let receipt):
            activeInterruption = ActiveInterruption(
                id: id,
                custody: .pending(receipt),
                tokenIDs: tokenIDs
            )
            Self.logger.info(
                "Media interruption retained pending release verification. Active tokens: \(tokenIDs.count, privacy: .public)"
            )
        }
        transition.custodyGate.open()
        if activeInterruption?.id == id, activeInterruption?.tokenIDs.isEmpty == true {
            await finishInterruptionIfUnowned()
        }
        await afterPauseTransitionFinalization()
    }

    /// Release adjudication must not race the opportunistic verification
    /// ladder: a retry Pause dispatched after the resume Play could strand the
    /// application paused. Release latches off retry Pauses and waits for the
    /// ladder's remaining bounded settle window before adjudicating finalized
    /// custody. The ladder is never cancelled here, so its accepted-Pause
    /// resolution guarantees are preserved.
    private func drainPauseVerificationForRelease() async {
        guard let transition = pauseTransition,
              let currentInterruption = activeInterruption,
              currentInterruption.id == transition.id,
              currentInterruption.tokenIDs.isEmpty
        else { return }
        transition.releaseControl.requestRelease()
        _ = await transition.task.value
    }

    /// Ladder pacing between verification passes. The injected sleep runs in a
    /// detached task so neither transition cancellation nor owner release can
    /// collapse the accepted-Pause settling window.
    private func ladderSleep(_ delay: UInt64) async {
        guard delay > 0 else { return }
        let sleep = self.sleep
        await Task.detached {
            await sleep(delay)
        }
        .value
    }

    private func sleepAfterAcceptedPause(_ delay: UInt64) async {
        await sleep(delay)
        guard Task.isCancelled else { return }
        let sleep = self.sleep
        await Task.detached {
            await sleep(delay)
        }.value
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
        await drainPauseVerificationForRelease()
        guard let currentInterruption = activeInterruption,
              currentInterruption.tokenIDs.isEmpty
        else { return }

        switch currentInterruption.custody {
        case .pending(let pendingReceipt):
            guard pendingReleaseVerificationID != currentInterruption.id else { return }
            pendingReleaseVerificationID = currentInterruption.id
            await verifyPendingInterruptionAtRelease(
                interruptionID: currentInterruption.id,
                pendingReceipt: pendingReceipt
            )
            if pendingReleaseVerificationID == currentInterruption.id {
                pendingReleaseVerificationID = nil
            }
            await finishInterruptionIfUnowned()
        case .verified(let receipt):
            activeInterruption = nil
            await startResumeTransition(receipt: receipt)
        }
    }

    private func verifyPendingInterruptionAtRelease(
        interruptionID: UUID,
        pendingReceipt: PendingPauseReceipt
    ) async {
        let releaseSnapshot = await driver.snapshot(
            observing: pendingReceipt.acceptedApplications
        )
        guard var currentInterruption = activeInterruption,
              currentInterruption.id == interruptionID,
              case .pending = currentInterruption.custody
        else { return }

        // What earlier passes saw stopped still counts, unless this reading
        // contradicts custody of that application.
        let uncontradictedReceipt = pendingReceipt.retainingCustody(after: releaseSnapshot)
        let verifiedApplications = pendingReceipt
            .verifiedApplicationBundleIdentifiers(atRelease: releaseSnapshot)
            .intersection(uncontradictedReceipt?.acceptedApplications ?? [])
        let retainedReceipt = uncontradictedReceipt?.recordingVerified(verifiedApplications)
        let hasOwners = !currentInterruption.tokenIDs.isEmpty

        if verifiedApplications == pendingReceipt.acceptedApplications {
            currentInterruption.custody = .verified(pendingReceipt.makeVerifiedReceipt())
            activeInterruption = currentInterruption
            Self.logger.info(
                "Pending media Pause verified at release for exact-app resume ownership."
            )
            if !hasOwners {
                await finishInterruptionIfUnowned()
            }
            return
        }

        if hasOwners {
            if releaseSnapshot.detection == .playing
                || releaseSnapshot.detection == .likelyPlaying
            {
                await repausePendingInterruption(
                    interruptionID: interruptionID,
                    pendingReceipt: pendingReceipt.recordingVerified(verifiedApplications),
                    activeSnapshot: releaseSnapshot
                )
                return
            }
            guard let retainedReceipt else {
                activeInterruption = nil
                Self.logger.info(
                    "Pending media custody was contradicted while owned; ownership was discarded without Play. Evidence: \(releaseSnapshot.logValue, privacy: .private)"
                )
                return
            }
            currentInterruption.custody = .pending(retainedReceipt)
            activeInterruption = currentInterruption
            return
        }

        // Release with no owner left. Custody that continues a pause Steno already
        // verified stays resumable while nothing contradicts it: the application is
        // paused because of Steno. Custody from a first Pause that was never seen
        // to stop playback authorizes nothing beyond what this snapshot verifies.
        activeInterruption = nil
        let resumableApplications = verifiedApplications.union(
            pendingReceipt.continuesVerifiedPause
                ? retainedReceipt?.acceptedApplications ?? []
                : []
        )
        guard !resumableApplications.isEmpty else {
            Self.logger.info(
                "Pending media custody was contradicted at release; no Play command was authorized. Evidence: \(releaseSnapshot.logValue, privacy: .private)"
            )
            return
        }
        Self.logger.info(
            "Pending media Pause resumed at release under preserved exact-app lineage."
        )
        await startResumeTransition(
            receipt: pendingReceipt.makeVerifiedReceipt(narrowedTo: resumableApplications)
        )
    }

    private func repausePendingInterruption(
        interruptionID: UUID,
        pendingReceipt: PendingPauseReceipt,
        activeSnapshot: MediaInterruptionSnapshot
    ) async {
        let destination = pendingReceipt.makeVerifiedReceipt().resumeDestination
        guard activeSnapshot.preservesExactProcessLineage(destination),
              let refreshedReceipt = pendingReceipt.refreshedForRePause(
                before: activeSnapshot
              )
        else {
            if activeInterruption?.id == interruptionID {
                activeInterruption = nil
            }
            Self.logger.info(
                "Active pending media process lineage changed before re-Pause; ownership was discarded without sending a command."
            )
            return
        }

        let dispatch = await driver.sendPause(to: destination)
        guard var currentInterruption = activeInterruption,
              currentInterruption.id == interruptionID,
              case .pending = currentInterruption.custody
        else { return }

        let acceptedApplications = Set(
            dispatch.acceptedApplicationBundleIdentifiers
        ).intersection(pendingReceipt.acceptedApplications)
        guard acceptedApplications == pendingReceipt.acceptedApplications else {
            activeInterruption = nil
            Self.logger.info(
                "Active pending media could not be safely re-paused for a new capture; ownership was discarded without Play."
            )
            return
        }

        currentInterruption.custody = .pending(refreshedReceipt)
        activeInterruption = currentInterruption
        Self.logger.info(
            "Active pending media was re-paused for a new capture without emitting Play."
        )
        if currentInterruption.tokenIDs.isEmpty {
            await finishInterruptionIfUnowned()
        }
    }

    private func startResumeTransition(receipt: MediaPauseReceipt) async {
        activeInterruption = nil
        let transitionID = UUID()
        let task = Task { @MainActor [weak self] () -> ResumeTransitionOutcome in
            guard let self else { return .resumed }
            return await self.performResumeTransition(id: transitionID, receipt: receipt)
        }
        let transition = ResumeTransition(
            id: transitionID,
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
        await beforeInitialResumeDispatch()
        if Task.isCancelled, hasJoiningResumeTokens(id: id) {
            return .retained(receipt)
        }
        let destination = receipt.resumeDestination
        let initialDispatch = await driver.sendPlay(to: destination)
        var acceptedPlayApplications = Set(
            initialDispatch.acceptedApplicationBundleIdentifiers
        )
        Self.logger.info(
            "Semantic media Play attempted destination=\(destination.logValue, privacy: .private)"
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

            let snapshot = await driver.snapshot(observing: expectedApplications)
            if hasJoiningResumeTokens(id: id) {
                return await retainInterruptionDuringResumeJoin(id: id, receipt: receipt)
            }

            if snapshot.confirmsResumedProcessLineage(destination) {
                Self.logger.info(
                    "Semantic media Play verified by exact target playback evidence destination=\(destination.logValue, privacy: .private)"
                )
                return .resumed
            }

            if let activeApplications = snapshot.observedActiveApplicationBundleIdentifiers {
                lastObservedActiveApplications = activeApplications
                if expectedApplications.isSubset(of: activeApplications) {
                    Self.logger.info(
                        "Semantic media Play verified destination=\(destination.logValue, privacy: .private)"
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
                let retryDestination = destination.narrowed(
                    to: missingApplications
                )
                guard snapshot.preservesResumeRetryLineage(retryDestination) else {
                    Self.logger.info(
                        "Semantic media Play retry rejected changed process lineage; no further resume command was sent."
                    )
                    return .resumed
                }
                let retryDispatch = await driver.sendPlay(to: retryDestination)
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
                resumeDestination: destination.narrowed(to: unconfirmedApplications)
            )
            Self.logger.info(
                "Semantic media Play remained unverified; preserving bounded exact-app resume lineage destination=\(pendingReceipt.resumeDestination.logValue, privacy: .private)"
            )
            return .resumedWithPendingLineage(pendingReceipt)
        }
        Self.logger.info(
            "Semantic media Play verification exhausted destination=\(destination.logValue, privacy: .private)"
        )
        return .resumed
    }

    private func retainInterruptionDuringResumeJoin(
        id: UUID,
        receipt: MediaPauseReceipt
    ) async -> ResumeTransitionOutcome {
        let applications = receipt.resumeDestination.applicationBundleIdentifiers
        let expectedApplications = Set(applications)
        guard hasJoiningResumeTokens(id: id) else { return .resumed }
        let lineageSnapshot = await driver.snapshot(observing: expectedApplications)
        guard hasJoiningResumeTokens(id: id),
              lineageSnapshot.detection == .playing
                || lineageSnapshot.detection == .likelyPlaying,
              lineageSnapshot.preservesExactProcessLineage(
                receipt.resumeDestination
              )
        else {
            Self.logger.info(
                "In-flight media resume lineage changed before re-Pause; no lineage command was sent."
            )
            return .resumed
        }

        let initialDispatch = await driver.sendPause(
            to: receipt.resumeDestination
        )
        var acceptedPauseApplications = Set(
            initialDispatch.acceptedApplicationBundleIdentifiers
        ).intersection(expectedApplications)
        Self.logger.info(
            "In-flight media resume was re-paused for a new dictation owner destination=\(receipt.resumeDestination.logValue, privacy: .private)"
        )

        guard !acceptedPauseApplications.isEmpty else {
            Self.logger.info(
                "In-flight media resume re-Pause was rejected; ownership was not retained."
            )
            return .resumed
        }
        let initialAcceptedDestination = receipt.resumeDestination.narrowed(
            to: acceptedPauseApplications
        )
        var pendingReceipt = PendingPauseReceipt.makeForAcceptedRePause(
            before: lineageSnapshot,
            destination: initialAcceptedDestination
        )
        for (index, delay) in verificationDelays.enumerated() {
            await sleepAfterAcceptedPause(delay)
            let snapshot = await driver.snapshot(observing: expectedApplications)
            let acceptedReceipt = MediaPauseReceipt(
                resumeDestination: receipt.resumeDestination.narrowed(
                    to: acceptedPauseApplications
                )
            )
            let hasOwner = hasJoiningResumeTokens(id: id)

            if snapshot.confirmsPausedProcessLineage(
                acceptedReceipt.resumeDestination
            ) {
                return .retained(acceptedReceipt)
            }

            pendingReceipt = pendingReceipt?.retainingCustody(after: snapshot)

            if let observation = snapshot.audioOutputObservation,
               observation.unresolvedProcessCount == 0
            {
                let stillActive = expectedApplications.intersection(
                    observation.applicationBundleIdentifiers
                )
                if stillActive.isEmpty {
                    continue
                }
                guard hasOwner,
                      index < verificationDelays.index(before: verificationDelays.endIndex)
                else { continue }
                let retryDestination = acceptedReceipt.resumeDestination.narrowed(
                    to: stillActive
                )
                guard snapshot.preservesExactProcessLineage(retryDestination) else {
                    continue
                }
                let retryDispatch = await driver.sendPause(
                    to: retryDestination
                )
                acceptedPauseApplications.formUnion(
                    Set(retryDispatch.acceptedApplicationBundleIdentifiers)
                        .intersection(stillActive)
                )
            }
        }

        if hasJoiningResumeTokens(id: id), let pendingReceipt {
            Self.logger.info(
                "In-flight media re-Pause remains exact but unverified; retaining pending custody until release."
            )
            return .retainedPending(pendingReceipt)
        }
        if !acceptedPauseApplications.isEmpty,
           !hasJoiningResumeTokens(id: id)
        {
            let restorationDestination = receipt.resumeDestination.narrowed(
                to: acceptedPauseApplications
            )
            _ = await driver.sendPlay(to: restorationDestination)
            Self.logger.info(
                "Cancelled in-flight media re-Pause was compensated with exact-lineage Play."
            )
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
                id: transition.id,
                custody: .verified(receipt),
                tokenIDs: transition.joiningTokenIDs
            )
            if transition.joiningTokenIDs.isEmpty {
                await finishInterruptionIfUnowned()
            }
        case .retainedPending(let pendingReceipt):
            activeInterruption = ActiveInterruption(
                id: transition.id,
                custody: .pending(pendingReceipt),
                tokenIDs: transition.joiningTokenIDs
            )
            if transition.joiningTokenIDs.isEmpty {
                await finishInterruptionIfUnowned()
            }
        }
    }

    private struct ActiveInterruption {
        let id: UUID
        var custody: PauseCustody
        var tokenIDs: Set<UUID>
    }

    private enum PauseCustody {
        case pending(PendingPauseReceipt)
        case verified(MediaPauseReceipt)
    }

    private struct PendingPauseReceipt {
        let before: MediaInterruptionSnapshot
        let acceptedApplications: Set<String>
        let observedTargets: Set<MediaAudioOutputTarget>
        /// Whether this custody re-pauses applications Steno had already verifiably
        /// paused and was resuming. A first Pause starts without it, and earns
        /// resume ownership only by being observed to stop playback.
        let continuesVerifiedPause: Bool
        /// Applications already seen to have stopped in response to the Pause.
        /// Evidence arrives per application and per reading, and a later reading
        /// that cannot see one application must not undo what an earlier one
        /// established.
        var verifiedApplications: Set<String> = []

        func recordingVerified(_ applications: Set<String>) -> Self {
            var receipt = self
            receipt.verifiedApplications.formUnion(
                applications.intersection(acceptedApplications)
            )
            return receipt
        }

        /// Provisional custody rests on what can actually be observed: the
        /// application was confirmed playing, and an application-targeted Pause was
        /// accepted for it. Elected-session state is not required, because it
        /// describes at most one application and is routinely degraded. Output
        /// processes that could not be resolved narrow the receipt instead of
        /// discarding it.
        static func make(
            before: MediaInterruptionSnapshot,
            acceptedApplications: Set<String>
        ) -> Self? {
            guard !acceptedApplications.isEmpty,
                  let observation = before.audioOutputObservation
            else { return nil }

            let observedTargets = Set(
                observation.targets.filter {
                    acceptedApplications.contains($0.applicationBundleIdentifier)
                }
            )
            let verifiedActiveApplications = Set(
                observedTargets.map(\.applicationBundleIdentifier)
            )
            guard !verifiedActiveApplications.isEmpty else { return nil }

            return Self(
                before: narrowedSnapshot(
                    before,
                    applications: verifiedActiveApplications,
                    targets: observedTargets
                ),
                acceptedApplications: verifiedActiveApplications,
                observedTargets: observedTargets,
                continuesVerifiedPause: false
            )
        }

        static func makeForAcceptedRePause(
            before snapshot: MediaInterruptionSnapshot,
            destination: VerifiedMediaResumeDestination
        ) -> Self? {
            let acceptedApplications = Set(destination.applicationBundleIdentifiers)
            let observedTargets = Set(destination.expectedProcessTargets)
            guard !acceptedApplications.isEmpty,
                  !observedTargets.isEmpty,
                  snapshot.detection == .playing || snapshot.detection == .likelyPlaying,
                  snapshot.preservesExactProcessLineage(destination)
            else { return nil }

            return Self(
                before: narrowedSnapshot(
                    snapshot,
                    applications: acceptedApplications,
                    targets: observedTargets
                ),
                acceptedApplications: acceptedApplications,
                observedTargets: observedTargets,
                continuesVerifiedPause: true
            )
        }

        func refreshedForRePause(
            before snapshot: MediaInterruptionSnapshot
        ) -> Self? {
            let expectedDestination = makeVerifiedReceipt().resumeDestination
            guard snapshot.detection == .playing || snapshot.detection == .likelyPlaying,
                  snapshot.preservesExactProcessLineage(expectedDestination)
            else { return nil }

            // The output lineage is refreshed, but playback is still measured
            // against what was seen before the first Pause. An application that
            // Pause already stopped would otherwise have nothing left to show.
            return Self(
                before: Self.narrowedSnapshot(
                    snapshot,
                    applications: acceptedApplications,
                    targets: observedTargets,
                    playbackEvidence: before
                ),
                acceptedApplications: acceptedApplications,
                observedTargets: observedTargets,
                continuesVerifiedPause: continuesVerifiedPause,
                verifiedApplications: verifiedApplications
            )
        }

        /// Narrows custody to the applications this snapshot does not contradict,
        /// or `nil` when none remain. Custody is per application: one application
        /// losing its lineage never discards another's. Once release has started,
        /// same-process playback remains provisional until the final release
        /// snapshot because an accepted Pause can take effect after this pass.
        func retainingCustody(
            after snapshot: MediaInterruptionSnapshot,
            allowingAcceptedPauseToSettle: Bool = false
        ) -> Self? {
            let retainedApplications = acceptedApplications.filter {
                !contradictsPendingCustody(
                    snapshot,
                    for: $0,
                    allowingAcceptedPauseToSettle: allowingAcceptedPauseToSettle
                )
            }
            guard !retainedApplications.isEmpty else { return nil }
            guard retainedApplications != acceptedApplications else { return self }
            return narrowed(to: retainedApplications)
        }

        /// A still-open output stream never contradicts custody: teardown lags an
        /// accepted Pause by seconds, and a weak-positive playing bit can stay set
        /// long after real silence.
        ///
        /// Lineage is judged purely in the Core Audio process domain. The elected
        /// now-playing session names a different process than the output producer
        /// by construction — Chrome elects its main process while the renderer
        /// helper owns the stream — so neither an elected process that is absent
        /// from the producer set nor drifting elected content is evidence about
        /// this application's custody. Only a replaced producer process, a media
        /// session that has disappeared, or fresh strong-positive playback
        /// evidence corroborated for this exact application, contradicts.
        private func contradictsPendingCustody(
            _ snapshot: MediaInterruptionSnapshot,
            for applicationBundleIdentifier: String,
            allowingAcceptedPauseToSettle: Bool
        ) -> Bool {
            let expectedTargets = observedTargets.filter {
                $0.applicationBundleIdentifier == applicationBundleIdentifier
            }
            // Custody of an application whose session has disappeared cannot be
            // redeemed: its Play would be handed to another application.
            if snapshot.sessionPlaybackByApplication[applicationBundleIdentifier] == .noSession {
                return true
            }
            guard let observation = snapshot.audioOutputObservation else { return false }
            let observedApplicationTargets = Set(
                observation.targets.filter {
                    $0.applicationBundleIdentifier == applicationBundleIdentifier
                }
            )
            guard observedApplicationTargets.isSubset(of: expectedTargets) else {
                return true
            }
            return !allowingAcceptedPauseToSettle
                && snapshot.detection == .playing
                && snapshot.target?.bundleIdentifier == applicationBundleIdentifier
                && !observedApplicationTargets.isEmpty
        }

        func narrowed(to applications: Set<String>) -> Self {
            let targets = observedTargets.filter {
                applications.contains($0.applicationBundleIdentifier)
            }
            return Self(
                before: Self.narrowedSnapshot(
                    before,
                    applications: applications,
                    targets: targets
                ),
                acceptedApplications: applications,
                observedTargets: targets,
                continuesVerifiedPause: continuesVerifiedPause,
                verifiedApplications: verifiedApplications.intersection(applications)
            )
        }

        func makeVerifiedReceipt(
            narrowedTo applications: Set<String>? = nil
        ) -> MediaPauseReceipt {
            let resolvedApplications = applications.map {
                acceptedApplications.intersection($0)
            } ?? acceptedApplications
            return MediaPauseReceipt(
                resumeDestination: VerifiedMediaResumeDestination(
                    applicationBundleIdentifiers: resolvedApplications.sorted(),
                    expectedProcessTargets: observedTargets
                        .filter {
                            resolvedApplications.contains($0.applicationBundleIdentifier)
                        }
                        .sorted { $0.processID < $1.processID }
                )
            )
        }

        /// Everything seen stopped so far: earlier readings plus this one.
        func verifiedApplicationBundleIdentifiers(
            atRelease snapshot: MediaInterruptionSnapshot
        ) -> Set<String> {
            verifiedApplications.union(
                snapshot.confirmedPausedApplicationBundleIdentifiers(
                    from: before,
                    among: acceptedApplications
                )
            )
        }

        private static func narrowedSnapshot(
            _ snapshot: MediaInterruptionSnapshot,
            applications: Set<String>,
            targets: Set<MediaAudioOutputTarget>,
            playbackEvidence: MediaInterruptionSnapshot? = nil
        ) -> MediaInterruptionSnapshot {
            let playbackEvidence = playbackEvidence ?? snapshot
            let target = snapshot.target.flatMap { target in
                applications.contains(target.bundleIdentifier) ? target : nil
            }
            return MediaInterruptionSnapshot(
                target: target,
                contentIdentifier: target == nil ? nil : snapshot.contentIdentifier,
                detection: snapshot.detection,
                nowPlayingIsPlaying: snapshot.nowPlayingIsPlaying,
                playbackState: snapshot.playbackState,
                audioOutputObservation: MediaAudioOutputObservation(
                    targets: targets.sorted { $0.processID < $1.processID },
                    unresolvedProcessCount: 0
                ),
                playbackActivityObservation: playbackEvidence.playbackActivityObservation?
                    .narrowed(to: applications),
                sessionPlaybackByApplication: playbackEvidence.sessionPlaybackByApplication
                    .filter { applications.contains($0.key) }
            )
        }
    }

    private enum PauseTransitionOutcome {
        case noOwnership
        case pending(PendingPauseReceipt)
        case verified(MediaPauseReceipt)
    }

    private struct PauseTransition {
        let id: UUID
        let task: Task<PauseTransitionOutcome, Never>
        var tokenIDs: Set<UUID>
        let custodyGate: PauseCustodyGate
        let releaseControl: LadderReleaseControl
    }

    /// Latched gate that releases `beginInterruption` once the transition has
    /// published a custody decision, whether or not its verification ladder has
    /// finished.
    @MainActor
    private final class PauseCustodyGate {
        private var isOpen = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    /// Latches owner release while the in-flight verification ladder finishes
    /// its bounded settle window. Ladder passes stop retrying Pause after this
    /// flips, but their configured pacing remains intact.
    @MainActor
    private final class LadderReleaseControl {
        private(set) var releaseRequested = false

        func requestRelease() {
            releaseRequested = true
        }
    }

    private struct ResumeTransition {
        let id: UUID
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
        case retainedPending(PendingPauseReceipt)
    }
}

enum SemanticMediaCommand: Int32, Sendable, Equatable {
    case play = 0
    case pause = 1

    var logValue: String {
        switch self {
        case .play: "Play"
        case .pause: "Pause"
        }
    }
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
    let expectedProcessTargets: [MediaAudioOutputTarget]

    init(
        applicationBundleIdentifiers: [String],
        expectedProcessTargets: [MediaAudioOutputTarget]
    ) {
        let applications = Set(applicationBundleIdentifiers)
        self.applicationBundleIdentifiers = applications.sorted()
        self.expectedProcessTargets = Array(Set(expectedProcessTargets))
            .filter { applications.contains($0.applicationBundleIdentifier) }
            .sorted {
                if $0.applicationBundleIdentifier == $1.applicationBundleIdentifier {
                    return $0.processID < $1.processID
                }
                return $0.applicationBundleIdentifier < $1.applicationBundleIdentifier
            }
    }

    func narrowed(to applicationBundleIdentifiers: Set<String>) -> Self {
        Self(
            applicationBundleIdentifiers: self.applicationBundleIdentifiers.filter(
                applicationBundleIdentifiers.contains
            ),
            expectedProcessTargets: expectedProcessTargets.filter {
                applicationBundleIdentifiers.contains($0.applicationBundleIdentifier)
            }
        )
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

    let processStartTimeMicroseconds: UInt64?

    init(
        processID: Int32,
        applicationBundleIdentifier: String,
        processStartTimeMicroseconds: UInt64? = nil
    ) {
        self.processID = processID
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.processStartTimeMicroseconds = processStartTimeMicroseconds
    }
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

/// A sleep-preventing power assertion held by one of an application's own
/// processes.
struct MediaPlaybackAssertion: Sendable, Equatable, Hashable {
    let applicationBundleIdentifier: String
    let identifier: UInt64
}

/// Which applications are keeping the system awake for playback right now.
///
/// A player holds a sleep-preventing power assertion while it is actually
/// playing and releases it when playback pauses, usually at once. Its Core
/// Audio output stream, by contrast, stays open for seconds after a pause. The
/// assertions therefore separate an application that is playing from one that
/// was paused earlier, which the output stream alone cannot do.
struct MediaPlaybackActivityObservation: Sendable, Equatable {
    /// The applications this reading covers. An application outside it was not
    /// read, so nothing is known about it: its absence from `assertions` is
    /// neither "holds nothing" nor "released".
    let observedApplications: Set<String>
    let assertions: Set<MediaPlaybackAssertion>

    var applicationBundleIdentifiers: Set<String> {
        Set(assertions.map(\.applicationBundleIdentifier))
    }

    func assertions(
        forApplication applicationBundleIdentifier: String
    ) -> Set<MediaPlaybackAssertion> {
        assertions.filter {
            $0.applicationBundleIdentifier == applicationBundleIdentifier
        }
    }

    func narrowed(to applicationBundleIdentifiers: Set<String>) -> Self {
        Self(
            observedApplications: observedApplications
                .intersection(applicationBundleIdentifiers),
            assertions: assertions.filter {
                applicationBundleIdentifiers.contains($0.applicationBundleIdentifier)
            }
        )
    }
}

/// What the system's media session registry reports about one application's
/// own now-playing session.
enum MediaSessionPlayback: Sendable, Equatable {
    /// The application has no now-playing session. A command addressed to it
    /// would be rerouted to whichever application the system considers to be
    /// now playing.
    case noSession
    case playing
    case stopped
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
    let playbackActivityObservation: MediaPlaybackActivityObservation?
    /// Per-application session state, for the applications whose state could be
    /// read. An application that is absent is unknown.
    let sessionPlaybackByApplication: [String: MediaSessionPlayback]

    /// An application is paused only when it is confirmed playing: it has an
    /// active Core Audio output stream, and either it is holding a playback
    /// assertion or its own media session reports that it is playing.
    ///
    /// The output stream identifies the exact producer process, but it stays
    /// open for seconds after a pause, so by itself it cannot tell playing media
    /// from media the listener just paused. The playback assertion is released
    /// when playback stops, and the session records the instant it stopped. An
    /// application with an open stream and neither sign of playback is left
    /// alone: Steno only touches playback it can later restore.
    ///
    /// The session can also rule an application out. One whose session reports
    /// that it has stopped is not playing, whatever assertion it still holds.
    /// One with no session at all is never sent a command, because the system
    /// would hand that command to a different application.
    ///
    /// The elected now-playing session reports at most one application and is
    /// frequently degraded, so it may only veto the single application it is
    /// actually about. It never vetoes other applications with independent active
    /// output, and `unknown` detection never blocks a confirmed target.
    /// Output processes that cannot be resolved to an application narrow the
    /// destination instead of cancelling it; they are simply never paused.
    var pauseDestination: MediaPauseDestination? {
        guard let audioOutputObservation else { return nil }
        let applicationsHoldingAssertions = playbackActivityObservation?
            .applicationBundleIdentifiers ?? []
        var observedApplications = audioOutputObservation.applicationBundleIdentifiers
            .filter { application in
                switch sessionPlaybackByApplication[application] {
                case .noSession, .stopped:
                    false
                case .playing:
                    true
                case nil:
                    applicationsHoldingAssertions.contains(application)
                }
            }
        if detection == .notPlaying, let target {
            observedApplications.remove(target.bundleIdentifier)
        }
        guard !observedApplications.isEmpty else { return nil }
        return .observedApplications(observedApplications.sorted())
    }

    var observedActiveApplicationBundleIdentifiers: Set<String>? {
        audioOutputObservation.map(\.applicationBundleIdentifiers)
    }

    /// Whether the application is seen to have stopped playing since `before`:
    /// its session went from playing to stopped, or it released a playback
    /// assertion it held in `before`. Assertions are compared by identity, so
    /// one the application takes later for new playback never hides the release.
    func observesPlaybackStopped(
        since before: MediaInterruptionSnapshot,
        forApplication applicationBundleIdentifier: String
    ) -> Bool {
        if before.sessionPlaybackByApplication[applicationBundleIdentifier] == .playing,
           sessionPlaybackByApplication[applicationBundleIdentifier] == .stopped
        {
            return true
        }
        // An application this reading does not cover is unknown. Reading it as
        // "holds nothing" would turn a stream that merely closed into a stop.
        guard let beforeActivity = before.playbackActivityObservation,
              let currentActivity = playbackActivityObservation,
              currentActivity.observedApplications.contains(applicationBundleIdentifier)
        else { return false }
        let heldBefore = beforeActivity.assertions(
            forApplication: applicationBundleIdentifier
        )
        guard !heldBefore.isEmpty else { return false }
        return !heldBefore.isSubset(
            of: currentActivity.assertions(forApplication: applicationBundleIdentifier)
        )
    }

    func preservesExactProcessLineage(
        _ destination: VerifiedMediaResumeDestination
    ) -> Bool {
        let expectedApplications = Set(destination.applicationBundleIdentifiers)
        let expectedTargets = Set(destination.expectedProcessTargets)
        guard !expectedApplications.isEmpty,
              !expectedTargets.isEmpty,
              let observation = audioOutputObservation,
              observation.unresolvedProcessCount == 0
        else { return false }

        let observedTargets = Set(observation.targets)
        guard expectedTargets.isSubset(of: observedTargets) else { return false }
        let observedExpectedApplicationTargets = Set(
            observedTargets.filter {
                expectedApplications.contains($0.applicationBundleIdentifier)
            }
        )
        guard observedExpectedApplicationTargets == expectedTargets else { return false }

        if let target,
           expectedApplications.contains(target.bundleIdentifier)
        {
            return expectedTargets.contains {
                $0.processID == target.processID
                    && $0.applicationBundleIdentifier == target.bundleIdentifier
            }
        }
        return true
    }

    func confirmsPausedProcessLineage(
        _ destination: VerifiedMediaResumeDestination
    ) -> Bool {
        let expectedApplications = Set(destination.applicationBundleIdentifiers)
        let expectedTargets = Set(destination.expectedProcessTargets)
        if let target,
           expectedApplications.contains(target.bundleIdentifier),
           !expectedTargets.contains(where: {
                $0.processID == target.processID
                    && $0.applicationBundleIdentifier == target.bundleIdentifier
           })
        {
            return false
        }
        guard let observation = audioOutputObservation,
              observation.unresolvedProcessCount == 0
        else { return false }

        let activeExpectedApplicationTargets = Set(observation.targets.filter {
            expectedApplications.contains($0.applicationBundleIdentifier)
        })
        guard activeExpectedApplicationTargets.isSubset(of: expectedTargets) else {
            return false
        }
        if activeExpectedApplicationTargets.isEmpty {
            guard target.map({ expectedApplications.contains($0.bundleIdentifier) }) == true
            else { return true }
            return detection != .playing
                && detection != .likelyPlaying
                && nowPlayingIsPlaying != true
        }
        return detection == .notPlaying
            && preservesExactProcessLineage(destination)
            && nowPlayingIsPlaying != true
    }

    func preservesResumeRetryLineage(
        _ destination: VerifiedMediaResumeDestination
    ) -> Bool {
        let expectedApplications = Set(destination.applicationBundleIdentifiers)
        let expectedTargets = Set(destination.expectedProcessTargets)
        guard !expectedApplications.isEmpty,
              !expectedTargets.isEmpty
        else { return false }

        var matchedExpectedTarget = false
        if let target,
           expectedApplications.contains(target.bundleIdentifier)
        {
            matchedExpectedTarget = expectedTargets.contains {
                $0.processID == target.processID
                    && $0.applicationBundleIdentifier == target.bundleIdentifier
            }
            guard matchedExpectedTarget else { return false }
        }

        guard let observation = audioOutputObservation else {
            return matchedExpectedTarget
        }
        guard observation.unresolvedProcessCount == 0 else { return false }
        let observedExpectedApplicationTargets = Set(
            observation.targets.filter {
                expectedApplications.contains($0.applicationBundleIdentifier)
            }
        )
        guard observedExpectedApplicationTargets.isSubset(of: expectedTargets) else {
            return false
        }
        return true
    }

    func confirmsResumedProcessLineage(
        _ destination: VerifiedMediaResumeDestination
    ) -> Bool {
        let expectedApplications = Set(destination.applicationBundleIdentifiers)
        let expectedTargets = Set(destination.expectedProcessTargets)
        guard detection == .playing,
              nowPlayingIsPlaying != false,
              let target,
              expectedApplications.contains(target.bundleIdentifier),
              expectedTargets.contains(where: {
                $0.processID == target.processID
                    && $0.applicationBundleIdentifier == target.bundleIdentifier
              })
        else { return false }
        return preservesResumeRetryLineage(destination)
    }

    func confirmedPausedApplicationBundleIdentifiers(
        from before: MediaInterruptionSnapshot,
        among candidates: Set<String>
    ) -> Set<String> {
        guard let beforeObservation = before.audioOutputObservation,
              let afterObservation = audioOutputObservation
        else { return [] }
        // An output process that cannot be tied to any application is not
        // evidence about these applications. It limits only the check below
        // that rests on the elected session, which names a single process.
        let everyOutputProcessIsResolved = beforeObservation.unresolvedProcessCount == 0
            && afterObservation.unresolvedProcessCount == 0

        let beforeTargets = Set(beforeObservation.targets)
        let afterTargets = Set(afterObservation.targets)
        var confirmedApplications: Set<String> = []

        for candidate in candidates {
            let originalTargets = Set(beforeTargets.filter {
                $0.applicationBundleIdentifier == candidate
            })
            let currentTargets = Set(afterTargets.filter {
                $0.applicationBundleIdentifier == candidate
            })
            guard !originalTargets.isEmpty,
                  currentTargets.isSubset(of: originalTargets)
            else { continue }
            // An application whose session is gone cannot be resumed: a Play
            // addressed to it would reach a different application.
            guard sessionPlaybackByApplication[candidate] != .noSession else { continue }

            // The application being seen to stop playing since the Pause is
            // what shows the Pause worked. A closed output stream alone does
            // not: the stream of media the listener paused earlier closes the
            // same way. This is judged on the application's own evidence, so
            // the elected session can contradict it only with strong evidence
            // that this application is playing.
            if observesPlaybackStopped(since: before, forApplication: candidate) {
                if detection != .playing || target?.bundleIdentifier != candidate {
                    confirmedApplications.insert(candidate)
                }
                continue
            }

            guard everyOutputProcessIsResolved else { continue }

            let beforeCandidateTarget = before.target.flatMap { target in
                target.bundleIdentifier == candidate ? target : nil
            }
            let currentCandidateTarget = target.flatMap { target in
                target.bundleIdentifier == candidate ? target : nil
            }
            // A different process of the same application taking over the elected
            // session is per-application evidence and still vetoes verification.
            if let currentCandidateTarget,
               currentCandidateTarget != beforeCandidateTarget
            {
                continue
            }
            // Content drift only vetoes while the same elected session is still
            // reported. A vanished elected session says nothing about this
            // application.
            if let beforeCandidateTarget,
               currentCandidateTarget == beforeCandidateTarget,
               before.contentIdentifier != nil,
               contentIdentifier != before.contentIdentifier
            {
                continue
            }

            // Where the elected session is trustworthy, the same session going
            // from confirmed playing to confirmed not playing shows the stop too.
            if before.detection == .playing,
               detection == .notPlaying,
               nowPlayingIsPlaying != true,
               let beforeTarget = before.target,
               target == beforeTarget,
               beforeTarget.bundleIdentifier == candidate,
               currentTargets.count == 1,
               currentTargets.contains(where: {
                    $0.processID == beforeTarget.processID
                        && $0.applicationBundleIdentifier == beforeTarget.bundleIdentifier
               })
            {
                confirmedApplications.insert(candidate)
            }
        }

        return confirmedApplications
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
        let activityValue = playbackActivityObservation.map { observation in
            "[\(observation.applicationBundleIdentifiers.sorted().joined(separator: ","))]"
        } ?? "unavailable"
        let sessionValue = sessionPlaybackByApplication
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        return "target=\(targetValue) detection=\(detection.logValue) electedPlaying=\(playingValue) state=\(stateValue) activeOutput=\(outputValue) playbackActivity=\(activityValue) sessions=[\(sessionValue)]"
    }

}

@MainActor
protocol MediaInterruptionDriving: AnyObject {
    func snapshot() async -> MediaInterruptionSnapshot
    /// A snapshot whose playback evidence also covers the given applications,
    /// whether or not they still have an open output stream. Verification uses
    /// it so that an application whose stream has closed is still read instead
    /// of dropping out of the evidence.
    func snapshot(
        observing applicationBundleIdentifiers: Set<String>
    ) async -> MediaInterruptionSnapshot
    func sendPause(to destination: MediaPauseDestination) async -> MediaCommandDispatchResult
    func sendPause(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult
    func sendPlay(to destination: VerifiedMediaResumeDestination) async -> MediaCommandDispatchResult
}

extension MediaInterruptionDriving {
    func snapshot(
        observing applicationBundleIdentifiers: Set<String>
    ) async -> MediaInterruptionSnapshot {
        await snapshot()
    }
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
    /// Reports the application's own now-playing session, or `nil` when that
    /// cannot be determined.
    func applicationSessionPlayback(
        forApplicationBundleIdentifier applicationBundleIdentifier: String
    ) async -> MediaSessionPlayback?
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
    private let processStartTimeMicrosecondsProvider: (Int32) -> UInt64?

    init(
        processPath: @escaping (Int32) -> String? = Self.runningProcessPath,
        bundleIdentifierAtURL: @escaping (URL) -> String? = {
            Bundle(url: $0)?.bundleIdentifier
        },
        processStartTimeMicroseconds: @escaping (Int32) -> UInt64? = Self.runningProcessStartTimeMicroseconds
    ) {
        self.processPath = processPath
        self.bundleIdentifierAtURL = bundleIdentifierAtURL
        self.processStartTimeMicrosecondsProvider = processStartTimeMicroseconds
    }

    func applicationBundleIdentifier(
        for processID: Int32
    ) -> String? {
        guard let processPath = processPath(processID) else { return nil }

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
        return nil
    }

    func processStartTimeMicroseconds(for processID: Int32) -> UInt64? {
        processStartTimeMicrosecondsProvider(processID)
    }

    private static func runningProcessPath(processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let pathBytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    private static func runningProcessStartTimeMicroseconds(processID: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                expectedSize
            )
        }
        guard actualSize == expectedSize else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}

struct ActiveAudioProcessRecord: Sendable, Equatable {
    let processID: Int32?
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
                    .applicationBundleIdentifier(for: processID),
                  !applicationBundleIdentifier.isEmpty,
                  let processStartTimeMicroseconds = applicationResolver
                    .processStartTimeMicroseconds(for: processID)
            else {
                unresolvedProcessCount += 1
                continue
            }

            targets.append(
                MediaAudioOutputTarget(
                    processID: processID,
                    applicationBundleIdentifier: applicationBundleIdentifier,
                    processStartTimeMicroseconds: processStartTimeMicroseconds
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
                "Core Audio output discovery unavailable: \(String(describing: error), privacy: .private)"
            )
            return nil
        }

        var activeProcesses: [ActiveAudioProcessRecord] = []
        var activeProcessCount = 0
        for process in processes {
            guard (try? process.isRunningOutput) == true else { continue }
            activeProcessCount += 1

            activeProcesses.append(
                ActiveAudioProcessRecord(
                    processID: try? process.pid
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
protocol PlaybackActivityMonitoring: AnyObject {
    /// Returns the playback assertions held by the given applications, or `nil`
    /// when the system's assertions cannot be read.
    func observePlaybackActivity(
        forApplications applicationBundleIdentifiers: Set<String>
    ) -> MediaPlaybackActivityObservation?
}

struct PowerAssertionRecord: Sendable, Equatable {
    let ownerProcessID: Int32
    let type: String
    let level: Int
    let identifier: UInt64
}

struct PlaybackActivityObservationBuilder {
    /// The assertion types a player takes to keep the system or display awake
    /// while it plays, under both their current and their legacy names.
    static let sleepPreventingAssertionTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventUserIdleDisplaySleep",
        "PreventSystemSleep",
        "NoIdleSleepAssertion",
        "NoDisplaySleepAssertion",
    ]

    let applicationResolver: AudioProcessApplicationResolver

    /// Keeps only active sleep-preventing assertions owned by a process of one
    /// of the given applications. Assertions the audio server holds on an
    /// application's behalf are owned by the audio server, so they are left
    /// out: they follow the output stream and lag a pause the same way it does.
    func makeObservation(
        from records: [PowerAssertionRecord],
        forApplications applicationBundleIdentifiers: Set<String>
    ) -> MediaPlaybackActivityObservation {
        var applicationsByProcessID: [Int32: String?] = [:]
        var assertions: Set<MediaPlaybackAssertion> = []
        for record in records {
            guard record.level != 0,
                  Self.sleepPreventingAssertionTypes.contains(record.type)
            else { continue }
            let application: String?
            if let resolved = applicationsByProcessID[record.ownerProcessID] {
                application = resolved
            } else {
                application = applicationResolver.applicationBundleIdentifier(
                    for: record.ownerProcessID
                )
                applicationsByProcessID[record.ownerProcessID] = application
            }
            guard let application,
                  applicationBundleIdentifiers.contains(application)
            else { continue }
            assertions.insert(
                MediaPlaybackAssertion(
                    applicationBundleIdentifier: application,
                    identifier: record.identifier
                )
            )
        }
        return MediaPlaybackActivityObservation(
            observedApplications: applicationBundleIdentifiers,
            assertions: assertions
        )
    }
}

@MainActor
final class PowerAssertionPlaybackActivityMonitor: PlaybackActivityMonitoring {
    private static let logger = StenoKitDiagnostics.logger
    private let applicationResolver: AudioProcessApplicationResolver

    init(applicationResolver: AudioProcessApplicationResolver = AudioProcessApplicationResolver()) {
        self.applicationResolver = applicationResolver
    }

    func observePlaybackActivity(
        forApplications applicationBundleIdentifiers: Set<String>
    ) -> MediaPlaybackActivityObservation? {
        guard !applicationBundleIdentifiers.isEmpty else {
            return MediaPlaybackActivityObservation(observedApplications: [], assertions: [])
        }
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard status == kIOReturnSuccess else {
            Self.logger.debug(
                "Power assertion discovery unavailable: \(status, privacy: .public)"
            )
            return nil
        }
        guard let records = Self.records(
            fromAssertionsByProcess: assertionsByProcess?.takeRetainedValue()
        ) else {
            Self.logger.debug("Power assertion list had an unexpected shape.")
            return nil
        }
        let observation = PlaybackActivityObservationBuilder(
            applicationResolver: applicationResolver
        ).makeObservation(
            from: records,
            forApplications: applicationBundleIdentifiers
        )
        Self.logger.debug(
            "Power assertion discovery assertions=\(records.count, privacy: .public) playback=\(observation.assertions.count, privacy: .public)"
        )
        return observation
    }
}

extension PowerAssertionPlaybackActivityMonitor {
    /// Success without a dictionary means no process holds an assertion. A
    /// dictionary that cannot be read is not that: it is an unknown, and
    /// returning an empty list for it would look like every assertion had been
    /// released.
    nonisolated static func records(
        fromAssertionsByProcess assertionsByProcess: CFDictionary?
    ) -> [PowerAssertionRecord]? {
        guard let assertionsByProcess else { return [] }
        guard let assertions = assertionsByProcess as? [NSNumber: [[String: Any]]] else {
            return nil
        }
        var records: [PowerAssertionRecord] = []
        for (processID, processAssertions) in assertions {
            for assertion in processAssertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      let identifier = (assertion["GlobalUniqueID"] as? NSNumber)
                        ?? (assertion["AssertionId"] as? NSNumber)
                else { continue }
                let level = (assertion[kIOPMAssertionLevelKey as String] as? NSNumber)?
                    .intValue ?? Int(kIOPMAssertionLevelOn)
                records.append(
                    PowerAssertionRecord(
                        ownerProcessID: processID.int32Value,
                        type: type,
                        level: level,
                        identifier: identifier.uint64Value
                    )
                )
            }
        }
        return records
    }
}

@MainActor
final class MacMediaInterruptionDriver: MediaInterruptionDriving {
    private static let logger = StenoKitDiagnostics.logger
    private let bridge: any MediaRemoteBridging
    private let playbackDetector: MultiSignalMediaPlaybackStateDetector
    private let audioOutputMonitor: any AudioOutputMonitoring
    private let playbackActivityMonitor: any PlaybackActivityMonitoring
    private let applicationResolver: AudioProcessApplicationResolver

    init(
        bridge: any MediaRemoteBridging,
        playbackDetector: MultiSignalMediaPlaybackStateDetector,
        audioOutputMonitor: any AudioOutputMonitoring,
        playbackActivityMonitor: any PlaybackActivityMonitoring,
        applicationResolver: AudioProcessApplicationResolver = AudioProcessApplicationResolver()
    ) {
        self.bridge = bridge
        self.playbackDetector = playbackDetector
        self.audioOutputMonitor = audioOutputMonitor
        self.playbackActivityMonitor = playbackActivityMonitor
        self.applicationResolver = applicationResolver
    }

    func snapshot() async -> MediaInterruptionSnapshot {
        await snapshot(observing: [])
    }

    func snapshot(
        observing applicationBundleIdentifiers: Set<String>
    ) async -> MediaInterruptionSnapshot {
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
        // Playback evidence is read for every application with an open output
        // stream and for the applications the caller is tracking. A tracked
        // application whose stream has closed must still be read: leaving it
        // out would make the closed stream look like a stop.
        let evidenceApplications = audioOutputObservation.map {
            $0.applicationBundleIdentifiers.union(applicationBundleIdentifiers)
        }
        let sessionPlaybackByApplication = await sessionPlayback(
            forApplications: evidenceApplications ?? []
        )
        // Read last, after the slower probes, so it describes the moment just
        // before any command is sent.
        let playbackActivityObservation = evidenceApplications.flatMap {
            playbackActivityMonitor.observePlaybackActivity(forApplications: $0)
        }

        return MediaInterruptionSnapshot(
            target: target,
            contentIdentifier: target == nil ? nil : resolvedContentIdentifier,
            detection: resolvedEvidence.result,
            nowPlayingIsPlaying: resolvedEvidence.nowPlayingIsPlaying,
            playbackState: resolvedEvidence.playbackState,
            audioOutputObservation: audioOutputObservation,
            playbackActivityObservation: playbackActivityObservation,
            sessionPlaybackByApplication: sessionPlaybackByApplication
        )
    }

    private func sessionPlayback(
        forApplications applicationBundleIdentifiers: Set<String>
    ) async -> [String: MediaSessionPlayback] {
        let bridge = self.bridge
        let tasks = applicationBundleIdentifiers.map { applicationBundleIdentifier in
            Task { @MainActor () -> (String, MediaSessionPlayback?) in
                let playback = await bridge.applicationSessionPlayback(
                    forApplicationBundleIdentifier: applicationBundleIdentifier
                )
                return (applicationBundleIdentifier, playback)
            }
        }
        var sessionPlaybackByApplication: [String: MediaSessionPlayback] = [:]
        for task in tasks {
            let (applicationBundleIdentifier, playback) = await task.value
            sessionPlaybackByApplication[applicationBundleIdentifier] = playback
        }
        return sessionPlaybackByApplication
    }

    func sendPause(to destination: MediaPauseDestination) async -> MediaCommandDispatchResult {
        await send(
            .pause,
            toApplicationBundleIdentifiers: destination.applicationBundleIdentifiers
        )
    }

    func sendPause(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        await sendVerified(.pause, to: destination)
    }

    func sendPlay(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        await sendVerified(.play, to: destination)
    }

    private func sendVerified(
        _ command: SemanticMediaCommand,
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        let verifiedApplications = destination.applicationBundleIdentifiers.filter {
            applicationBundleIdentifier in
            let expectedTargets = destination.expectedProcessTargets.filter {
                $0.applicationBundleIdentifier == applicationBundleIdentifier
            }
            guard !expectedTargets.isEmpty else { return false }
            var hasSurvivingOriginalProcess = false
            for target in expectedTargets {
                guard let resolvedApplication = applicationResolver
                    .applicationBundleIdentifier(for: target.processID)
                else { continue }
                guard resolvedApplication == applicationBundleIdentifier else {
                    return false
                }
                if let expectedStartTime = target.processStartTimeMicroseconds {
                    guard applicationResolver.processStartTimeMicroseconds(
                        for: target.processID
                    ) == expectedStartTime else {
                        return false
                    }
                }
                hasSurvivingOriginalProcess = true
            }
            return hasSurvivingOriginalProcess
        }
        let rejectedCount = destination.applicationBundleIdentifiers.count
            - verifiedApplications.count
        if rejectedCount > 0 {
            Self.logger.info(
                "Semantic media \(command.logValue, privacy: .public) rejected stale process lineage: rejected=\(rejectedCount, privacy: .public)."
            )
        }
        return await send(
            command,
            toApplicationBundleIdentifiers: verifiedApplications
        )
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
                // A session can disappear between the snapshot and the command,
                // or during a long capture. The system hands a command for an
                // application with no session to another application, so no
                // command of either kind is ever sent to one.
                let session = await bridge.applicationSessionPlayback(
                    forApplicationBundleIdentifier: applicationBundleIdentifier
                )
                guard session != .noSession else {
                    Self.logger.info(
                        "Semantic media \(command.logValue, privacy: .public) withheld from an application with no media session."
                    )
                    return (applicationBundleIdentifier, false)
                }
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
    private let pauseAcknowledgementRunner: MediaRemoteAsyncProbeRunner

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
    private let sendCommandOverride: TargetedCommandDispatch?
    private let playbackRateInfoKey: String?
    private let contentIdentifierInfoKeys: [String]
    private let disableImplicitAppLaunchOptionKey: String?

    /// Dispatches a targeted command and reports the synchronous result. The
    /// acknowledgement closure carries the asynchronous callback's error code,
    /// which is the only signal that actually distinguishes acceptance from
    /// rejection.
    typealias TargetedCommandDispatch = @MainActor (
        SemanticMediaCommand,
        String,
        @escaping @Sendable (UInt32) -> Void
    ) -> Bool

    /// Stands in for a callback that can never arrive because the command was
    /// refused synchronously.
    private static let unacknowledgedDispatchErrorCode: UInt32 = .max

    /// Pause runs after capture has already started, so waiting longer for its
    /// acknowledgement never delays recording. A late acknowledgement treated
    /// as a rejection would leave an application paused with nothing tracking
    /// it, so Pause gets a longer bound than state probes and Play.
    static let defaultPauseAcknowledgementTimeout: DispatchTimeInterval = .seconds(1)

    init(
        frameworkPath: String = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        callbackQueue: DispatchQueue = DispatchQueue(label: "Steno.MediaRemote.Callback", qos: .userInitiated),
        probeRunner: MediaRemoteAsyncProbeRunner = MediaRemoteAsyncProbeRunner(),
        pauseAcknowledgementTimeout: DispatchTimeInterval = MediaRemoteBridge.defaultPauseAcknowledgementTimeout,
        sendCommandOverride: TargetedCommandDispatch? = nil
    ) {
        self.callbackQueue = callbackQueue
        self.probeRunner = probeRunner
        self.pauseAcknowledgementRunner = MediaRemoteAsyncProbeRunner(
            timeout: pauseAcknowledgementTimeout,
            timeoutQueue: probeRunner.timeoutQueue
        )
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

    /// The registry reports when an application's player last played: the
    /// present moment while it is playing, and the instant it stopped once it
    /// has. Unlike the elected-session probes, this is answered per application
    /// for callers without special entitlements. A missing-client error is a
    /// definite answer that the application has no session; any other failure,
    /// a timeout, or an unavailable interface is unknown.
    func applicationSessionPlayback(
        forApplicationBundleIdentifier applicationBundleIdentifier: String
    ) async -> MediaSessionPlayback? {
        guard !applicationBundleIdentifier.isEmpty,
              let request = sessionRequest(
                forApplicationBundleIdentifier: applicationBundleIdentifier
              )
        else { return nil }

        let requestedAt = Date()
        let reply: SessionRequestReply? = await probeRunner.run { callback in
            let completion: SessionRequestInterface.LastPlayingDateCompletion = { date, error in
                if let error {
                    callback(.failed(domain: error.domain, code: error.code))
                } else if let date {
                    callback(.lastPlayed(date as Date))
                } else {
                    callback(.empty)
                }
            }
            SessionRequestInterface.requestLastPlayingDate(
                request,
                on: callbackQueue,
                completion: completion
            )
        }

        switch reply {
        case .lastPlayed(let date):
            // A playing session answers with the time of the request itself.
            let isPlaying = date >= requestedAt.addingTimeInterval(
                -Self.playingSessionTolerance
            )
            return isPlaying ? .playing : .stopped
        case .failed(let domain, let code):
            if domain == Self.mediaRemoteErrorDomain, code == Self.missingClientErrorCode {
                return .noSession
            }
            Self.logger.debug(
                "Media session request failed code=\(code, privacy: .public) application=\(applicationBundleIdentifier, privacy: .private)"
            )
            return nil
        case .empty, nil:
            return nil
        }
    }

    private static let playingSessionTolerance: TimeInterval = 0.05
    private static let mediaRemoteErrorDomain = "kMRMediaRemoteFrameworkErrorDomain"
    private static let missingClientErrorCode = 35

    private enum SessionRequestReply: Sendable {
        case lastPlayed(Date)
        case failed(domain: String, code: Int)
        case empty
    }

    private var sessionRequests: [String: AnyObject] = [:]

    private func sessionRequest(
        forApplicationBundleIdentifier applicationBundleIdentifier: String
    ) -> AnyObject? {
        if let request = sessionRequests[applicationBundleIdentifier] {
            return request
        }
        guard handle != nil,
              let origin = getLocalOriginFn?(),
              let request = SessionRequestInterface.makeRequest(
                origin: Unmanaged<AnyObject>.fromOpaque(origin).takeUnretainedValue(),
                applicationBundleIdentifier: applicationBundleIdentifier
              )
        else { return nil }
        sessionRequests[applicationBundleIdentifier] = request
        return request
    }

    /// Acceptance is the asynchronous callback reporting error 0 within a bounded
    /// wait (longer for Pause than for Play). The synchronous return reports only that the command was handed off:
    /// it is `true` even for a bundle identifier that is not running, so on its
    /// own it carries no acceptance information. A callback that never arrives
    /// fails closed.
    func send(
        _ command: SemanticMediaCommand,
        toApplicationBundleIdentifier applicationBundleIdentifier: String
    ) async -> Bool {
        guard !applicationBundleIdentifier.isEmpty else { return false }

        let acknowledgementRunner = command == .pause
            ? pauseAcknowledgementRunner
            : probeRunner
        let callbackError: UInt32? = await acknowledgementRunner.run { acknowledge in
            let dispatched = self.dispatch(
                command,
                toApplicationBundleIdentifier: applicationBundleIdentifier,
                acknowledge: acknowledge
            )
            if !dispatched {
                // No callback can follow a refused dispatch. Resolving here is
                // safe because the gate only honours the first acknowledgement.
                acknowledge(Self.unacknowledgedDispatchErrorCode)
            }
        }

        guard let callbackError else {
            Self.logger.debug(
                "Targeted semantic media \(command.logValue, privacy: .public) was not acknowledged within the bounded wait application=\(applicationBundleIdentifier, privacy: .private)"
            )
            return false
        }
        guard callbackError == 0 else {
            Self.logger.debug(
                "Targeted semantic media \(command.logValue, privacy: .public) callback error=\(callbackError, privacy: .public) application=\(applicationBundleIdentifier, privacy: .private)"
            )
            return false
        }
        return true
    }

    private func dispatch(
        _ command: SemanticMediaCommand,
        toApplicationBundleIdentifier applicationBundleIdentifier: String,
        acknowledge: @escaping @Sendable (UInt32) -> Void
    ) -> Bool {
        if let sendCommandOverride {
            return sendCommandOverride(command, applicationBundleIdentifier, acknowledge)
        }
        guard let sendCommandToAppFn,
              let disableImplicitAppLaunchOptionKey
        else { return false }

        let options = [disableImplicitAppLaunchOptionKey: true] as CFDictionary
        return sendCommandToAppFn(
            UInt32(command.rawValue),
            options,
            getLocalOriginFn?(),
            applicationBundleIdentifier as CFString,
            0,
            callbackQueue
        ) { error, _ in
            acknowledge(error)
        }.boolValue
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

/// Reaches the registry's per-application request objects through the
/// Objective-C runtime. Every class and method is looked up before use, so a
/// system without them yields `nil` instead of a call into something missing.
enum SessionRequestInterface {
    typealias LastPlayingDateCompletion = @convention(block) (NSDate?, NSError?) -> Void

    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias InitWithObjectFn = @convention(c) (
        Unmanaged<AnyObject>, Selector, AnyObject?
    ) -> Unmanaged<AnyObject>?
    private typealias InitPlayerPathFn = @convention(c) (
        Unmanaged<AnyObject>, Selector, AnyObject?, AnyObject?, AnyObject?
    ) -> Unmanaged<AnyObject>?
    private typealias RequestLastPlayingDateFn = @convention(c) (
        AnyObject, Selector, DispatchQueue, LastPlayingDateCompletion
    ) -> Void

    private static let allocSelector = NSSelectorFromString("alloc")
    private static let clientInitSelector = NSSelectorFromString("initWithBundleIdentifier:")
    private static let playerPathInitSelector = NSSelectorFromString("initWithOrigin:client:player:")
    private static let requestInitSelector = NSSelectorFromString("initWithPlayerPath:")
    private static let lastPlayingDateSelector = NSSelectorFromString(
        "requestLastPlayingDateOnQueue:completion:"
    )

    static func makeRequest(
        origin: AnyObject,
        applicationBundleIdentifier: String
    ) -> AnyObject? {
        guard let client = makeObject(
                className: "MRClient",
                initSelector: clientInitSelector,
                argument: applicationBundleIdentifier as NSString
              ),
              let playerPath = makePlayerPath(origin: origin, client: client),
              let request = makeObject(
                className: "MRNowPlayingRequest",
                initSelector: requestInitSelector,
                argument: playerPath
              ),
              class_getInstanceMethod(type(of: request), lastPlayingDateSelector) != nil
        else { return nil }
        return request
    }

    static func requestLastPlayingDate(
        _ request: AnyObject,
        on queue: DispatchQueue,
        completion: @escaping LastPlayingDateCompletion
    ) {
        guard let implementation = class_getMethodImplementation(
            type(of: request),
            lastPlayingDateSelector
        ) else { return }
        unsafeBitCast(implementation, to: RequestLastPlayingDateFn.self)(
            request,
            lastPlayingDateSelector,
            queue,
            completion
        )
    }

    private static func allocate(className: String, respondingTo initSelector: Selector) -> Unmanaged<AnyObject>? {
        guard let objectClass = NSClassFromString(className),
              class_getInstanceMethod(objectClass, initSelector) != nil,
              let allocMethod = class_getClassMethod(objectClass, allocSelector)
        else { return nil }
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFn.self)
        return alloc(objectClass, allocSelector)
    }

    // An initializer consumes the allocated object and returns a retained one.
    private static func makeObject(
        className: String,
        initSelector: Selector,
        argument: AnyObject
    ) -> AnyObject? {
        guard let allocated = allocate(className: className, respondingTo: initSelector),
              let objectClass = NSClassFromString(className),
              let implementation = class_getMethodImplementation(objectClass, initSelector)
        else { return nil }
        let initialize = unsafeBitCast(implementation, to: InitWithObjectFn.self)
        return initialize(allocated, initSelector, argument)?.takeRetainedValue()
    }

    private static func makePlayerPath(origin: AnyObject, client: AnyObject) -> AnyObject? {
        let className = "MRPlayerPath"
        guard let allocated = allocate(className: className, respondingTo: playerPathInitSelector),
              let objectClass = NSClassFromString(className),
              let implementation = class_getMethodImplementation(objectClass, playerPathInitSelector)
        else { return nil }
        let initialize = unsafeBitCast(implementation, to: InitPlayerPathFn.self)
        return initialize(allocated, playerPathInitSelector, origin, client, nil)?
            .takeRetainedValue()
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
