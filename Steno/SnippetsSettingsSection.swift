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
            "Your shortcuts",
            subtitle: "Give text you use often a short spoken trigger."
        ) {
            VStack(spacing: StenoDesign.sm) {
                if preferences.snippets.isEmpty {
                    Text("No shortcuts yet. Example: \u{201C}brb\u{201D} \u{2192} \u{201C}I'll be right back\u{201D}")
                        .font(StenoDesign.callout())
                        .foregroundStyle(StenoDesign.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
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
            }

            Divider()

            settingsTextField("Trigger word", prompt: "brb", text: $newTrigger)

            VStack(alignment: .leading, spacing: 6) {
                Text("Expands to")
                    .font(.system(size: 12, weight: .medium))
                TextField("Expands to", text: $newExpansion, prompt: Text("I'll be right back"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                    .labelsHidden()
                    .accessibilityLabel("Expands to")
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
                    Label("Add shortcut", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(newTrigger.isEmpty || newExpansion.isEmpty)
            }
        }
    }
}
