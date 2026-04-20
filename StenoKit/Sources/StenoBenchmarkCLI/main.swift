import Foundation
import StenoBenchmarkCore
import StenoKit

enum CLIError: Error, LocalizedError {
    case usage(String)
    case missingArgument(String)
    case invalidValue(argument: String, value: String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .missingArgument(let name):
            return "Missing required argument: --\(name)"
        case .invalidValue(let argument, let value):
            return "Invalid value for --\(argument): \(value)"
        }
    }
}

struct ParsedCommand {
    let name: String
    let options: [String: [String]]

    func required(_ key: String) throws -> String {
        guard let value = options[key]?.first, !value.isEmpty else {
            throw CLIError.missingArgument(key)
        }
        return value
    }

    func optional(_ key: String) -> String? {
        options[key]?.first
    }

    func values(_ key: String) -> [String] {
        options[key] ?? []
    }
}

@main
enum StenoBenchmarkCLI {
    static func main() async {
        do {
            let parsed = try parseCommandLine(Array(CommandLine.arguments.dropFirst()))
            try await run(parsed)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ command: ParsedCommand) async throws {
        switch command.name {
        case "run-raw":
            try await runRaw(command)
        case "run-pipeline":
            try await runPipeline(command)
        case "write-mac-sanity-template":
            try writeMacSanityTemplate(command)
        case "generate-report":
            try generateReport(command)
        case "validate-report":
            try validateReport(command)
        case "validate-pipeline":
            try validatePipeline(command)
        case "run-all":
            try await runAll(command)
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.usage(helpText())
        }
    }

    private static func runRaw(_ command: ParsedCommand) async throws {
        let manifestPath = try command.required("manifest")
        let outputPath = try command.required("output")
        let whisperCLIPath = try command.required("whisper-cli")
        let modelPath = try command.required("model")
        let defaultLanguage = command.optional("default-language")
        var extraArguments = command.values("extra-arg")

        if let threadsText = command.optional("threads") {
            guard let threads = Int(threadsText), threads > 0 else {
                throw CLIError.invalidValue(argument: "threads", value: threadsText)
            }
            extraArguments.append(contentsOf: ["-t", "\(threads)"])
        }

        let manifest = try BenchmarkIO.loadManifest(at: manifestPath)
        let rawOutput = await BenchmarkRunner.runRaw(
            manifest: manifest,
            configuration: RawRunConfiguration(
                manifestPath: manifestPath,
                whisperConfiguration: BenchmarkWhisperConfiguration(
                    whisperCLIPath: whisperCLIPath,
                    modelPath: modelPath,
                    additionalArguments: extraArguments
                ),
                defaultLanguageHint: defaultLanguage
            )
        )

        try BenchmarkIO.saveRawOutput(rawOutput, to: outputPath)
        print(
            "Raw benchmark saved to \(outputPath) — samples=\(rawOutput.summary.totalSamples), failureRate=\(formatPercent(rawOutput.summary.failureRate)), WER=\(formatDecimal(rawOutput.summary.wer))"
        )
    }

    private static func runPipeline(_ command: ParsedCommand) async throws {
        let manifestPath = try command.required("manifest")
        let rawPath = try command.required("raw")
        let outputPath = try command.required("output")
        let profile = try parseProfile(command)
        let lexicon = try parseLexicon(command)
        let latencyIterations = try parseOptionalInt(
            command.optional("latency-iterations"),
            argument: "latency-iterations"
        ) ?? 1

        let manifest = try BenchmarkIO.loadManifest(at: manifestPath)
        let rawOutput = try BenchmarkIO.loadRawOutput(at: rawPath)

        let pipelineOutput = await BenchmarkRunner.runPipeline(
            manifest: manifest,
            rawOutput: rawOutput,
            configuration: PipelineRunConfiguration(
                profile: profile,
                lexicon: lexicon,
                manifestPath: manifestPath,
                latencyIterations: latencyIterations
            )
        )
        try BenchmarkIO.savePipelineOutput(pipelineOutput, to: outputPath)
        print(
            "Pipeline benchmark saved to \(outputPath) — rawWER=\(formatDecimal(pipelineOutput.summary.rawWER)), cleanedWER=\(formatDecimal(pipelineOutput.summary.cleanedWER)), delta=\(formatDecimal(pipelineOutput.summary.werDelta))"
        )
    }

    private static func writeMacSanityTemplate(_ command: ParsedCommand) throws {
        let outputPath = try command.required("output")
        let checklist = BenchmarkRunner.defaultMacSanityChecklist()
        try BenchmarkIO.saveMacSanityChecklist(checklist, to: outputPath)
        print("Mac sanity template written to \(outputPath)")
    }

    private static func generateReport(_ command: ParsedCommand) throws {
        let manifestPath = try command.required("manifest")
        let rawPath = try command.required("raw")
        let pipelinePath = try command.required("pipeline")
        let macPath = try command.required("mac-sanity")
        let outputPath = try command.required("output")

        let manifest = try BenchmarkIO.loadManifest(at: manifestPath)
        let raw = try BenchmarkIO.loadRawOutput(at: rawPath)
        let pipeline = try BenchmarkIO.loadPipelineOutput(at: pipelinePath)
        let macSanity = try BenchmarkIO.loadMacSanityChecklist(at: macPath)

        let report = BenchmarkReportRenderer.render(
            manifest: manifest,
            raw: raw,
            pipeline: pipeline,
            macSanity: macSanity
        )
        try BenchmarkReportRenderer.validateRequiredLabels(in: report)
        try BenchmarkIO.saveReport(report, to: outputPath)
        print("Report written to \(outputPath)")
    }

    private static func validateReport(_ command: ParsedCommand) throws {
        let reportPath = try command.required("report")
        let report = try String(contentsOfFile: reportPath, encoding: .utf8)
        try BenchmarkReportRenderer.validateRequiredLabels(in: report)
        print("Report labels validated successfully for \(reportPath)")
    }

    private static func validatePipeline(_ command: ParsedCommand) throws {
        let pipelinePath = try command.required("pipeline")

        let maxWERDeltaText = command.optional("max-wer-delta") ?? "0"
        guard let maxWERDelta = Double(maxWERDeltaText) else {
            throw CLIError.invalidValue(argument: "max-wer-delta", value: maxWERDeltaText)
        }

        let maxCERDeltaText = command.optional("max-cer-delta") ?? "0"
        guard let maxCERDelta = Double(maxCERDeltaText) else {
            throw CLIError.invalidValue(argument: "max-cer-delta", value: maxCERDeltaText)
        }

        let maxRegressedText = command.optional("max-regressed-samples") ?? "0"
        guard let maxRegressed = Int(maxRegressedText), maxRegressed >= 0 else {
            throw CLIError.invalidValue(argument: "max-regressed-samples", value: maxRegressedText)
        }

        let minTermRecallAccuracy = try parseOptionalDouble(
            command.optional("min-term-recall-accuracy"),
            argument: "min-term-recall-accuracy"
        )
        let minRepairResolutionRate = try parseOptionalDouble(
            command.optional("min-repair-resolution-rate"),
            argument: "min-repair-resolution-rate"
        )
        let maxUnintendedRewriteRate = try parseOptionalDouble(
            command.optional("max-unintended-rewrite-rate"),
            argument: "max-unintended-rewrite-rate"
        )
        let minLiteralRepairPhrasePreservationRate = try parseOptionalDouble(
            command.optional("min-literal-repair-phrase-preservation-rate"),
            argument: "min-literal-repair-phrase-preservation-rate"
        )
        let maxPunctuationArtifactRate = try parseOptionalDouble(
            command.optional("max-punctuation-artifact-rate"),
            argument: "max-punctuation-artifact-rate"
        )
        let minCommandPassthroughAccuracy = try parseOptionalDouble(
            command.optional("min-command-passthrough-accuracy"),
            argument: "min-command-passthrough-accuracy"
        )
        let maxNoSpeechFalseInsertRate = try parseOptionalDouble(
            command.optional("max-no-speech-false-insert-rate"),
            argument: "max-no-speech-false-insert-rate"
        )
        let baselineP90LatencyMS = try parseOptionalDouble(
            command.optional("baseline-p90-latency-ms"),
            argument: "baseline-p90-latency-ms"
        )
        let maxP90RegressionRatio = try parseOptionalDouble(
            command.optional("max-p90-regression-ratio"),
            argument: "max-p90-regression-ratio"
        )
        let maxP90LatencyMS = try parseOptionalDouble(
            command.optional("max-p90-latency-ms"),
            argument: "max-p90-latency-ms"
        )
        let maxP99LatencyMS = try parseOptionalDouble(
            command.optional("max-p99-latency-ms"),
            argument: "max-p99-latency-ms"
        )

        let pipeline = try BenchmarkIO.loadPipelineOutput(at: pipelinePath)
        let thresholds = PipelineValidationThresholds(
            maxWERDelta: maxWERDelta,
            maxCERDelta: maxCERDelta,
            maxRegressedSamples: maxRegressed,
            minTermRecallAccuracy: minTermRecallAccuracy,
            minRepairResolutionRate: minRepairResolutionRate,
            maxUnintendedRewriteRate: maxUnintendedRewriteRate,
            minLiteralRepairPhrasePreservationRate: minLiteralRepairPhrasePreservationRate,
            maxPunctuationArtifactRate: maxPunctuationArtifactRate,
            minCommandPassthroughAccuracy: minCommandPassthroughAccuracy,
            maxNoSpeechFalseInsertRate: maxNoSpeechFalseInsertRate,
            baselineP90LatencyMS: baselineP90LatencyMS,
            maxP90RegressionRatio: maxP90RegressionRatio,
            maxP90LatencyMS: maxP90LatencyMS,
            maxP99LatencyMS: maxP99LatencyMS
        )
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)

        print(
            "Pipeline validation passed for \(pipelinePath) with thresholds: maxWERDelta=\(formatDecimal(maxWERDelta)), maxCERDelta=\(formatDecimal(maxCERDelta)), maxRegressedSamples=\(maxRegressed)"
        )
    }

