import AppKit
import Foundation
@testable import Steno
import StenoKit

/// Supplies test-owned storage and explicit system boundaries while exercising the real controller.
@MainActor
func makeTestDictationController(
    hotkey: any HotkeyService,
    overlay: WaveformOverlayPresenter = WaveformOverlayPresenter(observeAccessibilityChanges: false),
    mediaInterruption: MediaInterruptionService = IsolatedTestMediaService(),
    preferencesStore: AppPreferencesStore? = nil,
    coordinator: (any DictationSessionCoordinating)? = nil,
    runtimeRebuildOverride: (@MainActor () async -> (any DictationSessionCoordinating)?)? = nil,
    overlayDismissDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) },
    overlayDismissAction: (@MainActor @Sendable () -> Void)? = nil,
    historyStore: HistoryStore? = nil,
    usageAnalyticsStore: (any UsageAnalyticsStoreServicing)? = nil,
    legacyHistoryURL: URL? = nil,
    workspaceNotificationCenter: NotificationCenter? = nil
) -> DictationController {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoControllerTests-\(UUID().uuidString)", isDirectory: true)
    let clipboard = MemoryClipboardService()
    return DictationController(
        hotkey: hotkey,
        clipboardService: clipboard,
        overlay: overlay,
        mediaInterruption: mediaInterruption,
        preferencesStore: preferencesStore ?? AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
        coordinator: coordinator,
        runtimeRebuildOverride: runtimeRebuildOverride ?? { nil },
        overlayDismissDelay: overlayDismissDelay,
        overlayDismissAction: overlayDismissAction,
        historyStore: historyStore ?? HistoryStore(storageURL: directory.appendingPathComponent("history.json"), clipboardService: clipboard),
        usageAnalyticsStore: usageAnalyticsStore ?? UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
        legacyHistoryURL: legacyHistoryURL ?? directory.appendingPathComponent("legacy.json"),
        systemIntegrationsEnabled: false,
        appContextProvider: {
            AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor", inputFieldDescription: "Fixture document")
        },
        targetDisplayPointProvider: { CGPoint(x: 400, y: 300) },
        workspaceNotificationCenter: workspaceNotificationCenter
    )
}

@MainActor
final class IsolatedTestMediaService: MediaInterruptionService {
    func beginInterruption() async -> MediaInterruptionToken? { nil }
    func endInterruption(token: MediaInterruptionToken) async {}
}
