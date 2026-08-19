import Foundation
import Testing
@testable import StenoBenchmarkCore
import StenoKit
import CryptoKit

@Test("Active CPU attribution requires one exact helper process that survives the trial")
func activeCPUAttributionRequiresStableExactHelperPID() {
    #expect(LiveContextProcessProbe.uniqueProcessID([]) == nil)
    #expect(LiveContextProcessProbe.uniqueProcessID([41]) == 41)
    #expect(LiveContextProcessProbe.uniqueProcessID([41, 42]) == nil)

    let before = LiveContextProcessProbe.Usage(
        processIdentifier: 41,
        residentBytes: 1,
        physicalFootprintBytes: 1,
        cpuNanoseconds: 100_000_000
    )
    var sameProcessAfter = before
    sameProcessAfter.cpuNanoseconds = 150_000_000
    var replacementAfter = sameProcessAfter
    replacementAfter.processIdentifier = 42

    #expect(LiveContextProcessProbe.cpuPercent(
        before: before,
        after: sameProcessAfter,
        elapsedMS: 100
    ) == 50)
    #expect(LiveContextProcessProbe.cpuPercent(
        before: before,
        after: replacementAfter,
        elapsedMS: 100
    ) == nil)
}

@Test("Resource soak checkpoints use the exact declared periodic schedule")
func resourceCheckpointScheduleIsExact() {
    #expect(LiveContextBenchmarkRunner.resourceCheckpointIndices(requestedSessionCount: 0) == [])
    #expect(LiveContextBenchmarkRunner.resourceCheckpointIndices(requestedSessionCount: 24) == [
        1, 10, 24,
    ])
    #expect(LiveContextBenchmarkRunner.resourceCheckpointIndices(requestedSessionCount: 100) == [
        1, 10, 25, 50, 75, 100,
    ])
    #expect(LiveContextBenchmarkRunner.resourceCheckpointIndices(requestedSessionCount: 511) == [
        1, 10, 25, 50, 75, 100, 125, 150, 175, 200, 225, 250, 275, 300, 325,
        350, 375, 400, 425, 450, 475, 500, 511,
    ])
}

@Test("Post-soak resident telemetry uses a content-free start and cancel and surfaces a stale peak")
func postSoakResidentTelemetrySurfacesLatestPeakWithoutAudioOrText() async throws {
    let engine = TelemetryOnlyLiveEngine(
        identity: LiveTranscriptionRuntimeIdentity(
            protocolVersion: 2,
            runtimeIdentifier: "post-soak-runtime",
            modelIdentifier: "post-soak-model",
            vadIdentifier: "post-soak-vad",
            currentASRContextCount: 1,
            peakASRContextCount: 2
        )
    )

    let identity = try await LiveContextBenchmarkRunner.queryResidentModelTelemetry(
        engine: engine,
        request: TranscriptionRequest(languageHints: ["en"])
    )
    let evidence = await engine.evidence()

    #expect(identity.currentASRContextCount == 1)
    #expect(identity.peakASRContextCount == 2)
    #expect(evidence.startCalls == 1)
    #expect(evidence.cancelCalls == 1)
    #expect(evidence.appendCalls == 0)
    #expect(evidence.hypothesisCalls == 0)
    #expect(evidence.finishCalls == 0)
    #expect(evidence.transcribeCalls == 0)
}

@Test("Corpus runner computes directive, continuation, literal, and spacing decisions from typed inputs")
func liveCorpusRunnerUsesProductionPolicy() {
    let corpus = ContinuationDirectiveCorpus(rows: [
        .init(
            id: "directive",
            input: "lowercase This works",
            expectedOutput: "this works",
            category: "directive",
            cleanedText: "This works",
            expectedDirectiveKind: .lowercase,
            expectedTextForCleanup: "This works",
            expectedDirectiveAppliedText: "this works"
        ),
        .init(
            id: "continuation",
            input: "This works",
            expectedOutput: " this works",
            category: "continuation",
            cleanedText: "This works",
            context: .init(
                availability: .validated,
                leadingText: "hello",
                trailingText: "",
                boundaryStyle: .usesInterwordSpacing,
                allowsAutomaticContinuation: true
            ),
            expectedTextForCleanup: "This works",
            expectedDirectiveAppliedText: "This works",
            expectedCaseDecision: .lowercasedOrdinaryOpening,
            expectedInsertedLeadingSpace: true
        ),
        .init(
            id: "literal",
            input: "literal lowercase This",
            expectedOutput: "lowercase This",
            category: "literal-escape",
            cleanedText: "lowercase This",
            expectedDirectiveKind: .literalEscape,
            expectedTextForCleanup: "lowercase This",
            expectedDirectiveAppliedText: "lowercase This"
        ),
    ])

    let rows = LiveContextBenchmarkRunner.evaluateCorpus(corpus)
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0.status == .passed })
    #expect(rows.allSatisfy { $0.directiveDecisionCorrect })
    #expect(rows.allSatisfy { $0.continuationDecisionCorrect })
    #expect(rows.allSatisfy { $0.boundarySpacingCorrect })
}

@Test("Frozen public corpus is deterministic and passes the production policy exactly")
func frozenLiveContextCorpusPassesExactly() throws {
    let corpus = ContinuationDirectiveCorpus.frozenAcceptanceCorpus
    let firstEncoding = try LiveContextArtifactIO.encodeCorpus(corpus)
    let secondEncoding = try LiveContextArtifactIO.encodeCorpus(.frozenAcceptanceCorpus)
    let rows = LiveContextBenchmarkRunner.evaluateCorpus(corpus)

    #expect(corpus.rows.count == 14)
    #expect(firstEncoding == secondEncoding)
    #expect(rows.allSatisfy { $0.status == .passed })
}

@Test("Enabled trial streams canonical PCM, accepts provisional events, and finalizes authoritatively")
func enabledTrialExercisesProductionLiveProtocolAndWAVParser() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("public-fixture.wav")
    try makePCM16WAV(sampleCount: 8_000).write(to: audioURL)
    let engine = DeterministicLiveEngine()

    let trial = try await LiveContextBenchmarkRunner.runEnabledTrial(
        engine: engine,
        audioURL: audioURL,
        request: TranscriptionRequest(languageHints: ["en"]),
        speechOnsetMS: 0,
        realtimePacing: true
    )

    #expect(trial.summary.sampleCount == 8_000)
    #expect(trial.summary.byteCount == 16_000)
    #expect(trial.pcmSHA256.count == 64)
    #expect(trial.firstPartialMS != nil)
    #expect(trial.revisionCount == 2)
    #expect(trial.finalizationCount == 1)
    #expect(trial.stablePrefixConflicts == 0)
    #expect(trial.stablePrefixFinalConflicts == 0)
    #expect(await engine.appendedSampleCount() == 8_000)
    #expect(await engine.finishCallCount() == 1)

    var mismatchedLaterTrial = trial
    mismatchedLaterTrial.canonicalSummary.sampleCount = 7_999
    mismatchedLaterTrial.canonicalPCMSHA256 = String(repeating: "f", count: 64)
    let parityFailures = LiveContextBenchmarkRunner.captureParityFailureRows(
        [trial, mismatchedLaterTrial],
        expectedAudioSampleCount: 8_000
    )
    #expect(parityFailures.contains { $0.id == "capture-parity:1" && $0.reasonCode == "sample-count-mismatch" })
    #expect(parityFailures.contains { $0.id == "capture-parity:1" && $0.reasonCode == "pcm-hash-mismatch" })
    #expect(parityFailures.contains { $0.id == "capture-parity:all" && $0.reasonCode == "canonical-sample-count-varied-across-trials" })
    #expect(parityFailures.contains { $0.id == "capture-parity:all" && $0.reasonCode == "canonical-pcm-hash-varied-across-trials" })
}

