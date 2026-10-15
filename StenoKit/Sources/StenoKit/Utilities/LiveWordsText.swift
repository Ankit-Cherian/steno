import Foundation

/// Shared rules for showing words while someone is still speaking, used by the window's live
/// stage and by the island: runs of whitespace read as one space, only the newest words are kept
/// (a wide character counts double), and right-to-left text is recognised by its first letter.
/// Each call reads only the end of the words, so an hour's dictation costs the same as a
/// sentence.
public enum LiveWordsText {
    /// Runs of spaces, tabs and line breaks become one space; a leading one is kept unless
    /// `trimsLeading`.
    public static func collapsed<S: StringProtocol>(_ text: S, trimsLeading: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace, !(result.isEmpty && trimsLeading) { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        if pendingSpace, !(result.isEmpty && trimsLeading) { result.append(" ") }
        return result
    }

    /// Whether the first letter of `text` is from a right-to-left script (Hebrew, Arabic, Syriac,
    /// Thaana, N’Ko and their presentation forms), so its lines start at the right.
    public static func isRightToLeft<S: StringProtocol>(_ text: S) -> Bool {
        for scalar in text.unicodeScalars.prefix(400) where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
            default: return false
            }
        }
        return false
    }

    /// Two for a character drawn about twice as wide as a Latin letter (CJK, kana, Hangul,
    /// full-width forms, emoji), otherwise one.
    public static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// The newest words that fit `limit`: the settled words and the part that may still change,
    /// whitespace collapsed, cut from the front on a word boundary and led by an ellipsis when
    /// something was cut.
    public static func newest(stable: String, tail: String, limit: Int) -> (stable: String, tail: String) {
        // Only the end can be shown, and an hour's words arrive here a few times a second.
        let stableStart = stable.index(stable.endIndex, offsetBy: -4 * limit, limitedBy: stable.startIndex) ?? stable.startIndex
        let tailStart = tail.index(tail.endIndex, offsetBy: -4 * limit, limitedBy: tail.startIndex) ?? tail.startIndex
        let shownStable = collapsed(stable[stableStart...], trimsLeading: true)
        let shownTail = collapsed(tail[tailStart...], trimsLeading: shownStable.isEmpty)
        let keptTail = suffix(of: shownTail, within: limit)
        if keptTail.wasCut || tailStart > tail.startIndex { return ("", "…" + trimmedToWord(keptTail.text)) }
        let keptStable = suffix(of: shownStable, within: limit - keptTail.width)
        if keptStable.wasCut || stableStart > stable.startIndex { return ("…" + trimmedToWord(keptStable.text), shownTail) }
        return (shownStable, shownTail)
    }

    /// The end of `text` that fits `budget`, its width, and whether anything was left out.
    private static func suffix(of text: String, within budget: Int) -> (text: String, width: Int, wasCut: Bool) {
        var width = 0
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            let next = width + self.width(of: text[previous])
            if next > budget { break }
            width = next
            start = previous
        }
        return (String(text[start...]), width, start > text.startIndex)
    }

    /// Drops a partly cut first word. Only leading space goes: a trailing one still separates
    /// the settled words from the part that may change.
    private static func trimmedToWord(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace,
              let space = text.firstIndex(where: \.isWhitespace) else { return String(text.drop(while: \.isWhitespace)) }
        return String(text[space...].drop(while: \.isWhitespace))
    }
}
