import Foundation

/// A word corrected in a saved dictation with Fix a word.
public struct WordFix: Sendable, Codable, Equatable {
    /// The text that was replaced, exactly as it appeared.
    public var original: String
    public var replacement: String
    /// Which whole-word match of `original` was replaced, counting from 0.
    public var occurrence: Int
    /// Whether a word correction was also added for future dictations.
    public var appliesToFuture: Bool
    public var date: Date
    /// Where the replacement starts in the clean text after the fix, in UTF-16 code units, so the
    /// fix can be undone even when the replacement also appears elsewhere. Optional so a fix
    /// without it still decodes; such a fix is undone only when its replacement is unambiguous.
    public var location: Int?

    /// The longest `original` or `replacement`, in characters.
    public static let maximumWordLength = 80
    /// The most fixes one entry keeps.
    public static let maximumFixesPerEntry = 50

    public init(
        original: String,
        replacement: String,
        occurrence: Int,
        appliesToFuture: Bool,
        date: Date,
        location: Int? = nil
    ) {
        self.original = original
        self.replacement = replacement
        self.occurrence = occurrence
        self.appliesToFuture = appliesToFuture
        self.date = date
        self.location = location
    }

    enum CodingKeys: String, CodingKey {
        case original, replacement, occurrence, appliesToFuture, date, location
    }

    /// A fix whose text is longer than a fix can be fails to decode, so the list it is in leaves
    /// it out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        original = try container.decode(String.self, forKey: .original)
        replacement = try container.decode(String.self, forKey: .replacement)
        occurrence = try container.decode(Int.self, forKey: .occurrence)
        appliesToFuture = try container.decode(Bool.self, forKey: .appliesToFuture)
        date = try container.decode(Date.self, forKey: .date)
        location = try container.decodeIfPresent(Int.self, forKey: .location)
        guard original.count <= Self.maximumWordLength, replacement.count <= Self.maximumWordLength else {
            throw DecodingError.dataCorruptedError(
                forKey: .original,
                in: container,
                debugDescription: "A fixed word is longer than a fix can be."
            )
        }
    }
}

public enum WordFixError: Error, Equatable, LocalizedError {
    /// The chosen word isn't in the dictation's text at that occurrence.
    case wordNotFound
    /// The replacement is blank or the same as the word.
    case invalidReplacement
    /// The word or its replacement is longer than `WordFix.maximumWordLength`.
    case wordTooLong
    /// The dictation already has `WordFix.maximumFixesPerEntry` fixes.
    case tooManyFixes
    /// The word is a common English word, so fixing it in every dictation needs confirmation.
    /// Retry with `confirmingCommonWord: true` once the person confirms.
    case commonWord(String)
    /// Steno always keeps this word as spoken, so a correction for future dictations would never
    /// apply. The fix can still be made in this dictation alone.
    case keptAsSpoken(String)
    /// A word correction for the same word already exists with a different spelling.
    case conflictingCorrection(existing: LexiconEntry)
    /// Future dictations were requested but no word corrections are available to add to.
    case futureCorrectionsUnavailable
    /// Future dictations were requested for a dictation copied from a password field. Its words
    /// never become a word correction, which would reach recognition prompts.
    case concealedDictation
    /// The dictation has no fix to undo.
    case nothingToUndo
    /// The text changed since the last fix, so it can't be undone safely.
    case fixNoLongerApplies
    /// The dictation's text changed after the fix was chosen, so the fix was not made.
    case dictationChanged

    public var errorDescription: String? {
        switch self {
        case .wordNotFound:
            return "That word isn\u{2019}t in this dictation anymore."
        case .invalidReplacement:
            return "Enter a different word."
        case .wordTooLong:
            return "Choose a shorter word or phrase, up to \(WordFix.maximumWordLength) characters."
        case .tooManyFixes:
            return "This dictation has as many fixes as it can keep. Undo one first."
        case .commonWord(let word):
            return "\u{201C}\(word)\u{201D} is a common word. Fix it in this and future dictations?"
        case .keptAsSpoken(let word):
            return "Steno always keeps \u{201C}\(word)\u{201D} as spoken, so it can be fixed in this dictation only."
        case .conflictingCorrection(let existing):
            return "\u{201C}\(existing.term)\u{201D} is already corrected to \u{201C}\(existing.preferred)\u{201D}. Change it in Word corrections."
        case .futureCorrectionsUnavailable:
            return "Word corrections aren\u{2019}t available right now. Fix this dictation only, or try again."
        case .concealedDictation:
            return "This dictation came from a password field, so it can be fixed in this dictation only."
        case .nothingToUndo:
            return "There\u{2019}s no fix to undo."
        case .fixNoLongerApplies:
            return "This dictation changed since the fix, so the fix can\u{2019}t be undone."
        case .dictationChanged:
            return "This dictation changed before the fix was made. Choose the word again."
        }
    }
}

