import SwiftUI
import StenoKit

struct SnippetsSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTrigger: String = ""
    @State private var newExpansion: String = ""
    @State private var newBundleID: String = ""
    @State private var newGlobal = true

    var body: some View {
        settingsCardWithSubtitle(
            "Text Shortcuts",
            subtitle: "Say a trigger word to insert longer text"
        ) {
            if preferences.snippets.isEmpty {
                Text("No shortcuts yet. Example: \u{201C}brb\u{201D} \u{2192} \u{201C}I'll be right back\u{201D}")
                    .foregroundStyle(StenoDesign.textSecondary)
            } else {
                ForEach(preferences.snippets) { snippet in
                    entryRow(
                        leading: "\u{201C}\(snippet.trigger)\u{201D} \u{2192} \(snippet.expansion)",
                        scope: snippet.scope
                    ) {
                        preferences.snippets.removeAll { $0.id == snippet.id }
                    }
                }
            }

            Divider()

            HStack(spacing: StenoDesign.sm) {
                TextField("Trigger word", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                TextField("Expands to", text: $newExpansion)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                ScopePickerRow(isGlobal: $newGlobal, bundleID: $newBundleID)
                Spacer()
                Button {
                    guard !newTrigger.isEmpty, !newExpansion.isEmpty else { return }
                    let scope: Scope = newGlobal ? .global : .app(bundleID: newBundleID)
                    let newSnippet = Snippet(trigger: newTrigger, expansion: newExpansion, scope: scope)
                    if let existingIndex = preferences.snippets.firstIndex(where: { $0.trigger == newSnippet.trigger && $0.scope == newSnippet.scope }) {
                        preferences.snippets[existingIndex] = newSnippet
                    } else {
                        preferences.snippets.append(newSnippet)
                    }
                    newTrigger = ""
                    newExpansion = ""
                    newBundleID = ""
                    newGlobal = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
