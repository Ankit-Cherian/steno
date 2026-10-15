import Foundation
import Testing
@testable import StenoKit

@Suite("Fix a word")
struct WordFixTests {
    private static let profile = StyleProfile(
        name: "Test",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    private static func entry(_ clean: String, original: String? = nil) -> TranscriptEntry {
        TranscriptEntry(
            // Whole seconds, as History's ISO 8601 dates store them.
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            appBundleID: "com.example.editor",
            rawText: clean.lowercased(),
            cleanText: clean,
            audioURL: nil,
            insertionStatus: .inserted,
            originalCleanText: original
        )
    }

    private struct Store {
        let directory: URL
        let store: HistoryStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("word-fix-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = HistoryStore(
                storageURL: directory.appendingPathComponent("transcript-history.json")
            )
        }

        var storageURL: URL { directory.appendingPathComponent("transcript-history.json") }

        func stored(_ id: UUID) async -> TranscriptEntry? {
            await store.recent(limit: 100).first { $0.id == id }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Matching

    @Test("Occurrences count whole words only, with exact case")
    func wholeWordOccurrences() {
        let text = "Ship it, then ship the shipment. ship"
        let ranges = WordFixLocator.ranges(of: "ship", in: text)
        #expect(ranges.map { String(text[$0.lowerBound...].prefix(8)) } == ["ship the", "ship"])
        #expect(WordFixLocator.occurrence(of: "ship", at: ranges[1], in: text) == 1)
        #expect(WordFixLocator.ranges(of: "it", in: "it's it").count == 1)
    }

    @Test("In Chinese, Japanese and Thai a picked word matches inside the words around it")
    func unspacedScripts() throws {
        let chinese = "明天上午十点开会，请把议程和预算表发给大家。"
        let ranges = WordFixLocator.ranges(of: "议程", in: chinese)
        #expect(ranges.map { String(chinese[$0]) } == ["议程"])
        let picked = try #require(chinese.range(of: "议程"))
        #expect(WordFixLocator.occurrence(of: "议程", at: picked, in: chinese) == 0)
        #expect(WordFixLocator.ranges(of: "会議", in: "明日の会議は会議室で").count == 2)
        #expect(WordFixLocator.ranges(of: "ประชุม", in: "พรุ่งนี้มีประชุมตอนเช้า").count == 1)
        // Spaced scripts keep whole words only, beside an unspaced one too.
        #expect(WordFixLocator.ranges(of: "Sam", in: "Samuel 和 Sam").count == 1)
        #expect(WordFixLocator.ranges(of: "Sam", in: "Sam和Samuel").count == 1)
    }

    @Test("A fix in Chinese replaces the occurrence picked")
    func chineseFix() throws {
        let entry = Self.entry("请把议程和预算表发给大家，议程要先发。")
        let fixed = try entry.applyingWordFix(original: "议程", occurrence: 1, replacement: "会议议程", appliesToFuture: false)
        #expect(fixed.cleanText == "请把议程和预算表发给大家，会议议程要先发。")
    }

    // MARK: Store operations

    @Test("A fix replaces exactly the chosen occurrence and is recorded")
    func fixReplacesChosenOccurrence() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Send the deck to Sam, and Sam will review the deck.")
        try await fixture.store.append(entry: entry)

        let fixed = try await fixture.store.applyWordFix(
            entryID: entry.id,
            original: "Sam",
            occurrence: 1,
            replacement: "Pam",
            appliesToFuture: false
        )

        #expect(fixed.cleanText == "Send the deck to Sam, and Pam will review the deck.")
        #expect(fixed.fixes?.count == 1)
        #expect(fixed.fixes?.first?.original == "Sam")
        #expect(fixed.fixes?.first?.replacement == "Pam")
        #expect(fixed.fixes?.first?.occurrence == 1)
        #expect(fixed.fixes?.first?.appliesToFuture == false)
        #expect(fixed.rawText == entry.rawText)
        #expect(fixed.originalCleanText == nil)
        #expect(await fixture.stored(entry.id) == fixed)
    }

    @Test("A missing occurrence, a blank replacement or an unknown entry changes nothing")
    func invalidFixesChangeNothing() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("One word here.")
        try await fixture.store.append(entry: entry)

        await #expect(throws: WordFixError.wordNotFound) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "word", occurrence: 1, replacement: "term", appliesToFuture: false)
        }
        await #expect(throws: WordFixError.wordNotFound) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "wor", occurrence: 0, replacement: "term", appliesToFuture: false)
        }
        await #expect(throws: WordFixError.invalidReplacement) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "word", occurrence: 0, replacement: "  ", appliesToFuture: false)
        }
        await #expect(throws: HistoryStoreError.self) {
            try await fixture.store.applyWordFix(entryID: UUID(), original: "word", occurrence: 0, replacement: "term", appliesToFuture: false)
        }
        #expect(await fixture.stored(entry.id) == entry)
    }

    @Test("Undo reverts fixes one at a time, newest first, even when the replacement repeats")
    func undoRestores() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("a b a")
        try await fixture.store.append(entry: entry)

        _ = try await fixture.store.applyWordFix(entryID: entry.id, original: "a", occurrence: 1, replacement: "b", appliesToFuture: false)
        let twice = try await fixture.store.applyWordFix(entryID: entry.id, original: "a", occurrence: 0, replacement: "c", appliesToFuture: false)
        #expect(twice.cleanText == "c b b")

        let once = try await fixture.store.undoLastWordFix(entryID: entry.id)
        #expect(once.cleanText == "a b b")
        #expect(once.fixes?.count == 1)

        let none = try await fixture.store.undoLastWordFix(entryID: entry.id)
        #expect(none.cleanText == "a b a")
        #expect(none.fixes == nil)
        #expect(await fixture.stored(entry.id) == entry)

        await #expect(throws: WordFixError.nothingToUndo) {
            try await fixture.store.undoLastWordFix(entryID: entry.id)
        }
    }

    @Test("Restore original cleanup still works after a fix, and drops fixes it replaces")
    func restoreAfterFix() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        // Cleanup was run again, so the live dictation's text is kept aside.
        let entry = Self.entry("Open Steno now", original: "open stenoh now")
        try await fixture.store.append(entry: entry)

        let fixed = try await fixture.store.applyWordFix(entryID: entry.id, original: "now", occurrence: 0, replacement: "today", appliesToFuture: false)
        #expect(fixed.cleanText == "Open Steno today")
        #expect(fixed.originalCleanText == "open stenoh now")

        let restored = try #require(try await fixture.store.restoreOriginalCleanText(entryID: entry.id))
        #expect(restored.cleanText == "open stenoh now")
        #expect(restored.originalCleanText == nil)
        #expect(restored.fixes == nil)
    }

    @Test("Running cleanup again after a fix keeps the live text, not the fixed text, as the original")
    func rerunDropsFixes() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = TranscriptEntry(
            appBundleID: "com.apple.Notes",
            rawText: "open stenoh now",
            cleanText: "open stenoh now",
            audioURL: nil,
            insertionStatus: .inserted
        )
        try await fixture.store.append(entry: entry)
        _ = try await fixture.store.applyWordFix(entryID: entry.id, original: "now", occurrence: 0, replacement: "today", appliesToFuture: false)

        _ = try await fixture.store.retry(
            entryID: entry.id,
            using: RuleBasedCleanupEngine(),
            profile: Self.profile,
            lexicon: PersonalLexicon(entries: [LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global)]),
            appContext: .classified(bundleIdentifier: "com.apple.Notes", appName: "Notes"),
            snippets: nil
        )
        let rerun = try #require(await fixture.stored(entry.id))
        #expect(rerun.cleanText == "open Steno now")
        #expect(rerun.fixes == nil)
        // The original kept is what live dictation produced, before any word fix.
        #expect(rerun.originalCleanText == "open stenoh now")

        let restored = try #require(try await fixture.store.restoreOriginalCleanText(entryID: entry.id))
        #expect(restored.cleanText == "open stenoh now")
        #expect(restored.originalCleanText == nil)
    }

    // MARK: Limits

    @Test("A word or replacement that is too long, or one fix too many, is refused")
    func limitsAreEnforced() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let long = String(repeating: "x", count: WordFix.maximumWordLength + 1)
        let entry = Self.entry("Keep \(long) here and a here.")
        try await fixture.store.append(entry: entry)

        await #expect(throws: WordFixError.wordTooLong) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: long, occurrence: 0, replacement: "y", appliesToFuture: false)
        }
        await #expect(throws: WordFixError.wordTooLong) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "here", occurrence: 0, replacement: long, appliesToFuture: false)
        }
        #expect(await fixture.stored(entry.id) == entry)

        var full = Self.entry("a b")
        full.fixes = (0..<WordFix.maximumFixesPerEntry).map {
            WordFix(original: "c", replacement: "a", occurrence: 0, appliesToFuture: false, date: Date(timeIntervalSince1970: Double($0)))
        }
        #expect(throws: WordFixError.tooManyFixes) {
            try full.applyingWordFix(original: "b", occurrence: 0, replacement: "d", appliesToFuture: false)
        }
    }

    @Test("Saved fixes over the limits are trimmed when read")
    func decodedFixesAreBounded() throws {
        let fix = #"{"original":"a","replacement":"b","occurrence":0,"appliesToFuture":false,"date":"2026-10-05T10:00:00Z"}"#
        let oversized = #"{"original":"\#(String(repeating: "x", count: WordFix.maximumWordLength + 1))","replacement":"b","occurrence":0,"appliesToFuture":false,"date":"2026-10-05T10:00:00Z"}"#
        let fixes = [oversized] + Array(repeating: fix, count: WordFix.maximumFixesPerEntry + 3)
        let json = """
        {"id":"\(UUID().uuidString)","createdAt":"2026-10-05T10:00:00Z","appBundleID":"com.example.editor",
         "rawText":"a","cleanText":"b","durationMS":0,"insertionStatus":"inserted","fixes":[\(fixes.joined(separator: ","))]}
        """
        let log = DecodingIssueLog()
        let decoder = JSONDecoder.recordingIssues(to: log)
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(TranscriptEntry.self, from: Data(json.utf8))
        #expect(entry.fixes?.count == WordFix.maximumFixesPerEntry)
        #expect(entry.fixes?.allSatisfy { $0.original == "a" } == true)
        #expect(log.replacedCount > 0)
        #expect(log.skippedCount == 0)
    }

    // MARK: Future dictations

    @Test("Fixing a word for future dictations adds a word correction")
    func futureScopeAddsCorrection() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Ask Kubernetis about it.")
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService()

        let fixed = try await fixture.store.applyWordFix(
            entryID: entry.id,
            original: "Kubernetis",
            occurrence: 0,
            replacement: "Kubernetes",
            appliesToFuture: true,
            lexicon: lexicon
        )

        #expect(fixed.cleanText == "Ask Kubernetes about it.")
        #expect(fixed.fixes?.first?.appliesToFuture == true)
        #expect(await lexicon.snapshot().entries == [
            LexiconEntry(term: "Kubernetis", preferred: "Kubernetes", scope: .global),
        ])
        let cleaned = try await RuleBasedCleanupEngine().cleanup(
            raw: RawTranscript(text: "kubernetis is up"),
            profile: Self.profile,
            lexicon: await lexicon.snapshot()
        )
        #expect(cleaned.text.contains("Kubernetes"))
    }

    @Test("A word fixed at the start of a sentence isn't capitalized in every dictation")
    func sentenceStartCasing() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Teh plan is ready. Kubernetis is up. Then teh rest.")
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService()

        // Capitalized only because it starts the sentence: saved in lowercase.
        _ = try await fixture.store.applyWordFix(entryID: entry.id, original: "Teh", occurrence: 0, replacement: "The", appliesToFuture: true, lexicon: lexicon)
        // A name keeps the capital the person typed, wherever it was fixed.
        _ = try await fixture.store.applyWordFix(entryID: entry.id, original: "Kubernetis", occurrence: 0, replacement: "Kubernetes", appliesToFuture: true, lexicon: lexicon)
        let fixed = try #require(await fixture.stored(entry.id))
        #expect(fixed.cleanText == "The plan is ready. Kubernetes is up. Then teh rest.")
        #expect(await lexicon.snapshot().entries.sorted { $0.term < $1.term } == [
            LexiconEntry(term: "Kubernetis", preferred: "Kubernetes", scope: .global),
            LexiconEntry(term: "teh", preferred: "the", scope: .global),
        ])
        #expect(fixed.futureCorrectionForLastFix() == LexiconEntry(term: "Kubernetis", preferred: "Kubernetes", scope: .global))

        let cleaned = try await RuleBasedCleanupEngine().cleanup(
            raw: RawTranscript(text: "send teh plan to kubernetis"),
            profile: Self.profile,
            lexicon: await lexicon.snapshot()
        )
        #expect(cleaned.text.contains("send the plan to Kubernetes"))
    }

    @Test("Mid-sentence casing is saved as typed, and a sentence start is found after punctuation and line breaks")
    func midSentenceCasingAsTyped() throws {
        func correction(_ text: String, _ original: String, _ replacement: String) throws -> LexiconEntry? {
            try Self.entry(text)
                .applyingWordFix(original: original, occurrence: 0, replacement: replacement, appliesToFuture: true)
                .futureCorrectionForLastFix()
        }
        #expect(try correction("Ask teh team", "teh", "The") == LexiconEntry(term: "teh", preferred: "The", scope: .global))
        #expect(try correction("Done!\n  Teh end", "Teh", "The") == LexiconEntry(term: "teh", preferred: "the", scope: .global))
        #expect(try correction("Really? Teh end", "Teh", "The") == LexiconEntry(term: "teh", preferred: "the", scope: .global))
        #expect(try correction("Use Api calls", "Api", "API") == LexiconEntry(term: "Api", preferred: "API", scope: .global))
    }

    @Test("A common word needs confirmation before it is fixed in every dictation")
    func commonWordNeedsConfirmation() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Put the file there.")
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService()

        await #expect(throws: WordFixError.commonWord("the")) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "the", occurrence: 0, replacement: "a", appliesToFuture: true, lexicon: lexicon)
        }
        #expect(await fixture.stored(entry.id) == entry)
        #expect(await lexicon.snapshot().entries.isEmpty)
        #expect(WordFixError.commonWord("the").errorDescription == "\u{201C}the\u{201D} is a common word. Fix it in this and future dictations?")

        let confirmed = try await fixture.store.applyWordFix(
            entryID: entry.id, original: "the", occurrence: 0, replacement: "a",
            appliesToFuture: true, confirmingCommonWord: true, lexicon: lexicon
        )
        #expect(confirmed.cleanText == "Put a file there.")
        #expect(await lexicon.snapshot().entries.map(\.term) == ["the"])

        // Just this dictation never asks.
        let local = try await fixture.store.applyWordFix(entryID: entry.id, original: "file", occurrence: 0, replacement: "folder", appliesToFuture: false)
        #expect(local.cleanText == "Put a folder there.")
    }

    @Test("A casing-only fix of a common word still needs confirmation before it is fixed in every dictation")
    func caseOnlyFixOfCommonWordNeedsConfirmation() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Send the invoice to bill about the bill.")
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService()

        // A change to another word asks.
        await #expect(throws: WordFixError.commonWord("bill")) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "bill", occurrence: 0, replacement: "invoice", appliesToFuture: true, lexicon: lexicon)
        }

        // Changing only the case asks too, and changes nothing until confirmed.
        await #expect(throws: WordFixError.commonWord("bill")) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "bill", occurrence: 0, replacement: "Bill", appliesToFuture: true, lexicon: lexicon)
        }
        #expect(await fixture.stored(entry.id) == entry)
        #expect(await lexicon.snapshot().entries.isEmpty)

        let confirmed = try await fixture.store.applyWordFix(
            entryID: entry.id, original: "bill", occurrence: 0, replacement: "Bill",
            appliesToFuture: true, confirmingCommonWord: true, lexicon: lexicon
        )
        #expect(confirmed.cleanText == "Send the invoice to Bill about the bill.")
        #expect(await lexicon.snapshot().entries == [LexiconEntry(term: "bill", preferred: "Bill", scope: .global)])

        // Just this dictation never asks, and a case-only fix of an uncommon word does not either.
        let local = try await fixture.store.applyWordFix(entryID: entry.id, original: "bill", occurrence: 0, replacement: "BILL", appliesToFuture: false)
        #expect(local.cleanText == "Send the invoice to Bill about the BILL.")
        let uncommon = Self.entry("Ask kubernetes about it.")
        try await fixture.store.append(entry: uncommon)
        let fixedUncommon = try await fixture.store.applyWordFix(entryID: uncommon.id, original: "kubernetes", occurrence: 0, replacement: "Kubernetes", appliesToFuture: true, lexicon: lexicon)
        #expect(fixedUncommon.cleanText == "Ask Kubernetes about it.")
    }

    @Test("Words Steno always keeps as spoken, and conflicting corrections, are refused for future dictations")
    func futureScopeRefusals() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("I like stenoh.")
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService(entries: [LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global)])

        await #expect(throws: WordFixError.keptAsSpoken("like")) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "like", occurrence: 0, replacement: "love", appliesToFuture: true, confirmingCommonWord: true, lexicon: lexicon)
        }
        await #expect(throws: WordFixError.conflictingCorrection(existing: LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global))) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "stenoh", occurrence: 0, replacement: "Stenography", appliesToFuture: true, lexicon: lexicon)
        }
        await #expect(throws: WordFixError.futureCorrectionsUnavailable) {
            try await fixture.store.applyWordFix(entryID: entry.id, original: "stenoh", occurrence: 0, replacement: "Steno", appliesToFuture: true)
        }
        #expect(await fixture.stored(entry.id) == entry)
        #expect(await lexicon.snapshot().entries.count == 1)
    }

    @Test("A fix computed against text that has since changed is refused")
    func staleApplyIsRefused() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Dana met Dana.")
        try await fixture.store.append(entry: entry)

        let fixed = try await fixture.store.applyWordFix(
            entryID: entry.id, original: "Dana", occurrence: 0, replacement: "Danna",
            appliesToFuture: false, expectingText: "Dana met Dana."
        )
        #expect(fixed.cleanText == "Danna met Dana.")

        // The same press arriving again, computed against the text before the first fix.
        await #expect(throws: WordFixError.dictationChanged) {
            try await fixture.store.applyWordFix(
                entryID: entry.id, original: "Dana", occurrence: 0, replacement: "Danna",
                appliesToFuture: false, expectingText: "Dana met Dana."
            )
        }
        let stored = try #require(await fixture.stored(entry.id))
        #expect(stored.cleanText == "Danna met Dana.")
        #expect(stored.fixes?.count == 1)

        // Against the current text the fix is made.
        let second = try await fixture.store.applyWordFix(
            entryID: entry.id, original: "Dana", occurrence: 0, replacement: "Dani",
            appliesToFuture: false, expectingText: "Danna met Dana."
        )
        #expect(second.cleanText == "Danna met Dani.")
        #expect(second.fixes?.count == 2)
    }

    @Test("An undo computed against an older set of fixes is refused")
    func staleUndoIsRefused() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        let entry = Self.entry("Dana met Bryan.")
        try await fixture.store.append(entry: entry)
        _ = try await fixture.store.applyWordFix(entryID: entry.id, original: "Dana", occurrence: 0, replacement: "Danna", appliesToFuture: false)
        _ = try await fixture.store.applyWordFix(entryID: entry.id, original: "Bryan", occurrence: 0, replacement: "Brian", appliesToFuture: false)

        let undone = try await fixture.store.undoLastWordFix(entryID: entry.id, expectingFixCount: 2)
        #expect(undone.cleanText == "Danna met Bryan.")

        await #expect(throws: WordFixError.fixNoLongerApplies) {
            try await fixture.store.undoLastWordFix(entryID: entry.id, expectingFixCount: 2)
        }
        let stored = try #require(await fixture.stored(entry.id))
        #expect(stored.cleanText == "Danna met Bryan.")
        #expect(stored.fixes?.count == 1)
    }

    /// The words the system's word breaking finds, which is how the UI picks a word
    /// (`enumerateSubstrings(.byWords)` feeds Choose from a List).
    private static func systemWords(in text: String) -> [String] {
        var words: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word { words.append(word) }
        }
        return words
    }

    @Test("A word beside a possessive apostrophe or inside single quotes is a whole word that can be fixed")
    func wordBesideApostropheOrQuoteIsWholeWord() throws {
        let text = "Ask the students' office, 'Dana' and James\u{2019} car."

        // Preconditions: a contraction still reads as one word, and the system word breaking
        // that the UI uses to pick a word hands back the bare word, without the apostrophe.
        try #require(WordFixLocator.ranges(of: "it", in: "it's it").count == 1)
        let systemWords = Self.systemWords(in: text)
        try #require(systemWords.contains("students"))
        try #require(systemWords.contains("Dana"))
        try #require(systemWords.contains("James"))

        for word in ["students", "Dana", "James"] {
            #expect(WordFixLocator.ranges(of: word, in: text).count == 1, "\(word) in the possessive/quote text")
        }
        // Curly opening and closing quotes, and a leading straight quote on its own.
        #expect(WordFixLocator.ranges(of: "Dana", in: "\u{2018}Dana\u{2019} is late").count == 1, "curly-quoted Dana")
        #expect(WordFixLocator.ranges(of: "Dana", in: "'Dana' is late").count == 1, "straight-quoted Dana")

        // The word picked in the UI converts to an occurrence (DictationRecordBridge.occurrence
        // calls WordFixLocator.occurrence with the picked range).
        let students = try #require(text.range(of: "students"))
        #expect(WordFixLocator.occurrence(of: "students", at: students, in: text) == 0, "occurrence of the picked students")

        // And the fix is made, keeping the apostrophe.
        let source = Self.entry("Ask the students' office about it.")
        do {
            let fixed = try source.applyingWordFix(
                original: "students", occurrence: 0, replacement: "pupils", appliesToFuture: false
            )
            #expect(fixed.cleanText == "Ask the pupils' office about it.")
        } catch {
            Issue.record("applyingWordFix threw \(error) for students' in \"\(source.cleanText)\"")
        }
    }

    // MARK: Password-field dictations

    @Test("A password-field dictation is refused a fix for future dictations, and nothing reaches Word Corrections")
    func concealedEntryRefusesFutureScope() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        var entry = Self.entry("Hunter twoo")
        entry.concealedCopy = true
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService()

        await #expect(throws: WordFixError.concealedDictation) {
            try await fixture.store.applyWordFix(
                entryID: entry.id, original: "twoo", occurrence: 0,
                replacement: "two", appliesToFuture: true, confirmingCommonWord: true, lexicon: lexicon
            )
        }

        #expect(await lexicon.snapshot().entries.isEmpty)
        #expect(await lexicon.hotTerms(for: nil).isEmpty)
        #expect(await fixture.stored(entry.id)?.cleanText == "Hunter twoo")
        #expect(await fixture.stored(entry.id)?.fixes == nil)
        #expect(throws: WordFixError.concealedDictation) {
            try entry.applyingWordFix(original: "twoo", occurrence: 0, replacement: "two", appliesToFuture: true)
        }
    }

    @Test("A password-field dictation can still be fixed in that dictation alone")
    func concealedEntryAllowsThisDictationOnly() async throws {
        let fixture = try Store()
        defer { fixture.cleanUp() }
        var entry = Self.entry("Hunter twoo")
        entry.concealedCopy = true
        try await fixture.store.append(entry: entry)
        let lexicon = PersonalLexiconService()

        let fixed = try await fixture.store.applyWordFix(
            entryID: entry.id, original: "twoo", occurrence: 0,
            replacement: "two", appliesToFuture: false, lexicon: lexicon
        )

        #expect(fixed.cleanText == "Hunter two")
        #expect(fixed.fixes?.map(\.appliesToFuture) == [false])
        #expect(fixed.futureCorrectionForLastFix() == nil)
        #expect(await lexicon.snapshot().entries.isEmpty)
    }
}
