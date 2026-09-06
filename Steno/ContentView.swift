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
    @State private var hoveredTab: StenoTab?
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Steno")
                .font(StenoDesign.display(size: 30))
                .tracking(-0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.top, 22)
                .padding(.bottom, 22)
                .accessibilityHidden(true)
            ForEach(StenoTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    HStack(spacing: 11) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 20)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .foregroundStyle(Color.white.opacity(selectedTab == tab ? 1 : 0.78))
                    .background(Color.white.opacity(selectedTab == tab ? 0.12 : hoveredTab == tab ? 0.06 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredTab = $0 ? tab : nil }
                .keyboardShortcut(tab.shortcut, modifiers: .command)
                .accessibilityIdentifier("nav.\(tab.rawValue.lowercased())")
                .help("\(tab.rawValue) (Command-\(tab.shortcut.character))")
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer(minLength: 24)
            Label("Local transcription", systemImage: "lock")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.65))
                .padding(.horizontal, 12)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 12)
        .frame(width: StenoDesign.navigationWidth)
        .background(Color(red: 0.145, green: 0.212, blue: 0.314))
    }

    private func openSettings(_ section: SettingsSection) {
        selectedSettingsSection = section
        selectedTab = .settings
    }

}
