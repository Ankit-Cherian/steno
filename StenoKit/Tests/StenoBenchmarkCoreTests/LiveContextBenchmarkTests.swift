import Foundation
import Testing
@testable import StenoBenchmarkCore

private let liveNow = Date(timeIntervalSince1970: 2_000_000_000)

@Test("Case-sensitive rows do not inherit the WER scorer's lowercase normalization")
func caseSensitiveRowsRejectCasingDifferences() {
    let row = ContinuationDirectiveCorpus.Row(
        id: "continuation-uppercase",
        input: "Hello. | This works.",
        expectedOutput: "This works.",
        category: "continuation"
    )
    let result = CaseSensitiveBenchmark.row(
        corpusRow: row,
        actualOutput: "this works.",
        continuationDecisionCorrect: true,
        unintendedLowercaseCount: 1,
        directiveDecisionCorrect: true,
        literalLowercasePreserved: true,
        boundarySpacingCorrect: true
    )

    #expect(result.status == .failed)
    #expect(result.expectedSHA256 != result.actualSHA256)
    #expect(result.reasonCode == "case-sensitive-contract-mismatch")
}

@Test("Live-context validator accepts complete current evidence")
func liveContextValidatorAcceptsCompleteEvidence() throws {
    let fixture = try acceptedFixture()
    let caseResult = LiveContextBenchmarkValidator.validateCaseSensitive(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: fixture.expectedIdentity,
        now: liveNow
    )
    let liveResult = LiveContextBenchmarkValidator.validateLiveCoreDiagnostics(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: fixture.expectedIdentity,
        now: liveNow
    )

    #expect(caseResult.accepted)
    #expect(liveResult.accepted)
}

@Test("Current live artifact round-trips through the v6 loader and prior schemas are rejected")
func liveArtifactV6RoundTrip() throws {
    let fixture = try acceptedFixture()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-artifact-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifactURL = directory.appendingPathComponent("artifact.json")

    try LiveContextArtifactIO.encodeArtifact(fixture.artifact).write(to: artifactURL)
    let loaded = try LiveContextArtifactIO.loadArtifact(at: artifactURL.path)

    #expect(loaded == fixture.artifact)
    #expect(loaded.schemaVersion == LiveContextBenchmarkArtifact.currentSchemaVersion)
    #expect(loaded.resources.warmRuntime == fixture.artifact.resources.warmRuntime)

    var prior = fixture.artifact
    prior.schemaVersion = "steno-live-context-benchmark/v5"
    try LiveContextArtifactIO.encodeArtifact(prior).write(to: artifactURL)
    #expect(throws: LiveContextArtifactIOError.unsupportedSchema) {
        try LiveContextArtifactIO.loadArtifact(at: artifactURL.path)
    }
}

@Test("Authoritative final replacement does not invalidate monotonic provisional evidence")
func authoritativeFinalReplacementIsReportedButAllowed() throws {
    let fixture = try acceptedFixture()
    var artifact = fixture.artifact
    artifact.correctness.stablePrefixFinalConflicts = 5

    let result = LiveContextBenchmarkValidator.validateLiveCoreDiagnostics(
        artifact: artifact,
        corpus: fixture.corpus,
        expectedIdentity: fixture.expectedIdentity,
        now: liveNow
    )

    #expect(result.accepted)
}

@Test("Artifact identity, freshness, schema, hashes, and counts fail closed")
func liveContextIdentityFailures() throws {
    let fixture = try acceptedFixture()

    var unsupported = fixture.artifact
    unsupported.schemaVersion = "future"
    #expect(failures(unsupported, fixture).contains("unsupported-artifact-schema"))

    var priorSchema = fixture.artifact
    priorSchema.schemaVersion = "steno-live-context-benchmark/v5"
    #expect(failures(priorSchema, fixture).contains("unsupported-artifact-schema"))

    var stale = fixture.artifact
    stale.generatedAt = liveNow.addingTimeInterval(-86_401)
    #expect(failures(stale, fixture).contains("stale-artifact"))

    var dirty = fixture.artifact
    dirty.identity.treeIsDirty = true
    #expect(failures(dirty, fixture).contains("dirty-git-tree"))

    var wrongModelExpected = fixture.expectedIdentity
    wrongModelExpected.modelSHA256 = String(repeating: "9", count: 64)
    #expect(LiveContextBenchmarkValidator.validateLive(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: wrongModelExpected,
        now: liveNow
    ).failures.contains("wrong-model"))

    var manifestMismatch = fixture.expectedIdentity
    manifestMismatch.manifestSHA256 = String(repeating: "8", count: 64)
    #expect(LiveContextBenchmarkValidator.validateLive(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: manifestMismatch,
        now: liveNow
    ).failures.contains("manifest-hash-mismatch"))

    var mismatchedCount = fixture.artifact
    mismatchedCount.observedCorpusRowCount -= 1
    #expect(failures(mismatchedCount, fixture).contains("corpus-row-count-mismatch"))

    var externallyMismatchedCount = fixture.expectedIdentity
    externallyMismatchedCount.expectedCorpusRowCount += 1
    #expect(LiveContextBenchmarkValidator.validateLive(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: externallyMismatchedCount,
        now: liveNow
    ).failures.contains("expected-corpus-row-count-mismatch"))

    var zeroCount = fixture.artifact
    zeroCount.expectedCorpusRowCount = 0
    zeroCount.observedCorpusRowCount = 0
    #expect(failures(zeroCount, fixture).contains("corpus-row-count-mismatch"))

    var pathLeak = fixture.artifact
    pathLeak.identity.modelIdentity = "/private/model.bin"
    #expect(failures(pathLeak, fixture).contains("model-path-not-redacted"))

    var wrongProtocol = fixture.artifact
    wrongProtocol.identity.liveProtocolVersion = 1
    #expect(failures(wrongProtocol, fixture).contains("missing-or-invalid-identity"))

    var wrongHostedReceipt = fixture.expectedIdentity
    wrongHostedReceipt.hostedReceiptSHA256 = String(repeating: "2", count: 64)
    #expect(LiveContextBenchmarkValidator.validateLive(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: wrongHostedReceipt,
        now: liveNow
    ).failures.contains("hosted-receipt-hash-mismatch"))
}

