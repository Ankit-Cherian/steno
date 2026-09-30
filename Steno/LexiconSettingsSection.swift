import SwiftUI
import StenoKit

struct LexiconSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTerm: String = ""
    @State private var newPreferred: String = ""
    @State private var newAliases: String = ""
    @State private var newBundleID: String = ""
    @State private var newGlobal = true
    @State private var rejectionMessage: String?
    @State private var pendingEntry: LexiconEntry?
    @State private var pendingReview: LexiconEntryReview?

    var body: some View {
        settingsCardWithSubtitle(
            "Your corrections",
            subtitle: "Replace a recurring misheard word with the spelling you prefer."
        ) {
            VStack(spacing: StenoDesign.sm) {
                if preferences.lexiconEntries.isEmpty {
                    Text("No corrections yet. Example: \u{201C}stenoh\u{201D} \u{2192} \u{201C}Steno\u{201D}")
                        .font(StenoDesign.callout())
                        .foregroundStyle(StenoDesign.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ForEach(preferences.lexiconEntries.indices, id: \.self) { index in
                        let entry = preferences.lexiconEntries[index]
                        lexiconEntryRow(
                            entry: entry,
                            status: LexiconEntryValidator.status(of: entry, in: preferences.lexiconEntries)
                        ) {
                            preferences.lexiconEntries.remove(at: index)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: StenoDesign.sm) {
                settingsTextField("Misheard word", prompt: "stenoh", text: $newTerm)
                settingsTextField("Correct word", prompt: "Steno", text: $newPreferred)
            }

            settingsTextField("Aliases · optional", prompt: "Separate variants with commas", text: $newAliases)

            HStack {
                ScopePickerRow(isGlobal: $newGlobal, bundleID: $newBundleID)
                Spacer()
                Button {
                    addCorrection()
                } label: {
                    Label("Add correction", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(trimmed(newTerm).isEmpty || trimmed(newPreferred).isEmpty)
            }

            if let rejectionMessage {
                Text(rejectionMessage)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: newTerm) { _ in rejectionMessage = nil }
        .onChange(of: newBundleID) { _ in rejectionMessage = nil }
        .onChange(of: newGlobal) { _ in rejectionMessage = nil }
        .confirmationDialog(
            "Save this correction?",
            isPresented: Binding(
                get: { pendingEntry != nil },
                set: { if !$0 { pendingEntry = nil; pendingReview = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingEntry
        ) { entry in
            Button("Save correction") { save(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(pendingReview.map { confirmationMessage(for: entry, review: $0) } ?? "")
        }
    }

    @ViewBuilder
    private func lexiconEntryRow(
        entry: LexiconEntry,
        status: LexiconEntryStatus,
        onRemove: @escaping () -> Void
    ) -> some View {
        let statusText = statusDescription(status)
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

                Text(statusText.text)
                    .font(StenoDesign.caption())
                    .foregroundStyle(statusText.isProblem ? StenoDesign.warning : StenoDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StenoDesign.sm)
            scopeBadge(entry.scope)
            Button("Remove", role: .destructive, action: onRemove)
                .buttonStyle(.link)
                .accessibilityLabel("Remove entry")
                .accessibilityValue(entry.term)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, StenoDesign.sm)
        .background(StenoDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
    }

    private func statusDescription(_ status: LexiconEntryStatus) -> (text: String, isProblem: Bool) {
        switch status {
        case .active(let kept) where kept.isEmpty:
            return ("Active", false)
        case .active(let kept):
            return ("Active. Steno keeps \(quotedList(kept)) as spoken.", false)
        case .keptAsSpoken(let forms):
            return ("Never applies: Steno always keeps \(quotedList(forms)) as spoken.", true)
        case .missingApp:
            return ("Never applies: no app is set. Remove it and add it again with a bundle ID.", true)
        case .conflict(let winner):
            return ("Not used: \u{201C}\(winner.term)\u{201D} \u{2192} \u{201C}\(winner.preferred)\u{201D} already corrects the same words.", true)
        }
    }

    private func addCorrection() {
        let bundleID = trimmed(newBundleID)
        let entry = LexiconEntry(
            term: trimmed(newTerm),
            preferred: trimmed(newPreferred),
            scope: newGlobal ? .global : .app(bundleID: bundleID),
            aliases: parseAliases(newAliases)
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
        newAliases = ""
        newBundleID = ""
        newGlobal = true
    }

    private func message(for rejection: LexiconEntryReview.Rejection) -> String {
        switch rejection {
        case .blankTerm:
            return "Enter the misheard word."
        case .blankSpelling:
            return "Enter the correct word."
        case .missingApp:
            return "Enter the app\u{2019}s bundle ID, or turn on All apps."
        case .duplicate(let existing):
            return "\u{201C}\(existing.term)\u{201D} already has a correction here. Remove it first to change it."
        }
    }

    private func confirmationMessage(for entry: LexiconEntry, review: LexiconEntryReview) -> String {
        var sentences: [String] = []
        if review.commonWords.isEmpty == false {
            let isSingle = review.commonWords.count == 1
            sentences.append(
                "\(quotedList(review.commonWords)) \(isSingle ? "is a common word" : "are common words"). "
                    + "Steno will type \u{201C}\(entry.preferred)\u{201D} every time you say \(isSingle ? "it" : "them")."
            )
        }
        if review.keptSpokenForms.isEmpty == false {
            sentences.append(
                "Steno always keeps \(quotedList(review.keptSpokenForms)) as spoken, so \(review.keptSpokenForms.count == 1 ? "it" : "they") won\u{2019}t be replaced."
            )
        }
        return sentences.joined(separator: " ")
    }

    private func quotedList(_ words: [String]) -> String {
        let quoted = words.map { "\u{201C}\($0)\u{201D}" }
        guard quoted.count > 1, let last = quoted.last else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
