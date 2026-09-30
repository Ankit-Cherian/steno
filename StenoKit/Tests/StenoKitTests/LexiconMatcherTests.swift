import Foundation
import Testing
@testable import StenoKit

private let notesContext = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")

/// Resolves entries the way the app does (scope filtering through the service snapshot) and
/// applies them with the one matcher cleanup uses.
private func applyVocabulary(
    _ text: String,
    entries: [LexiconEntry],
    context: AppContext = notesContext
) async -> LexiconApplicationResult {
    let lexicon = await PersonalLexiconService(entries: entries).snapshot(for: context)
    return LexiconMatcher(lexicon: lexicon).apply(to: text)
}

@Test("Vocabulary replacements do not cascade, in either entry order")
func vocabularyReplacementsDoNotCascade() async {
    let hound = LexiconEntry(term: "hound", preferred: "dog", scope: .global)
    let dog = LexiconEntry(term: "dog", preferred: "wolf", scope: .global)

    for entries in [[hound, dog], [dog, hound]] {
        let result = await applyVocabulary("the hound chased the dog", entries: entries)
        #expect(result.text == "the dog chased the wolf")
    }
}

@Test("Equal-length overlapping entries resolve by position, not entry order")
func equalLengthOverlapsResolveByPosition() async {
    let first = LexiconEntry(term: "alpha bravo", preferred: "AB", scope: .global)
    let second = LexiconEntry(term: "bravo delta", preferred: "BD", scope: .global)

    for entries in [[first, second], [second, first]] {
        let result = await applyVocabulary("say alpha bravo delta now", entries: entries)
        #expect(result.text == "say AB delta now")
    }
}

@Test("An app-scoped entry beats a global entry for the same term, and hints agree")
func appScopedEntryBeatsGlobalForSameTerm() async {
    let global = LexiconEntry(term: "steno", preferred: "Steno", scope: .global)
    let app = LexiconEntry(term: "steno", preferred: "StenoKit", scope: .app(bundleID: "com.apple.Notes"))

    for entries in [[global, app], [app, global]] {
        let result = await applyVocabulary("open steno", entries: entries)
        #expect(result.text == "open StenoKit")

        let hints = await PersonalLexiconService(entries: entries).hotTerms(for: notesContext)
        #expect(hints == ["StenoKit"])

        let elsewhere = await applyVocabulary(
            "open steno",
            entries: entries,
            context: AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        )
        #expect(elsewhere.text == "open Steno")
    }
}

@Test("Casing-only entries apply")
func casingOnlyEntriesApply() async {
    let entry = LexiconEntry(term: "github", preferred: "GitHub", scope: .global)

    let lower = await applyVocabulary("push it to github", entries: [entry])
    #expect(lower.text == "push it to GitHub")
    #expect(lower.edits == [TranscriptEdit(kind: .lexiconCorrection, from: "github", to: "GitHub")])

    let spaced = await applyVocabulary("push it to git hub", entries: [entry])
    #expect(spaced.text == "push it to GitHub")

    let alreadyCorrect = await applyVocabulary("push it to GitHub", entries: [entry])
    #expect(alreadyCorrect.text == "push it to GitHub")
    #expect(alreadyCorrect.edits.isEmpty)
}

@Test("An existing preferred spelling is protected from its own entry")
func existingPreferredSpellingIsProtected() async {
    let entry = LexiconEntry(term: "visual", preferred: "Visual Studio", scope: .global)

    let result = await applyVocabulary("I use Visual Studio daily and visual too", entries: [entry])
    #expect(result.text == "I use Visual Studio daily and Visual Studio too")

    let unchanged = await applyVocabulary("I opened Visual Studio this morning", entries: [entry])
    #expect(unchanged.text == "I opened Visual Studio this morning")
    #expect(unchanged.edits.isEmpty)
}

@Test("Terms with symbol edges match alone but never inside a longer token")
func symbolEdgedTermsUseTokenBoundaries() async {
    let entries = [
        LexiconEntry(term: "c++", preferred: "C++", scope: .global),
        LexiconEntry(term: "c#", preferred: "C#", scope: .global),
        LexiconEntry(term: ".net", preferred: ".NET", scope: .global),
        LexiconEntry(term: "v1.2", preferred: "V1.2", scope: .global),
    ]

    let matched = await applyVocabulary("we use c++ and c# on .net, then ship v1.2.", entries: entries)
    #expect(matched.text == "we use C++ and C# on .NET, then ship V1.2.")

    for text in ["build c++17 now", "open asp.net docs", "ship v1.2.3 today", "ship v1.20 today", "tag xv1.2 now"] {
        let result = await applyVocabulary(text, entries: entries)
        #expect(result.text == text)
    }
}

@Test("Word terms still match next to apostrophes and hyphens")
func wordTermsMatchNextToApostrophesAndHyphens() async {
    let entry = LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global)

    let result = await applyVocabulary("stenoh's menu is stenoh-based", entries: [entry])
    #expect(result.text == "Steno's menu is Steno-based")
}

@Test("Entries that can never apply are ignored")
func unusableEntriesAreIgnored() async {
    let entries = [
        LexiconEntry(term: "stenoh", preferred: "Steno", scope: .app(bundleID: "")),
        LexiconEntry(term: "   ", preferred: "Nothing", scope: .global),
        LexiconEntry(term: "cloud", preferred: "Cloud", scope: .global),
        LexiconEntry(term: "code", preferred: "VS Code", scope: .global),
    ]

    let result = await applyVocabulary(
        "stenoh keeps code in the cloud",
        entries: entries,
        context: AppContext(bundleIdentifier: "", appName: "")
    )
    #expect(result.text == "stenoh keeps code in the cloud")
    #expect(result.edits.isEmpty)
}

@Test("Duplicate terms in one scope resolve to the entry saved first")
func duplicateTermsResolveToFirstSaved() async {
    let first = LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global)
    let second = LexiconEntry(term: "Stenoh ", preferred: "Stenography", scope: .global)

    let result = await applyVocabulary("open stenoh", entries: [first, second])
    #expect(result.text == "open Steno")
}