@Test("Case-sensitive corpus requires every exact row and never passes skips")
func continuationCorpusFailsClosed() throws {
    let fixture = try acceptedFixture()

    var missing = fixture.artifact
    missing.caseSensitiveRows.removeLast()
    #expect(caseFailures(missing, fixture).contains("missing-case-sensitive-results"))

    var skipped = fixture.artifact
    skipped.caseSensitiveRows[0].status = .skipped
    skipped.caseSensitiveRows[0].reasonCode = "not-evaluable"
    skipped.skips = [.init(id: skipped.caseSensitiveRows[0].id, reasonCode: "not-evaluable")]
    skipped.declaredSkipCount = 1
    let skippedFailures = caseFailures(skipped, fixture)
    #expect(skippedFailures.contains("skipped-evidence"))
    #expect(skippedFailures.contains("case-sensitive-row-not-passed"))

    var unaccounted = fixture.artifact
    unaccounted.declaredFailureCount = 1
    #expect(caseFailures(unaccounted, fixture).contains("failure-row-accounting"))

    var caseChanged = fixture.artifact
    caseChanged.caseSensitiveRows[0].actualSHA256 = String(repeating: "1", count: 64)
    #expect(caseFailures(caseChanged, fixture).contains("case-sensitive-row-not-passed"))
}

