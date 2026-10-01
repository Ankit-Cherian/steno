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
                            leading: SnippetService.normalizedTrigger(snippet.trigger) == nil
                                ? "\u{201C}\(snippet.trigger)\u{201D} \u{2192} \(snippet.expansion) (never applies: the trigger is blank)"
                                : "\u{201C}\(snippet.trigger)\u{201D} \u{2192} \(snippet.expansion)",
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
                    addShortcut()
                } label: {
                    Label("Add shortcut", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(canAdd == false)
            }
        }
    }

    /// A trigger must have something other than spaces in it, and an app shortcut needs its app.
    private var canAdd: Bool {
        SnippetService.normalizedTrigger(newTrigger) != nil
            && newExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && (newGlobal || newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    private func addShortcut() {
        guard canAdd, let trigger = SnippetService.normalizedTrigger(newTrigger) else { return }
        let scope: Scope = newGlobal
            ? .global
            : .app(bundleID: newBundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        let newSnippet = Snippet(trigger: trigger, expansion: newExpansion, scope: scope)
        let sameTrigger = { (snippet: Snippet) in
            snippet.scope == scope
                && snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trigger) == .orderedSame
        }
        if let existingIndex = preferences.snippets.firstIndex(where: sameTrigger) {
            preferences.snippets[existingIndex] = newSnippet
        } else {
            preferences.snippets.append(newSnippet)
        }
        newTrigger = ""
        newExpansion = ""
        newBundleID = ""
        newGlobal = true
    }
}
