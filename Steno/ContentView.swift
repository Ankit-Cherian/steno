import SwiftUI
import StenoKit

enum StenoTab: String, CaseIterable {
    case record = "Record"
    case history = "History"
    case settings = "Settings"
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var selectedTab: StenoTab = .record
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: StenoDesign.lg) {
                Text("Steno")
                    .font(StenoDesign.heading1())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Picker("Navigation", selection: $selectedTab) {
                    ForEach(StenoTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: StenoDesign.pickerWidth)
                .accessibilityLabel("Tab selection")

                Spacer()

                Button {
                    NSApp.keyWindow?.orderOut(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: StenoDesign.iconMD))
                        .foregroundStyle(StenoDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Hide Window")
                .accessibilityLabel("Hide Window")
            }
            .padding(.horizontal, StenoDesign.lg)
            .padding(.vertical, StenoDesign.md)

            // Divider
            Rectangle()
                .fill(StenoDesign.border)
                .frame(height: StenoDesign.dividerHeight)

            // Tab content
            Group {
                switch selectedTab {
                case .record:
                    RecordTab()
                case .history:
                    HistoryTab()
                case .settings:
                    SettingsView()
                }
            }
            .id(selectedTab)
            .transition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationNormal),
                value: selectedTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, StenoDesign.lg)
            .background(StenoDesign.background)
        }
        .frame(
            minWidth: StenoDesign.windowMinWidth,
            idealWidth: StenoDesign.windowIdealWidth,
            minHeight: StenoDesign.windowMinHeight,
            idealHeight: StenoDesign.windowIdealHeight
        )
        .background(StenoDesign.surface)
        .task {
            await controller.refreshHistory()
        }
        .onAppear {
            NSApp.windows.first?.setFrameAutosaveName("StenoMainWindow")
        }
    }
}
