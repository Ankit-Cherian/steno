#if DEBUG
import AppKit
import Combine
import Darwin
import os
import StenoKit

/// `--pipeline-benchmark <manifest.json>`, with `--isolated-ui-preview`: times every step from
/// Stop to the result through the real controller, coordinator, retained runtime, cleanup,
/// History and usage ledger, on recorded clips. Debug builds only.
///
/// Nothing here touches the microphone, the user's settings, History or usage files, media, or
/// another app: recording returns a copy of a clip, insertion returns without sending anything,
/// and every store lives in a new temporary folder seeded with 1,000 synthetic dictations plus
/// the worst-case samples.
///
/// Arguments: `--bench-model <ggml model>` `--bench-helper <steno-whisper-runtime>`
/// `--bench-cli <whisper-cli>` and optionally `--bench-vad <vad model>`, `--bench-threads <n>`
/// (6), `--bench-runs <n>` (5), `--bench-out <tsv path>`. Each run steps through every clip once,
/// so clips alternate across runs. Writes one row per dictation and quits.
@MainActor
enum PipelineBenchmark {
    struct Request {
        var manifestURL: URL
        var modelPath: String
        var helperPath: String
        var cliPath: String
        var vadPath: String?
        var threads: Int
        var runs: Int
        var outputURL: URL
        /// Whether the window stays hidden, as when dictating into another app with Steno's
        /// window closed, instead of being brought forward.
        var hidesWindow: Bool
    }

    struct Clip {
        var id: String
        var url: URL
        var durationMS: Int
    }

    static func request(from arguments: [String]) -> Request? {
        guard arguments.contains("--isolated-ui-preview") else { return nil }
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let manifest = value("--pipeline-benchmark"),
              let model = value("--bench-model"),
              let helper = value("--bench-helper"),
              let cli = value("--bench-cli") else { return nil }
        return Request(
            manifestURL: URL(fileURLWithPath: manifest),
            modelPath: model,
            helperPath: helper,
            cliPath: cli,
            vadPath: value("--bench-vad"),
            threads: value("--bench-threads").flatMap(Int.init) ?? 6,
            runs: value("--bench-runs").flatMap(Int.init) ?? 5,
            outputURL: URL(fileURLWithPath: value("--bench-out") ?? NSTemporaryDirectory() + "steno-pipeline-benchmark.tsv"),
            hidesWindow: value("--bench-window") == "hidden"
        )
    }

    static var isRequested: Bool { request(from: ProcessInfo.processInfo.arguments) != nil }

    private static var running: Task<Void, Never>?

