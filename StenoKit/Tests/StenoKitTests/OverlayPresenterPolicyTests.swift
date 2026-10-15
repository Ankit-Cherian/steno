import Foundation
#if os(macOS)
import AppKit
#endif
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
        ), appearance: .quill)
        let accessible = OverlayAccessibilityMetrics(preferences: .init(
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: true,
            preferredBodyPointSize: 26
        ), appearance: .quill)

        #expect(baseline.textScale == 1)
        #expect(baseline.backgroundAlpha == 1)
        #expect(baseline.borderWidth == 1)
        #expect(baseline.edgeAlpha == 0.14)
        #expect(baseline.duration(0.3) == 0.3)
        #expect(baseline.capsuleHeight == 40)
        #expect(baseline.controlSize == 28)
        #expect(baseline.labelFontSize == 13)
        #expect(accessible.textScale == 2)
        #expect(accessible.scaledFontSize(13.5) > baseline.scaledFontSize(13.5))
        #expect(accessible.backgroundAlpha == 1)
        #expect(accessible.borderWidth == 1)
        #expect(accessible.edgeAlpha == 0.48)
        #expect(accessible.innerShadowOpacity == 0)
        #expect(accessible.outerShadowOpacity == 0)
        #expect(accessible.duration(0.3) == 0)
    }

    @Test("Larger text grows the capsule as the board draws it: 17 pt text, 50 pt tall, 34 pt controls")
    func largerTextCapsule() {
        let larger = OverlayAccessibilityMetrics(preferences: .init(
            reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 17
        ), appearance: .quill)
        #expect(larger.labelFontSize == 17)
        #expect(larger.capsuleHeight == 50)
        #expect((34...35).contains(larger.controlSize))
        #expect(larger.transcriptFontSize == 19)
        #expect((370...385).contains(larger.capsuleWidth(.handsFree)))
    }

    @Test
    func largePreferredTextExpandsWithinTheScreenAndAdaptsTheVisibleLines() {
        let visibleFrameSize = CGSize(width: 800, height: 600)
        let metrics = OverlayAccessibilityMetrics(preferences: .init(
            reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 52
        ), appearance: .grove)
        let lines = OverlayPanelLayoutPolicy.transcriptLineCapacity(metrics: metrics, visibleFrameSize: visibleFrameSize)
        let expanded = OverlayPanelLayoutPolicy.panelSize(
            metrics: metrics, showsTranscript: true, transcriptLines: lines, visibleFrameSize: visibleFrameSize
        )
        let compact = OverlayPanelLayoutPolicy.panelSize(
            metrics: metrics, showsTranscript: false, transcriptLines: 1, visibleFrameSize: visibleFrameSize
        )

        #expect(metrics.textScale == 4)
        #expect(expanded.width <= visibleFrameSize.width - 32)
        #expect(expanded.height <= visibleFrameSize.height - 32)
        #expect(lines >= 2 && lines < OverlayPanelLayoutPolicy.maximumTranscriptLines)
        #expect(CGFloat(lines) * metrics.transcriptLineHeight >= 52 * 3)
        #expect(compact.height < expanded.height)
        #expect(compact.width <= expanded.width)
    }

    @Test("The panel holds the widest state, so state changes never move or resize the window")
    func panelHoldsTheWidestState() {
        let metrics = OverlayAccessibilityMetrics(preferences: .init(
            reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 13
        ), appearance: .quill)
        let screen = CGSize(width: 1440, height: 900)
        let compact = OverlayPanelLayoutPolicy.panelSize(metrics: metrics, showsTranscript: false, transcriptLines: 1, visibleFrameSize: screen)
        let live = OverlayPanelLayoutPolicy.panelSize(metrics: metrics, showsTranscript: true, transcriptLines: 4, visibleFrameSize: screen)
        let marginWidth = OverlayPanelLayoutPolicy.shadowMargins.horizontal
        let marginHeight = OverlayPanelLayoutPolicy.shadowMargins.vertical
        #expect(compact.width == 340 + marginWidth)
        #expect(compact.height == 40 + marginHeight)
        #expect(live.width == 440 + marginWidth)
        // Capsule, 8 pt gap, then exactly four 22 pt lines inside 12 + 14 pt padding.
        let cardHeight: CGFloat = 12 + 4 * 22 + 14
        #expect(live.height == 40 + 8 + cardHeight + marginHeight)
        #expect(OverlayPanelLayoutPolicy.transcriptLineCapacity(metrics: metrics, visibleFrameSize: screen) == 4)
    }

    #if os(macOS)
    @Test
    @MainActor
    func productionPresenterUsesOneImmediateTranscriptSurfaceAndCalmUnavailableShell() {
        let presenter = WaveformOverlayPresenter()
        presenter.appearance = .quill
        presenter.hostedEvidencePrepareOffscreen()
        presenter.setLiveTranscriptEnabled(true)
        presenter.prepareWindow()

        #expect(presenter.hostedEvidenceHasOneTranscriptSurface())
        #expect(presenter.hostedEvidenceUsesPreferredTypography())

        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceTextSurfacesAreEmpty())
        #expect(presenter.hostedEvidenceRecordingPresentationIsImmediateAndStatic())

        let session = makeSession()
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: session,
            stablePrefix: "These words ",
            revisableTail: "flow as one sentence.",
            lastAcceptedRevision: 1,
            decodedAudioWatermark: 1_600,
            emittedAtMonotonicNanos: 1_000
        ))
        #expect(presenter.hostedEvidenceVisibleTranscript() == "These words flow as one sentence.")

        presenter.showLiveTranscriptUnavailable()
        #expect(presenter.hostedEvidenceUsesCompactUnavailableShell())

        let forbiddenCopy = [
            "Live preview will appear here",
            "Listening locally",
            "Draft",
            "Live preview unavailable",
            "Recording continues",
            "final transcript remains authoritative",
        ]
        let userFacingStrings = presenter.hostedEvidenceUserFacingStrings()
        for forbidden in forbiddenCopy {
            #expect(userFacingStrings.allSatisfy { !$0.localizedCaseInsensitiveContains(forbidden) })
        }

        presenter.hide()
        #expect(presenter.hostedEvidenceTextSurfacesAreEmpty())
    }

    @Test
    @MainActor
    func productionPresenterFitsNewestSpeechAtLargePreferredTextAndRestoresAppearance() {
        let presenter = WaveformOverlayPresenter()
        presenter.appearance = .quill
        presenter.hostedEvidencePrepareOffscreen()
        presenter.setLiveTranscriptEnabled(true)
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: true,
            preferredBodyPointSize: 52
        ))
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        #expect(presenter.hostedEvidenceAccessibilityAppearanceMatchesPreferences())

        let provisional = Array(repeating: "Earlier context stays exact. ", count: 12)
            .joined()
            + "The newest sentence remains completely visible."
        presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
            session: makeSession(),
            stablePrefix: provisional,
            revisableTail: "",
            lastAcceptedRevision: 1,
            decodedAudioWatermark: 1_600,
            emittedAtMonotonicNanos: 1_000
        ))
        let visible = presenter.hostedEvidenceVisibleTranscript()

        #expect(!visible.isEmpty)
        #expect(provisional.hasSuffix(visible))
        #expect(presenter.hostedEvidenceLargeTextTranscriptIsFullyVisible(
            preferredBodyPointSize: 52
        ))

        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false,
            preferredBodyPointSize: 13
        ))
        #expect(presenter.hostedEvidenceAccessibilityAppearanceMatchesPreferences())
        presenter.hide()
    }

    @Test
    @MainActor
    func terminalStatesRemainCompactEvenWhenLivePreviewIsPreferred() {
        let terminalStates: [OverlayState] = [
            .transcribing,
            .inserted,
            .copiedOnly,
            .failure(message: "test"),
            .noSpeechDetected,
        ]

        for terminalState in terminalStates {
            let presenter = WaveformOverlayPresenter()
            presenter.hostedEvidencePrepareOffscreen()
            presenter.setLiveTranscriptEnabled(true)
            presenter.show(state: .listening(handsFree: false, elapsedSeconds: 0))
            presenter.show(state: terminalState)

            #expect(presenter.hostedEvidenceTerminalPresentationIsCompact())
            #expect(presenter.hostedEvidenceTextSurfacesAreEmpty())
            presenter.hide()
        }
    }

    @Test
    func presenterCanReleaseItsLastReferenceAwayFromTheMainActor() async {
        let owner = OverlayPresenterReleaseOwner()
        await owner.acquirePresenter()
        await owner.releasePresenter()

        await MainActor.run { }
    }
    #endif

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

#if os(macOS)
private actor OverlayPresenterReleaseOwner {
    private var presenter: WaveformOverlayPresenter?

    func acquirePresenter() async {
        presenter = await MainActor.run {
            WaveformOverlayPresenter()
        }
    }

    func releasePresenter() {
        presenter = nil
    }
}
#endif