@Test("Enabled-trial scheduler keeps one decode active and coalesces the newest watermark")
func enabledTrialSchedulerCoalescesNewestPendingWatermark() async throws {
    let session = makeBenchmarkLiveSession()
    let coordinator = LiveContextBenchmarkRunner.EnabledTrialHypothesisCoordinator(
        session: session,
        speechOnsetMS: 0,
        cadenceSamples: 3_200
    )

    await coordinator.offerAppendedWatermark(3_200)
    let first = try #require(await coordinator.nextRequest())
    #expect(first == .init(revision: 1, watermark: 3_200))

    await coordinator.offerAppendedWatermark(6_400)
    await coordinator.offerAppendedWatermark(9_600)
    try await coordinator.complete(
        first,
        event: benchmarkHypothesis(session: session, request: first, text: "one"),
        receivedAtMS: 250
    )

    let second = try #require(await coordinator.nextRequest())
    #expect(second == .init(revision: 2, watermark: 9_600))
    await coordinator.beginFinishing()
}

@Test("Enabled-trial scheduler rejects mismatched helper responses without poisoning metrics")
func enabledTrialSchedulerRejectsUncorrelatedResponses() async throws {
    let session = makeBenchmarkLiveSession()
    let mismatches: [(LiveTranscriptionEventKind, LiveTranscriptionSession, UInt64, UInt64)] = [
        (.hypothesis, session, 99, 3_200),
        (.hypothesis, session, 1, 9_999),
        (.authoritativeFinal, session, 1, 3_200),
        (.hypothesis, makeBenchmarkLiveSession(), 1, 3_200),
    ]

    for mismatch in mismatches {
        let coordinator = LiveContextBenchmarkRunner.EnabledTrialHypothesisCoordinator(
            session: session,
            speechOnsetMS: 0,
            cadenceSamples: 3_200
        )
        await coordinator.offerAppendedWatermark(3_200)
        let poisonedRequest = try #require(await coordinator.nextRequest())
        await #expect(throws: LiveContextBenchmarkRunnerError.uncorrelatedLiveHypothesisResponse) {
            try await coordinator.complete(
                poisonedRequest,
                event: benchmarkHypothesis(
                    session: mismatch.1,
                    request: poisonedRequest,
                    kind: mismatch.0,
                    revision: mismatch.2,
                    watermark: mismatch.3,
                    text: "poison"
                ),
                receivedAtMS: 100
            )
        }

        await coordinator.offerAppendedWatermark(6_400)
        let validRequest = try #require(await coordinator.nextRequest())
        try await coordinator.complete(
            validRequest,
            event: benchmarkHypothesis(
                session: session,
                request: validRequest,
                text: "valid"
            ),
            receivedAtMS: 250
        )
        await coordinator.beginFinishing()
        let metrics = await coordinator.finalize(
            authoritativeText: "valid final",
            sampleCount: 6_400
        )

        #expect(metrics.firstPartialMS == 250)
        #expect(metrics.subsequentGapsMS.isEmpty)
        #expect(metrics.eventCount == 1)
        #expect(metrics.stablePrefixConflicts == 0)
        #expect(metrics.stablePrefixFinalConflicts == 0)
        #expect(metrics.noSpeechFalseDisplays == 0)
        #expect(metrics.finalizationCount == 1)
    }
}

@Test("Enabled trial fails closed when the runtime returns an uncorrelated hypothesis")
func enabledTrialFailsClosedOnUncorrelatedHypothesis() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-uncorrelated-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("public-fixture.wav")
    try makePCM16WAV(sampleCount: 8_000).write(to: audioURL)
    let engine = DeterministicLiveEngine(
        returnedSessionOverride: makeBenchmarkLiveSession()
    )

    await #expect(throws: LiveContextBenchmarkRunnerError.uncorrelatedLiveHypothesisResponse) {
        _ = try await LiveContextBenchmarkRunner.runEnabledTrial(
            engine: engine,
            audioURL: audioURL,
            request: TranscriptionRequest(languageHints: ["en"]),
            speechOnsetMS: 0,
            realtimePacing: true
        )
    }
}

@Test("Enabled-trial gaps reset across non-speech and unknown evidence")
func enabledTrialSchedulerMeasuresOnlyUninterruptedSpeechRuns() async throws {
    let session = makeBenchmarkLiveSession()
    let coordinator = LiveContextBenchmarkRunner.EnabledTrialHypothesisCoordinator(
        session: session,
        speechOnsetMS: 0,
        cadenceSamples: 1
    )
    let observations: [(Double, LiveTranscriptionSpeechEvidence, String)] = [
        (100, .speechDetected, "one"),
        (300, .speechDetected, "one two"),
        (500, .noSpeechDetected, "one two"),
        (800, .speechDetected, "one two three"),
        (1_050, .speechDetected, "one two three four"),
        (1_100, .unknown, "one two three four"),
        (1_300, .speechDetected, "one two three four five"),
    ]

    for (index, observation) in observations.enumerated() {
        await coordinator.offerAppendedWatermark(UInt64(index + 1))
        let request = try #require(await coordinator.nextRequest())
        try await coordinator.complete(
            request,
            event: benchmarkHypothesis(
                session: session,
                request: request,
                text: observation.2,
                evidence: observation.1
            ),
            receivedAtMS: observation.0
        )
    }
    await coordinator.beginFinishing()
    let metrics = await coordinator.finalize(
        authoritativeText: "one two three four five",
        sampleCount: 7
    )

    #expect(metrics.firstPartialMS == 100)
    #expect(metrics.subsequentGapsMS == [200, 250])
}

@Test("Authoritative finish supersedes pending and late provisional work")
func enabledTrialSchedulerFinishSupersedesPreviewWork() async throws {
    let session = makeBenchmarkLiveSession()
    let coordinator = LiveContextBenchmarkRunner.EnabledTrialHypothesisCoordinator(
        session: session,
        speechOnsetMS: 0,
        cadenceSamples: 3_200
    )

    await coordinator.offerAppendedWatermark(3_200)
    let active = try #require(await coordinator.nextRequest())
    await coordinator.offerAppendedWatermark(6_400)
    await coordinator.offerAppendedWatermark(9_600)
    await coordinator.beginFinishing()
    try await coordinator.complete(
        active,
        event: benchmarkHypothesis(session: session, request: active, text: "late"),
        receivedAtMS: 500
    )

    #expect(await coordinator.nextRequest() == nil)
    let metrics = await coordinator.finalize(authoritativeText: "final", sampleCount: 9_600)
    #expect(metrics.firstPartialMS == nil)
    #expect(metrics.subsequentGapsMS.isEmpty)
    #expect(metrics.eventCount == 0)
    #expect(metrics.stablePrefixConflicts == 0)
    #expect(metrics.noSpeechFalseDisplays == 0)
}

