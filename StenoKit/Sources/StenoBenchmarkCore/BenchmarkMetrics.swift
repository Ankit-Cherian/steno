import Foundation

public struct TextNormalizer: Sendable {
    private let policy: NormalizationPolicy

    public init(policy: NormalizationPolicy) {
        self.policy = policy
    }

    public func normalize(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "\n", with: " ")

        if policy.lowercase {
            output = output.lowercased()
        }

        if policy.stripPunctuation {
            let punctuationPattern = policy.keepApostrophes
                ? "[^\\p{L}\\p{N}\\s']+"
                : "[^\\p{L}\\p{N}\\s]+"
            output = output.replacingOccurrences(
                of: punctuationPattern,
                with: " ",
                options: .regularExpression
            )
        }

        if policy.collapseWhitespace {
            output = output.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
        }

        if policy.trimWhitespace {
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return output
    }
}

public struct MetricTotals: Sendable {
    public var wordEdits: Int = 0
    public var wordReferenceCount: Int = 0
    public var charEdits: Int = 0
    public var charReferenceCount: Int = 0

    public init() {}

    public mutating func add(_ metrics: BenchmarkTextQualityMetrics) {
        wordEdits += metrics.wordEdits
        wordReferenceCount += metrics.wordReferenceCount
        charEdits += metrics.charEdits
        charReferenceCount += metrics.charReferenceCount
    }

    public func wer() -> Double? {
        guard wordReferenceCount > 0 else { return nil }
        return Double(wordEdits) / Double(wordReferenceCount)
    }

    public func cer() -> Double? {
        guard charReferenceCount > 0 else { return nil }
        return Double(charEdits) / Double(charReferenceCount)
    }
}

public enum BenchmarkScorer {
    public static func score(
        reference: String,
        hypothesis: String,
        normalizer: TextNormalizer
    ) -> BenchmarkTextQualityMetrics {
        let normalizedReference = normalizer.normalize(reference)
        let normalizedHypothesis = normalizer.normalize(hypothesis)

        let referenceWords = tokenizeWords(normalizedReference)
        let hypothesisWords = tokenizeWords(normalizedHypothesis)

        let referenceCharacters = tokenizeCharacters(normalizedReference)
        let hypothesisCharacters = tokenizeCharacters(normalizedHypothesis)

        let wordEdits = levenshteinDistance(referenceWords, hypothesisWords)
        let charEdits = levenshteinDistance(referenceCharacters, hypothesisCharacters)

        let wer = referenceWords.isEmpty
            ? (hypothesisWords.isEmpty ? 0 : 1)
            : Double(wordEdits) / Double(referenceWords.count)
        let cer = referenceCharacters.isEmpty
            ? (hypothesisCharacters.isEmpty ? 0 : 1)
            : Double(charEdits) / Double(referenceCharacters.count)

        return BenchmarkTextQualityMetrics(
            wer: wer,
            cer: cer,
            wordEdits: wordEdits,
            wordReferenceCount: referenceWords.count,
            charEdits: charEdits,
            charReferenceCount: referenceCharacters.count
        )
    }

    public static func tokenizeWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func tokenizeCharacters(_ text: String) -> [Character] {
        text.filter { !$0.isWhitespace }.map { $0 }
    }

    public static func containsWholeWordOrPhrase(
        in text: String,
        term: String
    ) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.contains(trimmed)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    public static func percentile(_ values: [Int], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let bounded = min(max(percentile, 0), 1)
        let rank = Int(ceil(bounded * Double(sorted.count))) - 1
        let index = min(max(rank, 0), sorted.count - 1)
        return Double(sorted[index])
    }

    public static func mean(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func levenshteinDistance<Element: Equatable>(
        _ lhs: [Element],
        _ rhs: [Element]
    ) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for (i, left) in lhs.enumerated() {
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                let cost = left == right ? 0 : 1
                let deletion = previous[j + 1] + 1
                let insertion = current[j] + 1
                let substitution = previous[j] + cost
                current[j + 1] = min(deletion, insertion, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
