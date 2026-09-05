import AppKit
import SwiftUI
import StenoKit

enum StenoTab: String, CaseIterable {
    case record = "Dictate"
    case history = "History"
    case insights = "Insights"
    case settings = "Settings"

    var shortcut: KeyEquivalent {
        switch self {
        case .record: return "1"
        case .history: return "2"
        case .insights: return "3"
        case .settings: return ","
        }
    }

    var symbol: String {
        switch self {
        case .record: return "mic"
        case .history: return "text.alignleft"
        case .insights: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: StenoTab
    @State private var selectedSettingsSection: SettingsSection

    init(initialTab: StenoTab = .record, initialSettingsSection: SettingsSection = .recording) {
        _selectedTab = State(initialValue: initialTab)
        _selectedSettingsSection = State(initialValue: initialSettingsSection)
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 64, height: 1)
                Text("Steno").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label(controller.isRecording ? "Listening" : controller.recordingLifecycleState == .transcribing ? "Transcribing" : "On this Mac", systemImage: controller.isRecording ? "record.circle" : "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(controller.isRecording ? theme.accent : theme.textDim)
            }
            .padding(.horizontal, 20)
            .frame(height: StenoDesign.titleBarHeight)
            .background(theme.ink1)

            Divider()
            HStack(spacing: 0) {
                navigation(theme: theme)
                Divider()
                ZStack {
                    if selectedTab != .settings {
                        Group {
                            switch selectedTab {
                            case .record:
                                RecordTab(onOpenSettings: openSettings, onOpenHistory: { selectedTab = .history })
                            case .history: HistoryTab()
                            case .insights: InsightsTab()
                            case .settings: EmptyView()
                            }
                        }
                        .id(selectedTab)
                        .transition(.opacity)
                    }
                    SettingsView(selectedSection: $selectedSettingsSection, showsSidebar: true)
                        .opacity(selectedTab == .settings ? 1 : 0)
                        .allowsHitTesting(selectedTab == .settings)
                        .disabled(selectedTab != .settings)
                        .accessibilityHidden(selectedTab != .settings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(theme.text)
        .background(theme.ink0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selectedTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await controller.refreshHistory() }
    }

    private func navigation(theme: StenoTheme) -> some View {
        let direction = StenoDesign.direction
        let isEditorial = direction == .manuscript
        return VStack(alignment: direction == .signal ? .center : .leading, spacing: direction == .signal ? 12 : 8) {
            Text(direction == .signal ? "st." : "steno.")
                .font(direction == .signal ? .system(size: 32, weight: .heavy) : StenoDesign.display(size: 34))
                .tracking(direction == .signal ? -2 : -1.3)
                .foregroundStyle(isEditorial ? .white : theme.text)
                .padding(.horizontal, direction == .signal ? 0 : 12)
                .padding(.top, 23)
                .padding(.bottom, 19)
                .accessibilityHidden(true)
            ForEach(StenoTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    Group {
                        if direction == .signal {
                            VStack(spacing: 9) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 19, weight: .medium))
                                    .frame(height: 23)
                                Text(tab.rawValue).font(.system(size: 10, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 66)
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(width: 19)
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 44)
                        }
                    }
                    .foregroundStyle(isEditorial ? Color.white.opacity(selectedTab == tab ? 1 : 0.72) : selectedTab == tab ? theme.accentInk : theme.textDim)
                    .background(selectedTab == tab ? isEditorial ? Color.white.opacity(0.12) : theme.accent : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: direction == .current ? 24 : direction == .manuscript ? 5 : 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(tab.shortcut, modifiers: .command)
                .accessibilityIdentifier("nav.\(tab.rawValue.lowercased())")
                .help("\(tab.rawValue) (Command-\(tab.shortcut.character))")
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer(minLength: 24)
            Image(systemName: "lock")
                .font(.system(size: 12))
                .foregroundStyle(isEditorial ? Color.white.opacity(0.6) : theme.textDim)
                .accessibilityLabel("Local transcription")
                .padding(.horizontal, direction == .signal ? 0 : 13)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 12)
        .frame(width: StenoDesign.navigationWidth)
        .background(isEditorial ? Color(red: 0.145, green: 0.212, blue: 0.314) : theme.ink1)
    }

    private func openSettings(_ section: SettingsSection) {
        selectedSettingsSection = section
        selectedTab = .settings
    }

}