@Test("Latency distributions are raw, finite, internally consistent, and threshold bound")
func liveLatencyFailsClosed() throws {
    let fixture = try acceptedFixture()

    var nonFinite = fixture.artifact
    nonFinite.latency.firstPartial.samplesMS = [.nan]
    nonFinite.latency.firstPartial.count = 1
    nonFinite.latency.firstPartial.p50MS = .nan
    nonFinite.latency.firstPartial.p95MS = .nan
    nonFinite.latency.firstPartial.p99MS = .nan
    #expect(failures(nonFinite, fixture).contains("invalid-latency-distribution:first-partial"))

    var summaryMismatch = fixture.artifact
    summaryMismatch.latency.firstPartial.p95MS = 1
    #expect(failures(summaryMismatch, fixture).contains("invalid-latency-distribution:first-partial"))

    var slow = fixture.artifact
    slow.latency.firstPartial = .summarize([501, 901, 1_501])
    let slowFailures = failures(slow, fixture)
    #expect(slowFailures.contains("first-partial-p50"))
    #expect(slowFailures.contains("first-partial-p95"))
    #expect(slowFailures.contains("first-partial-p99"))

    var weakened = fixture.artifact
    weakened.thresholds.firstPartialP95MS = 10_000
    #expect(failures(weakened, fixture).contains("threshold-contract-mismatch"))

    var tooFewTrials = fixture.artifact
    tooFewTrials.latency.alternatingTrialCount = 4
    #expect(failures(tooFewTrials, fixture).contains("alternating-control-trials"))

    var expandedTrialClaimWithSubsetEvidence = fixture.artifact
    expandedTrialClaimWithSubsetEvidence.latency.alternatingTrialCount = 12
    expandedTrialClaimWithSubsetEvidence.latency.trialOrder += [.enabled, .disabled]
    expandedTrialClaimWithSubsetEvidence.latency.acceptedSubsequentGapCountByEnabledTrial.append(1)
    #expect(failures(expandedTrialClaimWithSubsetEvidence, fixture).contains("alternating-control-trials"))

    var wrongOrder = fixture.artifact
    wrongOrder.latency.trialOrder.swapAt(0, 1)
    #expect(failures(wrongOrder, fixture).contains("alternating-control-trials"))

    var insufficientGaps = fixture.artifact
    insufficientGaps.latency.subsequentPartialGap = .summarize([200, 250, 300, 325])
    #expect(failures(insufficientGaps, fixture).contains("insufficient-subsequent-gap-coverage"))

    var favorableGapWithoutTrialAttribution = fixture.artifact
    favorableGapWithoutTrialAttribution.latency.subsequentPartialGap = .summarize([
        0, 200, 225, 250, 275, 300,
    ])
    #expect(failures(favorableGapWithoutTrialAttribution, fixture).contains(
        "insufficient-subsequent-gap-coverage"
    ))

    var inconsistentPerTrialGapTotal = fixture.artifact
    inconsistentPerTrialGapTotal.latency.acceptedSubsequentGapCountByEnabledTrial = [2, 1, 1, 1, 1]
    #expect(failures(inconsistentPerTrialGapTotal, fixture).contains(
        "insufficient-subsequent-gap-coverage"
    ))

    var overflowingPerTrialGapTotal = fixture.artifact
    overflowingPerTrialGapTotal.latency.acceptedSubsequentGapCountByEnabledTrial = [
        .max, .max, 1, 1, 1,
    ]
    #expect(failures(overflowingPerTrialGapTotal, fixture).contains(
        "insufficient-subsequent-gap-coverage"
    ))

    var identityMismatch = fixture.artifact
    identityMismatch.coreDiagnostics?.publicFixtureSHA256 = String(repeating: "9", count: 64)
    #expect(failures(identityMismatch, fixture).contains("production-core-diagnostic-gate"))

    var malformedStopDistribution = fixture.artifact
    malformedStopDistribution.latency.stopToInsertionEnabled.p95MS = 1
    #expect(failures(malformedStopDistribution, fixture).contains(
        "invalid-latency-distribution:stop-to-insertion-enabled"
    ))

    var slowStop = fixture.artifact
    slowStop.latency.stopToInsertionEnabled = .summarize([701, 701, 701, 701, 701])
    slowStop.latency.stopToInsertionDisabledControl = .summarize([690, 690, 690, 690, 690])
    #expect(failures(slowStop, fixture).contains("stop-to-insertion-p95"))

    var insufficientStopTrials = fixture.artifact
    insufficientStopTrials.latency.stopToInsertionEnabled = .summarize([500, 500, 500, 500])
    #expect(failures(insufficientStopTrials, fixture).contains("alternating-control-trials"))

    var fabricatedExtraSetup = fixture.artifact
    fabricatedExtraSetup.latency.helperStreamSetup = .summarize([20, 25, 30, 35, 40, 0])
    #expect(failures(fabricatedExtraSetup, fixture).contains("alternating-control-trials"))

    var fabricatedExtraFirstPartial = fixture.artifact
    fabricatedExtraFirstPartial.latency.firstPartial = .summarize([300, 400, 450, 500, 550, 0])
    #expect(failures(fabricatedExtraFirstPartial, fixture).contains("alternating-control-trials"))

    var fabricatedExtraFinal = fixture.artifact
    fabricatedExtraFinal.latency.finishToAuthoritativeFinalDisabledControl = .summarize([
        500, 540, 560, 590, 620, 0,
    ])
    #expect(failures(fabricatedExtraFinal, fixture).contains("alternating-control-trials"))

    var fabricatedExtraStopTrial = fixture.artifact
    fabricatedExtraStopTrial.latency.stopToInsertionEnabled = .summarize([
        500, 550, 575, 600, 650, 0,
    ])
    #expect(failures(fabricatedExtraStopTrial, fixture).contains("alternating-control-trials"))

    var regression = fixture.artifact
    regression.latency.stopToInsertionEnabled = .summarize([690, 690, 690, 690, 690])
    regression.latency.stopToInsertionDisabledControl = .summarize([600, 600, 600, 600, 600])
    #expect(failures(regression, fixture).contains("stop-to-insertion-regression"))
}

@Test("Shipping validation remains structurally blocked without an independent native receipt")
func nativeShippingEvidenceCannotBeSelfAttested() throws {
    let fixture = try acceptedFixture()
    let result = LiveContextBenchmarkValidator.validateLive(
        artifact: fixture.artifact,
        corpus: fixture.corpus,
        expectedIdentity: fixture.expectedIdentity,
        now: liveNow
    )
    #expect(result.failures.contains("native-listening-evidence-required"))
    #expect(result.failures.contains("native-stop-to-insertion-evidence-required"))
}