/// Finds whole-word matches in dictation text, the way Fix a word counts occurrences.
public enum WordFixLocator {
    /// Every match of `word` in `text` that isn't part of a longer word, in order. Matching is
    /// exact, including case. Chinese, Japanese, Thai and the other scripts written without
    /// spaces have no visible edge between words, so there any match counts: the word is the
    /// one the person picked.
    public static func ranges(of word: String, in text: String) -> [Range<String.Index>] {
        guard let first = word.first, let last = word.last else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: word, options: .literal, range: searchStart..<text.endIndex) {
            let beforeIndex = range.lowerBound == text.startIndex ? nil : text.index(before: range.lowerBound)
            let before = beforeIndex.map { text[$0] }
            let beforeFar = beforeIndex.flatMap { $0 == text.startIndex ? nil : text[text.index(before: $0)] }
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let afterFar = after == nil ? nil : text.index(after: range.upperBound) == text.endIndex
                ? nil : text[text.index(after: range.upperBound)]
            let startsWord = before.map {
                !isWordCharacter(first) || !joinsWord($0, farSide: beforeFar) || isUnspaced(first) || isUnspaced($0)
            } ?? true
            let endsWord = after.map {
                !isWordCharacter(last) || !joinsWord($0, farSide: afterFar) || isUnspaced(last) || isUnspaced($0)
            } ?? true
            if startsWord, endsWord {
                ranges.append(range)
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return ranges
    }

    /// The occurrence number of the match of `word` that starts at `range`, or nil when `range`
    /// isn't a whole-word match. The UI uses this to turn a selection into an occurrence.
    public static func occurrence(of word: String, at range: Range<String.Index>, in text: String) -> Int? {
        ranges(of: word, in: text).firstIndex { $0 == range }
    }

    /// Whether `index` starts a sentence: only spaces, quotes or opening brackets stand between
    /// it and the start of the text, a line break, or a ".", "!" or "?".
    static func isSentenceStart(_ index: String.Index, in text: String) -> Bool {
        var position = index
        while position > text.startIndex {
            let previous = text.index(before: position)
            let character = text[previous]
            if character.isNewline { return true }
            if character.isWhitespace || "\"\u{201C}'\u{2018}([".contains(character) {
                position = previous
                continue
            }
            return ".!?".contains(character)
        }
        return true
    }

    /// The scripts written without spaces between words: Han, kana, Thai, Lao, Khmer and
    /// Myanmar. Saved word corrections use the same ranges.
    static let unspacedScalars: [ClosedRange<UInt32>] = [
        0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,          // kana
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,          // Han
        0x20000...0x323AF,                                          // Han, supplementary
        0x0E00...0x0EFF, 0x1780...0x17FF, 0x1000...0x109F,          // Thai, Lao, Khmer, Myanmar
    ]

    /// A letter of a script written without spaces between words.
    static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return unspacedScalars.contains { $0.contains(scalar) }
    }

    /// Whether `neighbor`, next to a match, continues the word. An apostrophe does only when a
    /// letter or digit stands on its far side ("it's", "don't"); beside a possessive ("students'")
    /// or around a quoted word ("'Dana'") it is punctuation.
    private static func joinsWord(_ neighbor: Character, farSide: Character?) -> Bool {
        if neighbor == "'" || neighbor == "\u{2019}" {
            return farSide.map { $0.isLetter || $0.isNumber } ?? false
        }
        return isWordCharacter(neighbor)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
            || character == "'" || character == "\u{2019}"
    }
}

