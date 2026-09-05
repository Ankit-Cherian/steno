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
            historyStore: HistoryStore(storageURL: storageDirectory.appendingPathComponent("history.json"), clipboardService: clipboard),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: storageDirectory.appendingPathComponent("usage.json")),
            legacyHistoryURL: storageDirectory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            isIsolatedPreview: true
        )
        controller.preferences.appearance.accent = switch StenoDesign.direction {
        case .signal: .citron
        case .manuscript: .terracotta
        case .current: .cyan
        }
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
            ("Send the revised agenda on Thursday. Keep the launch date at September 18, and do not change the accessibility review.", .inserted),
            ("The editor closed before insertion. This sample is ready to copy when you return to your document.", .copiedOnly),
            (String(repeating: "A clear thought deserves room to breathe. Names, numbers, and deliberate punctuation should stay exactly as spoken. ", count: 12), .inserted),
            ("Please keep this sentence, even when insertion needs another try.", .failed)
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

    private enum ReviewState: String, CaseIterable {
        case ready = "Populated"
        case recording = "Listening"
        case finishing = "Transcribing"
        case recovery = "Recovery"
        case empty = "Empty"
        case onboarding = "Onboarding"
    }

    var body: some View {
        HStack(spacing: 16) {
            Text("Design review · Sample data")
                .font(.system(size: 11, weight: .semibold))
            Text("Microphone and system actions are disabled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
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
    }

    private func stage(_ state: ReviewState) {
        controller.preferences.general.showOnboarding = state == .onboarding
        controller.stageIsolatedPreviewLifecycle(.idle)
        controller.lastError = ""
        controller.hotkeyRegistrationMessage = ""
        controller.microphonePermissionStatus = .granted
        controller.recentEntries = state == .empty ? [] : IsolatedAppPreview.entries
        controller.lastTranscript = controller.recentEntries.first?.cleanText ?? ""
        let fixture = IsolatedAppPreview.makeController(populated: state != .empty)
        controller.usageAnalyticsSnapshot = fixture.usageAnalyticsSnapshot
        switch state {
        case .recording: controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        case .finishing: controller.stageIsolatedPreviewLifecycle(.transcribing)
        case .recovery:
            controller.lastError = "The editor closed before insertion. Your words are safe in History."
            controller.recentEntries = [IsolatedAppPreview.entries[3]]
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
