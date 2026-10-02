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
            "Default style",
            subtitle: "Applies to every app unless you add an override below."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                pickerRow(
                    "Structure",
                    description: "How the output text is formatted",
                    selection: effectiveStructure($preferences.globalStyleProfile.structureMode),
                    options: StructureMode.selectableCases
                )
                Divider()
                pickerRow(
                    "Filler removal",
                    description: "Minimal and Balanced preserve your spoken words, including phrases such as “like” and “you know.” Aggressive removal is an explicit opt-in and can remove more fillers.",
                    selection: $preferences.globalStyleProfile.fillerPolicy
                )
                Divider()
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
                        Picker("Structure", selection: $newStyleProfile.structureMode) {
                            ForEach(StructureMode.selectableCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
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
                            Label("Add override", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(newStyleBundleID.isEmpty)
                    }
                }
                .padding(.top, StenoDesign.sm)
            }
        }
    }

    /// Shows a saved Email or Command structure as the structure it behaves like. The saved value
    /// changes only when another structure is picked.
    private func effectiveStructure(_ binding: Binding<StructureMode>) -> Binding<StructureMode> {
        Binding(
            get: { binding.wrappedValue.effective },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func longestOption<T: RawRepresentable>(in options: [T]) -> String where T.RawValue == String {
        options
            .map { $0.rawValue.capitalized }
            .max(by: { $0.count < $1.count }) ?? ""
    }

    @ViewBuilder
    private func pickerRow<T: Hashable & CaseIterable & RawRepresentable>(
        _ label: String,
        description: String,
        selection: Binding<T>,
        options: [T] = Array(T.allCases)
    ) -> some View where T.RawValue == String {
        VStack(alignment: .leading, spacing: StenoDesign.xxs) {
            HStack(spacing: StenoDesign.sm) {
                Text(label)
                    .frame(width: 100, alignment: .leading)
                ZStack(alignment: .leading) {
                    // Invisible sizing text — widest option sets minimum width
                    Text(longestOption(in: options))
                        .padding(.horizontal, 28)
                        .opacity(0)
                        .accessibilityHidden(true)
                    Picker(label, selection: selection) {
                        ForEach(options, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .fixedSize()
                Spacer()
            }
            Text(description)
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }
}
