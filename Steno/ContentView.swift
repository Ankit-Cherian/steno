import AppKit
import SwiftUI
import StenoKit

enum StenoTab: String, CaseIterable {
    case record = "Record"
    case history = "History"
    case settings = "Settings"
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab: StenoTab = .record
    @State private var selectedSettingsSection: SettingsSection = .appearance
    @State private var keyMonitor: Any?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        shell(theme: theme)
        .task {
            await controller.refreshHistory()
        }
        .onAppear {
            installSpacebarMonitor()
        }
        .onDisappear {
            removeSpacebarMonitor()
        }
    }

    private func shell(theme: StenoTheme) -> some View {
        VStack(spacing: 0) {
            titleBar(theme: theme)

            Divider()
                .overlay(theme.line)

            Group {
                switch selectedTab {
                case .record:
                    RecordTab()
                case .history:
                    HistoryTab()
                case .settings:
                    SettingsView(selectedSection: $selectedSettingsSection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shellBackdrop(theme: theme))
            .id(selectedTab)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationNormal), value: selectedTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func titleBar(theme: StenoTheme) -> some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 64, height: 1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Steno")
                    .font(StenoDesign.heroSerif(size: 21))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("v\(appVersion)")
                    .font(StenoDesign.mono(size: 9.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(theme.textMuted.opacity(0.88))
                    .fixedSize()
            }
            .frame(minWidth: 148, alignment: .leading)

            Spacer()

            StenoSegmentedTabBar(selection: $selectedTab, theme: theme)

            Spacer()

            HStack(spacing: 10) {
                HeaderStatusChip(isRecording: controller.isRecording, theme: theme)

                Button {
                    selectedTab = .settings
                    selectedSettingsSection = .appearance
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 28, height: 28)
                        .background(theme.chromeButtonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open Appearance")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: StenoDesign.titleBarHeight)
        .background(titleBarBackground(theme: theme))
    }

    private func titleBarBackground(theme: StenoTheme) -> some View {
        ZStack {
            theme.titleBarGradient

            RadialGradient(
                colors: [theme.chromeAccentWash, .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 320
            )
            .offset(x: 90, y: -90)

            RadialGradient(
                colors: [theme.accent.opacity(theme.isLight ? 0.04 : 0.08), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 220
            )
            .offset(x: -80, y: -120)

            LinearGradient(
                colors: [Color.white.opacity(theme.isLight ? 0.18 : 0.05), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func shellBackdrop(theme: StenoTheme) -> some View {
        ZStack {
            theme.shellGradient

            RadialGradient(
                colors: [theme.accent.opacity(0.18 * theme.spotlightOpacity), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 360
            )

            RadialGradient(
                colors: [theme.stageGlowLeading.opacity(0.18 * theme.spotlightOpacity), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 340
            )
        }
    }

    private func installSpacebarMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard selectedTab == .record, event.keyCode == 49 else {
                return event
            }

            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return event
            }

            controller.toggleHandsFree()
            return nil
        }
    }

    private func removeSpacebarMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}

private struct HeaderStatusChip: View {
    let isRecording: Bool
    let theme: StenoTheme

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isRecording ? theme.accent : theme.textMuted)
                .frame(width: 7, height: 7)
                .shadow(color: isRecording ? theme.accentGlow : .clear, radius: 8)

            Text(isRecording ? "Listening" : "Idle")
                .font(StenoDesign.mono(size: 10, weight: .medium))
                .tracking(0.4)
        }
        .foregroundStyle(theme.textDim)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(isRecording ? theme.accentSoft : Color.white.opacity(theme.isLight ? 0.72 : 0.03))
        .overlay(
            Capsule(style: .continuous)
                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
        )
        .clipShape(Capsule(style: .continuous))
    }
}
