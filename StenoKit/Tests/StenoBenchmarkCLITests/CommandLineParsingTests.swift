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