extension TranscriptEntry {
    /// This entry with `occurrence` of `original` in its clean text replaced, and the fix recorded.
    /// `originalCleanText` is left as it is.
    public func applyingWordFix(
        original: String,
        occurrence: Int,
        replacement: String,
        appliesToFuture: Bool,
        date: Date = Date()
    ) throws -> TranscriptEntry {
        if appliesToFuture, concealedCopy == true { throw WordFixError.concealedDictation }
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, replacement != original else {
            throw WordFixError.invalidReplacement
        }
        guard original.count <= WordFix.maximumWordLength,
              replacement.count <= WordFix.maximumWordLength
        else {
            throw WordFixError.wordTooLong
        }
        guard (fixes?.count ?? 0) < WordFix.maximumFixesPerEntry else {
            throw WordFixError.tooManyFixes
        }
        let matches = WordFixLocator.ranges(of: original, in: cleanText)
        guard occurrence >= 0, occurrence < matches.count else {
            throw WordFixError.wordNotFound
        }
        let range = matches[occurrence]
        let location = cleanText.utf16.distance(from: cleanText.startIndex, to: range.lowerBound)

        var fixed = self
        fixed.cleanText.replaceSubrange(range, with: replacement)
        fixed.fixes = (fixes ?? []) + [WordFix(
            original: original,
            replacement: replacement,
            occurrence: occurrence,
            appliesToFuture: appliesToFuture,
            date: date,
            location: location
        )]
        return fixed
    }

    /// The clean text live dictation produced: the text kept aside by "Run cleanup again", or
    /// else the clean text with every word fix undone. When a fix can't be undone, the current
    /// clean text is the closest available.
    var liveCleanText: String {
        if let originalCleanText { return originalCleanText }
        var entry = self
        while entry.fixes?.isEmpty == false {
            guard let undone = try? entry.undoingLastWordFix() else { return cleanText }
            entry = undone
        }
        return entry.cleanText
    }

    /// The word correction that makes the newest fix in later dictations, in every app.
    ///
    /// A word fixed at the start of a sentence was capitalized because of where it stood. When
    /// the replacement there is an ordinary word (its lowercase form is a common English word),
    /// the correction is saved in lowercase, and cleanup capitalizes it again at the start of a
    /// sentence. Any other replacement, such as a name, keeps the casing the person typed, and so
    /// does every fix made mid-sentence.
    /// A dictation copied from a password field has none.
    public func futureCorrectionForLastFix() -> LexiconEntry? {
        guard concealedCopy != true, let fix = fixes?.last else { return nil }
        var term = fix.original
        var preferred = fix.replacement
        let utf16 = cleanText.utf16
        if let location = fix.location, location >= 0, location <= utf16.count,
           let start = utf16.index(utf16.startIndex, offsetBy: location).samePosition(in: cleanText),
           WordFixLocator.isSentenceStart(start, in: cleanText),
           preferred.first?.isUppercase == true,
           CommonEnglishWords.contains(preferred) {
            preferred = Self.lowercasingFirstLetter(preferred)
            term = Self.lowercasingFirstLetter(term)
        }
        return LexiconEntry(term: term, preferred: preferred, scope: .global)
    }

    private static func lowercasingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// This entry with its most recent fix reverted and removed.
    public func undoingLastWordFix() throws -> TranscriptEntry {
        guard var remaining = fixes, let last = remaining.popLast() else {
            throw WordFixError.nothingToUndo
        }
        let range: Range<String.Index>
        if let location = last.location {
            let utf16 = cleanText.utf16
            let end = location + last.replacement.utf16.count
            guard location >= 0, end <= utf16.count,
                  let start = utf16.index(utf16.startIndex, offsetBy: location).samePosition(in: cleanText),
                  let stop = utf16.index(utf16.startIndex, offsetBy: end).samePosition(in: cleanText),
                  cleanText[start..<stop] == last.replacement
            else {
                throw WordFixError.fixNoLongerApplies
            }
            range = start..<stop
        } else {
            let matches = WordFixLocator.ranges(of: last.replacement, in: cleanText)
            guard matches.count == 1 else { throw WordFixError.fixNoLongerApplies }
            range = matches[0]
        }

        var undone = self
        undone.cleanText.replaceSubrange(range, with: last.original)
        undone.fixes = remaining.isEmpty ? nil : remaining
        return undone
    }
}