@Test("Capture, resource, privacy, correctness, and lifecycle omissions are blocking")
func liveOperationalEvidenceFailsClosed() throws {
    let fixture = try acceptedFixture()
    func replacingResourceCheckpoints(
        _ artifact: LiveContextBenchmarkArtifact,
        transform: (inout [WarmRuntimeResourceCheckpoint]) -> Void
    ) -> LiveContextBenchmarkArtifact {
        var artifact = artifact
        let previous = artifact.resources.warmRuntime
        var checkpoints = previous.checkpoints
        transform(&checkpoints)
        let updated = WarmRuntimeResourceSummary.analyze(
            checkpoints: checkpoints,
            idleCPUPercent: previous.idleCPUPercent,
            idleSampleSeconds: previous.idleSampleSeconds,
            postIdleResidentBytes: previous.postIdleResidentBytes,
            postIdlePhysicalFootprintBytes: previous.postIdlePhysicalFootprintBytes
        )
        let residentValues = updated.checkpoints.compactMap { checkpoint in
            checkpoint.residentBytes.map { (checkpoint.requestIndex, $0) }
        }
        let physicalValues = updated.checkpoints.compactMap { checkpoint in
            checkpoint.physicalFootprintBytes.map { (checkpoint.requestIndex, $0) }
        }
        artifact.resources.warmRuntime = updated
        artifact.resources.peakRSSBytes = residentValues.map(\.1).max()
        artifact.resources.peakGrowthBytes = updated.peakGrowthBytesFromFirst
        artifact.resources.tailSlopeBytesPerRequest = updated.tailSlopeBytesPerRequest
        artifact.resources.monotonicGrowthObserved = updated.monotonicGrowthObserved
        artifact.resources.sawtoothGrowthObserved = LiveContextBenchmarkRunner.detectsUnboundedSawtooth(
            residentValues,
            maximumTailSlopeBytesPerRequest: LiveContextBenchmarkThresholds.required.maximumTailSlopeBytesPerRequest
        )
        artifact.resources.physicalFootprintSawtoothGrowthObserved =
            LiveContextBenchmarkRunner.detectsUnboundedSawtooth(
                physicalValues,
                maximumTailSlopeBytesPerRequest:
                    LiveContextBenchmarkThresholds.required.maximumTailSlopeBytesPerRequest
            )
        return artifact
    }

    var capture = fixture.artifact
    capture.capture.canonicalPCMHash = String(repeating: "7", count: 64)
    #expect(failures(capture, fixture).contains("capture-parity"))

    var wrongFNV = fixture.artifact
    wrongFNV.capture.trials[0].canonicalFNV1A64 = "ffffffffffffffff"
    #expect(failures(wrongFNV, fixture).contains("capture-fnv-parity"))

    var duplicateCaptureTrialIndex = fixture.artifact
    duplicateCaptureTrialIndex.capture.trials[1].trialIndex =
        duplicateCaptureTrialIndex.capture.trials[0].trialIndex
    #expect(failures(duplicateCaptureTrialIndex, fixture).contains("capture-fnv-parity"))

    var resources = fixture.artifact
    resources.resources.soakSessionCount = 499
    resources.resources.idleSampleSeconds = 59
    resources.resources.maximumConcurrentHelperProcessCount = 2
    #expect(failures(resources, fixture).contains("resource-gate"))

    var weakSoak = fixture.artifact
    weakSoak.resources.requestedSoakSessionCount = 499
    weakSoak.resources.completedSoakSessionCount = 499
    weakSoak.resources.soakSessionCount = 499
    #expect(failures(weakSoak, fixture).contains("resource-gate"))

    var interruptedIdle = fixture.artifact
    interruptedIdle.resources.observedIdleSampleSeconds = 59
    interruptedIdle.resources.idleObservationCompleted = false
    #expect(failures(interruptedIdle, fixture).contains("resource-gate"))

    var wrongCeiling = fixture.artifact
    wrongCeiling.resources.rssCeilingBytes = 2_000_000_000
    #expect(failures(wrongCeiling, fixture).contains("resource-gate"))

    var fallback = fixture.artifact
    fallback.resources.helperFallbackCount = 1
    fallback.resources.helperReloadCount = 1
    #expect(failures(fallback, fixture).contains("resource-gate"))

    var nonFiniteResource = fixture.artifact
    nonFiniteResource.resources.activeCPUPercentSamples = [.infinity]
    #expect(failures(nonFiniteResource, fixture).contains("resource-gate"))

    var missingActiveCPUSample = fixture.artifact
    missingActiveCPUSample.resources.activeCPUPercentSamples.removeLast()
    #expect(failures(missingActiveCPUSample, fixture).contains("resource-gate"))

    var missingResidentTelemetry = fixture.artifact
    missingResidentTelemetry.resources.currentResidentModelCount = nil
    #expect(failures(missingResidentTelemetry, fixture).contains("resource-gate"))

    var duplicateResidentContext = fixture.artifact
    duplicateResidentContext.resources.maximumResidentModelCount = 2
    #expect(failures(duplicateResidentContext, fixture).contains("resource-gate"))

    var missingRawCheckpoint = fixture.artifact
    missingRawCheckpoint.resources.warmRuntime.checkpoints.removeAll { $0.requestIndex == 10 }
    #expect(failures(missingRawCheckpoint, fixture).contains("resource-gate"))

    let missingPeriodicCheckpoint = replacingResourceCheckpoints(fixture.artifact) {
        $0.removeAll { $0.requestIndex == 25 }
    }
    #expect(failures(missingPeriodicCheckpoint, fixture).contains("resource-gate"))

    let offGridCheckpoint = replacingResourceCheckpoints(fixture.artifact) {
        $0.append(.init(
            requestIndex: 24,
            residentBytes: 1_480_000_000,
            physicalFootprintBytes: 1_530_000_000
        ))
    }
    #expect(failures(offGridCheckpoint, fixture).contains("resource-gate"))

    let duplicateCheckpoint = replacingResourceCheckpoints(fixture.artifact) {
        let first = $0[0]
        $0.append(first)
    }
    #expect(failures(duplicateCheckpoint, fixture).contains("resource-gate"))

    var missingPhysicalFootprint = fixture.artifact
    missingPhysicalFootprint.resources.warmRuntime.checkpoints[0].physicalFootprintBytes = nil
    #expect(failures(missingPhysicalFootprint, fixture).contains("resource-gate"))

    var physicalTailGrowth = fixture.artifact
    physicalTailGrowth.resources.warmRuntime.physicalFootprintTailSlopeBytesPerRequest = 32 * 1_024 + 1
    #expect(failures(physicalTailGrowth, fixture).contains("resource-gate"))

    var missingPostIdleEvidence = fixture.artifact
    missingPostIdleEvidence.resources.warmRuntime.postIdlePhysicalFootprintBytes = nil
    #expect(failures(missingPostIdleEvidence, fixture).contains("resource-gate"))

    var interruptedHelperMonitor = fixture.artifact
    interruptedHelperMonitor.resources.maximumHelperMonitorGapMS = 250.001
    #expect(failures(interruptedHelperMonitor, fixture).contains("resource-gate"))

    var emptyHelperPoll = fixture.artifact
    emptyHelperPoll.resources.helperProcessUnexpectedObservationCount = 1
    #expect(failures(emptyHelperPoll, fixture).contains("resource-gate"))

    var monitorStartedAfterSoak = fixture.artifact
    monitorStartedAfterSoak.resources.helperMonitorPreSoakObservationLeadMS = -0.001
    #expect(failures(monitorStartedAfterSoak, fixture).contains("resource-gate"))

    var monitorEndedBeforeSoak = fixture.artifact
    monitorEndedBeforeSoak.resources.helperMonitorPostSoakObservationLagMS = -0.001
    #expect(failures(monitorEndedBeforeSoak, fixture).contains("resource-gate"))

    var monitorCoveredSoakTooLate = fixture.artifact
    monitorCoveredSoakTooLate.resources.helperMonitorPostSoakObservationLagMS = 250.001
    #expect(failures(monitorCoveredSoakTooLate, fixture).contains("resource-gate"))

    var idleMemoryGrowth = fixture.artifact
    let idleBaseline = try #require(
        idleMemoryGrowth.resources.warmRuntime.checkpoints.last?.residentBytes
    )
    let priorWarm = idleMemoryGrowth.resources.warmRuntime
    idleMemoryGrowth.resources.warmRuntime = .analyze(
        checkpoints: priorWarm.checkpoints,
        idleCPUPercent: priorWarm.idleCPUPercent,
        idleSampleSeconds: priorWarm.idleSampleSeconds,
        postIdleResidentBytes: idleBaseline + 1,
        postIdlePhysicalFootprintBytes: priorWarm.postIdlePhysicalFootprintBytes
    )
    #expect(failures(idleMemoryGrowth, fixture).contains("resource-gate"))

    var contradictorySummary = fixture.artifact
    contradictorySummary.resources.peakGrowthBytes = 0
    #expect(failures(contradictorySummary, fixture).contains("resource-gate"))

    var privacy = fixture.artifact
    privacy.privacy.canaryProbeCount = 0
    privacy.privacy.argumentVectorLeaks = 1
    #expect(failures(privacy, fixture).contains("privacy-gate"))

    var correctness = fixture.artifact
    correctness.correctness.stablePrefixMutations = 1
    #expect(failures(correctness, fixture).contains("correctness-regression"))

    var forgedPreviewSessionCounts = fixture.artifact
    forgedPreviewSessionCounts.correctness.provisionalSessionCount = 1
    forgedPreviewSessionCounts.correctness.finalizationCount = 1
    #expect(failures(forgedPreviewSessionCounts, fixture).contains("preview-convergence-not-proven"))

    var insufficientAcceptedRevisions = fixture.artifact
    insufficientAcceptedRevisions.correctness.revisionCount = 9
    #expect(failures(insufficientAcceptedRevisions, fixture).contains("preview-convergence-not-proven"))

    var lifecycle = fixture.artifact
    lifecycle.lifecycle.rapidCancelRestartCases = 249
    #expect(failures(lifecycle, fixture).contains("lifecycle-gate"))
}

