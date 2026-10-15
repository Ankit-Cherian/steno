import Foundation

/// What happened to one dictation on this Mac, step by step. Every field is optional so a record
/// written by a newer version, or missing a step, still decodes. Holds no audio and no editor
/// context.
public struct DictationRecord: Sendable, Codable, Equatable {
    /// The record's format. 1 for records with every field below.
    public var schemaVersion: Int?
    /// Identifies the dictation attempt. It is the session ID created when capture started.
    public var attemptID: UUID?
    /// "inserted", "pasted", "copied", "notPasted", "failed" or "noSpeech". A string, so another
    /// value written by a newer version still decodes.
    public var outcome: String?
    /// Why the text was copied instead of inserted, as a `CopyReason` raw value. Nil unless the
    /// outcome is "copied" and the insertion said why.
    public var copyReason: String?
    public var recordingMS: Int?
    public var transcriptionMS: Int?
    public var cleanupMS: Int?
    public var insertionMS: Int?
    /// From the request to stop recording to insertion finished.
    public var endToEndMS: Int?
    public var microphoneName: String?
    /// The speech model's display name, such as "Small".
    public var modelName: String?
    /// The speech model file's identifier, such as "ggml-small.en".
    public var modelID: String?
    /// The recognition language requested, such as "en-US".
    public var language: String?
    /// Whether voice detection was turned on.
    public var vadEnabled: Bool?
    /// The filler-removal setting cleanup used, as its raw value.
    public var cleanupStyle: String?
    /// "typed", "accessibility", "pasted" or "copied". A string, not an enum, so a value written by
    /// a newer version never fails to decode.
    public var insertionMethod: String?
    public var appName: String?
    public var appBundleID: String?
    public var cleanupChanges: [CleanupChangeRecord]?
    /// How many changes cleanup made in all, when `cleanupChanges` holds only the first
    /// `CleanupChangeRecord.maximumCount` of them. Nil in a record written before this field existed.
    public var cleanupChangeCount: Int?
    /// True when the text before and after cleanup was too long to compare, so `cleanupChanges`
    /// is empty because nothing was compared, not because nothing changed. Nil otherwise.
    public var cleanupComparisonSkipped: Bool?