    private static func runAll(_ command: ParsedCommand) async throws {
        let manifestPath = try command.required("manifest")
        let rawOutputPath = try command.required("raw-output")
        let pipelineOutputPath = try command.required("pipeline-output")
        let macSanityPath = try command.required("mac-sanity")
        let reportOutputPath = try command.required("report-output")
        let whisperCLIPath = try command.required("whisper-cli")
        let modelPath = try command.required("model")

        let defaultLanguage = command.optional("default-language")
        var extraArguments = command.values("extra-arg")
        if let threadsText = command.optional("threads") {
            guard let threads = Int(threadsText), threads > 0 else {
                throw CLIError.invalidValue(argument: "threads", value: threadsText)
            }
            extraArguments.append(contentsOf: ["-t", "\(threads)"])
        }

        let manifest = try BenchmarkIO.loadManifest(at: manifestPath)
        let rawOutput = await BenchmarkRunner.runRaw(
            manifest: manifest,
            configuration: RawRunConfiguration(
                manifestPath: manifestPath,
                whisperConfiguration: BenchmarkWhisperConfiguration(
                    whisperCLIPath: whisperCLIPath,
                    modelPath: modelPath,
                    additionalArguments: extraArguments
                ),
                defaultLanguageHint: defaultLanguage
            )
        )
        try BenchmarkIO.saveRawOutput(rawOutput, to: rawOutputPath)

        let profile = try parseProfile(command)
        let lexicon = try parseLexicon(command)
        let latencyIterations = try parseOptionalInt(
            command.optional("latency-iterations"),
            argument: "latency-iterations"
        ) ?? 1
        let pipelineOutput = await BenchmarkRunner.runPipeline(
            manifest: manifest,
            rawOutput: rawOutput,
            configuration: PipelineRunConfiguration(
                profile: profile,
                lexicon: lexicon,
                manifestPath: manifestPath,
                latencyIterations: latencyIterations
            )
        )
        try BenchmarkIO.savePipelineOutput(pipelineOutput, to: pipelineOutputPath)

        let macSanity: MacSanityChecklist
        if FileManager.default.fileExists(atPath: macSanityPath) {
            macSanity = try BenchmarkIO.loadMacSanityChecklist(at: macSanityPath)
        } else {
            macSanity = BenchmarkRunner.defaultMacSanityChecklist()
            try BenchmarkIO.saveMacSanityChecklist(macSanity, to: macSanityPath)
        }

        let report = BenchmarkReportRenderer.render(
            manifest: manifest,
            raw: rawOutput,
            pipeline: pipelineOutput,
            macSanity: macSanity
        )
        try BenchmarkReportRenderer.validateRequiredLabels(in: report)
        try BenchmarkIO.saveReport(report, to: reportOutputPath)

        print("Run complete.")
        print("- Raw results: \(rawOutputPath)")
        print("- Pipeline results: \(pipelineOutputPath)")
        print("- Mac sanity: \(macSanityPath)")
        print("- Report: \(reportOutputPath)")
    }

