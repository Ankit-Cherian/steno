import Foundation

public enum BenchmarkReportError: Error, LocalizedError {
    case missingRequiredLabel(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredLabel(let label):
            return "Report is missing required label: \(label)"
        }
    }
}

public enum BenchmarkReportRenderer {
    public static let rawLabel = "Raw ASR (whisper-cli)"
    public static let pipelineLabel = "Steno post-processing output"

    public static func render(
        manifest: BenchmarkManifest,
        raw: RawEngineOutput,
        pipeline: PipelineOutput,
        macSanity: MacSanityChecklist
    ) -> String {
        let rawSummary = raw.summary
        let pipelineSummary = pipeline.summary

        var markdown: [String] = []
        markdown.append("# \(manifest.benchmarkName) Benchmark Report")
        markdown.append("")
        markdown.append("## Methodology")
        markdown.append("- Manifest schema: `\(manifest.schemaVersion)`")
        markdown.append("- Scoring normalization: `\(manifest.scoring.normalization.version)`")
        markdown.append("- Samples: \(manifest.samples.count)")
        markdown.append("- Whisper model path: `\(raw.whisperConfiguration.modelPath)`")
        markdown.append("- Whisper CLI path: `\(raw.whisperConfiguration.whisperCLIPath)`")
        markdown.append("- Cleanup profile: `\(pipeline.profile.name)` (`\(pipeline.profile.fillerPolicy.rawValue)`, `\(pipeline.profile.structureMode.rawValue)`)")
        markdown.append("- Lexicon entries in pipeline run: \(pipeline.lexiconEntryCount)")
        markdown.append("")

        markdown.append("## Scorecard: \(rawLabel)")
        markdown.append("| Metric | Value |")
        markdown.append("|---|---:|")
        markdown.append("| Samples | \(rawSummary.totalSamples) |")
        markdown.append("| Success | \(rawSummary.succeeded) |")
        markdown.append("| Failure | \(rawSummary.failed) |")
        markdown.append("| Failure Rate | \(percent(rawSummary.failureRate)) |")
        markdown.append("| WER | \(decimal(rawSummary.wer)) |")
        markdown.append("| CER | \(decimal(rawSummary.cer)) |")
        markdown.append("| Mean Latency (ms) | \(decimal(rawSummary.meanLatencyMS)) |")
        markdown.append("| p50 Latency (ms) | \(decimal(rawSummary.p50LatencyMS)) |")
        markdown.append("| p90 Latency (ms) | \(decimal(rawSummary.p90LatencyMS)) |")
        markdown.append("| p99 Latency (ms) | \(decimal(rawSummary.p99LatencyMS)) |")
        markdown.append("| Mean RTF | \(decimal(rawSummary.meanRTF)) |")
        markdown.append("")

        if !raw.datasetBreakdown.isEmpty {
            markdown.append("### Dataset Breakdown (\(rawLabel))")
            markdown.append("| Dataset | Samples | Failure Rate | WER | CER | Mean Latency (ms) |")
            markdown.append("|---|---:|---:|---:|---:|---:|")
            for dataset in raw.datasetBreakdown.keys.sorted() {
                guard let summary = raw.datasetBreakdown[dataset] else { continue }
                markdown.append(
                    "| \(dataset) | \(summary.totalSamples) | \(percent(summary.failureRate)) | \(decimal(summary.wer)) | \(decimal(summary.cer)) | \(decimal(summary.meanLatencyMS)) |"
                )
            }
            markdown.append("")
        }

        markdown.append("## Scorecard: \(pipelineLabel)")
        markdown.append("| Metric | Value |")
        markdown.append("|---|---:|")
        markdown.append("| Scored Samples | \(pipelineSummary.scoredSamples) / \(pipelineSummary.totalSamples) |")
        markdown.append("| Raw WER (same samples) | \(decimal(pipelineSummary.rawWER)) |")
        markdown.append("| Cleaned WER | \(decimal(pipelineSummary.cleanedWER)) |")
        markdown.append("| WER Delta (cleaned - raw) | \(decimal(pipelineSummary.werDelta)) |")
        markdown.append("| Raw CER (same samples) | \(decimal(pipelineSummary.rawCER)) |")
        markdown.append("| Cleaned CER | \(decimal(pipelineSummary.cleanedCER)) |")
        markdown.append("| CER Delta (cleaned - raw) | \(decimal(pipelineSummary.cerDelta)) |")
        markdown.append("| Improved | \(pipelineSummary.improved) |")
        markdown.append("| Unchanged | \(pipelineSummary.unchanged) |")
        markdown.append("| Regressed | \(pipelineSummary.regressed) |")
        markdown.append("| Unscored | \(pipelineSummary.unscored) |")
        markdown.append("")

        markdown.append("### Lexicon Effectiveness (\(pipelineLabel))")
        markdown.append("| Metric | Value |")
        markdown.append("|---|---:|")
        markdown.append("| Applied Lexicon Edits | \(pipelineSummary.lexicon.totalAppliedEdits) |")
        markdown.append("| Edits Matching Reference | \(pipelineSummary.lexicon.editsMatchingReference) |")
        markdown.append("| Edits Not Matching Reference | \(pipelineSummary.lexicon.editsNotMatchingReference) |")
        markdown.append("| Reference-Match Accuracy | \(percent(pipelineSummary.lexicon.referenceMatchAccuracy)) |")
        markdown.append("")

        markdown.append("### Filler Policy Impact (\(pipelineLabel))")
        markdown.append("| Metric | Value |")
        markdown.append("|---|---:|")
        markdown.append("| Samples With Filler Removals | \(pipelineSummary.fillerImpact.samplesWithFillerRemovals) |")
        markdown.append("| Total Removed Fillers | \(pipelineSummary.fillerImpact.totalRemovedFillers) |")
        markdown.append("| Raw WER (filler subset) | \(decimal(pipelineSummary.fillerImpact.rawWEROnFillerSamples)) |")
        markdown.append("| Cleaned WER (filler subset) | \(decimal(pipelineSummary.fillerImpact.cleanedWEROnFillerSamples)) |")
        markdown.append("| Delta WER (filler subset) | \(decimal(pipelineSummary.fillerImpact.deltaWEROnFillerSamples)) |")
        markdown.append("| Improved / Unchanged / Regressed | \(pipelineSummary.fillerImpact.improved) / \(pipelineSummary.fillerImpact.unchanged) / \(pipelineSummary.fillerImpact.regressed) |")
        markdown.append("")

        markdown.append("## Mac Integration Sanity")
        markdown.append("| Check | Status | Notes |")
        markdown.append("|---|---|---|")
        for item in macSanity.items {
            markdown.append("| \(item.title) | \(item.status) | \(item.notes ?? "") |")
        }
        markdown.append("")
        markdown.append("- Overall status: \(macSanity.overallStatus)")
        markdown.append("- App build SHA: `\(macSanity.appBuildSHA)`")
        markdown.append("- macOS version: `\(macSanity.macOSVersion)`")
        markdown.append("")

        markdown.append("## Claim Guardrails")
        markdown.append("- Always report and chart \(rawLabel) separately from \(pipelineLabel).")
        markdown.append("- Linux/VM runs benchmark ASR and text transforms only; they do not validate full macOS runtime behavior.")
        markdown.append("- Unknown/no-evidence media playback states must remain safety-noop in macOS behavior claims.")
        markdown.append("")

        return markdown.joined(separator: "\n")
    }

    public static func validateRequiredLabels(in report: String) throws {
        let required = [rawLabel, pipelineLabel]
        for label in required where !report.contains(label) {
            throw BenchmarkReportError.missingRequiredLabel(label)
        }
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.4f", value)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f%%", value * 100)
    }
}
