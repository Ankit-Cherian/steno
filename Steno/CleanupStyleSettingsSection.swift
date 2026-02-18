import SwiftUI
import StenoKit

struct CleanupStyleSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @State private var newStyleBundleID: String = ""
    @State private var newStyleProfile: StyleProfile = .init(
        name: "App Override",
        tone: .professional,
        structureMode: .paragraph,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    var body: some View {
        settingsCardWithSubtitle(
            "Cleanup Style",
            subtitle: "How transcripts are cleaned and formatted"
        ) {
            describedPicker(
                "Tone",
                description: "How formal the cleaned text sounds",
                selection: $controller.preferences.globalStyleProfile.tone
            )

            describedPicker(
                "Structure",
                description: "How the output text is formatted",
                selection: $controller.preferences.globalStyleProfile.structureMode
            )

            describedPicker(
                "Filler removal",
                description: "How aggressively \u{201C}um\u{201D}, \u{201C}like\u{201D} are removed",
                selection: $controller.preferences.globalStyleProfile.fillerPolicy
            )

            describedPicker(
                "Commands",
                description: "Whether /slash commands pass through raw",
                selection: $controller.preferences.globalStyleProfile.commandPolicy
            )

            DisclosureGroup(
                "Per-app overrides (\(controller.preferences.appStyleProfiles.count) configured)"
            ) {
                VStack(alignment: .leading, spacing: StenoDesign.sm) {
                    if controller.preferences.appStyleProfiles.isEmpty {
                        Text("No app overrides yet. Add a bundle ID to customize cleanup per app.")
                            .foregroundStyle(StenoDesign.textSecondary)
                    } else {
                        ForEach(controller.preferences.appStyleProfiles.keys.sorted(), id: \.self) { bundleID in
                            entryRow(
                                leading: bundleID,
                                trailing: controller.preferences.appStyleProfiles[bundleID]?.name ?? "Profile"
                            ) {
                                controller.preferences.appStyleProfiles.removeValue(forKey: bundleID)
                            }
                        }
                    }

                    Divider()

                    TextField("Bundle ID", text: $newStyleBundleID)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: StenoDesign.sm) {
                        enumPicker("Tone", selection: $newStyleProfile.tone)
                        enumPicker("Structure", selection: $newStyleProfile.structureMode)
                    }
                    HStack(spacing: StenoDesign.sm) {
                        enumPicker("Filler", selection: $newStyleProfile.fillerPolicy)
                        enumPicker("Commands", selection: $newStyleProfile.commandPolicy)
                    }

                    HStack {
                        Spacer()
                        Button {
                            guard !newStyleBundleID.isEmpty else { return }
                            controller.preferences.appStyleProfiles[newStyleBundleID] = newStyleProfile
                            newStyleBundleID = ""
                            newStyleProfile = .init(
                                name: "App Override",
                                tone: .professional,
                                structureMode: .paragraph,
                                fillerPolicy: .balanced,
                                commandPolicy: .transform
                            )
                        } label: {
                            Label("Add Override", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, StenoDesign.sm)
            }
        }
    }
}
