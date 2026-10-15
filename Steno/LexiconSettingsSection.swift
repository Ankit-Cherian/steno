import SwiftUI
import StenoKit

struct LexiconSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTerm: String = ""
    @State private var newPreferred: String = ""
    @State private var newScope: Scope = .global
    @State private var rejectionMessage: String?
    @State private var pendingEntry: LexiconEntry?
    @State private var pendingReview: LexiconEntryReview?
    @Environment(\.quillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(
                section: .corrections,
                intro: "Replace a word Steno keeps mishearing with the spelling you want. Fix a Word can also add corrections here."
            )
            SettingsCard {
                addRow
                ForEach(Array(preferences.lexiconEntries.enumerated()), id: \.offset) { index, entry in
                    entryRow(entry, index: index)
                }
            }
            if let rejectionMessage {
                SettingsCautionLine(text: rejectionMessage).padding(.top, 8)
            }
            SettingsFootnote(text: "To catch other ways Steno hears a word, add them after it, separated by commas.")
                .padding(.top, -4)
        }
        .onChange(of: newTerm) { _ in rejectionMessage = nil }
        .onChange(of: newScope) { _ in rejectionMessage = nil }
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { pendingEntry != nil },
                set: { if !$0 { pendingEntry = nil; pendingReview = nil } }
            ),
            presenting: pendingEntry
        ) { entry in
            Button("Cancel", role: .cancel) {}
            Button(pendingReview?.commonWords.isEmpty == false ? Self.commonWordConfirmTitle(entry.scope) : "Save Correction") { save(entry) }
                .keyboardShortcut(.defaultAction)
        } message: { entry in
            Text(pendingReview.map { confirmationMessage(for: entry, review: $0) } ?? "")
        }
    }

    static let columns: (scope: CGFloat, action: CGFloat) = (120, 80)

    private var addRow: some View {
        HStack(spacing: 12) {
            TextField("Misheard word", text: $newTerm, prompt: Text("Misheard word"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Misheard word, with other ways it's heard separated by commas")
                .onSubmit(addCorrection)
            arrow
            TextField("Correct word", text: $newPreferred, prompt: Text("Correct word"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Correct word")
                .onSubmit(addCorrection)
            ScopeMenu(scope: $newScope, problem: $rejectionMessage, knownBundleIDs: knownBundleIDs)
                .frame(width: Self.columns.scope, alignment: .leading)
            Button("Add", action: addCorrection)
                .settingsButton(.primary)
                .disabled(trimmed(newTerm).isEmpty || trimmed(newPreferred).isEmpty)
                .frame(width: Self.columns.action, alignment: .trailing)
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

    private func entryRow(_ entry: LexiconEntry, index: Int) -> some View {
        let status = statusDescription(LexiconEntryValidator.status(of: entry, in: preferences.lexiconEntries))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.term).font(.system(size: 13))
                    if !entry.aliases.isEmpty {
                        Text("also \(entry.aliases.joined(separator: ", "))")
                            .settingsFont(.caption)
                            .foregroundStyle(theme.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                arrow
                Text(entry.preferred)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // An app that is not installed is named by its bundle ID, whose end is the part
                // that differs, so a long one is cut in the middle and shown in full on hover.
                Text(AppIdentity.scopeTitle(entry.scope))
                    .settingsFont(.caption)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: Self.columns.scope, alignment: .leading)
                    .help(AppIdentity.scopeTitle(entry.scope))
                Button("Remove") {
                    preferences.lexiconEntries.remove(at: index)
                }
                .settingsButton(.quiet)
                .accessibilityLabel("Remove \(entry.term)")
                .frame(width: Self.columns.action, alignment: .trailing)
            }
            .foregroundStyle(theme.ink)
            if let problem = status {
                SettingsCautionLine(text: problem)
            }
        }
        .settingsRowInset(vertical: 11)
        .accessibilityElement(children: .contain)
    }

    private var knownBundleIDs: [String] {
        var seen: Set<String> = []
        return (preferences.lexiconEntries.map(\.scope) + preferences.snippets.map(\.scope)).compactMap { scope in
            guard case .app(let bundleID) = scope, !bundleID.isEmpty, seen.insert(bundleID).inserted else { return nil }
            return bundleID
        }
    }

    /// A problem that stops an entry from applying; nil when it works.
    private func statusDescription(_ status: LexiconEntryStatus) -> String? {
        switch status {
        case .active(let kept) where kept.isEmpty:
            return nil
        case .active(let kept):
            return "Steno keeps \(quotedList(kept)) as spoken."
        case .keptAsSpoken(let forms):
            return "Never applies: Steno always keeps \(quotedList(forms)) as spoken."
        case .missingApp:
            return "Never applies: no app is set. Remove it and add it again for an app."
        case .conflict(let winner):
            return "Not used: “\(winner.term)” → “\(winner.preferred)” already corrects the same words."
        }
    }

    private var alertTitle: String {
        guard let review = pendingReview, !review.commonWords.isEmpty else { return "Save this correction?" }
        let isSingle = review.commonWords.count == 1
        let scope = pendingEntry.map { $0.scope == .global ? "every dictation" : "every dictation in \(AppIdentity.name(for: bundleID(of: $0.scope)))" } ?? "every dictation"
        return "\(quotedList(review.commonWords)) \(isSingle ? "is a common word" : "are common words"). Fix \(isSingle ? "it" : "them") in \(scope)?"
    }

    /// Names where the correction applies, as the question does: every dictation, or one app's.
    static func commonWordConfirmTitle(_ scope: Scope) -> String {
        switch scope {
        case .global: "Fix in Every Dictation"
        case .app(let bundleID): "Fix in \(AppIdentity.name(for: bundleID))"
        }
    }

    private func bundleID(of scope: Scope) -> String {
        if case .app(let bundleID) = scope { return bundleID }
        return ""
    }

    private func addCorrection() {
        let spoken = parseList(newTerm)
        guard let term = spoken.first, !trimmed(newPreferred).isEmpty else { return }
        let entry = LexiconEntry(
            term: term,
            preferred: trimmed(newPreferred),
            scope: newScope,
            aliases: Array(spoken.dropFirst())
        )
        let review = LexiconEntryValidator.review(entry, existing: preferences.lexiconEntries)
        if let rejection = review.rejection {
            rejectionMessage = message(for: rejection)
            return
        }
        rejectionMessage = nil
        if review.needsConfirmation {
            pendingReview = review
            pendingEntry = entry
            return
        }
        save(entry)
    }

    private func save(_ entry: LexiconEntry) {
        if let existingIndex = preferences.lexiconEntries.firstIndex(where: { $0.term == entry.term && $0.scope == entry.scope }) {
            preferences.lexiconEntries[existingIndex] = entry
        } else {
            preferences.lexiconEntries.append(entry)
        }
        pendingEntry = nil
        pendingReview = nil
        newTerm = ""
        newPreferred = ""
    }

    private func message(for rejection: LexiconEntryReview.Rejection) -> String {
        switch rejection {
        case .blankTerm: "Enter the misheard word."
        case .blankSpelling: "Enter the correct word."
        case .missingApp: "Choose an app, or use All Apps."
        case .duplicate(let existing): "“\(existing.term)” already has a correction here. Remove it first to change it."
        }
    }

    private func confirmationMessage(for entry: LexiconEntry, review: LexiconEntryReview) -> String {
        var sentences: [String] = []
        if !review.commonWords.isEmpty {
            let place = entry.scope == .global ? "in every app" : "in \(AppIdentity.name(for: bundleID(of: entry.scope)))"
            let said = review.commonWords.map { "Every “\($0)” you say" }.joined(separator: " and ")
            sentences.append("\(said) will become “\(entry.preferred)”, \(place). You can remove it here at any time.")
        }
        if !review.keptSpokenForms.isEmpty {
            sentences.append(
                "Steno always keeps \(quotedList(review.keptSpokenForms)) as spoken, so \(review.keptSpokenForms.count == 1 ? "it" : "they") won’t be replaced."
            )
        }
        return sentences.joined(separator: " ")
    }

    private func quotedList(_ words: [String]) -> String {
        let quoted = words.map { "“\($0)”" }
        guard quoted.count > 1, let last = quoted.last else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "stenoh, steno, stenno" is the misheard word followed by other ways it's heard.
    private func parseList(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

/// All Apps, an app already used elsewhere in these settings, or another app chosen from disk.
struct ScopeMenu: View {
    @Binding var scope: Scope
    /// Set when the app chosen from disk cannot be used, and cleared by any other choice.
    @Binding var problem: String?
    let knownBundleIDs: [String]

    var body: some View {
        Menu {
            Button("All Apps") { problem = nil; scope = .global }
            if !knownBundleIDs.isEmpty {
                Divider()
                ForEach(knownBundleIDs, id: \.self) { bundleID in
                    Button("Only in \(AppIdentity.name(for: bundleID))") { problem = nil; scope = .app(bundleID: bundleID) }
                }
            }
            Divider()
            Button("Choose an App…") {
                switch AppIdentity.chooseApp() {
                case .cancelled: problem = nil
                case .noIdentifier: problem = AppIdentity.noIdentifierMessage
                case .app(let bundleID):
                    problem = nil
                    scope = .app(bundleID: bundleID)
                }
            }
        } label: {
            Text(scope == .global ? "All Apps" : AppIdentity.name(for: bundleID))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: 28)
        .modifier(PopUpChrome())
        .accessibilityLabel("Apps")
        .accessibilityValue(scope == .global ? "All Apps" : AppIdentity.name(for: bundleID))
    }

    private var bundleID: String {
        if case .app(let bundleID) = scope { return bundleID }
        return ""
    }
}

/// The paper fill and control border of a pop-up button.
private struct PopUpChrome: ViewModifier {
    @Environment(\.quillTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.controlBorder.opacity(0.6), lineWidth: 1))
    }
}
