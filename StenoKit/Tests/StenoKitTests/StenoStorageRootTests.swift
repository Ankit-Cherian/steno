import Foundation
import Testing
@testable import StenoKit

@Suite("Storage root")
struct StenoStorageRootTests {
    @Test("The release root is exactly the released app's folders")
    func releaseRootKeepsReleasedPaths() throws {
        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let root = StenoStorageRoot.release()

        #expect(root.dataDirectory == appSupport.appendingPathComponent("Steno", isDirectory: true))
        #expect(root.preferencesURL.path == appSupport.path + "/Steno/preferences.json")
        #expect(root.historyURL.path == appSupport.path + "/Steno/transcript-history.json")
        #expect(root.usageAnalyticsURL.path == appSupport.path + "/Steno/usage-analytics.json")
        #expect(root.modelsDirectory?.path == appSupport.path + "/Steno/WhisperModels")
        #expect(root.legacyDataDirectory.path == appSupport.path + "/WhisperClone")
        #expect(root.legacyHistoryURL.path == appSupport.path + "/WhisperClone/transcript-history.json")
        #expect(root.temporaryDirectory == FileManager.default.temporaryDirectory)
        let migration = try #require(root.legacyMigration)
        #expect(migration.source.path == appSupport.path + "/WhisperClone")
        #expect(migration.destination.path == appSupport.path + "/Steno")
    }

    @Test("Stores given no location use the release root")
    func storesDefaultToTheReleaseRoot() async {
        let root = StenoStorageRoot.release()
        let history = HistoryStore()
        #expect(history.storageURL == root.historyURL)
        let outsideTests = UsageAnalyticsStore.defaultStorageURL(
            environment: [:],
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: 1
        )
        #expect(outsideTests == root.usageAnalyticsURL)
    }

    @MainActor
    @Test("Every store, capture folder and transcript folder stays inside an injected root")
    func nothingWritesOutsideAnInjectedRoot() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoStorageRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let data = sandbox.appendingPathComponent("Application Support/Steno Acceptance", isDirectory: true)
        let temporary = data.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = StenoStorageRoot(
            dataDirectory: data,
            temporaryDirectory: temporary,
            legacyDataDirectory: data.appendingPathComponent("Legacy", isDirectory: true),
            migratesLegacyDirectory: false,
            modelsDirectory: data.appendingPathComponent("WhisperModels", isDirectory: true)
        )
        #expect(root.legacyMigration == nil)

        // History, with its recovery copies.
        let history = HistoryStore(storageURL: root.historyURL)
        for index in 0..<2 {
            try await history.append(entry: TranscriptEntry(
                appBundleID: "com.example.editor",
                rawText: "note \(index)",
                cleanText: "Note \(index)",
                durationMS: 1_000,
                audioURL: nil,
                insertionStatus: .inserted
            ))
        }
        #expect(history.storageURL == root.historyURL)

        // The Insights ledger and its event segments.
        let usage = UsageAnalyticsStore(storageURL: root.usageAnalyticsURL)
        try await usage.record(event: UsageEvent(
            id: UUID(),
            createdAt: Date(),
            appBundleID: "com.example.editor",
            rawWordCount: 4,
            finalWordCount: 4,
            durationMS: 2_000,
            durationQuality: .captureExact,
            cleanupChanges: .zero,
            cleanupQuality: .exact,
            insertionStatus: .inserted
        ))
        #expect(usage.storageURL == root.usageAnalyticsURL)

        // The backup transcription tool's output files.
        let script = temporary.appendingPathComponent("fake-whisper.sh")
        try """
        #!/bin/sh
        output_base=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then shift; output_base="$1"; fi
          shift
        done
        printf "%s" "$output_base" > "\(temporary.path)/seen-output-base"
        printf "hello there\\n" > "${output_base}.txt"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: script.path)
        let audio = temporary.appendingPathComponent("clip.wav")
        try Data().write(to: audio)
        let engine = WhisperCLITranscriptionEngine(config: .init(
            whisperCLIPath: script,
            modelPath: URL(fileURLWithPath: "/nonexistent/model.bin"),
            outputDirectory: root.temporaryDirectory
        ))
        let transcript = try await engine.transcribe(audioURL: audio, languageHints: ["en-US"])
        #expect(transcript.text == "hello there")
        let outputBase = try String(contentsOf: temporary.appendingPathComponent("seen-output-base"), encoding: .utf8)
        #expect(outputBase.hasPrefix(root.temporaryDirectory.path + "/"))

        // The setup check's clip.
        let clipDirectories = SeenClipDirectory()
        let probe = ClipProbeEngine(clipDirectories)
        _ = await WhisperSetupSelfTest.run(
            .init(
                microphoneAllowed: true,
                modelPath: script.path,
                vadEnabled: false,
                vadModelPath: "",
                mainEngine: nil,
                toolEngine: probe,
                temporaryDirectory: root.temporaryDirectory
            ),
            fileExists: { _ in true }
        )
        let clipDirectory = try #require(clipDirectories.paths.first)
        #expect(clipDirectory.hasPrefix(root.temporaryDirectory.path + "/"))

        // The capture service records into the folder it is given.
        #if os(macOS)
        let capture = MacAudioCaptureService(recordingDirectory: root.temporaryDirectory)
        #expect(capture.recordingDirectory == root.temporaryDirectory)
        #endif

        // Nothing at all exists in the sandbox outside the root.
        let everything = try FileManager.default.subpathsOfDirectory(atPath: sandbox.path)
        var outside: [String] = []
        let rootPrefix = "Application Support/Steno Acceptance"
        for relative in everything {
            let isAncestor = rootPrefix.hasPrefix(relative)
            if !isAncestor && !relative.hasPrefix(rootPrefix) { outside.append(relative) }
        }
        #expect(outside.isEmpty, "\(outside)")
        let written = try FileManager.default.contentsOfDirectory(atPath: data.path)
        #expect(written.contains("transcript-history.json"))
        #expect(written.contains("usage-analytics-events"))
    }
}

private final class SeenClipDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ path: String) { lock.lock(); storage.append(path); lock.unlock() }
}

private struct ClipProbeEngine: TranscriptionEngine {
    let seen: SeenClipDirectory
    init(_ seen: SeenClipDirectory) { self.seen = seen }
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        seen.add(audioURL.deletingLastPathComponent().path)
        return RawTranscript(text: "")
    }
}
