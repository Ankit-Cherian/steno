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
