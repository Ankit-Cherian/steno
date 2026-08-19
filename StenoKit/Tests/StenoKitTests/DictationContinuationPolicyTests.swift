import Testing
@testable import StenoKit

@Test("Lowercase directive recognizes only the frozen leading grammar")
func lowercaseDirectiveRecognition() {
    let policy = DictationContinuationPolicy()
    let accepted: [(String, String)] = [
        ("lowercase Hello world", "Hello world"),
        ("LOWERCASE\tHello", "Hello"),
        ("  LowerCase\u{2003}Hello", "Hello"),
        ("lowercase \"Hello world\"", "\"Hello world\""),
        ("lowercase 42 😀 Hello", "42 😀 Hello"),
        ("lowercase ÉCOLE", "ÉCOLE"),
    ]

    for (input, payload) in accepted {
        let plan = policy.prepareDirective(in: input)
        #expect(plan.kind == .lowercase, "Input: \(input)")
        #expect(plan.textForCleanup == payload, "Input: \(input)")
    }
}

@Test("Lowercase directive preserves every form outside the frozen grammar")
func lowercaseDirectiveRejections() {
    let policy = DictationContinuationPolicy()
    let rejected = [
        "lowercase",
        "lowercase   ",
        "lowercase, hello",
        "use lowercase hello",
        "the word lowercase hello",
        "please lowercase Hello",
        "say lowercase Hello",
        "\"lowercase hello\"",
        "'lowercase hello'",
        "`lowercase hello`",
        "lowercase(Hello)",
        "lowercase 123 😀",
        "This says lowercase Hello",
    ]

    for input in rejected {
        let plan = policy.prepareDirective(in: input)
        #expect(plan == DictationDirectivePlan(kind: .none, textForCleanup: input), "Input: \(input)")
    }
}

@Test("Literal lowercase escape is recognized first and never invokes the directive")
func literalLowercaseEscape() {
    let policy = DictationContinuationPolicy()

    let plan = policy.prepareDirective(in: "  LiTeRaL\tlOwErCaSe\u{00A0}Hello NASA")
    #expect(plan.kind == .literalEscape)
    #expect(plan.textForCleanup == "lowercase Hello NASA")
    #expect(policy.applyDirective(plan, toCleanedText: "lowercase Hello NASA") == "lowercase Hello NASA")
    #expect(policy.applyDirective(plan, toCleanedText: "Lowercase Hello NASA") == "lowercase Hello NASA")

    let missingPayload = "literal lowercase"
    #expect(
        policy.prepareDirective(in: missingPayload)
            == DictationDirectivePlan(kind: .none, textForCleanup: missingPayload)
    )
}

@Test("Literal escape normalizes only an intact leading token after cleanup")
func literalLowercaseEscapePostCleanupSafety() {
    let policy = DictationContinuationPolicy()
    let plan = policy.prepareDirective(in: "literal lowercase Hello NASA")

    let normalized: [(String, String)] = [
        ("LOWERCASE\tHello NASA", "lowercase\tHello NASA"),
        ("Lowercase\u{00A0}Hello NASA", "lowercase\u{00A0}Hello NASA"),
        ("Lowercase \"Hello, NASA!\"", "lowercase \"Hello, NASA!\""),
    ]
    for (cleaned, expected) in normalized {
        #expect(policy.applyDirective(plan, toCleanedText: cleaned) == expected)
    }

    let failClosed = [
        " Lowercase Hello NASA",
        "Lowercase, Hello NASA",
        "Lowercase",
        "Lowercase   ",
        "Lower case Hello NASA",
        "Hello NASA",
        "\"Lowercase Hello NASA\"",
    ]
    for cleaned in failClosed {
        #expect(policy.applyDirective(plan, toCleanedText: cleaned) == cleaned)
    }
}

@Test("Directive lowercases only the first Unicode cased grapheme after cleanup")
func directiveLowercasesFirstCasedGraphemeOnly() {
    let policy = DictationContinuationPolicy()
    let examples: [(String, String)] = [
        ("\"Hello NASA\"", "\"hello NASA\""),
        ("42 😀 Hello NASA", "42 😀 hello NASA"),
        ("Sarah Chen", "sarah Chen"),
        ("NASA launch", "nASA launch"),
        ("ÉCOLE déjà", "éCOLE déjà"),
        ("E\u{301}COLE", "e\u{301}COLE"),
        ("I agree", "i agree"),
    ]

    for (cleaned, expected) in examples {
        let plan = DictationDirectivePlan(kind: .lowercase, textForCleanup: "unused")
        #expect(policy.applyDirective(plan, toCleanedText: cleaned) == expected, "Input: \(cleaned)")
    }
}