    /// The controller the app shows, wired to the benchmark pipeline. Starts the run once the
    /// window is up.
    static func makeController() -> DictationController {
        let request = request(from: ProcessInfo.processInfo.arguments)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPipelineBenchmark-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clipboard = MemoryClipboardService()
        let seeded = WindowSampleData.worstCaseEntries() + WindowSampleData.thousandEntries()
        let historyURL = directory.appendingPathComponent("history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(seeded).write(to: historyURL)
        let history = HistoryStore(storageURL: historyURL)
        let usage = UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json"))
        let capture = BenchmarkCapture(directory: directory)
        let engine = RetainedWhisperTranscriptionEngine(
            configuration: RetainedWhisperTranscriptionConfiguration(
                helperExecutableURL: URL(fileURLWithPath: request.helperPath),
                modelPath: URL(fileURLWithPath: request.modelPath),
                threadCount: request.threads,
                vadModelPath: request.vadPath.map { URL(fileURLWithPath: $0) },
                suppressNonSpeechTokens: true,
                suppressRegex: nil,
                beamSize: 5,
                bestOf: 5
            ),
            fallback: WhisperCLITranscriptionEngine(config: .init(
                whisperCLIPath: URL(fileURLWithPath: request.cliPath),
                modelPath: URL(fileURLWithPath: request.modelPath),
                additionalArguments: WhisperRuntimeConfiguration.additionalArguments(
                    threadCount: request.threads,
                    vadEnabled: request.vadPath != nil,
                    vadModelPath: request.vadPath ?? ""
                ),
                outputDirectory: directory
            )),
            stepObserver: DictationLatency.step
        )
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: engine,
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [BenchmarkInsertion()]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: AppPreferences.default.lexiconEntries),
            styleProfileService: StyleProfileService(
                globalProfile: AppPreferences.default.globalStyleProfile,
                appProfiles: AppPreferences.default.appStyleProfiles
            ),
            snippetService: SnippetService(snippets: AppPreferences.default.snippets),
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            usageRecorder: usage,
            recordSettings: DictationRecordSettings(modelName: "Benchmark", modelID: "benchmark", vadEnabled: request.vadPath != nil),
            editorTargetCapture: { _ in .failure(.unsupportedElement) },
            stepObserver: DictationLatency.step
        )
        let hotkey = BenchmarkHotkey()
        let controller = DictationController(
            hotkey: hotkey,
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: BenchmarkMedia(),
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            coordinator: coordinator,
            runtimeRebuildOverride: { coordinator },
            historyStore: history,
            usageAnalyticsStore: usage,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            appContextProvider: {
                AppContext(bundleIdentifier: "com.example.steno-benchmark-editor", appName: "Benchmark Editor")
            },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) },
            permissionStatusReader: {
                PermissionStatusSnapshot(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)
            },
            isOptionHeld: { true },
            launchConfiguration: LaunchConfiguration(
                storage: StenoStorageRoot(
                    dataDirectory: directory,
                    temporaryDirectory: directory,
                    legacyDataDirectory: directory.appendingPathComponent("legacy", isDirectory: true),
                    migratesLegacyDirectory: false,
                    modelsDirectory: nil
                ),
                managesLaunchAtLogin: false
            )
        )
        controller.preferences.general.showOnboarding = false
        controller.preferences.general.launchAtLoginEnabled = false
        controller.preferences.dictation.modelPath = request.modelPath
        controller.microphonePermissionStatus = .granted
        controller.accessibilityPermissionStatus = .granted
        controller.inputMonitoringPermissionStatus = .granted
        controller.hasBootstrapped = true

        running = Task { @MainActor in
            await run(request: request, controller: controller, engine: engine, coordinator: coordinator,
                      history: history, usage: usage, directory: directory)
        }
        return controller
    }

    private static func loadClips(from manifestURL: URL) throws -> [Clip] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let samples = object?["samples"] as? [[String: Any]] ?? []
        return samples.compactMap { sample in
            guard let id = sample["id"] as? String, let path = sample["audioPath"] as? String else { return nil }
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : manifestURL.deletingLastPathComponent().appendingPathComponent(path)
            return Clip(id: id, url: url, durationMS: sample["audioDurationMS"] as? Int ?? 0)
        }
    }

    private static func run(
        request: Request,
        controller: DictationController,
        engine: RetainedWhisperTranscriptionEngine,
        coordinator: SessionCoordinator,
        history: HistoryStore,
        usage: UsageAnalyticsStore,
        directory: URL
    ) async {
        let events = EventLog()
        DictationLatency.busyThresholdMS = 16
        DictationLatency.watchMainThread()
        DictationLatency.sink.withLock { $0 = { name, at in events.append(name, at) } }
        // Each change the controller publishes invalidates every view that observes it.
        let publishes = controller.objectWillChange.sink { _ in
            events.append("publish", ProcessInfo.processInfo.systemUptime)
        }
        defer { publishes.cancel() }

        let clips: [Clip]
        do {
            clips = try loadClips(from: request.manifestURL)
        } catch {
            finish(output: "error\tmanifest unreadable: \(error.localizedDescription)\n", request: request)
            return
        }

        // Insights reads the usage ledger, so it holds the same dictations as History.
        let seeded = await history.recent(limit: 1_000)
        if let oldest = seeded.last?.createdAt {
            try? await usage.backfill(entries: seeded, coverage: UsageCoverageInterval(start: oldest, end: Date()))
        }
        await controller.refreshHistory()
        await controller.refreshUsageAnalytics()
        try? await Task.sleep(for: .seconds(2))

        // Loads the model and runs one dictation that is not reported.
        try? await engine.prepareRetainedResources()
        if let first = clips.first {
            _ = await dictate(first, controller: controller, events: events, hidesWindow: request.hidesWindow)
        }

        var rows = ["clip\tclip_ms\trun\tstatus\twords\t" + Row.stageNames.joined(separator: "\t")
                    + "\tpublishes_to_result\tpublishes_after_result\twindow_visible\tmain_cpu_ms\tmain_minstr\tmain_over16\tmain_over50\tmain_max_ms\tbusy_stretches\thelper_cpu_ms\thelper_minstr"]
        for run in 1...max(1, request.runs) {
            for clip in clips {
                let helperBefore = helperUsage()
                let row = await dictate(clip, controller: controller, events: events, hidesWindow: request.hidesWindow)
                let helperAfter = helperUsage()
                var line = "\(clip.id)\t\(clip.durationMS)\t\(run)\t\(row.status)\t\(row.words)\t"
                line += Row.stageNames.map { row.stages[$0].map { String(format: "%.1f", $0) } ?? "" }.joined(separator: "\t")
                line += "\t\(row.publishesToResult)\t\(row.publishesAfterResult)\t\(row.windowVisible ? 1 : 0)\t\(row.mainThread)\t\(row.busy.joined(separator: ";"))"
                if let before = helperBefore, let after = helperAfter {
                    line += String(format: "\t%.1f\t%.0f", Double(after.cpuNS &- before.cpuNS) / 1e6, Double(after.instructions &- before.instructions) / 1e6)
                } else {
                    line += "\t\t"
                }
                rows.append(line)
            }
        }
        await coordinator.shutdown()
        await engine.shutdown()
        try? FileManager.default.removeItem(at: directory)
        finish(output: rows.joined(separator: "\n") + "\n", request: request)
    }

    private static func finish(output: String, request: Request) {
        try? output.write(to: request.outputURL, atomically: true, encoding: .utf8)
        DictationLatency.sink.withLock { $0 = nil }
        // The runtime and stores are already shut down; the app's own termination path waits
        // on a reply this task would block.
        exit(0)
    }

    struct Row {
        static let stageNames = [
            "capture closed", "transcription started", "helper requested", "helper replied",
            "artifacts stripped", "transcribed", "cleaned up", "inserted", "history saved",
            "usage recorded", "result shown", "result presented",
        ]
        var status = "timeout"
        var words = 0
        var stages: [String: Double] = [:]
        var mainThread = "\t\t\t\t"
        var busy: [String] = []
        var windowVisible = false
        var publishesToResult = 0
        var publishesAfterResult = 0
    }

    /// One dictation the way Option drives it: down, confirmed after the shortcut delay, held,
    /// released. Returns each step's time after the release, and what the main thread spent
    /// from the release until the window settled.
    private static func dictate(_ clip: Clip, controller: DictationController, events: EventLog, hidesWindow: Bool) async -> Row {
        BenchmarkCapture.nextClip.withLock { $0 = clip.url }
        // Brought forward without activating the app, so no key focus is taken, or hidden. Whether the
        // window was actually visible is recorded, since a covered window does not draw.
        let window = NSApp.windows.first { $0.identifier?.rawValue.contains(SettingsRouter.mainWindowID) == true || $0.title == "Steno" }
        if hidesWindow {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
        controller.pressToTalkStart()
        try? await Task.sleep(for: .milliseconds(150))
        controller.pressToTalkConfirmed()
        try? await Task.sleep(for: .milliseconds(600))

        DictationLatency.tourStep("pipeline: stop to settle")
        events.reset()
        controller.pressToTalkStop()
        var row = Row()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !events.contains("result presented") {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The overlay holds the result for two seconds; History and Insights refresh meanwhile.
        try? await Task.sleep(for: .milliseconds(2_600))
        DictationLatency.tourStep("pipeline: idle")
        row.windowVisible = window?.occlusionState.contains(.visible) == true

        let recorded = events.snapshot()
        if let stop = recorded.first(where: { $0.name == "stop" })?.at {
            for event in recorded where Row.stageNames.contains(event.name) && row.stages[event.name] == nil {
                row.stages[event.name] = (event.at - stop) * 1000
            }
        }
        if let shown = recorded.first(where: { $0.name == "result shown" })?.at {
            let published = recorded.filter { $0.name == "publish" }
            row.publishesToResult = published.filter { $0.at < shown }.count
            row.publishesAfterResult = published.count - row.publishesToResult
        }
        row.busy = recorded.filter { $0.name.hasPrefix("main thread busy") }.map { event in
            event.name.replacingOccurrences(of: "main thread busy ", with: "")
        }
        if let tour = recorded.last(where: { $0.name.hasPrefix("tour total") })?.name {
            let numbers = tour.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Int($0) }
            // "tour total cpu A ms, B Minstr, C over 16, D over 50, max E ms"
            if numbers.count >= 7 {
                row.mainThread = "\(numbers[0])\t\(numbers[1])\t\(numbers[2])\t\(numbers[4])\t\(numbers[6])"
            }
        }
        row.status = recorded.contains(where: { $0.name == "result presented" }) ? controller.status : "timeout"
        row.words = controller.lastTranscript.split(whereSeparator: \.isWhitespace).count
        return row
    }

    /// CPU time and instructions of the retained runtime process, which runs VAD and decoding.
    private static func helperUsage() -> (cpuNS: UInt64, instructions: UInt64)? {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(getpid(), &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard count > 0 else { return nil }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
            return (cpu, info.ri_instructions)
        }
        return nil
    }
}