@Test("Enabled trial appends audio while one decode is suspended and finish supersedes it")
func enabledTrialFeedsAudioConcurrentlyWithDecode() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-concurrent-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("public-fixture.wav")
    try makePCM16WAV(sampleCount: 8_000).write(to: audioURL)
    let engine = FinishSupersedingLiveEngine()

    let trial = try await LiveContextBenchmarkRunner.runEnabledTrial(
        engine: engine,
        audioURL: audioURL,
        request: TranscriptionRequest(languageHints: ["en"]),
        speechOnsetMS: 0,
        realtimePacing: true
    )
    let evidence = await engine.evidence()

    #expect(evidence.appendedSamples == 8_000)
    #expect(evidence.samplesObservedAtFinish == 8_000)
    #expect(evidence.hypothesisRequests == 1)
    #expect(evidence.maximumConcurrentHypotheses == 1)
    #expect(evidence.finishCalls == 1)
    #expect(trial.firstPartialMS == nil)
    #expect(trial.revisionCount == 0)
    #expect(trial.finalizationCount == 1)
}

@Test("Benchmark finalization stays in the provisional producer's monotonic clock domain")
func enabledTrialFinalizesAcrossIndependentMonotonicEpochs() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-clock-domain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("public-fixture.wav")
    try makePCM16WAV(sampleCount: 8_000).write(to: audioURL)
    let engine = DeterministicLiveEngine(hypothesisTimestampBase: UInt64.max - 10)

    let trial = try await LiveContextBenchmarkRunner.runEnabledTrial(
        engine: engine,
        audioURL: audioURL,
        request: TranscriptionRequest(languageHints: ["en"]),
        speechOnsetMS: 0,
        realtimePacing: true
    )

    #expect(trial.revisionCount == 2)
    #expect(trial.finalizationCount == 1)
}

@Test("Non-speech hypotheses rejected by the reducer are not reported as displayed")
func silenceHallucinationIsSuppressedBeforeDisplay() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-silence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("public-silence.wav")
    try makePCM16WAV(sampleCount: 8_000, sample: { _ in 0 }).write(to: audioURL)
    let engine = DeterministicLiveEngine(speechEvidence: .noSpeechDetected)

    let trial = try await LiveContextBenchmarkRunner.runEnabledTrial(
        engine: engine,
        audioURL: audioURL,
        request: TranscriptionRequest(languageHints: ["en"]),
        speechOnsetMS: 0,
        realtimePacing: true
    )

    #expect(trial.noSpeechFalseDisplays == 0)
    #expect(await engine.hypothesisRequestCount() == 2)

    let unknownEngine = DeterministicLiveEngine(speechEvidence: .unknown)
    let unknownTrial = try await LiveContextBenchmarkRunner.runEnabledTrial(
        engine: unknownEngine,
        audioURL: audioURL,
        request: TranscriptionRequest(languageHints: ["en"]),
        speechOnsetMS: 0,
        realtimePacing: true
    )
    #expect(unknownTrial.noSpeechFalseDisplays == 0)
    #expect(await unknownEngine.hypothesisRequestCount() == 2)
}

@Test("Runner rejects incomplete external receipts before launching a helper")
func runnerRejectsIncompleteReceipts() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-receipt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let corpusURL = directory.appendingPathComponent("corpus.json")
    let audioURL = directory.appendingPathComponent("public.wav")
    let helperURL = directory.appendingPathComponent("helper")
    let cliURL = directory.appendingPathComponent("whisper-cli")
    let modelURL = directory.appendingPathComponent("model.bin")
    let hostedURL = directory.appendingPathComponent("hosted.json")
    let adversarialURL = directory.appendingPathComponent("adversarial.json")
    try LiveContextArtifactIO.encodeCorpus(.frozenAcceptanceCorpus).write(to: corpusURL)
    try makePCM16WAV(sampleCount: 1_600).write(to: audioURL)
    for url in [helperURL, cliURL, modelURL] { try Data("fixture".utf8).write(to: url) }
    try Data("{}".utf8).write(to: hostedURL)
    try Data("{}".utf8).write(to: adversarialURL)
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    let configuration = LiveContextBenchmarkConfiguration(
        corpusPath: corpusURL.path,
        audioFixturePath: audioURL.path,
        audioFixtureIsPublic: true,
        declaredSpeechOnsetMS: 0,
        helperPath: helperURL.path,
        whisperCLIPath: cliURL.path,
        modelPath: modelURL.path,
        sourceRootPath: repositoryRoot.path,
        hostedReceiptPath: hostedURL.path,
        adversarialReceiptPath: adversarialURL.path,
        resourceSoakSessions: 1,
        idleSampleSeconds: 0.01,
        realtimePacing: false
    )
    #expect(configuration.alternatingTrialCount == 10)
    await #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        _ = try await LiveContextBenchmarkRunner.run(configuration: configuration)
    }
}

