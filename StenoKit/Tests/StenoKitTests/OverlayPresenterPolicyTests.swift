import Foundation
import Testing
@testable import StenoKit

@Suite("Overlay presenter policy")
struct OverlayPresenterPolicyTests {
    @Test
    func partialUpdatesPreserveTheListeningLifecycleEpoch() {
        var gate = OverlayLiveUpdateGate()
        gate.beginListening()
        let epoch = gate.lifecycleEpoch
        let session = makeSession()

        let firstAccepted = gate.accept(makeSnapshot(session: session, revision: 1, watermark: 1_600))
        let secondAccepted = gate.accept(makeSnapshot(session: session, revision: 2, watermark: 3_200))
        #expect(firstAccepted)
        #expect(secondAccepted)
        #expect(gate.lifecycleEpoch == epoch)

        gate.beginListening()
        #expect(gate.lifecycleEpoch == epoch)
    }

    @Test
    func acceptsOnlyTheBoundSessionControllerAndRuntimeGeneration() {
        var gate = OverlayLiveUpdateGate()
        gate.beginListening()
        let acceptedSession = makeSession()
        let firstAccepted = gate.accept(makeSnapshot(session: acceptedSession, revision: 1, watermark: 100))
        #expect(firstAccepted)

        let differentSessionID = LiveTranscriptionSession(
            sessionID: UUID(),
            controllerGeneration: acceptedSession.controllerGeneration,
            runtimeGeneration: acceptedSession.runtimeGeneration,
            runtimeIdentity: acceptedSession.runtimeIdentity
        )
        let differentController = LiveTranscriptionSession(
            sessionID: acceptedSession.sessionID,
            controllerGeneration: UUID(),
            runtimeGeneration: acceptedSession.runtimeGeneration,
            runtimeIdentity: acceptedSession.runtimeIdentity
        )
        let differentRuntime = LiveTranscriptionSession(
            sessionID: acceptedSession.sessionID,
            controllerGeneration: acceptedSession.controllerGeneration,
            runtimeGeneration: acceptedSession.runtimeGeneration + 1,
            runtimeIdentity: acceptedSession.runtimeIdentity
        )

        let sessionRejected = gate.accept(makeSnapshot(session: differentSessionID, revision: 2, watermark: 200))
        let controllerRejected = gate.accept(makeSnapshot(session: differentController, revision: 2, watermark: 200))
        let runtimeRejected = gate.accept(makeSnapshot(session: differentRuntime, revision: 2, watermark: 200))
        #expect(!sessionRejected)
        #expect(!controllerRejected)
        #expect(!runtimeRejected)
    }

    @Test
    func rejectsDuplicateOutOfOrderMissingAndPostTerminalUpdates() {
        var gate = OverlayLiveUpdateGate()
        gate.beginListening()
        let session = makeSession()

        let accepted = gate.accept(makeSnapshot(session: session, revision: 2, watermark: 200))
        let duplicate = gate.accept(makeSnapshot(session: session, revision: 2, watermark: 300))
        let outOfOrder = gate.accept(makeSnapshot(session: session, revision: 1, watermark: 300))
        let staleWatermark = gate.accept(makeSnapshot(session: session, revision: 3, watermark: 199))
        let terminal = gate.accept(makeSnapshot(
            session: session,
            phase: .finalized,
            revision: 3,
            watermark: 300
        ))
        let missingIdentityFields = gate.accept(LiveTranscriptionSnapshot(session: session))
        #expect(accepted)
        #expect(!duplicate)
        #expect(!outOfOrder)
        #expect(!staleWatermark)
        #expect(!terminal)
        #expect(!missingIdentityFields)

        gate.endListening()
        let postTerminal = gate.accept(makeSnapshot(session: session, revision: 3, watermark: 300))
        #expect(!postTerminal)
    }

    @Test
    func unavailableStateIsStickyForTheCurrentSession() {
        var gate = OverlayLiveUpdateGate()
        gate.beginListening()
        let session = makeSession()

        let becameUnavailable = gate.markUnavailable()
        let duplicateUnavailable = gate.markUnavailable()
        let updateDuringUnavailable = gate.accept(makeSnapshot(session: session, revision: 1, watermark: 100))
        #expect(becameUnavailable)
        #expect(!duplicateUnavailable)
        #expect(!updateDuringUnavailable)

        gate.endListening()
        gate.beginListening()
        #expect(!gate.isUnavailable)
        let nextSessionAccepted = gate.accept(makeSnapshot(session: session, revision: 1, watermark: 100))
        #expect(nextSessionAccepted)
    }

    @Test
    func settingsChangesApplyToTheNextSessionOnly() {
        var gate = OverlayLiveUpdateGate()
        let session = makeSession()
        gate.beginListening()
        gate.setConfiguredEnabled(false)

        #expect(gate.sessionEnabled)
        let currentSessionAccepted = gate.accept(makeSnapshot(session: session, revision: 1, watermark: 100))
        #expect(currentSessionAccepted)

        gate.endListening()
        gate.beginListening()
        #expect(!gate.sessionEnabled)
        let nextSessionRejected = gate.accept(makeSnapshot(session: session, revision: 1, watermark: 100))
        #expect(!nextSessionRejected)
    }