/// Every mark the benchmark has seen, in order.
private final class EventLog: @unchecked Sendable {
    struct Event { var name: String; var at: TimeInterval }
    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ name: String, _ at: TimeInterval) { lock.withLock { events.append(Event(name: name, at: at)) } }
    func reset() { lock.withLock { events.removeAll() } }
    func contains(_ name: String) -> Bool { lock.withLock { events.contains { $0.name == name } } }
    func snapshot() -> [Event] { lock.withLock { events } }
}

/// Records nothing: each capture returns a fresh copy of the clip the benchmark chose, as the
/// recorder would leave a finished file. The coordinator deletes it after the dictation.
private actor BenchmarkCapture: AudioCaptureService {
    static let nextClip = OSAllocatedUnfairLock<URL?>(initialState: nil)
    let directory: URL
    private var sessions: Set<SessionID> = []

    init(directory: URL) { self.directory = directory }

    func beginCapture(sessionID: SessionID) async throws { sessions.insert(sessionID) }

    func endCapture(sessionID: SessionID) async throws -> URL {
        guard sessions.remove(sessionID) != nil, let clip = Self.nextClip.withLock({ $0 }) else {
            throw CancellationError()
        }
        let copy = directory.appendingPathComponent("steno-audio-\(sessionID.uuidString).wav")
        try FileManager.default.copyItem(at: clip, to: copy)
        return copy
    }

    func cancelCapture(sessionID: SessionID) async { sessions.remove(sessionID) }
}

/// Accepts the text without sending it anywhere.
private struct BenchmarkInsertion: InsertionTransport {
    let method: InsertionMethod = .accessibility
    func insert(text: String, target: AppContext) async throws {}
}

@MainActor
private final class BenchmarkHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var onPressToTalkConfirmed: (() -> Void)?
    var onPressToTalkDiscarded: (() -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?
    var confirmsPressToTalk: Bool { true }
    func start() {}
    func stop() {}
}

/// Never pauses or plays anything.
@MainActor
private final class BenchmarkMedia: MediaInterruptionService {
    func beginInterruption() async -> MediaInterruptionToken? { nil }
    func endInterruption(token: MediaInterruptionToken) async {}
}
#endif
