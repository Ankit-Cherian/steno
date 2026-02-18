import Foundation

enum TokenEstimator {
    static func estimatedTokens(for text: String) -> Int {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(1, Int(Double(wordCount) * 1.35))
    }
}
