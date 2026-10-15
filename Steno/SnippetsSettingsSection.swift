import SwiftUI
import StenoKit

struct SnippetsSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTrigger: String = ""
    @State private var newExpansion: String = ""
    @State private var newScope: Scope = .global
    /// Why the last app chosen for the phrase could not be used, or nil.
    @State private var scopeProblem: String?
    @Environment(\.quillTheme) private var theme

    private static let triggerWidth: CGFloat = 130
    private static let scopeWidth: CGFloat = 100
    private static let actionWidth: CGFloat = 80
    static let expansionLineLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(
                section: .shortcuts,
                intro: "Say a short phrase and Steno types the longer text. Adding a phrase that already exists for the same apps replaces it."
            )
            SettingsCard {
                addRow
                ForEach(preferences.snippets) { snippet in
                    snippetRow(snippet)
                }
            }
            if let scopeProblem {
                SettingsCautionLine(text: scopeProblem).padding(.top, 8)
            }
        }
        .onChange(of: newTrigger) { _ in scopeProblem = nil }
    }

    private var addRow: some View {
        HStack(alignment: .top, spacing: 12) {
            TextField("Say…", text: $newTrigger, prompt: Text("Say…"))
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.triggerWidth)
                .accessibilityLabel("Phrase to say")
            arrow.padding(.top, 6)
            TextField("Steno types…", text: $newExpansion, prompt: Text("Steno types…"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .accessibilityLabel("Text Steno types")
            ScopeMenu(scope: $newScope, problem: $scopeProblem, knownBundleIDs: knownBundleIDs)
                .frame(width: Self.scopeWidth, alignment: .leading)
            Button("Add", action: addShortcut)
                .settingsButton(.primary)
                .disabled(!canAdd)
                .frame(width: Self.actionWidth, alignment: .trailing)
        }
        .settingsRowInset(vertical: 11)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11.5))
            .foregroundStyle(theme.ink3)
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        let isBlank = SnippetService.normalizedTrigger(snippet.trigger) == nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                Text("“\(snippet.trigger)”")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .frame(width: Self.triggerWidth, alignment: .leading)
                    .padding(.top, 2)
                arrow.padding(.top, 4)
                // A long expansion, such as a letter, stops after a few lines; the whole text is
                // its tooltip and what VoiceOver reads.
                Text(snippet.expansion)
                    .settingsFont(.body)
                    .lineSpacing(3)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(Self.expansionLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(snippet.expansion)
                Text(AppIdentity.scopeTitle(snippet.scope))
                    .settingsFont(.caption)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: Self.scopeWidth, alignment: .leading)
                    .padding(.top, 2)
                    .help(AppIdentity.scopeTitle(snippet.scope))
                Button("Remove") {
                    preferences.snippets.removeAll { $0.id == snippet.id }
                }
                .settingsButton(.quiet)
                .accessibilityLabel("Remove “\(snippet.trigger)”")
                .frame(width: Self.actionWidth, alignment: .trailing)
            }
            if isBlank {
                SettingsCautionLine(text: "Never applies: the phrase is blank.")
            }
        }
        .settingsRowInset(vertical: 11)
        .accessibilityElement(children: .contain)
    }

    private var knownBundleIDs: [String] {
        var seen: Set<String> = []
        return (preferences.snippets.map(\.scope) + preferences.lexiconEntries.map(\.scope)).compactMap { scope in
            guard case .app(let bundleID) = scope, !bundleID.isEmpty, seen.insert(bundleID).inserted else { return nil }
            return bundleID
        }
    }

    /// A trigger must have something other than spaces in it.
    private var canAdd: Bool {
        SnippetService.normalizedTrigger(newTrigger) != nil
            && !newExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addShortcut() {
        guard canAdd, let trigger = SnippetService.normalizedTrigger(newTrigger) else { return }
        let scope = newScope
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
    }
}
