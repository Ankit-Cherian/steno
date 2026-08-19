import Foundation

public enum DictationLowercaseDirectiveKind: Sendable, Equatable {
    case none
    case lowercase
    case literalEscape
}

/// A directive decision made before general cleanup changes command boundaries.
/// `textForCleanup` is the only text that should enter the normal final cleanup pipeline.
public struct DictationDirectivePlan: Sendable, Equatable {
    public var kind: DictationLowercaseDirectiveKind
    public var textForCleanup: String

    public init(kind: DictationLowercaseDirectiveKind, textForCleanup: String) {
        self.kind = kind
        self.textForCleanup = textForCleanup
    }
}

public enum ContinuationBoundaryStyle: Sendable, Equatable {
    case usesInterwordSpacing
    case doesNotUseInterwordSpacing
    case unknown
}

/// Ephemeral editor text used only to shape the final insertion payload.
///
/// This deliberately does not conform to `Codable`: nearby editor content must not be
/// persisted in requests, history, analytics, diagnostics, or benchmark artifacts.
public struct ContinuationContextSnapshot: Sendable, Equatable {
    public var targetIdentityToken: String
    public var leadingText: String
    public var trailingText: String
    public var boundaryStyle: ContinuationBoundaryStyle
    public var allowsAutomaticContinuation: Bool

    public init(
        targetIdentityToken: String,
        leadingText: String,
        trailingText: String,
        boundaryStyle: ContinuationBoundaryStyle,
        allowsAutomaticContinuation: Bool = true
    ) {
        self.targetIdentityToken = targetIdentityToken
        self.leadingText = leadingText
        self.trailingText = trailingText
        self.boundaryStyle = boundaryStyle
        self.allowsAutomaticContinuation = allowsAutomaticContinuation
    }
}

public enum ContinuationContextState: Sendable, Equatable {
    case unavailable
    case drifted
    case validated(ContinuationContextSnapshot)
}

public enum ContinuationCaseDecision: Sendable, Equatable {
    case notConsidered
    case preservedSentenceStart
    case preservedUnsafeOpening
    case lowercasedOrdinaryOpening
}

public struct ContinuationInsertionResult: Sendable, Equatable {
    public var text: String
    public var caseDecision: ContinuationCaseDecision
    public var insertedLeadingSpace: Bool
    public var insertedTrailingSpace: Bool

    public init(
        text: String,
        caseDecision: ContinuationCaseDecision,
        insertedLeadingSpace: Bool,
        insertedTrailingSpace: Bool
    ) {
        self.text = text
        self.caseDecision = caseDecision
        self.insertedLeadingSpace = insertedLeadingSpace
        self.insertedTrailingSpace = insertedTrailingSpace
    }
}

/// Pure, deterministic policy for the explicit lowercase directive and nearby-text continuation.
public struct DictationContinuationPolicy: Sendable {
    private static let defaultOrdinaryTitlecaseOpenings: Set<String> = [
        "A", "An", "It", "That", "The", "These", "They", "This", "Those", "We", "You",
    ]

    private let ordinaryTitlecaseOpenings: Set<String>

    public init(ordinaryTitlecaseOpenings: Set<String>? = nil) {
        self.ordinaryTitlecaseOpenings = ordinaryTitlecaseOpenings
            ?? Self.defaultOrdinaryTitlecaseOpenings
    }

    /// Detects reserved-prefix intent against the ASR result before general cleanup.
    /// Only leading whitespace is ignored for recognition.
    public func prepareDirective(in recognizedText: String) -> DictationDirectivePlan {
        let recognitionStart = recognizedText.firstIndex(where: { !$0.isWhitespace })
            ?? recognizedText.endIndex
        let candidate = recognizedText[recognitionStart...]

        // The escape is intentionally evaluated before the reserved directive.
        if let afterLiteral = consumeLeadingToken("literal", in: candidate),
           let afterLowercase = consumeLeadingToken("lowercase", in: afterLiteral),
           let payload = nonemptyPayload(in: afterLowercase)
        {
            return DictationDirectivePlan(
                kind: .literalEscape,
                textForCleanup: "lowercase " + payload
            )
        }

        if let afterLowercase = consumeLeadingToken("lowercase", in: candidate),
           let payload = nonemptyPayload(in: afterLowercase),
           containsCasedGrapheme(payload)
        {
            return DictationDirectivePlan(kind: .lowercase, textForCleanup: payload)
        }

        return DictationDirectivePlan(kind: .none, textForCleanup: recognizedText)
    }

    /// Applies the already-frozen directive to text after the normal final cleanup pipeline.
    public func applyDirective(
        _ plan: DictationDirectivePlan,
        toCleanedText cleanedText: String
    ) -> String {
        switch plan.kind {
        case .none:
            return cleanedText
        case .lowercase:
            return lowercasingFirstCasedGrapheme(in: cleanedText)
        case .literalEscape:
            return normalizingIntactLiteralEscape(in: cleanedText)
        }
    }