@Test("Receipt validation rejects skips, dirty evidence, non-Metal evidence, and hash mismatches")
func evidenceReceiptsFailClosed() throws {
    let fixture = try makeReceiptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    try LiveContextBenchmarkRunner.validateEvidenceReceipts(
        configuration: fixture.configuration,
        identity: fixture.identity,
        now: fixture.now
    )
    #expect(LiveContextBenchmarkRunner.adversarialReceiptSchemaDecodes(at: fixture.adversarialURL.path))

    var hostedWithLegacyOverlayTiming = fixture.hosted
    hostedWithLegacyOverlayTiming.overlayMainActorDefinition =
        "production-overlay-accepted-snapshot-to-mainactor-render-complete"
    try JSONEncoder().encode(hostedWithLegacyOverlayTiming).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedWithUnboundOverlayWork = fixture.hosted
    hostedWithUnboundOverlayWork.overlayMainActorWork = .summarize([1, 2, 3, 4, 5, 6])
    try JSONEncoder().encode(hostedWithUnboundOverlayWork).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedMissingWrapperAttestation = fixture.hosted
    hostedMissingWrapperAttestation.wrapperAttestation = nil
    try JSONEncoder().encode(hostedMissingWrapperAttestation).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedTamperedWrapperAttestation = fixture.hosted
    hostedTamperedWrapperAttestation.wrapperAttestation?.networkScanCount += 1
    try JSONEncoder().encode(hostedTamperedWrapperAttestation).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedURLLoadingLeak = fixture.hosted
    hostedURLLoadingLeak.privacy.injectedURLProtocolProductionPathHits = 1
    try JSONEncoder().encode(hostedURLLoadingLeak).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedTamperedCanaryIdentity = fixture.hosted
    hostedTamperedCanaryIdentity.privacy.contextCanarySHA256 = String(
        repeating: "f",
        count: 64
    )
    try JSONEncoder().encode(hostedTamperedCanaryIdentity).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedMissingCanaryDerivation = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(fixture.hosted)
    ) as! [String: Any]
    var hostedPrivacy = hostedMissingCanaryDerivation["privacy"] as! [String: Any]
    hostedPrivacy.removeValue(forKey: "canaryDerivationDefinition")
    hostedMissingCanaryDerivation["privacy"] = hostedPrivacy
    try JSONSerialization.data(withJSONObject: hostedMissingCanaryDerivation).write(
        to: fixture.hostedURL
    )
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedSkipped = fixture.hosted
    hostedSkipped.skipCount = 1
    try JSONEncoder().encode(hostedSkipped).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedMissingMeasurement = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(fixture.hosted)
    ) as! [String: Any]
    var hostedStaticAudit = hostedMissingMeasurement["staticAudit"] as! [String: Any]
    hostedStaticAudit.removeValue(forKey: "featureLogInvocationSourceAuditPerformed")
    hostedMissingMeasurement["staticAudit"] = hostedStaticAudit
    try JSONSerialization.data(withJSONObject: hostedMissingMeasurement).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedSkippedStaticAudit = fixture.hosted
    hostedSkippedStaticAudit.staticAudit.ephemeralFilenameDiagnosticSourceAuditPerformed = false
    try JSONEncoder().encode(hostedSkippedStaticAudit).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedMismatchedAuditManifest = fixture.hosted
    hostedMismatchedAuditManifest.staticAudit.boundHostedSourceManifestSHA256 = String(
        repeating: "f",
        count: 64
    )
    try JSONEncoder().encode(hostedMismatchedAuditManifest).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var wrongHostedConfiguration = fixture.hosted
    wrongHostedConfiguration.trialOrder.swapAt(0, 1)
    try JSONEncoder().encode(wrongHostedConfiguration).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    var silenceHallucination = fixture.hosted
    silenceHallucination.correctness.noSpeechFalseDisplays = 1
    try JSONEncoder().encode(silenceHallucination).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var hostedWithIgnoredLeak = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(fixture.hosted)
    ) as! [String: Any]
    hostedWithIgnoredLeak["debugTranscript"] = "STENO-LIVE-CONTEXT-HOSTED-CANARY-V1"
    try JSONSerialization.data(withJSONObject: hostedWithIgnoredLeak).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var burstyHosted = fixture.hosted
    burstyHosted.renderedUpdateTimestampsMS = [0, 100, 350, 600, 850]
    try JSONEncoder().encode(burstyHosted).write(to: fixture.hostedURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
    try JSONEncoder().encode(fixture.hosted).write(to: fixture.hostedURL)

    var adversarial = fixture.adversarial
    var git = adversarial["git"] as! [String: Any]
    git["dirty"] = true
    adversarial["git"] = git
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    adversarial["canary"] = "STENO-PUBLIC-PROTOCOL-CANARY-V1"
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    adversarial["debugTranscript"] = "private content"
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    adversarial["schemaVersion"] = 1
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    var runtimeIdentity = adversarial["identity"] as! [String: Any]
    runtimeIdentity.removeValue(forKey: "peakASRContextCount")
    adversarial["identity"] = runtimeIdentity
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    runtimeIdentity = adversarial["identity"] as! [String: Any]
    runtimeIdentity["peakASRContextCount"] = 2
    adversarial["identity"] = runtimeIdentity
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    var cases = adversarial["cases"] as! [String: Any]
    var categories = cases["categories"] as! [String: Any]
    categories.removeValue(forKey: "receiptIntegrity")
    cases["categories"] = categories
    cases["rows"] = (cases["rows"] as! [[String: Any]]).filter {
        $0["category"] as? String != "receiptIntegrity"
    }
    cases["expected"] = (cases["expected"] as! Int) - 1
    cases["passed"] = (cases["passed"] as! Int) - 1
    adversarial["cases"] = cases
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    var hashes = adversarial["hashes"] as! [String: Any]
    hashes["vadModelSHA256"] = String(repeating: "f", count: 64)
    adversarial["hashes"] = hashes
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    hashes = adversarial["hashes"] as! [String: Any]
    hashes.removeValue(forKey: "vadModelSHA256")
    adversarial["hashes"] = hashes
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("hosted/adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    var network = adversarial["network"] as! [String: Any]
    network["runtimeMonitorPerformed"] = false
    adversarial["network"] = network
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    network = adversarial["network"] as! [String: Any]
    network["checkedProcessCount"] = 4
    network["ownedProcessCount"] = 5
    adversarial["network"] = network
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    var execution = adversarial["execution"] as! [String: Any]
    execution["productionMetalSmokePerformed"] = false
    adversarial["execution"] = execution
    try JSONSerialization.data(withJSONObject: adversarial).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["backend"] = "mixed"
    execution["observedBackends"] = ["cpu": 2, "metal": 3, "unknown": 0]
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["backend"] = "unobserved"
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["backend"] = "observed-cpu"
    execution["observedBackends"] = ["cpu": 4, "metal": 0, "unknown": 0]
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["backendEligibleProcessCount"] = 3
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["observedBackends"] = ["cpu": 0, "metal": 4, "unknown": 1]
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["requestedDeviceMode"] = "cpu-device-suppressed"
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    execution = adversarial["execution"] as! [String: Any]
    execution["qualification"] = "qualifying-metal"
    adversarial["execution"] = execution
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    network = adversarial["network"] as! [String: Any]
    network["continuous"] = false
    adversarial["network"] = network
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    network = adversarial["network"] as! [String: Any]
    network["scanCount"] = 9
    adversarial["network"] = network
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    network = adversarial["network"] as! [String: Any]
    network["observationDurationMS"] = 49
    adversarial["network"] = network
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    network = adversarial["network"] as! [String: Any]
    network["minimumScanCountPerProcess"] = 1
    adversarial["network"] = network
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    network = adversarial["network"] as! [String: Any]
    network["observedNetworkFDCount"] = 1
    adversarial["network"] = network
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    var configuration = adversarial["configuration"] as! [String: Any]
    var vadThresholds = configuration["vadThresholds"] as! [String: Any]
    vadThresholds["previewThreshold"] = 0.5
    configuration["vadThresholds"] = vadThresholds
    adversarial["configuration"] = configuration
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)

    adversarial = fixture.adversarial
    configuration = adversarial["configuration"] as! [String: Any]
    vadThresholds = configuration["vadThresholds"] as! [String: Any]
    vadThresholds["previewMinimumSpeechDurationMS"] = 250
    configuration["vadThresholds"] = vadThresholds
    adversarial["configuration"] = configuration
    try expectAdversarialReceiptRejected(adversarial, fixture: fixture)
}

@Test("Canonical receipt manifest hashing matches the Python producer wire format")
func canonicalReceiptManifestHashMatchesProducer() {
    let vector: [[String: Any]] = [[
        "path": "vendor/whisper.cpp/samples/jfk.wav",
        "role": "audioFixture",
        "sha256": String(repeating: "0", count: 64),
    ]]

    #expect(
        LiveContextBenchmarkRunner.canonicalJSONSHA256(vector)
            == "2144fd26456dd7727603c18d0bbaf4f080acbefd8984c1632e3666f6953a629c"
    )
}

@Test("Independent PCM oracle ignores transport frame boundaries")
func productionCoreAudioOracleIgnoresFrameBoundaries() {
    let summary = LivePCMStreamSummary(
        sampleCount: 176_000,
        byteCount: 352_000,
        frameCount: 11,
        fnv1a64: 0xd24a_d879_cea3_f9c4
    )

    #expect(LiveContextBenchmarkRunner.productionCoreAudioOracleMatches(
        summary,
        expectedSampleCount: 176_000,
        sampleWidthBytes: 2,
        expectedFNV1A64: "d24ad879cea3f9c4"
    ))
    var differentlyFramed = summary
    differentlyFramed.frameCount = 44
    #expect(LiveContextBenchmarkRunner.productionCoreAudioOracleMatches(
        differentlyFramed,
        expectedSampleCount: 176_000,
        sampleWidthBytes: 2,
        expectedFNV1A64: "d24ad879cea3f9c4"
    ))

    var mismatched = summary
    mismatched.sampleCount -= 1
    #expect(!LiveContextBenchmarkRunner.productionCoreAudioOracleMatches(
        mismatched,
        expectedSampleCount: 176_000,
        sampleWidthBytes: 2,
        expectedFNV1A64: "d24ad879cea3f9c4"
    ))
    mismatched = summary
    mismatched.byteCount -= 2
    #expect(!LiveContextBenchmarkRunner.productionCoreAudioOracleMatches(
        mismatched,
        expectedSampleCount: 176_000,
        sampleWidthBytes: 2,
        expectedFNV1A64: "d24ad879cea3f9c4"
    ))
    mismatched = summary
    mismatched.fnv1a64 ^= 1
    #expect(!LiveContextBenchmarkRunner.productionCoreAudioOracleMatches(
        mismatched,
        expectedSampleCount: 176_000,
        sampleWidthBytes: 2,
        expectedFNV1A64: "d24ad879cea3f9c4"
    ))
    mismatched = summary
    mismatched.frameCount = 0
    #expect(!LiveContextBenchmarkRunner.productionCoreAudioOracleMatches(
        mismatched,
        expectedSampleCount: 176_000,
        sampleWidthBytes: 2,
        expectedFNV1A64: "d24ad879cea3f9c4"
    ))
}

