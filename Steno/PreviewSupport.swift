#if DEBUG
import AppKit
import SwiftUI
import StenoKit

/// An opt-in interface preview. All displayed text and storage belong to this fixture.
@MainActor
enum IsolatedAppPreview {
    static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// The preview's window titles, so it is never mistaken for the real Steno.
    static let windowTitle = "Steno Preview (test data)"
    static let settingsWindowTitle = "Steno Preview Settings (test data)"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--isolated-ui-preview")
            || Bundle.main.object(forInfoDictionaryKey: "StenoIsolatedReview") as? Bool == true
    }

    static func makeController(
        populated: Bool = true,
        storageDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPreview-\(UUID().uuidString)", isDirectory: true)
    ) -> DictationController {
        let clipboard = MemoryClipboardService()
        let controller = DictationController(
            hotkey: PreviewHotkeyService(),
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: PreviewMediaInterruptionService(),
            preferencesStore: AppPreferencesStore(storageURL: storageDirectory.appendingPathComponent("preferences.json")),
            historyStore: HistoryStore(storageURL: storageDirectory.appendingPathComponent("history.json")),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: storageDirectory.appendingPathComponent("usage.json")),
            legacyHistoryURL: storageDirectory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            isIsolatedPreview: true
        )
        controller.preferences.appearance.accent = .dodger
        controller.preferences.general.showOnboarding = false
        controller.preferences.general.launchAtLoginEnabled = false
        controller.preferences.dictation.whisperCLIPath = "/preview/whisper-cli"
        controller.preferences.dictation.modelPath = "/preview/ggml-small.en.bin"
        controller.preferences.dictation.vadModelPath = "/preview/ggml-silero-v6.2.0.bin"
        controller.hasBootstrapped = true
        controller.status = "Ready"
        controller.microphonePermissionStatus = .granted
        controller.accessibilityPermissionStatus = .granted
        controller.inputMonitoringPermissionStatus = .granted
        if populated {
            controller.recentEntries = entries
            controller.lastTranscript = entries[0].cleanText
            let now = Date()
            let events = (0..<42).map { index in
                UsageEvent(id: UUID(), createdAt: now.addingTimeInterval(-Double(index / 6) * 86_400),
                    appBundleID: index.isMultiple(of: 3) ? "com.example.preview-editor" : "com.example.preview-notes",
                    rawWordCount: 24 + index, finalWordCount: 24 + index,
                    durationMS: 18_000 + index * 200, durationQuality: .captureExact,
                    cleanupChanges: UsageCleanupBreakdown(punctuationChanges: index % 3),
                    cleanupQuality: .exact, insertionStatus: .inserted)
            }
            controller.usageAnalyticsSnapshot = UsageAnalyticsCalculator.snapshot(events: events,
                coverage: [UsageCoverageInterval(start: now.addingTimeInterval(-30 * 86_400), end: nil)], now: now)
        }
        return controller
    }

    static var entries: [TranscriptEntry] {
        let samples: [(String, InsertionStatus)] = [
            ("Move the planning meeting from Thursday to Friday. Send the updated agenda before lunch so everyone has time to read it.", .inserted),
            ("Pick up tomatoes, pasta, olive oil, and a loaf of bread. Check whether we need coffee before leaving.", .copiedOnly),
            (String(repeating: "Take the path along the river, turn left at the bridge, and meet outside the cafe after the walk. ", count: 12), .inserted),
            ("Book a table for four near the window, and ask whether there is space for a stroller.", .failed)
        ]
        return samples.enumerated().map { index, sample in
            TranscriptEntry(createdAt: Date().addingTimeInterval(-Double(index * 3_600)),
                appBundleID: "com.example.preview", rawText: sample.0, cleanText: sample.0,
                durationMS: 12_000 + index * 2_000, audioURL: nil, insertionStatus: sample.1)
        }
    }
}

struct IsolatedReviewControls: View {
    @EnvironmentObject private var controller: DictationController
    @State private var state: ReviewState = .ready
    @StateObject private var overlayReview = OverlayReviewPlayer()

    enum ReviewState: String, CaseIterable {
        case ready = "Populated"
        case recording = "Listening"
        case finishing = "Transcribing"
        case recovery = "Recovery"
        case empty = "Empty"
        case worstCase = "Worst case"
        case one = "One dictation"
        case thousand = "1,000 dictations"
        case onboarding = "Onboarding"
    }

    var body: some View {
        HStack(spacing: 16) {
            Text("Design review · Sample data")
                .font(.system(size: 11, weight: .semibold))
            Text("No microphone or data changes")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Menu("Preview overlay") {
                ForEach(OverlayReviewPlayer.Sample.allCases) { sample in
                    Button(sample.rawValue) {
                        overlayReview.updateAppearance(controller.preferences.appearance)
                        overlayReview.show(sample)
                    }
                }
                Divider()
                Picker("Grove form", selection: $overlayReview.form) {
                    ForEach(OverlayReviewPlayer.Form.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Hide overlay") { overlayReview.stop() }
            }
            .fixedSize()
            .accessibilityIdentifier("isolated-preview-overlay")
            Picker("Review state", selection: $state) {
                ForEach(ReviewState.allCases, id: \.self) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .frame(width: 200)
            .onChange(of: state) { value in stage(value) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
        .accessibilityIdentifier("isolated-preview-banner")
        .onChange(of: controller.preferences.appearance) { appearance in
            overlayReview.updateAppearance(appearance)
        }
        .onAppear {
            // A populated preview shows the window's sample dictations, records and usage.
            if !controller.recentEntries.isEmpty { WindowSampleData.install(on: controller) }
        }
        .onDisappear { overlayReview.stop() }
    }

    private func stage(_ state: ReviewState) {
        Self.stage(state, on: controller)
    }

    /// Puts an isolated preview controller into `state` with the sample data. Never touches
    /// real History, Settings or Insights.
    static func stage(_ state: ReviewState, on controller: DictationController) {
        controller.preferences.general.showOnboarding = state == .onboarding
        controller.stageIsolatedPreviewLifecycle(.idle)
        controller.lastError = ""
        controller.hotkeyRegistrationMessage = ""
        controller.microphonePermissionStatus = .granted
        if state == .empty {
            controller.recentEntries = []
            controller.lastTranscript = ""
            controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(weeks: [])
        } else {
            WindowSampleData.install(on: controller)
        }
        switch state {
        case .worstCase: controller.recentEntries = WindowSampleData.worstCaseEntries()
        case .one: controller.recentEntries = WindowSampleData.oneEntry()
        case .thousand: controller.recentEntries = WindowSampleData.thousandEntries()
        case .recording: controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        case .finishing: controller.stageIsolatedPreviewLifecycle(.transcribing)
        case .recovery:
            controller.lastError = "The editor closed before insertion. Your words are safe in History."
            controller.recentEntries = controller.recentEntries.filter { $0.id == WindowSampleData.bookingID }
        default: break
        }
    }
}

@MainActor
private final class PreviewHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = false
    var globalToggleKeyCode: UInt16?
    func start() {}
    func stop() {}
}

@MainActor
private final class PreviewMediaInterruptionService: MediaInterruptionService {
    func beginInterruption() async -> MediaInterruptionToken? { nil }
    func endInterruption(token: MediaInterruptionToken) async {}
}
#endif