    /// Shapes only the ephemeral insertion payload. Callers retain their original raw and clean text.
    public func shapeInsertionPayload(
        cleanedText: String,
        context: ContinuationContextState,
        protectedTerms: Set<String> = []
    ) -> ContinuationInsertionResult {
        guard case .validated(let snapshot) = context,
              snapshotAllowsPolicy(snapshot)
        else {
            return unchanged(cleanedText)
        }

        var insertion = cleanedText
        let midSentence = stronglyProvesMidSentence(snapshot.leadingText)
        var caseDecision: ContinuationCaseDecision = midSentence
            ? .preservedUnsafeOpening
            : .preservedSentenceStart

        if midSentence,
           let opening = safeOrdinaryOpening(in: insertion, protectedTerms: protectedTerms)
        {
            insertion.replaceSubrange(
                opening.firstGraphemeRange,
                with: String(insertion[opening.firstGraphemeRange]).lowercased()
            )
            caseDecision = .lowercasedOrdinaryOpening
        }

        let addLeading = needsLeadingSpace(
            between: snapshot.leadingText,
            and: insertion
        )
        if addLeading {
            insertion.insert(" ", at: insertion.startIndex)
        }

        let addTrailing = needsTrailingSpace(
            between: insertion,
            and: snapshot.trailingText
        )
        if addTrailing {
            insertion.append(" ")
        }

        return ContinuationInsertionResult(
            text: insertion,
            caseDecision: caseDecision,
            insertedLeadingSpace: addLeading,
            insertedTrailingSpace: addTrailing
        )
    }

    private func unchanged(_ text: String) -> ContinuationInsertionResult {
        ContinuationInsertionResult(
            text: text,
            caseDecision: .notConsidered,
            insertedLeadingSpace: false,
            insertedTrailingSpace: false
        )
    }

    private func consumeLeadingToken(
        _ expected: String,
        in text: Substring
    ) -> Substring? {
        guard let whitespaceIndex = text.firstIndex(where: \.isWhitespace) else {
            return nil
        }
        let token = text[..<whitespaceIndex]
        guard String(token).lowercased() == expected else {
            return nil
        }
        let remainder = text[whitespaceIndex...]
        guard let nextTokenStart = remainder.firstIndex(where: { !$0.isWhitespace }) else {
            return text[text.endIndex...]
        }
        return text[nextTokenStart...]
    }