    private static func parseProfile(_ command: ParsedCommand) throws -> StyleProfile {
        let profileName = command.optional("profile-name") ?? "benchmark-local"
        let tone = try parseEnum(
            command.optional("tone") ?? StyleTone.natural.rawValue,
            argument: "tone",
            as: StyleTone.self
        )
        let structureMode = try parseEnum(
            command.optional("structure-mode") ?? StructureMode.natural.rawValue,
            argument: "structure-mode",
            as: StructureMode.self
        )
        let fillerPolicy = try parseEnum(
            command.optional("filler-policy") ?? FillerPolicy.balanced.rawValue,
            argument: "filler-policy",
            as: FillerPolicy.self
        )
        let commandPolicy = try parseEnum(
            command.optional("command-policy") ?? CommandPolicy.passthrough.rawValue,
            argument: "command-policy",
            as: CommandPolicy.self
        )

        return StyleProfile(
            name: profileName,
            tone: tone,
            structureMode: structureMode,
            fillerPolicy: fillerPolicy,
            commandPolicy: commandPolicy
        )
    }

    private static func parseLexicon(_ command: ParsedCommand) throws -> PersonalLexicon {
        guard let path = command.optional("lexicon") else {
            return PersonalLexicon(entries: [])
        }
        let file = try BenchmarkIO.loadLexiconFile(at: path)
        return PersonalLexicon(entries: file.entries.map(\.stenoEntry))
    }

