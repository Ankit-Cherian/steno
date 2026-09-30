import Foundation
import Testing
@testable import StenoKit

@Test("Saving a correction for a common word asks for confirmation")
func commonWordEntryNeedsConfirmation() {
    let review = LexiconEntryValidator.review(
        LexiconEntry(term: "won", preferred: "Juan", scope: .global),
        existing: defaultVocabularyEntries
    )

    #expect(review.rejection == nil)
    #expect(review.commonWords == ["won"])
    #expect(review.needsConfirmation)
}

@Test("A common-word correction is applied everywhere once saved, which is why it is confirmed")
func commonWordEntryAppliesEverywhere() async throws {
    let entries = defaultVocabularyEntries + [LexiconEntry(term: "won", preferred: "Juan", scope: .global)]

    #expect(try await dictateThroughCoordinator("We won the game.", entries: entries) == "We Juan the game.")
}

@Test("Aliases that are common words are flagged too")
func commonWordAliasNeedsConfirmation() {
    let review = LexiconEntryValidator.review(
        LexiconEntry(term: "kash", preferred: "Cache", scope: .global, aliases: ["cash", "catch"]),
        existing: []
    )

    #expect(review.commonWords == ["cash", "catch"])
    #expect(review.needsConfirmation)
}

@Test("Ordinary corrections save without confirmation")
func ordinaryEntrySavesWithoutConfirmation() {
    for entry in [
        LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global),
        LexiconEntry(term: "steno kit", preferred: "StenoKit", scope: .global),
        LexiconEntry(term: "github", preferred: "GitHub", scope: .global),
    ] {
        let review = LexiconEntryValidator.review(entry, existing: [])
        #expect(review.rejection == nil)
        #expect(review.needsConfirmation == false)
    }
}

@Test("Corrections for words Steno keeps as spoken are flagged before saving")
func keptWordEntryIsFlagged() {
    let review = LexiconEntryValidator.review(
        LexiconEntry(term: "code", preferred: "VS Code", scope: .global),
        existing: []
    )

    #expect(review.keptSpokenForms == ["code"])
    #expect(review.commonWords.isEmpty)
    #expect(review.needsConfirmation)
}

@Test("An app scope without a bundle ID is rejected")
func appScopeWithoutBundleIDIsRejected() {
    for bundleID in ["", "   "] {
        let review = LexiconEntryValidator.review(
            LexiconEntry(term: "stenoh", preferred: "Steno", scope: .app(bundleID: bundleID)),
            existing: []
        )
        #expect(review.rejection == .missingApp)
    }
}

@Test("Duplicates that differ only by case or spacing are rejected")
func nearDuplicatesAreRejected() {
    let existing = [
        LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global),
        LexiconEntry(term: "steno kit", preferred: "StenoKit", scope: .app(bundleID: "com.example.editor")),
    ]

    let caseOnly = LexiconEntryValidator.review(
        LexiconEntry(term: "Stenoh", preferred: "Stenography", scope: .global),
        existing: existing
    )
    #expect(caseOnly.rejection == .duplicate(existing: existing[0]))

    let spacingOnly = LexiconEntryValidator.review(
        LexiconEntry(term: "steno  kit", preferred: "StenoKit", scope: .app(bundleID: "com.example.editor ")),
        existing: existing
    )
    #expect(spacingOnly.rejection == .duplicate(existing: existing[1]))

    let otherScope = LexiconEntryValidator.review(
        LexiconEntry(term: "Stenoh", preferred: "Steno", scope: .app(bundleID: "com.example.editor")),
        existing: existing
    )
    #expect(otherScope.rejection == nil)

    let sameSpelling = LexiconEntryValidator.review(
        LexiconEntry(term: "stenoh", preferred: "Stenography", scope: .global),
        existing: existing
    )
    #expect(sameSpelling.rejection == nil)
}

@Test("Settings status reports active, kept-as-spoken, missing-app and conflicting entries")
func entryStatusReportsEachState() async {
    let steno = LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global)
    let rival = LexiconEntry(term: "stenno", preferred: "Stenography", scope: .global, aliases: ["stenoh"])
    let code = LexiconEntry(term: "code", preferred: "VS Code", scope: .global)
    let cloudCasing = LexiconEntry(term: "cloud", preferred: "Cloud", scope: .global)
    let noApp = LexiconEntry(term: "stenoh", preferred: "Steno", scope: .app(bundleID: ""))
    let appOverride = LexiconEntry(term: "stenoh", preferred: "StenoKit", scope: .app(bundleID: "com.example.editor"))
    let mailAlias = LexiconEntry(term: "gee mail", preferred: "Gmail", scope: .global, aliases: ["mail"])
    let entries = [steno, rival, code, cloudCasing, noApp, appOverride, mailAlias]

    #expect(LexiconEntryValidator.status(of: steno, in: entries) == .active(keptSpokenForms: []))
    #expect(LexiconEntryValidator.status(of: rival, in: entries) == .conflict(with: steno))
    #expect(LexiconEntryValidator.status(of: code, in: entries) == .keptAsSpoken(spokenForms: ["code"]))
    #expect(LexiconEntryValidator.status(of: cloudCasing, in: entries) == .keptAsSpoken(spokenForms: ["cloud"]))
    #expect(LexiconEntryValidator.status(of: noApp, in: entries) == .missingApp)
    #expect(LexiconEntryValidator.status(of: appOverride, in: entries) == .active(keptSpokenForms: []))
    #expect(LexiconEntryValidator.status(of: mailAlias, in: entries) == .active(keptSpokenForms: ["mail"]))

    // The reported winner is the entry cleanup actually uses.
    let lexicon = await PersonalLexiconService(entries: entries).snapshot(for: nil)
    #expect(LexiconMatcher(lexicon: lexicon).apply(to: "open stenoh").text == "open Steno")
}