@Test("Current schema-v2 CPU diagnostic receipt strict-decodes but cannot qualify as Metal")
func generatedCPUReceiptIsSchemaValidButNonqualifying() throws {
    let fixture = try makeReceiptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var receipt = fixture.adversarial
    var git = receipt["git"] as! [String: Any]
    git["dirty"] = true
    git["state"] = "dirty"
    receipt["git"] = git
    var execution = receipt["execution"] as! [String: Any]
    execution["requestedDeviceMode"] = "cpu"
    execution["backend"] = "observed-cpu"
    execution["productionMetalSmokePerformed"] = false
    execution["qualification"] = "diagnostic-cpu-only"
    execution["observedBackends"] = ["cpu": 4, "metal": 0, "unknown": 0]
    receipt["execution"] = execution
    try JSONSerialization.data(withJSONObject: receipt).write(to: fixture.adversarialURL)

    #expect(LiveContextBenchmarkRunner.adversarialReceiptSchemaDecodes(
        at: fixture.adversarialURL.path
    ))
    let qualificationFailures = LiveContextBenchmarkRunner.adversarialReceiptQualificationFailures(
        at: fixture.adversarialURL.path
    )
    #expect(qualificationFailures.contains("dirty-git-tree"))
    #expect(qualificationFailures.contains("non-metal-backend"))
    #expect(!qualificationFailures.contains("adversarial-catalog-mismatch"))

    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
}

private struct ReceiptFixture {
    var directory: URL
    var hostedURL: URL
    var adversarialURL: URL
    var hosted: LiveContextHostedReceipt
    var adversarial: [String: Any]
    var configuration: LiveContextBenchmarkConfiguration
    var identity: LiveContextBenchmarkIdentity
    var now: Date
}

private func expectAdversarialReceiptRejected(
    _ receipt: [String: Any],
    fixture: ReceiptFixture
) throws {
    try JSONSerialization.data(withJSONObject: receipt).write(to: fixture.adversarialURL)
    #expect(throws: LiveContextBenchmarkRunnerError.invalidEvidenceReceipt("adversarial")) {
        try LiveContextBenchmarkRunner.validateEvidenceReceipts(
            configuration: fixture.configuration,
            identity: fixture.identity,
            now: fixture.now
        )
    }
}

