import Testing
@testable import StenoBenchmarkCLI

@Test("CLI parser preserves repeatable extra args that start with dashes")
func parseCommandLinePreservesDashedExtraArgs() throws {
    let command = try StenoBenchmarkCLI.parseCommandLine([
        "run-all",
        "--manifest", "manifest.json",
        "--raw-output", "raw.json",
        "--pipeline-output", "pipeline.json",
        "--mac-sanity", "mac.json",
        "--report-output", "report.md",
        "--whisper-cli", "/tmp/whisper-cli",
        "--model", "/tmp/model.bin",
        "--extra-arg", "--vad",
        "--extra-arg", "--vad-model",
        "--extra-arg", "/tmp/vad.bin",
        "--threads", "8",
    ])

    #expect(command.values("extra-arg") == ["--vad", "--vad-model", "/tmp/vad.bin"])
    #expect(command.optional("threads") == "8")
}

@Test("CLI parser accepts the matched retained-runtime benchmark contract")
func parseMatchedWarmRuntimeBenchmarkCommand() throws {
    let command = try StenoBenchmarkCLI.parseCommandLine([
        "compare-retained",
        "--manifest", "manifest.json",
        "--output", "warm-runtime.json",
        "--whisper-cli", "/tmp/whisper-cli",
        "--helper", "/tmp/steno-whisper-runtime",
        "--model", "/tmp/large-v3-turbo.bin",
        "--vad-model", "/tmp/silero.bin",
        "--threads", "6",
        "--language", "en",
        "--iterations", "100",
        "--resource-checkpoint-interval", "25",
        "--repeatability-iterations", "20",
        "--beam-size", "5",
        "--best-of", "5",
        "--suppress-nst",
        "--idle-sample-seconds", "2",
    ])

    #expect(command.name == "compare-retained")
    #expect(command.optional("helper") == "/tmp/steno-whisper-runtime")
    #expect(command.optional("iterations") == "100")
    #expect(command.optional("resource-checkpoint-interval") == "25")
    #expect(command.optional("repeatability-iterations") == "20")
    #expect(command.optional("suppress-nst") == "true")
    #expect(command.optional("idle-sample-seconds") == "2")
}

@Test("CLI parser accepts fail-closed live-context validator identity bindings")
func parseLiveContextValidationCommand() throws {
    let command = try StenoBenchmarkCLI.parseCommandLine([
        "validate-live-context",
        "--artifact", "live-context.json",
        "--corpus", "continuation-corpus.json",
        "--expected-git-sha", String(repeating: "a", count: 40),
        "--expected-manifest-sha256", String(repeating: "b", count: 64),
        "--expected-model-sha256", String(repeating: "c", count: 64),
        "--expected-runtime-sha256", String(repeating: "d", count: 64),
        "--expected-hosted-receipt-sha256", String(repeating: "e", count: 64),
        "--expected-adversarial-receipt-sha256", String(repeating: "f", count: 64),
        "--expected-audio-fixture-sha256", String(repeating: "1", count: 64),
        "--expected-hosted-source-manifest-sha256", String(repeating: "2", count: 64),
        "--expected-helper-source-sha256", String(repeating: "3", count: 64),
        "--expected-adversarial-harness-sha256", String(repeating: "4", count: 64),
        "--expected-language", "en",
        "--expected-corpus-row-count", "42",
        "--expected-thread-count", "8",
        "--max-age-seconds", "3600",
    ])

    #expect(command.name == "validate-live-context")
    #expect(command.optional("artifact") == "live-context.json")
    #expect(command.optional("expected-model-sha256") == String(repeating: "c", count: 64))
    #expect(command.optional("expected-corpus-row-count") == "42")
    #expect(command.optional("expected-thread-count") == "8")
    #expect(command.optional("max-age-seconds") == "3600")
}

@Test("CLI parser accepts the reproducible public-fixture live-context run")
func parseLiveContextRunCommand() throws {
    let command = try StenoBenchmarkCLI.parseCommandLine([
        "run-live-context",
        "--corpus", "research/benchmarks/live-context-corpus.json",
        "--audio-fixture", "vendor/whisper.cpp/samples/jfk.wav",
        "--public-audio-fixture",
        "--helper", "runtime-helper/steno-whisper-runtime",
        "--whisper-cli", "vendor/whisper.cpp/build/bin/whisper-cli",
        "--model", "vendor/whisper.cpp/models/ggml-large-v3-turbo.bin",
        "--vad-model", "vendor/whisper.cpp/models/ggml-silero-v6.2.0.bin",
        "--source-root", ".",
        "--hosted-receipt", "research/benchmarks/results/live-context-hosted-receipt.json",
        "--adversarial-receipt", "research/benchmarks/results/live-context-helper-receipt.json",
        "--rss-ceiling-bytes", "2147483648",
        "--output", "research/benchmarks/results/live-context.json",
    ])

    #expect(command.name == "run-live-context")
    #expect(command.optional("public-audio-fixture") == "true")
    #expect(command.optional("audio-fixture") == "vendor/whisper.cpp/samples/jfk.wav")
    #expect(command.optional("rss-ceiling-bytes") == "2147483648")
    #expect(command.optional("hosted-receipt") == "research/benchmarks/results/live-context-hosted-receipt.json")
}
