import Foundation

/// Counts words for display. Text is split at whitespace, and each piece in a script written
/// without spaces between words (Chinese, Japanese, Thai and their neighbours) is split again
/// with the system's word breaking, so “我们明天开会” counts as three words instead of one. Pieces
/// in other scripts count as one word each, exactly as a whitespace split does.
///
/// Only for counts people read. Counts kept in the usage ledger have their own rule.
public enum WordCount {
    public static func count<S: StringProtocol>(_ text: S) -> Int {
        var total = 0
        for piece in text.split(whereSeparator: \.isWhitespace) {
            guard needsWordBreaking(piece) else {
                total += 1
                continue
            }
            let string = String(piece)
            var words = 0
            string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                words += 1
            }
            // A piece is always at least one word, as it was before, even when it holds only
            // marks the system doesn't count.
            total += max(1, words)
        }
        return total
    }

    /// Whether `piece` holds a letter from a script written without spaces between words.
    static func needsWordBreaking<T: StringProtocol>(_ piece: T) -> Bool {
        piece.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, // Thai, Lao
                 0x1000...0x109F, // Myanmar
                 0x1100...0x11FF, // Hangul Jamo
                 0x1780...0x17FF, // Khmer
                 0x3040...0x30FF, // Hiragana, Katakana
                 0x3130...0x318F, // Hangul Compatibility Jamo
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0xFF66...0xFF9F, // Halfwidth Katakana
                 0x20000...0x323AF: // CJK Extensions B to H
                true
            default:
                false
            }
        }
    }
}
