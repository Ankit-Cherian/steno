import AppKit
import StenoKit
import SwiftUI

enum StenoTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case history = "History"
    case insights = "Insights"

    var id: String { rawValue }
    var title: String { rawValue }

    var shortcut: KeyEquivalent {
        switch self {
        case .today: "1"
        case .history: "2"
        case .insights: "3"
        }
    }
}

/// Main window sizes. History needs its list plus the page's fixed measure, so the minimum
/// is wider than 1.0's 940 pt (decision recorded in the design record: raise to 960 pt).
enum MainWindowMetrics {
    static let minWidth: CGFloat = 960
    static let minHeight: CGFloat = 640
    static let idealWidth: CGFloat = 1120
    static let idealHeight: CGFloat = 760
    static let toolbarHeight: CGFloat = 52
}

// MARK: - Commands

struct SelectedStenoTabKey: FocusedValueKey {
    typealias Value = Binding<StenoTab>
}

extension FocusedValues {
    var selectedStenoTab: Binding<StenoTab>? {
        get { self[SelectedStenoTabKey.self] }
        set { self[SelectedStenoTabKey.self] = newValue }
    }
}

/// Today, History and Insights in the View menu with ⌘1–3. Install on the main window scene:
/// `.commands { StenoWindowCommands() }`.
struct StenoWindowCommands: Commands {
    @FocusedBinding(\.selectedStenoTab) private var tab

    init() {
        StenoWindowCommandsInstallation.isInstalled = true
    }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(StenoTab.allCases) { item in
                Button(item.title) { tab = item }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(tab == nil)
            }
            Divider()
        }
    }
}

/// Until the scene installs `StenoWindowCommands`, the window keeps ⌘1–3 itself.
@MainActor
enum StenoWindowCommandsInstallation {
    nonisolated(unsafe) static var isInstalled = false
}

// MARK: - Toolbar pieces

/// The three sections as a native segmented control.
struct SectionPicker: View {
    @Binding var selection: StenoTab

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(StenoTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Today, History and Insights (⌘1, ⌘2, ⌘3)")
        .accessibilityLabel("Section")
    }
}

/// The status pill, with a live elapsed time while listening.
struct WindowStatusPill: View {
    let inputs: WindowStatusInputs
    let onTodayTab: Bool
    var action: ((QuillStatusPillState) -> Void)?

    var body: some View {
        if inputs.isRecording, let start = inputs.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                pill(QuillStatusPillState.derive(inputs, now: context.date))
            }
        } else {
            pill(QuillStatusPillState.derive(inputs))
        }
    }

    @ViewBuilder
    private func pill(_ state: QuillStatusPillState) -> some View {
        // Where the pill is not wanted it stays in the toolbar, clear and inert, instead of being
        // removed: adding and removing an item makes the toolbar lay itself out again, which was
        // most of the time a section switch took.
        let shown = state.isShown(onToday: onTodayTab)
        StatusPill(state: state, action: state.settingsSection == nil ? nil : { action?(state) })
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// The gear: Settings… (⌘,).
struct SettingsToolbarButton: View {
    @Environment(\.quillTheme) private var theme

    var body: some View {
        Button { SettingsRouter.shared.open() } label: {
            Image(systemName: "gearshape")
        }
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }
}

extension EnvironmentValues {
    /// Render tests draw the toolbar inside the content, because an offscreen hosting view
    /// has no window toolbar. The app never sets this.
    @Entry var drawsWindowChromeInline = false
}

/// The toolbar row as the window draws it, for render tests only.
struct InlineWindowChrome: View {
    @Binding var tab: StenoTab
    let inputs: WindowStatusInputs
    @Environment(\.quillTheme) private var theme

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                }
                Spacer()
                WindowStatusPill(inputs: inputs, onTodayTab: tab == .today)
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 30, height: 28)
            }
            SectionPicker(selection: $tab)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: MainWindowMetrics.toolbarHeight)
        .accessibilityHidden(true)
    }
}

/// The model's display name for a model file path, such as "Small".
enum SpeechModelNames {
    static func title(forPath path: String) -> String? {
        let file = URL(fileURLWithPath: path).lastPathComponent
        let ids: [WhisperModelID] = [.baseEn, .smallEn, .mediumEn, .largeV3Turbo]
        return ids.first { WhisperModelCatalog.fileName(for: $0) == file }.map(WhisperModelCatalog.title(for:))
    }
}