@Test("Artifact serialization contains aggregate hashes and no transcript or context fields")
func liveArtifactEncodingIsRedacted() throws {
    let fixture = try acceptedFixture()
    let data = try LiveContextArtifactIO.encodeArtifact(fixture.artifact)
    let json = String(decoding: data, as: UTF8.self)

    #expect(!json.contains(fixture.corpus.rows[0].input))
    #expect(!json.contains(fixture.corpus.rows[0].expectedOutput))
    #expect(!json.localizedCaseInsensitiveContains("hypothesisText"))
    #expect(!json.localizedCaseInsensitiveContains("contextText"))
    #expect(!json.contains("/private/model.bin"))
    #expect(try LiveContextArtifactIO.validatePrivacy(of: data))

    let injected = Data("{\"hypothesisText\":\"private canary\"}".utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: injected))
    let pathInjected = Data("{\"modelIdentity\":\"/Users/private/model.bin\"}".utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: pathInjected))
    let embeddedUserPath = Data("{\"modelIdentity\":\"diagnostic: /Users/private/model.bin\"}".utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: embeddedUserPath))
    let embeddedPrivatePath = Data("{\"modelIdentity\":\"diagnostic: /private/tmp/model.bin\"}".utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: embeddedPrivatePath))
    let mixedCaseLocalPath = Data("{\"modelIdentity\":\"diagnostic: /uSeRs/private/model.bin\"}".utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: mixedCaseLocalPath))
    let embeddedFileURI = Data("{\"modelIdentity\":\"diagnostic: FILE:///tmp/model.bin\"}".utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: embeddedFileURI))
    let escapedEmbeddedPath = Data(#"{"modelIdentity":"diagnostic: \\/Users/private/model.bin"}"#.utf8)
    #expect(try !LiveContextArtifactIO.validatePrivacy(of: escapedEmbeddedPath))
    let repositoryRelativePath = Data(
        "{\"modelIdentity\":\"vendor/whisper.cpp/models/ggml-model.bin\"}".utf8
    )
    #expect(try LiveContextArtifactIO.validatePrivacy(of: repositoryRelativePath))

    var canaryArtifact = fixture.artifact
    canaryArtifact.identity.runtimeIdentity = LiveContextReceiptManifest.hostedPrivacyCanaries(
        gitSHA: canaryArtifact.identity.gitSHA
    )[0]
    #expect(failures(canaryArtifact, fixture).contains("raw-artifact-canary-leak"))
    #expect(throws: LiveContextArtifactIOError.privacyValidationFailed) {
        try LiveContextArtifactIO.encodeArtifact(canaryArtifact)
    }
}