@Test("Directive intent remains frozen across normal cleanup")
func directiveCleanupOrdering() {
    let policy = DictationContinuationPolicy()
    let plan = policy.prepareDirective(in: "lowercase um Open paren project")

    // This stands in for the independently selected normal cleanup pipeline.
    let normallyCleanedPayload = "Open (project"
    #expect(plan.textForCleanup == "um Open paren project")
    #expect(policy.applyDirective(plan, toCleanedText: normallyCleanedPayload) == "open (project")

    let ordinary = policy.prepareDirective(in: "Use lowercase and say question mark")
    #expect(ordinary.kind == .none)
    #expect(policy.applyDirective(ordinary, toCleanedText: "Use lowercase and say ?") == "Use lowercase and say ?")
}

@Test("Automatic continuation lowercases a safe ordinary opening only in a proven continuation")
func automaticContinuationExample() {
    let policy = DictationContinuationPolicy()
    let snapshot = context(leading: "I think ", trailing: " is right.")

    let result = policy.shapeInsertionPayload(
        cleanedText: "This approach",
        context: .validated(snapshot)
    )

    #expect(result.text == "this approach")
    #expect(result.caseDecision == .lowercasedOrdinaryOpening)
    #expect("I think " + result.text + " is right." == "I think this approach is right.")
}

@Test("Automatic continuation preserves clear sentence and list starts")
func automaticContinuationPreservesStarts() {
    let policy = DictationContinuationPolicy()
    let starts = [
        "That failed. ",
        "She said, \"That failed.\" ",
        "Really? ",
        "Great! ",
        "Heading: ",
        "Paragraph one.\n",
        "- ",
        "• ",
        "- [ ] ",
        "1. ",
        "2) ",
    ]

    for leading in starts {
        let result = policy.shapeInsertionPayload(
            cleanedText: "We should retry",
            context: .validated(context(leading: leading))
        )
        #expect(result.text == "We should retry", "Leading: \(leading)")
        #expect(result.caseDecision == .preservedSentenceStart, "Leading: \(leading)")
    }
}

@Test("Automatic continuation fails closed for unsafe opening tokens")
func automaticContinuationPreservesUnsafeOpenings() {
    let policy = DictationContinuationPolicy()
    let unsafe = [
        "I agree",
        "NASA agrees",
        "eBay works",
        "StenoKit works",
        "Sarah Chen",
        "Https://example.com",
        "This_value",
        "This/path",
        "This2 works",
        "\"This is quoted\"",
        "😀 This starts later",
    ]

    for text in unsafe {
        let result = policy.shapeInsertionPayload(
            cleanedText: text,
            context: .validated(context(leading: "I think "))
        )
        #expect(result.text == text, "Input: \(text)")
        #expect(result.caseDecision == .preservedUnsafeOpening, "Input: \(text)")
    }
}

@Test("Lexicon and hot-term protection overrides the ordinary-opening allowlist")
func automaticContinuationProtectsTerms() {
    let policy = DictationContinuationPolicy()
    let result = policy.shapeInsertionPayload(
        cleanedText: "This Product",
        context: .validated(context(leading: "We chose ")),
        protectedTerms: ["This Product"]
    )

    #expect(result.text == "This Product")
    #expect(result.caseDecision == .preservedUnsafeOpening)
}

@Test("Automatic continuation supports explicitly allowed Unicode titlecase openings")
func automaticContinuationUnicodeTitlecase() {
    let policy = DictationContinuationPolicy(ordinaryTitlecaseOpenings: ["Élan"])
    let result = policy.shapeInsertionPayload(
        cleanedText: "Élan vital",
        context: .validated(context(leading: "Un grand "))
    )

    #expect(result.text == "élan vital")
    #expect(result.caseDecision == .lowercasedOrdinaryOpening)
}

@Test("Boundary spacing adds only missing interword spaces")
func continuationBoundarySpacing() {
    let policy = DictationContinuationPolicy()

    let missingBoth = policy.shapeInsertionPayload(
        cleanedText: "This approach",
        context: .validated(context(leading: "I think", trailing: "is right."))
    )
    #expect(missingBoth.text == " this approach ")
    #expect(missingBoth.insertedLeadingSpace)
    #expect(missingBoth.insertedTrailingSpace)

    let alreadyPresent = policy.shapeInsertionPayload(
        cleanedText: "This approach",
        context: .validated(context(leading: "I think ", trailing: " is right."))
    )
    #expect(alreadyPresent.text == "this approach")
    #expect(!alreadyPresent.insertedLeadingSpace)
    #expect(!alreadyPresent.insertedTrailingSpace)

    let closingPunctuation = policy.shapeInsertionPayload(
        cleanedText: "This works",
        context: .validated(context(leading: "I think ", trailing: "."))
    )
    #expect(closingPunctuation.text == "this works")
    #expect(!closingPunctuation.insertedTrailingSpace)

    let existingIntentionalWhitespace = policy.shapeInsertionPayload(
        cleanedText: " This works ",
        context: .validated(context(leading: "I think ", trailing: " next"))
    )
    #expect(existingIntentionalWhitespace.text == " this works ")

    let ambiguousDashBoundary = policy.shapeInsertionPayload(
        cleanedText: "This works",
        context: .validated(context(leading: "I think—"))
    )
    #expect(ambiguousDashBoundary.text == "This works")
    #expect(!ambiguousDashBoundary.insertedLeadingSpace)

    let ambiguousEmojiBoundary = policy.shapeInsertionPayload(
        cleanedText: "This works",
        context: .validated(context(leading: "I think🙂"))
    )
    #expect(ambiguousEmojiBoundary.text == "This works")
    #expect(!ambiguousEmojiBoundary.insertedLeadingSpace)
}

