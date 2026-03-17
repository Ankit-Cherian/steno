import SwiftUI
import StenoKit

struct CleanupStyleSettingsSection: View {
    @Binding var preferences: AppPreferences
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
            Grid(alignment: .leading, horizontalSpacing: StenoDesign.sm, verticalSpacing: 0) {
                pickerRow(
                    "Tone",
                    description: "How formal the cleaned text sounds",
                    selection: $preferences.globalStyleProfile.tone
                )
                Divider().gridCellColumns(2)
                pickerRow(
                    "Structure",
                    description: "How the output text is formatted",
                    selection: $preferences.globalStyleProfile.structureMode
                )
                Divider().gridCellColumns(2)
                pickerRow(
                    "Filler removal",
                    description: "How aggressively fillers like \u{201C}um\u{201D}, \u{201C}you know\u{201D}, and \u{201C}like\u{201D} are removed",
                    selection: $preferences.globalStyleProfile.fillerPolicy
                )
                Divider().gridCellColumns(2)
                pickerRow(
                    "Commands",
                    description: "Whether /slash commands pass through raw",
                    selection: $preferences.globalStyleProfile.commandPolicy
                )
            }

            DisclosureGroup(
                "Per-app overrides (\(preferences.appStyleProfiles.count) configured)"
            ) {
                VStack(alignment: .leading, spacing: StenoDesign.sm) {
                    if preferences.appStyleProfiles.isEmpty {
                        Text("No app overrides yet. Add a bundle ID to customize cleanup per app.")
                            .foregroundStyle(StenoDesign.textSecondary)
                    } else {
                        ForEach(preferences.appStyleProfiles.keys.sorted(), id: \.self) { bundleID in
                            entryRow(
                                leading: bundleID,
                                trailing: preferences.appStyleProfiles[bundleID]?.name ?? "Profile"
                            ) {
                                preferences.appStyleProfiles.removeValue(forKey: bundleID)
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
                            preferences.appStyleProfiles[newStyleBundleID] = newStyleProfile
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

    @ViewBuilder
    private func pickerRow<T: Hashable & CaseIterable & RawRepresentable>(
        _ label: String,
        description: String,
        selection: Binding<T>
    ) -> some View where T.RawValue == String {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                Picker("", selection: selection) {
                    ForEach(Array(T.allCases), id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Text(description)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
            }
        }
        .padding(.vertical, StenoDesign.sm)
    }
}