    /// The current `schemaVersion`.
    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int? = nil,
        attemptID: UUID? = nil,
        outcome: String? = nil,
        copyReason: String? = nil,
        recordingMS: Int? = nil,
        transcriptionMS: Int? = nil,
        cleanupMS: Int? = nil,
        insertionMS: Int? = nil,
        endToEndMS: Int? = nil,
        microphoneName: String? = nil,
        modelName: String? = nil,
        modelID: String? = nil,
        language: String? = nil,
        vadEnabled: Bool? = nil,
        cleanupStyle: String? = nil,
        insertionMethod: String? = nil,
        appName: String? = nil,
        appBundleID: String? = nil,
        cleanupChanges: [CleanupChangeRecord]? = nil,
        cleanupChangeCount: Int? = nil,
        cleanupComparisonSkipped: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.attemptID = attemptID
        self.outcome = outcome
        self.copyReason = copyReason
        self.recordingMS = recordingMS
        self.transcriptionMS = transcriptionMS
        self.cleanupMS = cleanupMS
        self.insertionMS = insertionMS
        self.endToEndMS = endToEndMS
        self.microphoneName = microphoneName
        self.modelName = modelName
        self.modelID = modelID
        self.language = language
        self.vadEnabled = vadEnabled
        self.cleanupStyle = cleanupStyle
        self.insertionMethod = insertionMethod
        self.appName = appName
        self.appBundleID = appBundleID
        self.cleanupChanges = cleanupChanges
        self.cleanupChangeCount = cleanupChangeCount
        self.cleanupComparisonSkipped = cleanupComparisonSkipped
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, attemptID, outcome, copyReason
        case recordingMS, transcriptionMS, cleanupMS, insertionMS, endToEndMS
        case microphoneName, modelName, modelID, language, vadEnabled, cleanupStyle
        case insertionMethod, appName, appBundleID, cleanupChanges
        case cleanupChangeCount, cleanupComparisonSkipped
    }

    /// A field that can't be read is left out instead of failing the whole record. A field that
    /// can't be read, a change that can't be read, or a record from a newer format is reported as
    /// a replaced value, so History keeps a copy of the original file before rewriting it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            do {
                return try container.decodeIfPresent(T.self, forKey: key)
            } catch {
                decoder.recordReplacedValue()
                return nil
            }
        }
        schemaVersion = field(.schemaVersion)
        attemptID = field(.attemptID)
        outcome = field(.outcome)
        copyReason = field(.copyReason)
        recordingMS = field(.recordingMS)
        transcriptionMS = field(.transcriptionMS)
        cleanupMS = field(.cleanupMS)
        insertionMS = field(.insertionMS)
        endToEndMS = field(.endToEndMS)
        microphoneName = field(.microphoneName)
        modelName = field(.modelName)
        modelID = field(.modelID)
        language = field(.language)
        vadEnabled = field(.vadEnabled)
        cleanupStyle = field(.cleanupStyle)
        insertionMethod = field(.insertionMethod)
        appName = field(.appName)
        appBundleID = field(.appBundleID)
        do {
            cleanupChanges = try container.decodeLossyDetailsIfPresent(
                of: CleanupChangeRecord.self,
                forKey: .cleanupChanges
            )
        } catch {
            decoder.recordReplacedValue()
            cleanupChanges = nil
        }
        if let decoded = cleanupChanges, decoded.count > CleanupChangeRecord.maximumCount {
            cleanupChanges = Array(decoded.prefix(CleanupChangeRecord.maximumCount))
            decoder.recordReplacedValue()
        }
        cleanupChangeCount = field(.cleanupChangeCount)
        cleanupComparisonSkipped = field(.cleanupComparisonSkipped)
        if let schemaVersion, schemaVersion > Self.currentSchemaVersion {
            decoder.recordReplacedValue()
        }
    }

    /// The outcome of a paste skipped because another app wrote to the clipboard first.
    public static let notPastedOutcome = "notPasted"

    /// The record's outcome for an insertion result.
    public static func outcomeName(for result: InsertResult) -> String {
        switch result.status {
        case .inserted:
            return result.method == .clipboardPaste ? "pasted" : "inserted"
        case .copiedOnly:
            if result.pasteAttempted == true { return "pasted" }
            // Another app wrote to the clipboard first, so nothing was pasted or left copied.
            return result.copyReason == .clipboardChanged ? notPastedOutcome : "copied"
        case .failed:
            return "failed"
        case .noSpeech:
            return "noSpeech"
        }
    }

    /// The record's copy reason for an insertion result: a `CopyReason` raw value when the text
    /// was copied for a known reason, otherwise nil.
    public static func copyReasonName(for result: InsertResult) -> String? {
        guard outcomeName(for: result) == "copied", let reason = result.copyReason else { return nil }
        return CopyReason(reason).rawValue
    }

    /// The record's name for how text reached the app, or nil when it didn't.
    public static func insertionMethodName(for result: InsertResult) -> String? {
        switch result.status {
        case .inserted:
            switch result.method {
            case .direct: return "typed"
            case .accessibility: return "accessibility"
            case .clipboardPaste: return "pasted"
            case .none: return nil
            }
        case .copiedOnly:
            if result.pasteAttempted == true { return "pasted" }
            return result.copyReason == .clipboardChanged ? nil : "copied"
        case .failed, .noSpeech:
            return nil
        }
    }
}

/// One thing cleanup removed, added or replaced.
public struct CleanupChangeRecord: Sendable, Codable, Equatable {
    /// "removed", "added" or "replaced".
    public var kind: String
    public var before: String?
    public var after: String?

    public init(kind: String, before: String?, after: String?) {
        self.kind = kind
        self.before = before
        self.after = after
    }

    enum CodingKeys: String, CodingKey {
        case kind, before, after
    }

