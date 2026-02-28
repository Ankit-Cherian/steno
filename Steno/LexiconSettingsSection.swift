import SwiftUI
import StenoKit

struct LexiconSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTerm: String = ""
    @State private var newPreferred: String = ""
    @State private var newBundleID: String = ""
    @State private var newGlobal = true

    var body: some View {
        settingsCardWithSubtitle(
            "Word Corrections",
            subtitle: "Auto-fix words that speech recognition gets wrong"
        ) {
            if preferences.lexiconEntries.isEmpty {
                Text("No corrections yet. Example: \u{201C}stenoh\u{201D} \u{2192} \u{201C}Steno\u{201D}")
                    .foregroundStyle(StenoDesign.textSecondary)
            } else {
                ForEach(preferences.lexiconEntries.indices, id: \.self) { index in
                    let entry = preferences.lexiconEntries[index]
                    entryRow(
                        leading: "\u{201C}\(entry.term)\u{201D} \u{2192} \u{201C}\(entry.preferred)\u{201D}",
                        scope: entry.scope
                    ) {
                        preferences.lexiconEntries.remove(at: index)
                    }
                }
            }

            Divider()

            HStack(spacing: StenoDesign.sm) {
                TextField("Misheard word", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                TextField("Correct word", text: $newPreferred)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                ScopePickerRow(isGlobal: $newGlobal, bundleID: $newBundleID)
                Spacer()
                Button {
                    guard !newTerm.isEmpty, !newPreferred.isEmpty else { return }
                    let scope: Scope = newGlobal ? .global : .app(bundleID: newBundleID)
                    let newEntry = LexiconEntry(term: newTerm, preferred: newPreferred, scope: scope)
                    if let existingIndex = preferences.lexiconEntries.firstIndex(where: { $0.term == newEntry.term && $0.scope == newEntry.scope }) {
                        preferences.lexiconEntries[existingIndex] = newEntry
                    } else {
                        preferences.lexiconEntries.append(newEntry)
                    }
                    newTerm = ""
                    newPreferred = ""
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
