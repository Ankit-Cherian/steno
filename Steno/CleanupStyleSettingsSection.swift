import SwiftUI
import StenoKit

struct CleanupStyleSettingsSection: View {
    @Binding var preferences: AppPreferences
    /// Why the last app chosen was not added, or nil.
    @State private var appProblem: String?
    @Environment(\.quillTheme) private var theme

    static let layouts: [(StructureMode, String)] = [(.natural, "As spoken"), (.paragraph, "Paragraphs"), (.bullets, "Bullets")]
    static let fillers: [(FillerPolicy, String)] = [(.minimal, "Light"), (.balanced, "Balanced"), (.aggressive, "Thorough")]
    static let commands: [(CommandPolicy, String)] = [(.transform, "Clean up"), (.passthrough, "Keep as spoken")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(
                section: .cleanup,
                intro: "What Steno cleans up before inserting. The original words are always saved in History."
            )
            SettingsCard(title: "Everywhere") {
                SettingsRow(label: "Layout", help: "How the text is arranged.") {
                    layoutPicker(effective($preferences.globalStyleProfile.structureMode), style: .segmented)
                }
                SettingsRow(
                    label: "Filler words",
                    help: "Light and Balanced keep every filler word. Thorough removes um, uh, I mean, basically, sort of and kind of, and can change meaning, so check the result."
                ) {
                    fillerPicker($preferences.globalStyleProfile.fillerPolicy, style: .segmented)
                }
                SettingsRow(
                    label: "Slash commands",
                    help: "For a dictation that starts with “/”. Keep as spoken leaves the command as you said it; Clean up treats it like any other text."
                ) {
                    Picker("Slash commands", selection: $preferences.globalStyleProfile.commandPolicy) {
                        ForEach(Self.commands, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.top, -16)
            SettingsCard(title: "For specific apps") {
                ForEach(appBundleIDs, id: \.self) { bundleID in
                    appRow(bundleID)
                }
                HStack {
                    Button {
                        addApp()
                    } label: {
                        Label("Add an App…", systemImage: "plus")
                    }
                    .settingsButton(.secondary)
                    Spacer()
                }
                .settingsRowInset(vertical: 11)
                if let appProblem {
                    SettingsCautionLine(text: appProblem).settingsRowInset(vertical: 6)
                }
            }
        }
    }

    private var appBundleIDs: [String] {
        preferences.appStyleProfiles.keys.sorted {
            AppIdentity.name(for: $0).localizedCaseInsensitiveCompare(AppIdentity.name(for: $1)) == .orderedAscending
        }
    }

    private func appRow(_ bundleID: String) -> some View {
        HStack(spacing: 10) {
            AppIconTile(bundleID: bundleID)
            Text(AppIdentity.name(for: bundleID))
                .settingsFont(.label)
                .foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            layoutPicker(profileBinding(bundleID, \.structureMode, effective: true), style: .menu)
            fillerPicker(profileBinding(bundleID, \.fillerPolicy), style: .menu)
            Button("Remove") { preferences.appStyleProfiles.removeValue(forKey: bundleID) }
                .settingsButton(.quiet)
                .accessibilityLabel("Remove \(AppIdentity.name(for: bundleID))")
        }
        .settingsRowInset(vertical: 10)
        .accessibilityElement(children: .contain)
    }

    private enum PickerKind { case segmented, menu }

    @ViewBuilder
    private func layoutPicker(_ selection: Binding<StructureMode>, style: PickerKind) -> some View {
        let picker = Picker("Layout", selection: selection) {
            ForEach(Self.layouts, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .fixedSize()
        if style == .segmented { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
    }

    @ViewBuilder
    private func fillerPicker(_ selection: Binding<FillerPolicy>, style: PickerKind) -> some View {
        let picker = Picker("Filler words", selection: selection) {
            ForEach(Self.fillers, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .fixedSize()
        if style == .segmented { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
    }

    /// Shows a saved Email or Command structure as the structure it behaves like. The saved value
    /// changes only when another structure is picked.
    private func effective(_ binding: Binding<StructureMode>) -> Binding<StructureMode> {
        Binding(get: { binding.wrappedValue.effective }, set: { binding.wrappedValue = $0 })
    }

    private func profileBinding<Value>(
        _ bundleID: String,
        _ keyPath: WritableKeyPath<StyleProfile, Value>,
        effective: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: {
                let value = preferences.appStyleProfiles[bundleID]?[keyPath: keyPath]
                    ?? preferences.globalStyleProfile[keyPath: keyPath]
                if effective, let mode = value as? StructureMode, let shown = mode.effective as? Value {
                    return shown
                }
                return value
            },
            set: { preferences.appStyleProfiles[bundleID]?[keyPath: keyPath] = $0 }
        )
    }

    private func addApp() {
        switch AppIdentity.chooseApp() {
        case .cancelled:
            appProblem = nil
        case .noIdentifier:
            appProblem = AppIdentity.noIdentifierMessage
        case .app(let bundleID):
            guard preferences.appStyleProfiles[bundleID] == nil else {
                appProblem = "\(AppIdentity.name(for: bundleID)) already has an override."
                return
            }
            appProblem = nil
            var profile = preferences.globalStyleProfile
            profile.name = "App Override"
            preferences.appStyleProfiles[bundleID] = profile
        }
    }
}

/// An app's own icon, with no tile behind it.
struct AppIconTile: View {
    let bundleID: String
    @Environment(\.quillTheme) private var theme

    var body: some View {
        ZStack {
            if let icon = AppIdentity.icon(for: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app").font(.system(size: 12)).foregroundStyle(theme.ink3)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