    private func nonemptyPayload(in text: Substring) -> String? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        return String(text[start...])
    }

    private func containsCasedGrapheme(_ text: String) -> Bool {
        text.contains { grapheme in
            let value = String(grapheme)
            return value.lowercased() != value.uppercased()
        }
    }

    private func lowercasingFirstCasedGrapheme(in text: String) -> String {
        guard let index = text.firstIndex(where: { grapheme in
            let value = String(grapheme)
            return value.lowercased() != value.uppercased()
        }) else {
            return text
        }

        var result = text
        let next = result.index(after: index)
        result.replaceSubrange(index..<next, with: String(result[index..<next]).lowercased())
        return result
    }

    private func normalizingIntactLiteralEscape(in text: String) -> String {
        guard let whitespaceIndex = text.firstIndex(where: \.isWhitespace) else {
            return text
        }
        let token = text[..<whitespaceIndex]
        guard String(token).lowercased() == "lowercase",
              text[whitespaceIndex...].contains(where: { !$0.isWhitespace })
        else {
            return text
        }

        var result = text
        result.replaceSubrange(result.startIndex..<whitespaceIndex, with: "lowercase")
        return result
    }

    private func snapshotAllowsPolicy(_ snapshot: ContinuationContextSnapshot) -> Bool {
        guard snapshot.allowsAutomaticContinuation,
              snapshot.boundaryStyle == .usesInterwordSpacing,
              !snapshot.targetIdentityToken.isEmpty,
              snapshot.leadingText.utf16.count <= 512,
              snapshot.trailingText.utf16.count <= 512,
              snapshot.leadingText.count <= 256,
              snapshot.trailingText.count <= 256,
              snapshot.leadingText.utf8.count + snapshot.trailingText.utf8.count <= 8_192
        else {
            return false
        }
        return true
    }

    private func stronglyProvesMidSentence(_ leadingText: String) -> Bool {
        let trailingWhitespace = leadingText.reversed().prefix(while: \.isWhitespace)
        if trailingWhitespace.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return false
        }

        if endsAtListBoundary(leadingText) {
            return false
        }

        let trimmed = leadingText.dropLast(trailingWhitespace.count)
        guard !trimmed.isEmpty else { return false }

        var cursor = trimmed.endIndex
        var decisive = trimmed[trimmed.index(before: cursor)]
        while Self.sentenceClosingPunctuation.contains(decisive) {
            cursor = trimmed.index(before: cursor)
            guard cursor > trimmed.startIndex else { return false }
            decisive = trimmed[trimmed.index(before: cursor)]
        }

        if Self.terminalOrBoundaryPunctuation.contains(decisive) {
            return false
        }
        if decisive.isLetter || decisive.isNumber {
            return true
        }
        return Self.midSentencePunctuation.contains(decisive)
            || Self.closingPunctuation.contains(decisive)
    }

    private func endsAtListBoundary(_ text: String) -> Bool {
        let lastLine = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        ).last ?? ""
        let marker = String(lastLine).trimmingCharacters(in: .whitespaces)
        if ["-", "*", "+", "•", ">", "- [ ]", "- [x]", "- [X]"].contains(marker) {
            return true
        }
        guard let suffix = marker.last, suffix == "." || suffix == ")" else {
            return false
        }
        return marker.dropLast().allSatisfy { $0.isNumber } && marker.count > 1
    }

    private struct SafeOpening {
        var firstGraphemeRange: Range<String.Index>
    }

    private func safeOrdinaryOpening(
        in text: String,
        protectedTerms: Set<String>
    ) -> SafeOpening? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }),
              text[start].isLetter
        else {
            return nil
        }

        var tokenEnd = start
        while tokenEnd < text.endIndex, text[tokenEnd].isLetter {
            tokenEnd = text.index(after: tokenEnd)
        }
        let token = String(text[start..<tokenEnd])
        guard token != "I",
              isSimpleTitlecase(token),
              ordinaryTitlecaseOpenings.contains(token),
              !isProtectedOpening(text: text[start...], token: token, terms: protectedTerms),
              !isCodeLikeFirstUnit(in: text, from: start)
        else {
            return nil
        }

        return SafeOpening(firstGraphemeRange: start..<text.index(after: start))
    }

    private func isSimpleTitlecase(_ token: String) -> Bool {
        let cased = token.filter { grapheme in
            let value = String(grapheme)
            return value.lowercased() != value.uppercased()
        }
        guard let first = cased.first else { return false }
        let firstValue = String(first)
        guard firstValue == firstValue.uppercased(),
              firstValue != firstValue.lowercased()
        else {
            return false
        }
        return cased.dropFirst().allSatisfy { grapheme in
            let value = String(grapheme)
            return value == value.lowercased() && value != value.uppercased()
        }
    }

    private func isProtectedOpening(
        text: Substring,
        token: String,
        terms: Set<String>
    ) -> Bool {
        let foldedText = String(text).folding(options: [.caseInsensitive], locale: nil)
        let foldedToken = token.folding(options: [.caseInsensitive], locale: nil)

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let foldedTerm = trimmed.folding(options: [.caseInsensitive], locale: nil)
            guard foldedText.hasPrefix(foldedTerm) else { continue }

            let boundary = foldedText.index(foldedText.startIndex, offsetBy: foldedTerm.count)
            if boundary == foldedText.endIndex || !foldedText[boundary].isLetter {
                return true
            }
        }

        return terms.contains(where: {
            $0.folding(options: [.caseInsensitive], locale: nil) == foldedToken
        })
    }

    private func isCodeLikeFirstUnit(in text: String, from start: String.Index) -> Bool {
        let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        let unit = text[start..<end]
        return unit.contains(where: { Self.codeLikeCharacters.contains($0) })
            || unit.contains(where: \.isNumber)
    }

    private func needsLeadingSpace(between leadingText: String, and insertion: String) -> Bool {
        guard let left = leadingText.last,
              let right = insertion.first,
              !left.isWhitespace,
              !right.isWhitespace,
              !Self.openingPunctuation.contains(left),
              !Self.closingPunctuation.contains(right),
              left.isLetter || left.isNumber || Self.closingPunctuation.contains(left)
        else {
            return false
        }
        return right.isLetter || right.isNumber || Self.openingPunctuation.contains(right)
    }

    private func needsTrailingSpace(between insertion: String, and trailingText: String) -> Bool {
        guard let left = insertion.last,
              let right = trailingText.first,
              !left.isWhitespace,
              !right.isWhitespace,
              !Self.closingPunctuation.contains(right),
              !Self.openingPunctuation.contains(left)
        else {
            return false
        }
        return (left.isLetter || left.isNumber || Self.closingPunctuation.contains(left))
            && (right.isLetter || right.isNumber || Self.openingPunctuation.contains(right))
    }

    private static let terminalOrBoundaryPunctuation: Set<Character> = [
        ".", "?", "!", "…", ":",
    ]
    private static let midSentencePunctuation: Set<Character> = [
        ",", ";",
    ]
    private static let openingPunctuation: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "“", "‘",
    ]
    private static let closingPunctuation: Set<Character> = [
        ")", "]", "}", ">", ".", ",", "?", "!", ";", ":", "%", "\"", "'", "”", "’", "…",
    ]
    private static let sentenceClosingPunctuation: Set<Character> = [
        ")", "]", "}", "\"", "'", "”", "’",
    ]
    private static let codeLikeCharacters: Set<Character> = [
        ".", "/", "\\", "@", "_", ":", "=", "{", "}", "[", "]", "(", ")", "<", ">",
        "#", "$", "%", "&", "*", "+", "-", "`", "~",
    ]
}