    @Test
    func visibleRenderCadenceIsAtMostFourPerSecondAndPendingUpdatesCoalesce() {
        #expect(OverlayLiveUpdatePolicy.delay(lastRenderTime: nil, now: 0) == 0)
        let delayed = OverlayLiveUpdatePolicy.delay(lastRenderTime: 1, now: 1.10)
        #expect(abs(delayed - 0.15) < 0.000_001)
        #expect(OverlayLiveUpdatePolicy.delay(lastRenderTime: 1, now: 1.249) > 0)
        #expect(OverlayLiveUpdatePolicy.delay(lastRenderTime: 1, now: 1.25) == 0)

        var buffer = OverlayLiveRenderBuffer()
        let session = makeSession()
        buffer.enqueue(makeSnapshot(session: session, revision: 1, watermark: 100))
        buffer.enqueue(makeSnapshot(session: session, revision: 2, watermark: 200))
        buffer.enqueue(makeSnapshot(session: session, revision: 3, watermark: 300))

        let pending = buffer.takePending()
        #expect(buffer.coalescedSnapshotCount == 2)
        #expect(pending?.lastAcceptedRevision == 3)
        #expect(buffer.pendingSnapshot == nil)
    }

    @Test
    func pinnedDisplayRemainsStableAfterTheFirstResolution() {
        let first = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let second = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let candidates = [
            OverlayDisplayCandidate(frame: first, visibleFrame: first.insetBy(dx: 0, dy: 20)),
            OverlayDisplayCandidate(frame: second, visibleFrame: second.insetBy(dx: 0, dy: 20))
        ]
        let initial = OverlayDisplayPinPolicy.resolvedVisibleFrame(
            pinnedVisibleFrame: nil,
            targetPoint: CGPoint(x: 1_500, y: 400),
            candidates: candidates,
            fallbackVisibleFrame: first
        )
        let afterPointerMove = OverlayDisplayPinPolicy.resolvedVisibleFrame(
            pinnedVisibleFrame: initial,
            targetPoint: CGPoint(x: 100, y: 100),
            candidates: Array(candidates.reversed()),
            fallbackVisibleFrame: first
        )

        #expect(initial == candidates[1].visibleFrame)
        #expect(afterPointerMove == initial)
    }

    @Test
    func voiceOverAnnouncementsAreLifecycleOnlyAndTerminalExactlyOnce() {
        var gate = OverlayAnnouncementGate()
        gate.beginSession()

        let started = gate.accept(.sessionStarted)
        let inserted = gate.accept(.inserted)
        let duplicateInserted = gate.accept(.inserted)
        let conflictingFailure = gate.accept(.failure)
        let lateCancellation = gate.accept(.cancelled)
        #expect(started)
        #expect(inserted)
        #expect(!duplicateInserted)
        #expect(!conflictingFailure)
        #expect(!lateCancellation)

        gate.beginSession()
        let restarted = gate.accept(.sessionStarted)
        let cancelled = gate.accept(.cancelled)
        let duplicateCancelled = gate.accept(.cancelled)
        #expect(restarted)
        #expect(cancelled)
        #expect(!duplicateCancelled)
    }

    @Test
    func accessibilityMetricsRespectMotionTransparencyContrastAndLargeText() {
        let baseline = OverlayAccessibilityMetrics(preferences: .init(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false,
            preferredBodyPointSize: 13
        ))
        let accessible = OverlayAccessibilityMetrics(preferences: .init(
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: true,
            preferredBodyPointSize: 26
        ))

        #expect(baseline.textScale == 1)
        #expect(baseline.backgroundAlpha == 0.94)
        #expect(baseline.borderWidth == 0.5)
        #expect(baseline.duration(0.3) == 0.3)
        #expect(accessible.textScale == 1.6)
        #expect(accessible.scaledFontSize(13.5) > baseline.scaledFontSize(13.5))
        #expect(accessible.backgroundAlpha == 1)
        #expect(accessible.borderWidth == 1.5)
        #expect(accessible.outerShadowOpacity == 0)
        #expect(accessible.duration(0.3) == 0)
    }

    private func makeSession() -> LiveTranscriptionSession {
        LiveTranscriptionSession(
            sessionID: UUID(),
            controllerGeneration: UUID(),
            runtimeGeneration: 7,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "overlay-runtime",
                modelIdentifier: "overlay-model",
                vadIdentifier: nil,
                currentASRContextCount: 1,
                peakASRContextCount: 1
            )
        )
    }

    private func makeSnapshot(
        session: LiveTranscriptionSession,
        phase: LiveTranscriptionPhase = .active,
        revision: UInt64,
        watermark: UInt64
    ) -> LiveTranscriptionSnapshot {
        LiveTranscriptionSnapshot(
            session: session,
            phase: phase,
            stablePrefix: "stable ",
            revisableTail: "draft",
            authoritativeFinalText: phase == .finalized ? "final" : nil,
            lastAcceptedRevision: revision,
            decodedAudioWatermark: watermark,
            emittedAtMonotonicNanos: revision * 1_000
        )
    }
}