@Test("Privacy sentinel scanning covers byte surfaces and process arguments exactly")
func livePrivacySentinelScanner() {
    let sentinel = "STENO-CANARY-AbC-123"
    #expect(LiveContextSentinelScanner.leakCount(
        sentinel: sentinel,
        surfaces: [Data("safe".utf8), Data("prefix \(sentinel) suffix".utf8)]
    ) == 1)
    #expect(LiveContextSentinelScanner.argumentVectorLeakCount(
        sentinel: sentinel,
        arguments: ["--language", "en", "--prompt=\(sentinel)"]
    ) == 1)
    #expect(LiveContextSentinelScanner.argumentVectorLeakCount(
        sentinel: sentinel,
        arguments: ["--language", "en"]
    ) == 0)
}

private struct LiveFixture {
    var corpus: ContinuationDirectiveCorpus
    var artifact: LiveContextBenchmarkArtifact
    var expectedIdentity: LiveContextExpectedIdentity
}

private func acceptedFixture() throws -> LiveFixture {
    let corpus = ContinuationDirectiveCorpus(rows: [
        .init(id: "continuation", input: "Hello. | This works.", expectedOutput: "This works.", category: "continuation"),
        .init(id: "literal", input: "literal lowercase Hello", expectedOutput: "lowercase Hello", category: "literal-escape"),
    ])
    let corpusHash = try corpus.sha256()
    let git = String(repeating: "a", count: 40)
    let manifest = String(repeating: "b", count: 64)
    let model = String(repeating: "c", count: 64)
    let runtime = String(repeating: "d", count: 64)
    let pcm = String(repeating: "e", count: 64)
    let hostedReceipt = String(repeating: "f", count: 64)
    let adversarialReceipt = String(repeating: "1", count: 64)
    let audio = String(repeating: "2", count: 64)
    let hostedSource = String(repeating: "3", count: 64)
    let helperSource = String(repeating: "4", count: 64)
    let harness = String(repeating: "5", count: 64)
    let expectedIdentity = LiveContextExpectedIdentity(
        gitSHA: git,
        manifestSHA256: manifest,
        modelSHA256: model,
        runtimeSHA256: runtime,
        expectedCorpusRowCount: corpus.rows.count,
        threadCount: 8,
        hostedReceiptSHA256: hostedReceipt,
        adversarialReceiptSHA256: adversarialReceipt,
        audioFixtureSHA256: audio,
        hostedSourceManifestSHA256: hostedSource,
        helperSourceSHA256: helperSource,
        adversarialHarnessSHA256: harness,
        language: "en"
    )
    let caseRows = corpus.rows.map { row in
        CaseSensitiveBenchmark.row(
            corpusRow: row,
            actualOutput: row.expectedOutput,
            continuationDecisionCorrect: true,
            unintendedLowercaseCount: 0,
            directiveDecisionCorrect: true,
            literalLowercasePreserved: true,
            boundarySpacingCorrect: true
        )
    }
    let resourceCheckpoints = [1, 10, 25, 50, 75, 100, 125, 150, 175, 200,
                               225, 250, 275, 300, 325, 350, 375, 400, 425, 450,
                               475, 500].map { index in
        WarmRuntimeResourceCheckpoint(
            requestIndex: index,
            residentBytes: UInt64(index == 10 ? 1_500_000_000 : 1_480_000_000),
            physicalFootprintBytes: UInt64(index == 10 ? 1_550_000_000 : 1_530_000_000)
        )
    }
    let warmResources = WarmRuntimeResourceSummary.analyze(
        checkpoints: resourceCheckpoints,
        idleCPUPercent: 0.05,
        idleSampleSeconds: 60,
        postIdleResidentBytes: 1_479_000_000,
        postIdlePhysicalFootprintBytes: 1_529_000_000
    )
    let artifact = LiveContextBenchmarkArtifact(
        generatedAt: liveNow.addingTimeInterval(-60),
        identity: .init(
            gitSHA: git,
            treeIsDirty: false,
            manifestSHA256: manifest,
            corpusSHA256: corpusHash,
            modelSHA256: model,
            audioFixtureSHA256: audio,
            modelIdentity: "ggml-large-v3-turbo.bin",
            modelPathPolicy: .repositoryRelative,
            threadCount: 8,
            language: "en",
            realtimePacing: true,
            runtimeSHA256: runtime,
            runtimeIdentity: "steno-whisper-runtime",
            liveProtocolVersion: 2,
            liveRuntimeIdentifier: "runtime-token",
            liveModelIdentifier: String(repeating: "3", count: 64),
            hostedReceiptSHA256: hostedReceipt,
            adversarialReceiptSHA256: adversarialReceipt,
            hostedSourceManifestSHA256: hostedSource,
            helperSourceSHA256: helperSource,
            adversarialHarnessSHA256: harness,
            hardware: "Apple M5 Pro",
            operatingSystem: "macOS 27.0",
            powerState: "ac-power"
        ),
        thresholds: .required,
        expectedCorpusRowCount: corpus.rows.count,
        observedCorpusRowCount: corpus.rows.count,
        declaredFailureCount: 0,
        declaredSkipCount: 0,
        failures: [],
        skips: [],
        caseSensitiveRows: caseRows,
        latency: .init(
            listeningAcknowledgement: .summarize([40, 50, 60, 70, 80]),
            helperStreamSetup: .summarize([20, 25, 30, 35, 40]),
            firstPartial: .summarize([300, 350, 400, 450, 800]),
            subsequentPartialGap: .summarize([200, 225, 250, 275, 300]),
            overlayMainActorWork: .summarize([2, 4, 7]),
            finishToAuthoritativeFinalEnabled: .summarize([500, 550, 575, 600, 650]),
            finishToAuthoritativeFinalDisabledControl: .summarize([500, 540, 560, 590, 620]),
            stopToInsertionEnabled: .summarize([500, 550, 575, 600, 650]),
            stopToInsertionDisabledControl: .summarize([500, 540, 560, 590, 620]),
            maximumVisibleUpdatesPerSecond: 4,
            alternatingTrialCount: 10,
            trialOrder: [.enabled, .disabled, .enabled, .disabled, .enabled, .disabled, .enabled, .disabled, .enabled, .disabled],
            sameConfigurationAcrossTrials: true,
            coreDiagnosticDefinition: LiveContextProductionCoordinatorBenchmark.definition,
            coreDiagnosticReadinessDefinition: LiveContextProductionCoordinatorBenchmark.enabledReadinessDefinition,
            coreDiagnosticConfigurationSHA256: String(repeating: "6", count: 64),
            acceptedSubsequentGapCountByEnabledTrial: [1, 1, 1, 1, 1]
        ),
        correctness: .init(
            stablePrefixMutations: 0,
            provisionalSideEffects: 0,
            duplicateFinalInsertions: 0,
            staleEventsAccepted: 0,
            stablePrefixConflicts: 0,
            stablePrefixFinalConflicts: 0,
            provisionalSessionCount: 5,
            noSpeechFalseDisplays: 0,
            latePartialsAfterCancellation: 0,
            revisionCount: 250,
            finalizationCount: 5
        ),
        capture: .init(
            expectedAudioSampleCount: 16_000,
            streamedSampleCount: 16_000,
            canonicalSampleCount: 16_000,
            streamedPCMHash: pcm,
            canonicalPCMHash: pcm,
            frameSequenceOrOffsetDiscontinuities: 0,
            expectedFNV1A64: "0123456789abcdef",
            streamedFNV1A64: "0123456789abcdef",
            canonicalFNV1A64: "0123456789abcdef",
            audioFixtureSHA256: audio,
            trials: (0..<5).map {
                .init(trialIndex: $0 * 2, expectedSampleCount: 16_000, streamedSampleCount: 16_000, canonicalSampleCount: 16_000, expectedFNV1A64: "0123456789abcdef", streamedFNV1A64: "0123456789abcdef", canonicalFNV1A64: "0123456789abcdef")
            }
        ),
        resources: .init(
            soakSessionCount: 500,
            warmRuntime: warmResources,
            peakRSSBytes: resourceCheckpoints.compactMap(\.residentBytes).max(),
            rssCeilingBytes: 2_147_483_648,
            peakGrowthBytes: warmResources.peakGrowthBytesFromFirst,
            tailSlopeBytesPerRequest: warmResources.tailSlopeBytesPerRequest,
            monotonicGrowthObserved: warmResources.monotonicGrowthObserved,
            sawtoothGrowthObserved: false,
            physicalFootprintSawtoothGrowthObserved: false,
            idleCPUPercent: warmResources.idleCPUPercent,
            idleSampleSeconds: 60,
            activeCPUPercentSamples: [40, 45, 50, 55, 60],
            maximumQueueDepth: 1,
            coalescedPreviewCount: 10,
            helperReloadCount: 0,
            helperFallbackCount: 0,
            maximumConcurrentHelperProcessCount: 1,
            thermalState: "nominal",
            requestedSoakSessionCount: 500,
            completedSoakSessionCount: 500,
            observedIdleSampleSeconds: 60,
            idleObservationCompleted: true,
            continuousHelperMonitorPerformed: true,
            helperProcessObservationCount: 500,
            maximumHelperMonitorGapMS: 70,
            helperMonitorPreSoakObservationLeadMS: 1,
            helperMonitorPostSoakObservationLagMS: 1,
            currentResidentModelCount: 1,
            maximumResidentModelCount: 1,
            modelInitializationSourceSHA256: helperSource,
            modelInitializationSiteCount: 1
        ),
        privacy: .init(
            staticNetworkTransportMatches: 0,
            listeningSocketsObserved: 0,
            runtimeNetworkConnectionsObserved: 0,
            canaryProbeCount: 10,
            requestLeaks: 0,
            cleanupLeaks: 0,
            historyLeaks: 0,
            insertionLeaks: 0,
            clipboardRecoveryLeaks: 0,
            analyticsLeaks: 0,
            configuredSnippetTrapCount: 1,
            snippetTrapActivations: 0,
            liveCallbackUnexpectedContextLeaks: 0,
            overlayRetainedTextLeaks: 0,
            artifactLeaks: 0,
            argumentVectorLeaks: 0,
            staticAuditBoundSourceManifestSHA256: hostedSource,
            featureLogInvocationSourceFindings: 0,
            crashMetadataSinkReferenceSourceFindings: 0,
            ephemeralPersistenceSourceFindings: 0,
            ephemeralFilenameDiagnosticSourceFindings: 0,
            prohibitedNetworkAPISourceFindings: 0,
            secureFieldContextReadRequests: 0,
            maximumAXUTF16ReadPerSide: 512,
            maximumAXGraphemesPerSide: 256,
            maximumAXContextBytes: 8_192
        ),
        lifecycle: .init(
            randomizedSessions: 1_000,
            rapidCancelRestartCases: 250,
            targetTransitions: 10_000,
            helperCrashScenariosPassed: 4,
            helperCrashScenariosExpected: 4,
            malformedProtocolScenariosPassed: 5,
            malformedProtocolScenariosExpected: 5,
            authoritativeFinishCalls: 100,
            maximumAuthoritativeFinishCallsPerSession: 1,
            coordinatorSecondFinalInferenceAttempts: 0,
            finalInsertionCount: 1_000,
            expectedFinalInsertionCount: 1_000
        ),
        coreDiagnostics: .init(
            trialOrder: [.enabled, .disabled, .enabled, .disabled, .enabled, .disabled, .enabled, .disabled, .enabled, .disabled],
            authoritativeFinalOwnershipCount: 10,
            insertionCommitCount: 10,
            historyAppendCount: 10,
            successfulEnabledReadinessCount: 5,
            liveFinishAuthoritativeFinalCount: 5,
            disabledTranscribeAuthoritativeFinalCount: 5,
            coordinatorFallbackCount: 0,
            runtimeIdentityCount: 1,
            publicFixtureSHA256: audio,
            configurationSHA256: String(repeating: "6", count: 64),
            enabledCanonicalSummaries: (0..<5).map { _ in
                .init(sampleCount: 16_000, byteCount: 32_000, frameCount: 4, fnv1a64: "0123456789abcdef")
            }
        )
    )
    return LiveFixture(corpus: corpus, artifact: artifact, expectedIdentity: expectedIdentity)
}

private func failures(_ artifact: LiveContextBenchmarkArtifact, _ fixture: LiveFixture) -> [String] {
    LiveContextBenchmarkValidator.validateLiveCoreDiagnostics(
        artifact: artifact,
        corpus: fixture.corpus,
        expectedIdentity: fixture.expectedIdentity,
        now: liveNow
    ).failures
}

private func caseFailures(_ artifact: LiveContextBenchmarkArtifact, _ fixture: LiveFixture) -> [String] {
    LiveContextBenchmarkValidator.validateCaseSensitive(
        artifact: artifact,
        corpus: fixture.corpus,
        expectedIdentity: fixture.expectedIdentity,
        now: liveNow
    ).failures
}
