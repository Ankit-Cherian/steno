import SwiftUI
import StenoKit

struct LexiconSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTerm: String = ""
    @State private var newPreferred: String = ""
    @State private var newAliases: String = ""
    @State private var newBundleID: String = ""
    @State private var newGlobal = true

    var body: some View {
        settingsCardWithSubtitle(
            "Word Corrections",
            subtitle: "Auto-fix words that speech recognition gets wrong, with optional aliases for likely variants"
        ) {
            VStack(spacing: StenoDesign.sm) {
                if preferences.lexiconEntries.isEmpty {
                    Text("No corrections yet. Example: \u{201C}stenoh\u{201D} \u{2192} \u{201C}Steno\u{201D}")
                        .foregroundStyle(StenoDesign.textSecondary)
                } else {
                    ForEach(preferences.lexiconEntries.indices, id: \.self) { index in
                        let entry = preferences.lexiconEntries[index]
                        lexiconEntryRow(entry: entry) {
                            preferences.lexiconEntries.remove(at: index)
                        }
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

            TextField("Aliases (comma-separated, optional)", text: $newAliases)
                .textFieldStyle(.roundedBorder)

            HStack {
                ScopePickerRow(isGlobal: $newGlobal, bundleID: $newBundleID)
                Spacer()
                Button {
                    guard !newTerm.isEmpty, !newPreferred.isEmpty else { return }
                    let scope: Scope = newGlobal ? .global : .app(bundleID: newBundleID)
                    let aliases = parseAliases(newAliases)
                    let newEntry = LexiconEntry(term: newTerm, preferred: newPreferred, scope: scope, aliases: aliases)
                    if let existingIndex = preferences.lexiconEntries.firstIndex(where: { $0.term == newEntry.term && $0.scope == newEntry.scope }) {
                        preferences.lexiconEntries[existingIndex] = newEntry
                    } else {
                        preferences.lexiconEntries.append(newEntry)
                    }
                    newTerm = ""
                    newPreferred = ""
                    newAliases = ""
                    newBundleID = ""
                    newGlobal = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func lexiconEntryRow(entry: LexiconEntry, onRemove: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: StenoDesign.sm) {
            VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                Text("\u{201C}\(entry.term)\u{201D} \u{2192} \u{201C}\(entry.preferred)\u{201D}")
                    .font(StenoDesign.callout())
                    .lineLimit(2)

                if entry.aliases.isEmpty == false {
                    Text("Aliases: \(entry.aliases.joined(separator: ", "))")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: StenoDesign.sm)
            scopeBadge(entry.scope)
            Button("Remove", role: .destructive, action: onRemove)
                .buttonStyle(.link)
                .accessibilityLabel("Remove entry")
                .accessibilityValue(entry.term)
        }
        .padding(.vertical, StenoDesign.xs)
        .padding(.horizontal, StenoDesign.sm)
        .background(StenoDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
    }

    private func parseAliases(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}