private func makeReceiptFixture() throws -> ReceiptFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-receipt-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let helperURL = directory.appendingPathComponent("helper")
    let modelURL = directory.appendingPathComponent("model")
    let vadModelURL = directory.appendingPathComponent("vad-model")
    let audioURL = directory.appendingPathComponent("audio")
    let hostedURL = directory.appendingPathComponent("hosted.json")
    let adversarialURL = directory.appendingPathComponent("adversarial.json")
    try Data("helper".utf8).write(to: helperURL)
    try Data("model".utf8).write(to: modelURL)
    try Data("vad-model".utf8).write(to: vadModelURL)
    try Data("audio".utf8).write(to: audioURL)
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let git = String(repeating: "a", count: 40)
    let helperHash = testSHA256(try Data(contentsOf: helperURL))
    let modelHash = testSHA256(try Data(contentsOf: modelURL))
    let vadModelHash = testSHA256(try Data(contentsOf: vadModelURL))
    let audioHash = testSHA256(try Data(contentsOf: audioURL))
    let hostedCanaryHashes = LiveContextReceiptManifest.hostedPrivacyCanaries(
        gitSHA: git
    ).map { testSHA256(Data($0.utf8)) }
    let hostedSourceHash = try LiveContextReceiptManifest.hostedSourceSHA256(sourceRootPath: repositoryRoot.path)
    let hostedTrialOrder = (0..<10).map { $0.isMultiple(of: 2) ? LiveContextTrialMode.enabled : .disabled }
    let hostedEnvironment = LiveContextHostedReceipt.Environment(
        hardwareModelIdentifier: "fixture-hardware",
        operatingSystemVersion: "fixture-os",
        architecture: "arm64",
        trialCount: 10,
        language: "en"
    )
    var hostedWrapperAttestation = LiveContextHostedReceipt.WrapperAttestation(
        testIdentifier: "StenoTests.LiveContextHostedEvidenceTests.produceHostedEvidence",
        networkObservationDefinition: "50ms-lsof-polling-hosted-xctest-pid-and-descendants-transient-fds-between-polls-not-observed",
        resultBundleScanDefinition: "raw-xcresult-plus-exported-diagnostics-attachments-and-decoded-test-summary-all-derived-deterministic-canaries-scan",
        hostedTestProcessID: 42,
        observationStartUnixMilliseconds: 2_000_000_000_000,
        observationEndUnixMilliseconds: 2_000_000_001_000,
        networkMonitorPerformed: true,
        networkPollIntervalMilliseconds: 50,
        networkScanCount: 20,
        networkObservationDurationMilliseconds: 1_000,
        maximumObservedProcessTreeCount: 1,
        observedNetworkFileDescriptorCount: 0,
        resultBundleScanPerformed: true,
        resultBundleScannedFileCount: 5,
        resultBundleCanaryFindings: 0,
        resultBundleManifestSHA256: String(repeating: "b", count: 64),
        attestationIdentitySHA256: ""
    )
    hostedWrapperAttestation.attestationIdentitySHA256 =
        LiveContextReceiptManifest.hostedWrapperAttestationSHA256(
            hostedWrapperAttestation
        )
    let hosted = LiveContextHostedReceipt(
        generatedAt: formatter.string(from: now.addingTimeInterval(-1)),
        gitSHA: git,
        treeIsDirty: false,
        sourceManifestSHA256: hostedSourceHash,
        failureCount: 0,
        skipCount: 0,
        failures: [],
        skips: [],
        wrapperAttestation: hostedWrapperAttestation,
        environment: hostedEnvironment,
        environmentIdentitySHA256: LiveContextReceiptManifest.hostedEnvironmentSHA256(
            hostedEnvironment
        ),
        syntheticCoordinatorListeningAcknowledgementDiagnostic: .summarize(
            [10, 11, 12, 13, 14]
        ),
        overlayMainActorWork: .summarize([1, 2, 3, 4, 5]),
        renderedUpdateTimestampsMS: [0, 250, 500, 750, 1_000],
        syntheticCoordinatorStopToInsertionEnabledDiagnostic: .summarize(
            [100, 110, 120, 130, 140]
        ),
        syntheticCoordinatorStopToInsertionDisabledControlDiagnostic: .summarize(
            [100, 110, 120, 130, 140]
        ),
        acceptedPreviewCount: 10,
        renderedPreviewCount: 5,
        maximumQueueDepth: 1,
        coalescedPreviewCount: 5,
        trialOrder: hostedTrialOrder,
        configurationIdentitySHA256: LiveContextReceiptManifest.hostedConfigurationSHA256(
            gitSHA: git, sourceManifestSHA256: hostedSourceHash, language: "en", trialCount: 10
        ),
        lifecycle: .init(randomizedSessions: 1_000, rapidCancelRestartCases: 250, targetTransitions: 10_000, authoritativeFinishCalls: 5, maximumAuthoritativeFinishCallsPerSession: 1, coordinatorSecondFinalInferenceAttempts: 0, finalInsertionCount: 10, expectedFinalInsertionCount: 10),
        correctness: .init(provisionalSideEffects: 0, duplicateFinalInsertions: 0, staleEventsAccepted: 0, speechPreviewRenderedControlCount: 1, noSpeechFalseDisplays: 0),
        privacy: .init(canaryDerivationDefinition: LiveContextReceiptManifest.hostedPrivacyCanaryDerivationDefinition, baseCanarySHA256: hostedCanaryHashes[0], provisionalCanarySHA256: hostedCanaryHashes[1], contextCanarySHA256: hostedCanaryHashes[2], snippetExpansionCanarySHA256: hostedCanaryHashes[3], provisionalCanaryInjectionCount: 5, contextCanaryInjectionCount: 5, snippetCanaryInjectionCount: 10, scannedSurfaceCount: 100, requestLeaks: 0, cleanupLeaks: 0, historyLeaks: 0, insertionLeaks: 0, clipboardRecoveryLeaks: 0, analyticsLeaks: 0, configuredSnippetTrapCount: 10, snippetTrapActivations: 0, liveCallbackProvisionalObservations: 5, liveCallbackUnexpectedContextLeaks: 0, unavailableCallbackObservations: 1, overlayRetainedTextLeaks: 0, injectedURLProtocolSelfTestHits: 1, injectedURLProtocolProductionPathHits: 0, secureFieldContextReadRequests: 0, maximumAXUTF16ReadPerSide: 512, maximumAXGraphemesPerSide: 256, maximumAXContextBytes: 8_192),
        staticAudit: .init(boundHostedSourceManifestSHA256: hostedSourceHash, auditedFileCount: LiveContextReceiptManifest.hostedProductionRelativePaths.count, featureLogInvocationSourceAuditPerformed: true, featureLogInvocationSourceFindings: 0, crashMetadataSinkReferenceSourceAuditPerformed: true, crashMetadataSinkReferenceSourceFindings: 0, ephemeralPersistenceSourceAuditPerformed: true, ephemeralPersistenceSourceFindings: 0, ephemeralFilenameDiagnosticSourceAuditPerformed: true, ephemeralFilenameDiagnosticSourceFindings: 0, prohibitedNetworkAPISourceAuditPerformed: true, prohibitedNetworkAPISourceFindings: 0)
    )
    let helperSourceURL = repositoryRoot.appendingPathComponent("runtime-helper/steno_whisper_runtime.cpp")
    let harnessURL = repositoryRoot.appendingPathComponent("scripts/test-whisper-runtime-helper-v2.py")
    let caseRows: [(String, String)] = [
        ("compatibility", "v1 backward compatibility"),
        ("protocolValidation", "v2 validation, cross-session, duplicate, and terminal rejection"),
        ("protocolValidation", "v2 out-of-order, malformed, and per-append size bounds"),
        ("protocolValidation", "v2 shutdown rejects malformed fields and permits active teardown"),
        ("terminalPriority", "v2 finish priority and exactly one final"),
        ("terminalPriority", "v2 cancellation priority"),
        ("terminalPriority", "v2 cancel during finish preserves restart"),
        ("speechEvidence", "v2 decode-scoped Silero speech evidence"),
        ("authoritativeIntegrity", "v2 finish rejects matching count with wrong FNV and emits no final"),
        ("lifecycleCrashEOF", "v2 crash after exactly one final"),
        ("parserBounds", "global oversized frame rejection"),
        ("receiptIntegrity", "CPU attestation cannot qualify as Metal"),
        ("lifecycleCrashEOF", "crash before ready"),
        ("lifecycleCrashEOF", "EOF before ready"),
        ("lifecycleCrashEOF", "crash during before-append"),
        ("lifecycleCrashEOF", "crash during append"),
        ("lifecycleCrashEOF", "crash during hypothesis"),
        ("lifecycleCrashEOF", "crash during finish"),
        ("lifecycleCrashEOF", "EOF during before-append"),
        ("lifecycleCrashEOF", "EOF during append"),
        ("lifecycleCrashEOF", "EOF during hypothesis"),
        ("lifecycleCrashEOF", "EOF during finish"),
    ]
    let categories = Dictionary(grouping: caseRows, by: \.0).mapValues { rows in
        ["expected": rows.count, "passed": rows.count, "failed": 0, "skipped": 0]
    }
    let manifestPath: (URL) -> String = { url in
        let root = repositoryRoot.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
    let manifestEntries: [[String: Any]] = [
        ["role": "audioFixture", "path": manifestPath(audioURL), "sha256": audioHash],
        ["role": "harnessSource", "path": manifestPath(harnessURL), "sha256": testSHA256(try Data(contentsOf: harnessURL))],
        ["role": "helperBinary", "path": manifestPath(helperURL), "sha256": helperHash],
        ["role": "helperSource", "path": manifestPath(helperSourceURL), "sha256": testSHA256(try Data(contentsOf: helperSourceURL))],
        ["role": "vadModel", "path": vadModelURL.standardizedFileURL.path, "sha256": vadModelHash],
        ["role": "whisperModel", "path": modelURL.standardizedFileURL.path, "sha256": modelHash],
    ]
    let manifestHash = testSHA256(try JSONSerialization.data(
        withJSONObject: manifestEntries,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ))
    let adversarial: [String: Any] = [
        "schemaVersion": 2,
        "generatedAt": formatter.string(from: now.addingTimeInterval(-1)),
        "git": ["sha": git, "dirty": false, "state": "clean"],
        "protocolVersions": [1, 2],
        "execution": [
            "requestedDeviceMode": "default", "backend": "observed-metal",
            "backendEligibleProcessCount": 4, "attestedProcessCount": 4,
            "observedBackends": ["cpu": 0, "metal": 4, "unknown": 0],
            "productionMetalSmokePerformed": true,
            "qualification": "qualifying-production-metal", "matrix": "full-adversarial",
        ],
        "environment": [
            "hardware": ["architecture": "arm64", "chip": "fixture", "logicalProcessorCount": 8, "memoryBytes": 16_000_000_000 as UInt64, "modelIdentifier": "fixture"],
            "operatingSystem": ["build": "fixture", "name": "macOS", "version": "fixture"],
        ],
        "identity": [
            "schema": 2, "capabilities": 127,
            "runtime": "runtime", "model": "model", "vad": "vad",
            "currentASRContextCount": 1, "peakASRContextCount": 1,
            "helperBinary": "helper", "helperBinarySHA256": helperHash,
        ],
        "configuration": [
            "audio": ["channelCount": 1, "encoding": "signed-integer-little-endian", "sampleRateHz": 16_000, "sampleWidthBytes": 2],
            "bounds": ["maximumAppendBytes": 32_768, "maximumAppendSamples": 16_384, "maximumHypothesisBytes": 1_048_576, "maximumPayloadBytes": 67_108_864, "maximumStreamSamples": 691_200_000, "maximumStringBytes": 1_048_576, "previewWindowSamples": 192_000],
            "harnessTimeoutsSeconds": ["backendAttestation": 2.0, "defaultFrameRead": 5.0, "inference": 30.0, "loadReady": 15.0, "networkMonitorStartup": 3.0, "networkPollInterval": 0.05],
            "inferenceThresholds": ["entropyThreshold": 2.4, "logProbabilityThreshold": -1.0, "noSpeechThreshold": 0.6, "temperature": 0.0, "temperatureIncrement": 0.2],
            "streamRequest": ["beamSize": 1, "bestOf": 1, "flags": 3, "language": "en", "prompt": NSNull(), "suppressNonSpeechTokens": true, "suppressRegex": NSNull(), "threads": 8, "vadEnabled": true],
            "vadThresholds": ["maximumSpeechDurationSeconds": "FLT_MAX", "minimumSilenceDurationMS": 100, "minimumSpeechDurationMS": 250, "previewMinimumSpeechDurationMS": 50, "previewScope": "newly-accepted-audio-since-prior-admitted-decode", "previewThreshold": 0.12, "samplesOverlap": 0.1, "speechPadMS": 30, "threshold": 0.5],
        ],
        "sourceFixtureManifest": ["algorithm": "sha256-canonical-json-v1", "sha256": manifestHash, "entries": manifestEntries],
        "cases": ["expected": caseRows.count, "passed": caseRows.count, "failed": 0, "skipped": 0,
                  "categories": categories,
                  "failureRows": [], "skipRows": [],
                  "rows": caseRows.map { ["category": $0.0, "durationMS": 1, "name": $0.1, "status": "passed", "failureReason": NSNull(), "skipReason": NSNull()] }],
        "hashes": ["harnessSHA256": testSHA256(try Data(contentsOf: harnessURL)),
                   "helperSourceSHA256": testSHA256(try Data(contentsOf: helperSourceURL)),
                   "helperBinarySHA256": helperHash, "modelSHA256": modelHash,
                   "vadModelSHA256": vadModelHash,
                   "audioSHA256": audioHash, "sourceFixtureManifestSHA256": manifestHash,
                   "canarySHA256": testSHA256(Data("STENO-PUBLIC-PROTOCOL-CANARY-V1".utf8))],
        "artifacts": [
            "audioFixture": ["path": manifestPath(audioURL), "sha256": audioHash],
            "helper": ["path": manifestPath(helperURL), "sha256": helperHash],
            "model": ["path": modelURL.standardizedFileURL.path, "sha256": modelHash],
            "vadModel": ["path": vadModelURL.standardizedFileURL.path, "sha256": vadModelHash],
        ],
        "audio": ["expectedSampleCount": 3, "observedSampleCount": 3, "channelCount": 1, "sampleWidthBytes": 2, "sampleRateHz": 16_000, "fnv1a64": "0123456789abcdef"],
        "canary": ["scannedSurfaceCount": 10, "escapes": 0],
        "fallback": ["performed": false, "attempts": 0, "successes": 0],
        "network": [
            "undefinedSymbolScanPerformed": true, "prohibitedUndefinedSymbols": [],
            "runtimeMonitorPerformed": true, "checkedProcessCount": 5, "ownedProcessCount": 5,
            "observedNetworkFileDescriptorCount": 0, "observedNetworkFDCount": 0,
            "continuous": true, "scanCount": 10, "observationDurationMS": 50,
            "minimumScanCountPerProcess": 2, "pollIntervalMS": 50,
        ],
    ]
    try JSONEncoder().encode(hosted).write(to: hostedURL)
    try JSONSerialization.data(withJSONObject: adversarial).write(to: adversarialURL)
    let configuration = LiveContextBenchmarkConfiguration(
        corpusPath: directory.appendingPathComponent("corpus").path,
        audioFixturePath: audioURL.path,
        audioFixtureIsPublic: true,
        declaredSpeechOnsetMS: 0,
        helperPath: helperURL.path,
        whisperCLIPath: helperURL.path,
        modelPath: modelURL.path,
        vadModelPath: vadModelURL.path,
        sourceRootPath: repositoryRoot.path,
        hostedReceiptPath: hostedURL.path,
        adversarialReceiptPath: adversarialURL.path
    )
    let identity = LiveContextBenchmarkIdentity(
        gitSHA: git, treeIsDirty: false, manifestSHA256: String(repeating: "b", count: 64),
        corpusSHA256: String(repeating: "c", count: 64), modelSHA256: modelHash,
        audioFixtureSHA256: audioHash,
        modelIdentity: "model", modelPathPolicy: .approvedExternalRedacted,
        vadModelSHA256: vadModelHash, threadCount: 8, language: "en", realtimePacing: true,
        runtimeSHA256: helperHash, runtimeIdentity: "helper",
        liveProtocolVersion: 2, liveRuntimeIdentifier: "runtime",
        liveModelIdentifier: String(repeating: "d", count: 64),
        liveVADIdentifier: String(repeating: "e", count: 64),
        hostedReceiptSHA256: testSHA256(try Data(contentsOf: hostedURL)),
        adversarialReceiptSHA256: testSHA256(try Data(contentsOf: adversarialURL)),
        hostedSourceManifestSHA256: try LiveContextReceiptManifest.hostedSourceSHA256(sourceRootPath: repositoryRoot.path),
        helperSourceSHA256: testSHA256(try Data(contentsOf: helperSourceURL)),
        adversarialHarnessSHA256: testSHA256(try Data(contentsOf: harnessURL)),
        hardware: "hardware", operatingSystem: "macOS", powerState: "ac-power"
    )
    return ReceiptFixture(directory: directory, hostedURL: hostedURL, adversarialURL: adversarialURL, hosted: hosted, adversarial: adversarial, configuration: configuration, identity: identity, now: now)
}

