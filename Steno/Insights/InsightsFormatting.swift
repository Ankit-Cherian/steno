import os
import SwiftUI

enum InsightsFormatting {
    /// A count with its noun in the matching singular or plural form, such as
    /// "1 session" or "1,234 sessions".
    static func count(_ value: Int, _ noun: String, locale: Locale = .autoupdatingCurrent) -> String {
        // Grammatical agreement is slow to compute, and the same few counts are asked for on
        // every redraw.
        let key = "\(value)|\(noun)|\(locale.identifier)"
        if let cached = countMemo.withLock({ $0[key] }) { return cached }
        let text = String(AttributedString(localized: "^[\(value) \(noun)](inflect: true)", locale: locale).characters)
        countMemo.withLock { memo in
            if memo.count > 512 { memo.removeAll() }
            memo[key] = text
        }
        return text
    }

    private static let countMemo = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
}