    /// A side longer than `maximumSideLength` is shortened, and reported as a replaced value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        let before = try container.decodeIfPresent(String.self, forKey: .before)
        let after = try container.decodeIfPresent(String.self, forKey: .after)
        self.before = before.map(Self.bounded)
        self.after = after.map(Self.bounded)
        if self.before != before || self.after != after {
            decoder.recordReplacedValue()
        }
    }

    /// `text`, shortened with an ellipsis to `maximumSideLength` characters when longer.
    static func bounded(_ text: String) -> String {
        guard text.count > maximumSideLength else { return text }
        return String(text.prefix(maximumSideLength - 1)) + "\u{2026}"
    }

    /// The most changes one record keeps.
    public static let maximumCount = 24
    /// The most characters kept on either side of a change, including the ellipsis.
    public static let maximumSideLength = 40

    /// The most words and marks, before and after cleanup together, compared after the
    /// unchanged start and end are set aside. Above it, the comparison is skipped so a long
    /// dictation that changed throughout never holds up saving it.
    public static let maximumComparedTokens = 3_000

    /// Compares the text before cleanup with the text after it, word by word, and lists what
    /// changed in reading order. Punctuation marks count as words of their own, so added
    /// punctuation reads as an addition. Spacing differences are ignored. Returns nil when the
    /// changed region is longer than `maximumComparedTokens`.
    public static func changes(from before: String, to after: String) -> [CleanupChangeRecord]? {
        compare(from: before, to: after).changes
    }

    /// What `compare(from:to:)` found: the first `maximumCount` changes and how many there were
    /// in all, or neither when the texts were too long to compare.
    public struct Comparison: Sendable, Equatable {
        /// The first `maximumCount` changes in reading order. Nil when the comparison was skipped.
        public var changes: [CleanupChangeRecord]?
        /// Every change found, which can exceed `changes.count`. Nil when the comparison was skipped.
        public var changeCount: Int?

        /// Whether the texts were too long to compare.
        public var wasSkipped: Bool { changes == nil }
    }

    /// Like `changes(from:to:)`, and also counts the changes past the ones kept.
    public static func compare(from before: String, to after: String) -> Comparison {
        let old = tokens(in: before)
        let new = tokens(in: after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].text == new[prefix].text {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix].text == new[new.count - 1 - suffix].text {
            suffix += 1
        }
        let oldMiddle = old[prefix..<(old.count - suffix)].map(\.text)
        let newMiddle = new[prefix..<(new.count - suffix)].map(\.text)
        guard oldMiddle.count + newMiddle.count <= maximumComparedTokens else {
            return Comparison(changes: nil, changeCount: nil)
        }

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(prefix + offset)
            case .insert(let offset, _, _): insertedOffsets.insert(prefix + offset)
            }
        }

        var changes: [CleanupChangeRecord] = []
        var changeCount = 0
        func note(_ change: CleanupChangeRecord) {
            changeCount += 1
            if changes.count < maximumCount { changes.append(change) }
        }
        // The unchanged start and end need no walk.
        var oldIndex = prefix
        var newIndex = prefix
        while oldIndex < old.count - suffix || newIndex < new.count - suffix {
            let removedStart = oldIndex
            while oldIndex < old.count, removedOffsets.contains(oldIndex) { oldIndex += 1 }
            let insertedStart = newIndex
            while newIndex < new.count, insertedOffsets.contains(newIndex) { newIndex += 1 }

            let removed = span(old[removedStart..<oldIndex], in: before)
            let inserted = span(new[insertedStart..<newIndex], in: after)
            switch (removed, inserted) {
            case let (removed?, inserted?):
                note(CleanupChangeRecord(kind: "replaced", before: removed, after: inserted))
            case let (removed?, nil):
                note(CleanupChangeRecord(kind: "removed", before: removed, after: nil))
            case let (nil, inserted?):
                note(CleanupChangeRecord(kind: "added", before: nil, after: inserted))
            case (nil, nil):
                // An unchanged word in both texts.
                oldIndex += 1
                newIndex += 1
            }
        }
        return Comparison(changes: changes, changeCount: changeCount)
    }

    private struct Token {
        var text: String
        var range: Range<String.Index>
    }

    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }
            let start = index
            if WordFixLocator.isWordCharacter(character) {
                while index < text.endIndex, WordFixLocator.isWordCharacter(text[index]) {
                    index = text.index(after: index)
                }
            } else {
                index = text.index(after: index)
            }
            tokens.append(Token(text: String(text[start..<index]), range: start..<index))
        }
        return tokens
    }

    /// The source text the tokens cover, with its own spacing, shortened to fit.
    private static func span(_ tokens: ArraySlice<Token>, in text: String) -> String? {
        guard let first = tokens.first, let last = tokens.last else { return nil }
        return bounded(String(text[first.range.lowerBound..<last.range.upperBound]))
    }
}

/// Settings a dictation's record names, fixed for the life of one dictation runtime.
public struct DictationRecordSettings: Sendable, Equatable {
    public var modelName: String?
    public var modelID: String?
    public var vadEnabled: Bool?

    public init(modelName: String? = nil, modelID: String? = nil, vadEnabled: Bool? = nil) {
        self.modelName = modelName
        self.modelID = modelID
        self.vadEnabled = vadEnabled
    }
}