private func testSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeBenchmarkLiveSession() -> LiveTranscriptionSession {
    LiveTranscriptionSession(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        runtimeGeneration: 1,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity(
            protocolVersion: 2,
            runtimeIdentifier: "benchmark-test-runtime",
            modelIdentifier: "benchmark-test-model",
            vadIdentifier: "benchmark-test-vad",
            currentASRContextCount: 1,
            peakASRContextCount: 1
        )
    )
}

private func benchmarkHypothesis(
    session: LiveTranscriptionSession,
    request: LiveContextBenchmarkRunner.EnabledTrialDecodeRequest,
    kind: LiveTranscriptionEventKind = .hypothesis,
    revision: UInt64? = nil,
    watermark: UInt64? = nil,
    text: String,
    evidence: LiveTranscriptionSpeechEvidence = .speechDetected
) -> LiveTranscriptionEvent {
    LiveTranscriptionEvent(
        kind: kind,
        session: session,
        revision: revision ?? request.revision,
        decodedAudioWatermark: watermark ?? request.watermark,
        emittedAtMonotonicNanos: request.revision,
        fullHypothesisText: text,
        speechEvidence: evidence
    )
}

private actor FinishSupersedingLiveEngine: LiveTranscriptionEngine {
    struct Evidence: Sendable, Equatable {
        var appendedSamples: Int
        var samplesObservedAtFinish: Int
        var hypothesisRequests: Int
        var maximumConcurrentHypotheses: Int
        var finishCalls: Int
    }

    private var active: LiveTranscriptionSession?
    private var appendedSamples = 0
    private var samplesObservedAtFinish = 0
    private var hypothesisRequests = 0
    private var activeHypotheses = 0
    private var maximumConcurrentHypotheses = 0
    private var finishCalls = 0
    private var hypothesisContinuation: CheckedContinuation<LiveTranscriptionEvent, Error>?

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        _ = request
        let session = LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: 1,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "finish-superseding-runtime",
                modelIdentifier: "finish-superseding-model",
                vadIdentifier: "finish-superseding-vad",
                currentASRContextCount: 1,
                peakASRContextCount: 1
            )
        )
        active = session
        return session
    }

    func appendLiveAudio(
        _ frame: LivePCMFrame,
        session: LiveTranscriptionSession
    ) async throws {
        guard active == session else { throw CancellationError() }
        appendedSamples += frame.sampleCount
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        _ = revision
        _ = decodedAudioWatermark
        guard active == session, hypothesisContinuation == nil else {
            throw CancellationError()
        }
        hypothesisRequests += 1
        activeHypotheses += 1
        maximumConcurrentHypotheses = max(maximumConcurrentHypotheses, activeHypotheses)
        defer { activeHypotheses -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            hypothesisContinuation = continuation
        }
    }

    func finishLiveTranscription(
        session: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        _ = canonicalAudioURL
        _ = streamSummary
        _ = request
        guard active == session else { throw CancellationError() }
        samplesObservedAtFinish = appendedSamples
        finishCalls += 1
        active = nil
        let continuation = hypothesisContinuation
        hypothesisContinuation = nil
        continuation?.resume(throwing: CancellationError())
        return RawTranscript(text: "final", durationMS: 500)
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        if active == session { active = nil }
        let continuation = hypothesisContinuation
        hypothesisContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    func transcribe(
        audioURL: URL,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        return RawTranscript(text: "final", durationMS: 500)
    }

    func shutdown() async {}
    func unloadRetainedResources() async {}

    func evidence() -> Evidence {
        Evidence(
            appendedSamples: appendedSamples,
            samplesObservedAtFinish: samplesObservedAtFinish,
            hypothesisRequests: hypothesisRequests,
            maximumConcurrentHypotheses: maximumConcurrentHypotheses,
            finishCalls: finishCalls
        )
    }
}