    private static func parseEnum<Value: RawRepresentable>(
        _ raw: String,
        argument: String,
        as type: Value.Type
    ) throws -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: raw) else {
            throw CLIError.invalidValue(argument: argument, value: raw)
        }
        return value
    }

    private static func parseOptionalDouble(_ raw: String?, argument: String) throws -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let value = Double(raw) else {
            throw CLIError.invalidValue(argument: argument, value: raw)
        }
        return value
    }

    private static func parseOptionalInt(_ raw: String?, argument: String) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw CLIError.invalidValue(argument: argument, value: raw)
        }
        return value
    }

    static func parseCommandLine(_ args: [String]) throws -> ParsedCommand {
        guard let command = args.first else {
            throw CLIError.usage(helpText())
        }

        var options: [String: [String]] = [:]
        let allowsDashedValue: Set<String> = ["extra-arg"]
        var index = 1
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw CLIError.usage("Unexpected token: \(token)\n\n\(helpText())")
            }
            let key = String(token.dropFirst(2))
            if index + 1 < args.count,
               (!args[index + 1].hasPrefix("--") || allowsDashedValue.contains(key)) {
                options[key, default: []].append(args[index + 1])
                index += 2
            } else {
                options[key, default: []].append("true")
                index += 1
            }
        }

        return ParsedCommand(name: command, options: options)
    }

    private static func helpText() -> String {
        """
        StenoBenchmarkCLI

        Commands:
          run-raw
            --manifest <path>
            --output <path>
            --whisper-cli <path>
            --model <path>
            [--threads <int>]
            [--extra-arg <arg>] (repeatable)
            [--default-language <code>]

          run-pipeline
            --manifest <path>
            --raw <path>
            --output <path>
            [--latency-iterations <int>]
            [--lexicon <path>]
            [--profile-name <name>]
            [--tone natural|professional|concise|friendly|technical]
            [--structure-mode natural|paragraph|bullets|email|command]
            [--filler-policy minimal|balanced|aggressive]
            [--command-policy passthrough|transform]

          write-mac-sanity-template
            --output <path>

          generate-report
            --manifest <path>
            --raw <path>
            --pipeline <path>
            --mac-sanity <path>
            --output <path>

          validate-report
            --report <path>

          validate-pipeline
            --pipeline <path>
            [--max-wer-delta <double>] (default: 0)
            [--max-cer-delta <double>] (default: 0)
            [--max-regressed-samples <int>] (default: 0)
            [--min-term-recall-accuracy <double>]
            [--min-repair-resolution-rate <double>]
            [--max-unintended-rewrite-rate <double>]
            [--min-literal-repair-phrase-preservation-rate <double>]
            [--max-punctuation-artifact-rate <double>]
            [--min-command-passthrough-accuracy <double>]
            [--max-no-speech-false-insert-rate <double>]
            [--baseline-p90-latency-ms <double>]
            [--max-p90-regression-ratio <double>]
            [--max-p90-latency-ms <double>]
            [--max-p99-latency-ms <double>]

          run-all
            --manifest <path>
            --raw-output <path>
            --pipeline-output <path>
            --mac-sanity <path>
            --report-output <path>
            --whisper-cli <path>
            --model <path>
            [--threads <int>]
            [--extra-arg <arg>] (repeatable)
            [--default-language <code>]
            [--latency-iterations <int>]
            [--lexicon <path>]
            [--profile-name <name>]
            [--tone natural|professional|concise|friendly|technical]
            [--structure-mode natural|paragraph|bullets|email|command]
            [--filler-policy minimal|balanced|aggressive]
            [--command-policy passthrough|transform]
        """
    }

    private static func printHelp() {
        print(helpText())
    }

    private static func formatDecimal(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.4f", value)
    }

    private static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f%%", value * 100)
    }
}
