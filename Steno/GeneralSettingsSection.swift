import SwiftUI

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String
    var launchAtLoginNeedsApproval = false
    var onOpenLoginItems: () -> Void = {}
    @EnvironmentObject private var controller: DictationController
    @State private var isConfirmingDeleteAll = false
    @Environment(\.quillTheme) private var theme

    static let releaseNotesURL = URL(string: "https://github.com/Ankit-Cherian/steno/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .general)
            SettingsCard {
                SettingsRow(
                    label: "Open at login",
                    help: "Steno starts quietly in the menu bar.",
                    caution: launchAtLoginWarning.isEmpty ? nil : launchAtLoginWarning
                ) {
                    HStack(spacing: 10) {
                        if launchAtLoginNeedsApproval {
                            Button("Open Login Items", action: onOpenLoginItems)
                                .settingsButton(.secondary)
                        }
                        SettingsSwitch(label: "Open at login", isOn: $preferences.general.launchAtLoginEnabled)
                    }
                }
                SettingsToggleRow(
                    label: "Show in the Dock",
                    help: "Steno is always in the menu bar.",
                    isOn: $preferences.general.showDockIcon
                )
                SettingsToggleRow(
                    label: "Show the setup guide",
                    help: "Opens the guide again after you save.",
                    isOn: $preferences.general.showOnboarding
                )
            }
            SettingsCard(title: "Data") {
                SettingsRow(label: "History", help: "Keeps your latest 1,000 dictations on this Mac.") {
                    Button("Delete All History…") { isConfirmingDeleteAll = true }
                        .settingsButton(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text("\(SettingsSidebarVersion.line) · MIT License ·")
                Link("Release notes", destination: Self.releaseNotesURL)
                    .foregroundStyle(theme.accent)
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.ink3)
            .padding(.top, 18)
        }
        .confirmationDialog(
            Self.deleteAllTitle(listedCount: controller.recentEntries.count),
            isPresented: $isConfirmingDeleteAll
        ) {
            Button("Delete All History", role: .destructive) {
                Task { await Self.deleteAllHistory(using: controller) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved dictation from this Mac, including History backups and copies kept when it couldn’t be read. Insights totals stay, and text already inserted into other apps isn’t affected.")
        }
    }

    static func deleteAllTitle(listedCount: Int) -> String {
        guard listedCount > 0 else { return "Delete all History?" }
        return listedCount == 1 ? "Delete 1 dictation?" : "Delete all \(listedCount.formatted()) dictations?"
    }

    /// Deletes every saved dictation, then lets go of deleted text the app still holds.
    static func deleteAllHistory(using controller: DictationController) async {
        await controller.deleteAllHistory()
        guard controller.status == "History deleted." else { return }
        controller.lastTranscript = ""
        if let notice = controller.storageNotice,
           notice.recoverableText != nil
            || notice.fileURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            controller.dismissStorageNotice()
        }
    }
}

/// "Steno 1.1 (5)" from the bundle.
enum SettingsSidebarVersion {
    static var line: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.1"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Steno \(version) (\($0))" } ?? "Steno \(version)"
    }
}