private actor DeterministicLiveEngine: LiveTranscriptionEngine {
    private var active: LiveTranscriptionSession?
    private var samples = 0
    private var finishes = 0
    private var hypothesisRequests = 0
    private let speechEvidence: LiveTranscriptionSpeechEvidence
    private let hypothesisTimestampBase: UInt64?
    private let returnedSessionOverride: LiveTranscriptionSession?

    init(
        speechEvidence: LiveTranscriptionSpeechEvidence = .speechDetected,
        hypothesisTimestampBase: UInt64? = nil,
        returnedSessionOverride: LiveTranscriptionSession? = nil
    ) {
        self.speechEvidence = speechEvidence
        self.hypothesisTimestampBase = hypothesisTimestampBase
        self.returnedSessionOverride = returnedSessionOverride
    }

    func startLiveTranscription(sessionID: SessionID, controllerGeneration: UUID, request: TranscriptionRequest) async throws -> LiveTranscriptionSession {
        _ = request
        let session = LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: 1,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "test-runtime",
                modelIdentifier: "test-model",
                vadIdentifier: nil,
                currentASRContextCount: 1,
                peakASRContextCount: 1
            )
        )
        active = session
        return session
    }

    func appendLiveAudio(_ frame: LivePCMFrame, session: LiveTranscriptionSession) async throws {
        guard active == session else { throw CancellationError() }
        samples += frame.sampleCount
    }

    func requestLiveHypothesis(session: LiveTranscriptionSession, revision: UInt64, decodedAudioWatermark: UInt64) async throws -> LiveTranscriptionEvent {
        guard active == session else { throw CancellationError() }
        hypothesisRequests += 1
        return LiveTranscriptionEvent(
            session: returnedSessionOverride ?? session,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark,
            emittedAtMonotonicNanos: hypothesisTimestampBase.map { $0 + revision }
                ?? DispatchTime.now().uptimeNanoseconds,
            fullHypothesisText: revision == 1 ? "This" : "This works",
            speechEvidence: speechEvidence
        )
    }

    func finishLiveTranscription(session: LiveTranscriptionSession, canonicalAudioURL: URL, streamSummary: LivePCMStreamSummary, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = canonicalAudioURL
        _ = streamSummary
        _ = request
        guard active == session else { throw CancellationError() }
        active = nil
        finishes += 1
        return RawTranscript(text: "This works", durationMS: 500)
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        if active == session { active = nil }
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        return RawTranscript(text: "This works", durationMS: 500)
    }

    func shutdown() async {}
    func unloadRetainedResources() async {}
    func appendedSampleCount() -> Int { samples }
    func finishCallCount() -> Int { finishes }
    func hypothesisRequestCount() -> Int { hypothesisRequests }
}

private actor TelemetryOnlyLiveEngine: LiveTranscriptionEngine {
    struct Evidence: Sendable, Equatable {
        var startCalls: Int
        var cancelCalls: Int
        var appendCalls: Int
        var hypothesisCalls: Int
        var finishCalls: Int
        var transcribeCalls: Int
    }

    private let identity: LiveTranscriptionRuntimeIdentity
    private var startCalls = 0
    private var cancelCalls = 0
    private var appendCalls = 0
    private var hypothesisCalls = 0
    private var finishCalls = 0
    private var transcribeCalls = 0

    init(identity: LiveTranscriptionRuntimeIdentity) {
        self.identity = identity
    }

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        _ = request
        startCalls += 1
        return LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: 1,
            runtimeIdentity: identity
        )
    }

    func appendLiveAudio(
        _ frame: LivePCMFrame,
        session: LiveTranscriptionSession
    ) async throws {
        _ = frame
        _ = session
        appendCalls += 1
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        _ = session
        _ = revision
        _ = decodedAudioWatermark
        hypothesisCalls += 1
        throw CancellationError()
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
        _ = request
        finishCalls += 1
        throw CancellationError()
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        _ = session
        cancelCalls += 1
    }

    func transcribe(
        audioURL: URL,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        transcribeCalls += 1
        throw CancellationError()
    }

    func shutdown() async {}
    func unloadRetainedResources() async {}

    func evidence() -> Evidence {
        Evidence(
            startCalls: startCalls,
            cancelCalls: cancelCalls,
            appendCalls: appendCalls,
            hypothesisCalls: hypothesisCalls,
            finishCalls: finishCalls,
            transcribeCalls: transcribeCalls
        )
    }
}

private func makePCM16WAV(
    sampleCount: Int,
    sample: (Int) -> Int16 = { $0.isMultiple(of: 2) ? 2_000 : -2_000 }
) -> Data {
    let pcmBytes = sampleCount * 2
    var data = Data()
    data.append(Data("RIFF".utf8))
    appendLE32(UInt32(36 + pcmBytes), to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLE32(16, to: &data)
    appendLE16(1, to: &data)
    appendLE16(1, to: &data)
    appendLE32(16_000, to: &data)
    appendLE32(32_000, to: &data)
    appendLE16(2, to: &data)
    appendLE16(16, to: &data)
    data.append(Data("data".utf8))
    appendLE32(UInt32(pcmBytes), to: &data)
    for index in 0..<sampleCount {
        appendLE16(UInt16(truncatingIfNeeded: sample(index)), to: &data)
    }
    return data
}

private func appendLE16(_ value: UInt16, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func appendLE32(_ value: UInt32, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}