@Test("Unavailable, drifted, ineligible, and unbounded context never shapes text")
func continuationFailsClosedForContext() {
    let policy = DictationContinuationPolicy()
    let original = "This approach"

    #expect(policy.shapeInsertionPayload(cleanedText: original, context: .unavailable).text == original)
    #expect(policy.shapeInsertionPayload(cleanedText: original, context: .drifted).text == original)
    #expect(
        policy.shapeInsertionPayload(
            cleanedText: original,
            context: .validated(context(leading: "I think ", style: .unknown))
        ).text == original
    )
    #expect(
        policy.shapeInsertionPayload(
            cleanedText: original,
            context: .validated(context(leading: "I think ", allowed: false))
        ).text == original
    )
    #expect(
        policy.shapeInsertionPayload(
            cleanedText: original,
            context: .validated(context(identity: "", leading: "I think "))
        ).text == original
    )
    #expect(
        policy.shapeInsertionPayload(
            cleanedText: original,
            context: .validated(context(leading: String(repeating: "a", count: 257)))
        ).text == original
    )
}

@Test("Scripts without proven interword spacing receive no automatic spaces or recasing")
func continuationDoesNotGuessLanguageBoundaries() {
    let policy = DictationContinuationPolicy(ordinaryTitlecaseOpenings: ["This"])
    let result = policy.shapeInsertionPayload(
        cleanedText: "This",
        context: .validated(
            context(leading: "前", trailing: "後", style: .doesNotUseInterwordSpacing)
        )
    )

    #expect(result.text == "This")
    #expect(result.caseDecision == .notConsidered)
}

@Test("Random non-leading lowercase phrases are never consumed")
func randomizedDirectiveNonConsumption() {
    let policy = DictationContinuationPolicy()
    var generator = DeterministicGenerator(state: 0x5EED_CAFE)
    let prefixes = ["use ", "say ", "the word ", "quote ", "x ", "😀 ", "\"", "("]
    let suffixes = ["hello", "NASA", "École", "42 Hello", "this/path"]

    for _ in 0..<2_000 {
        let prefix = prefixes[generator.nextInt(upperBound: prefixes.count)]
        let suffix = suffixes[generator.nextInt(upperBound: suffixes.count)]
        let input = prefix + "lowercase " + suffix
        let plan = policy.prepareDirective(in: input)
        #expect(plan.kind == .none, "Input: \(input)")
        #expect(plan.textForCleanup == input, "Input: \(input)")
    }
}

@Test("Random fail-closed contexts preserve insertion payload byte-for-byte")
func randomizedFailClosedContextInvariant() {
    let policy = DictationContinuationPolicy()
    var generator = DeterministicGenerator(state: 0xC0FF_EE11)
    let texts = ["This works", "NASA", "Élan", " I agree ", "😀 This", "This/path"]

    for _ in 0..<2_000 {
        let text = texts[generator.nextInt(upperBound: texts.count)]
        let contextState: ContinuationContextState = generator.nextInt(upperBound: 2) == 0
            ? .unavailable
            : .drifted
        let result = policy.shapeInsertionPayload(cleanedText: text, context: contextState)
        #expect(result.text == text)
        #expect(result.caseDecision == .notConsidered)
        #expect(!result.insertedLeadingSpace)
        #expect(!result.insertedTrailingSpace)
    }
}

private func context(
    identity: String = "session-target-1",
    leading: String,
    trailing: String = "",
    style: ContinuationBoundaryStyle = .usesInterwordSpacing,
    allowed: Bool = true
) -> ContinuationContextSnapshot {
    ContinuationContextSnapshot(
        targetIdentityToken: identity,
        leadingText: leading,
        trailingText: trailing,
        boundaryStyle: style,
        allowsAutomaticContinuation: allowed
    )
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func nextInt(upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}
