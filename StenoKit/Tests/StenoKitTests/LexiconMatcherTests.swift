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

@Test("A correction applies in Chinese, Japanese and Thai, where words have no spaces between them")
func correctionsApplyInUnspacedScripts() async {
    let cases: [(term: String, text: String, expected: String)] = [
        ("斯特诺", "我们用斯特诺写邮件。", "我们用Steno写邮件。"),
        ("ステノ", "今日はステノで書きました。", "今日はStenoで書きました。"),
        ("สเตโน", "ฉันใช้สเตโนเขียนอีเมล", "ฉันใช้Stenoเขียนอีเมล"),
        // A word from a spaced script, written against Japanese with no space.
        ("steno", "私はstenoを使います。", "私はStenoを使います。"),
    ]
    for (term, text, expected) in cases {
        let result = await applyVocabulary(text, entries: [LexiconEntry(term: term, preferred: "Steno", scope: .global)])
        #expect(result.text == expected, "\(term) in \(text)")
    }
}

@Test("A Thai correction never splits a letter from the vowel or tone mark written on it")
func thaiCorrectionKeepsMarksWithTheirLetter() async {
    let entry = LexiconEntry(term: "บา", preferred: "Ba", scope: .global)
    // "บ้าน": the tone mark sits on บ, so บา is not in it as written.
    let result = await applyVocabulary("ไปบ้านบา", entries: [entry])
    #expect(result.text == "ไปบ้านBa")
    let marked = await applyVocabulary("ส่งให้กิน", entries: [LexiconEntry(term: "ก", preferred: "K", scope: .global)])
    #expect(marked.text == "ส่งให้กิน")
}

@Test("Fix a Word's correction for later dictations applies to a later Chinese dictation")
func wordFixCorrectionAppliesToLaterChineseDictation() async throws {
    let entry = TranscriptEntry(appBundleID: "com.apple.Notes", rawText: "我们用斯特诺写邮件。", cleanText: "我们用斯特诺写邮件。",
                                audioURL: nil, insertionStatus: .inserted)
    let fixed = try entry.applyingWordFix(original: "斯特诺", occurrence: 0, replacement: "Steno", appliesToFuture: true)
    let correction = try #require(fixed.futureCorrectionForLastFix())
    let later = await applyVocabulary("明天把斯特诺的设置发给我。", entries: [correction])
    #expect(later.text == "明天把Steno的设置发给我。")
}

@Test("In spaced languages a term still matches only as a whole word")
func spacedLanguagesStillMatchWholeWords() async {
    let entry = LexiconEntry(term: "steno", preferred: "Steno", scope: .global)
    let result = await applyVocabulary("stenography xsteno steno_kit steno2 open steno now", entries: [entry])
    #expect(result.text == "stenography xsteno steno_kit steno2 open Steno now")
    let cyrillic = await applyVocabulary("стено стенограф", entries: [LexiconEntry(term: "стено", preferred: "Стено", scope: .global)])
    #expect(cyrillic.text == "Стено стенограф")
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
