// Unit tests for the prompt-verification decision rules. The header is pure,
// so these tests compile without the whisper library. They pin the frozen
// constants, the word grouping, and the decision for measured support values;
// scripts/test-whisper-prompt-scoring.sh drives the same rules through real
// inference.

#include "../runtime-helper/steno_prompt_verification.h"

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

int failures = 0;

void require(bool condition, const std::string & message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

const std::vector<std::string> kTerms = {"stenokit", "steno", "turso", "ankit"};
const std::vector<std::string> kLabels = {"language", "en", "terms"};

// Token ranges and supports for a text whose words are single tokens: every
// alphabetic word gets one token with the given support, punctuation and the
// leading space are separate unscored tokens, and end-of-text is appended.
steno::SupportScores single_token_scores(
    const std::string & text,
    const std::vector<double> & word_supports
) {
    std::vector<steno::ByteRange> ranges;
    std::vector<double> supports;
    size_t word_index = 0;
    size_t cursor = 0;
    while (cursor < text.size()) {
        const bool word_byte = steno::is_word_byte(static_cast<unsigned char>(text[cursor]));
        size_t end = cursor + 1;
        while (end < text.size()
               && steno::is_word_byte(static_cast<unsigned char>(text[end])) == word_byte) {
            ++end;
        }
        ranges.emplace_back(cursor, end);
        if (word_byte) {
            supports.push_back(word_index < word_supports.size() ? word_supports[word_index] : 0.0);
            ++word_index;
        } else {
            supports.push_back(0.5);  // punctuation support never enters a statistic
        }
        cursor = end;
    }
    ranges.emplace_back(text.size(), text.size());
    supports.push_back(0.0);  // end-of-text
    return steno::aggregate_support(text, ranges, supports, kLabels, kTerms);
}

std::vector<std::string> words_of(const std::string & text) {
    return steno::alphabetic_words(text, kLabels, kTerms);
}

void test_constants() {
    require(steno::kMinimumFirstOccurrenceSupport == 5.0, "first-occurrence threshold is 5.0 nats");
    require(steno::kMinimumWordSupport == 1.0, "replacement word threshold is 1.0 nats");
    require(steno::kMinimumReplacementSupport == 10.0, "replacement total threshold is 10.0 nats");
}

void test_aggregation() {
    const steno::SupportScores scores = single_token_scores(
        " Please read the Terms of the terms' agreement, Steno.",
        {4.0, 6.0, 2.0, 9.5, 3.0, 5.0, 0.5, 1.0, 12.0}
    );
    require(scores.words.size() == 9, "nine alphabetic words");
    require(scores.words[3] == "terms" && scores.words[6] == "terms", "possessive folds into the label word");
    require(scores.suspect_words.size() == 2, "terms and steno are the suspect words");
    require(scores.suspect_words[0].word == "terms", "suspect words keep first-appearance order");
    require(scores.suspect_words[0].occurrences == 2, "terms occurs twice");
    require(scores.suspect_words[0].first_occurrence_support == 9.5, "first occurrence keeps its own support");
    require(scores.suspect_words[0].group == steno::WordGroup::Label, "terms is a label word");
    require(scores.suspect_words[1].group == steno::WordGroup::Vocabulary, "steno is a configured term");
    require(scores.other_word_tokens == 6, "six other word tokens");
    require(std::abs(scores.other_word_support - (4.0 + 6.0 + 2.0 + 3.0 + 5.0 + 1.0) / 6.0) < 1e-9,
            "other words average their tokens");
    require(steno::repeats_suspect_word(scores), "a repeated suspect word is detected");
    require(!steno::repeats_suspect_word(single_token_scores(" Terms.", {9.0})), "a single occurrence is not a repetition");
}

// A negative first-occurrence support value must reject an unsupported run
// regardless of length. The alternative is authored, unrelated test text;
// it deliberately contains no prompt label or configured vocabulary.
void test_fabrication_rejects_regardless_of_length() {
    const std::vector<std::string> prompt_free = words_of(
        " Please place the blue notebook beside the lamp and leave the office door open until early tomorrow morning."
    );
    for (int repetitions : {1, 2, 3, 4, 8, 19, 40}) {
        std::string text;
        std::vector<double> supports;
        for (int index = 0; index < repetitions; ++index) {
            text += " Terms.";
            // Later repetitions are cheap to predict from the text alone, which
            // is what diluted the old mean; here they are irrelevant.
            supports.push_back(index == 0 ? -2.20 : 3.0);
        }
        const steno::SupportScores scores = single_token_scores(text, supports);
        require(!steno::suspect_words_supported(scores), "unsupported first occurrence x" + std::to_string(repetitions));
        require(!steno::prompted_window_supported(scores, prompt_free),
                "fabricated run rejects at x" + std::to_string(repetitions));
        require(!steno::prompted_window_supported(scores, {}),
                "fabricated run rejects against an empty prompt-free decode x" + std::to_string(repetitions));
    }
    // Punctuation and case variants group the same way.
    for (const char * variant : {" Terms, Terms, Terms.", " TERMS. TERMS. TERMS.", " terms terms terms", " Terms' Terms's Terms."}) {
        const steno::SupportScores scores = single_token_scores(variant, {-2.20, 3.0, 3.0});
        require(scores.suspect_words.size() == 1 && scores.suspect_words[0].occurrences == 3,
                std::string("variant groups as one word x3: ") + variant);
        require(!steno::prompted_window_supported(scores, prompt_free), std::string("variant rejects: ") + variant);
    }
}

// A supported first occurrence followed by a fabricated run: the audio holds one
// `terms` inside a sentence (measured +9.79) and the decoder loops on it.
void test_supported_first_occurrence_with_uncorroborated_run() {
    const std::vector<std::string> prompt_free = words_of(
        " Please read the terms of the rental agreement before you sign anything."
    );
    const steno::SupportScores genuine = single_token_scores(
        " Please read the terms of the rental agreement before you sign anything.",
        {5.0, 5.0, 5.0, 9.79, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0}
    );
    require(steno::suspect_words_supported(genuine), "genuine sentence is supported");
    require(!steno::repeats_suspect_word(genuine), "genuine sentence needs no prompt-free decode");
    require(steno::prompted_window_supported(genuine, prompt_free), "genuine sentence stands");

    for (int extra : {2, 4, 8, 19}) {
        std::string text = " Please read the terms of the rental agreement before you sign anything.";
        std::vector<double> supports = {5.0, 5.0, 5.0, 9.79, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0};
        for (int index = 0; index < extra; ++index) {
            text += " Terms.";
            supports.push_back(3.0);
        }
        const steno::SupportScores scores = single_token_scores(text, supports);
        require(steno::suspect_words_supported(scores), "first occurrence stays supported +" + std::to_string(extra));
        require(steno::repeats_suspect_word(scores), "run is a repetition +" + std::to_string(extra));
        require(!steno::prompted_window_supported(scores, prompt_free),
                "uncorroborated run rejects +" + std::to_string(extra));
    }
}

// Genuine repetition: the prompt-free decode hears the word as often, or
// consistently mishears every slot the same way.
void test_genuine_repetition_stands() {
    const steno::SupportScores spoken = single_token_scores(" Terms. Terms. Terms.", {14.57, 3.0, 3.0});
    require(steno::prompted_window_supported(spoken, words_of(" Terms. Terms. Terms.")), "heard three times stands");
    require(steno::prompted_window_supported(spoken, words_of(" Terms, terms, terms, terms.")), "heard more often stands");
    require(steno::prompted_window_supported(spoken, words_of(" Turns. Turns. Turns.")), "consistent mishearing stands");
    require(!steno::prompted_window_supported(spoken, words_of(" Turns. Terms. Firms.")), "inconsistent slots reject");
    require(!steno::prompted_window_supported(spoken, words_of(" Terms.")), "one heard against three rejects");
    require(!steno::prompted_window_supported(spoken, {}), "an empty prompt-free decode does not corroborate");

    // A word the prompt-free decode reproduces at least as often was not
    // induced by the prompt, so it stands even when its first occurrence
    // scores below the threshold (the e2e repeated-terms fixture measured
    // +5.17, at the edge).
    const steno::SupportScores weak = single_token_scores(" Terms, Terms, Terms.", {1.5, 3.0, 3.0});
    require(!steno::suspect_words_supported(weak), "weak first occurrence is not supported on its own");
    require(steno::prompted_window_supported(weak, words_of(" Terms. Terms. Terms.")), "prompt-free agreement keeps a weak repetition");
    require(!steno::prompted_window_supported(weak, words_of(" Turns. Turns. Turns.")),
            "consistent mishearing does not rescue an unsupported first occurrence");
    require(!steno::prompted_window_supported(weak, words_of(" Terms.")), "one heard does not rescue three");
    const steno::SupportScores weak_single = single_token_scores(" Terms.", {1.5});
    require(steno::prompted_window_supported(weak_single, words_of(" terms")), "prompt-free agreement keeps a weak single word");
    require(!steno::prompted_window_supported(weak_single, words_of(" Can you imagine?")), "a weak single word without agreement rejects");
}

// Names and configured vocabulary are judged by their own first occurrence,
// not by a worst word or by the label word.
void test_vocabulary_and_names() {
    const steno::SupportScores two_terms = single_token_scores(" StenoKit, Turso.", {22.3, 13.8});
    require(steno::prompted_window_supported(two_terms, {}), "two supported terms stand without a prompt-free decode");
    const steno::SupportScores weak_term = single_token_scores(" Send this to Ankit.", {5.0, 5.0, 5.0, 4.4});
    require(!steno::suspect_words_supported(weak_term), "a term forced onto other audio is unsupported");
    require(steno::prompted_window_supported(weak_term, words_of(" Send this to Ankit.")), "prompt-free agreement keeps it");
    require(!steno::prompted_window_supported(weak_term, words_of(" Send this to uncut.")), "disagreement rejects it");
    const steno::SupportScores name = single_token_scores(" Ask Priya and Tomasz to review it.", {2.0, 1.0, 2.0, 0.5, 2.0, 2.0, 2.0});
    require(name.suspect_words.empty() && steno::prompted_window_supported(name, {}),
            "unlisted names are not suspect words");
}

// A replacement must carry supported words itself.
void test_replacement() {
    const std::vector<std::string> prompt_free = words_of(" Can you imagine?");
    require(steno::replacement_supported(single_token_scores(" Can you imagine?", {3.8, 3.8, 3.8}), prompt_free),
            "the supported prompt-free decode replaces");
    require(!steno::replacement_supported(single_token_scores(" Can you imagine?", {0.5, 0.5, 0.5}), prompt_free),
            "an unsupported alternative does not replace");
    require(!steno::replacement_supported(single_token_scores("", {}), prompt_free), "an empty alternative does not replace");
    require(!steno::replacement_supported(single_token_scores(" Terms. Terms.", {-2.2, 3.0}), prompt_free),
            "an alternative that repeats the label does not replace");
    require(steno::replacement_supported(single_token_scores(" Turso.", {13.8}), words_of(" Terso.")),
            "a supported vocabulary retry replaces");
    require(!steno::replacement_supported(single_token_scores(" Turso.", {2.0}), words_of(" Terso.")),
            "an unsupported vocabulary retry does not replace");
    // Measured on 28 s of broadband noise: the prompt-free decode is `so` at
    // 6.17 nats, the prompted decode nine `Terms.`; neither may stand.
    require(!steno::replacement_supported(single_token_scores(" so", {6.17}), words_of(" so")),
            "a lone filler word does not replace a rejected window");
    require(!steno::replacement_supported(single_token_scores(" Mm.", {8.59}), words_of(" Mm.")),
            "a short uncertain word does not replace a rejected window");
    require(steno::replacement_supported(single_token_scores(" So I think it should", {3.3, 3.3, 3.3, 3.3, 3.3}), words_of(" So I think it should")),
            "a supported phrase replaces");
    // A supported configured term alone is the vocabulary retry's purpose:
    // `Ankit.` on small.en measured 8.31 with the prompt-free decode `and good.`
    require(steno::replacement_supported(single_token_scores(" Ankit.", {8.31}), words_of(" and good.")),
            "a supported configured term alone replaces");
    require(!steno::replacement_supported(single_token_scores(" Ankit.", {4.9}), words_of(" and good.")),
            "a weakly supported configured term alone does not replace");
    require(!steno::replacement_supported(single_token_scores(" so Ankit.", {6.0, 8.31}), words_of(" and good.")),
            "a supported term does not carry a weak other word");
    require(std::abs(steno::other_word_total_support(single_token_scores(" Send this to Ankit.", {2.0, 2.0, 2.0, 12.0})) - 6.0) < 1e-9,
            "other-word total excludes suspect words");
}

void test_retry_and_preview() {
    require(steno::attempts_vocabulary_retry(false, true), "a final with vocabulary retries");
    require(!steno::attempts_vocabulary_retry(false, false), "no vocabulary means no retry");
    require(!steno::attempts_vocabulary_retry(true, true), "previews have no second tier");
    require(!steno::attempts_vocabulary_retry(true, false), "previews never retry");
}

void test_prompt_vocabulary_parsing() {
    const std::string prompt = "Language: en. Terms: StenoKit, Steno, Turso, Ankit.";
    const std::string vocabulary = "StenoKit, Steno, Turso, Ankit.";
    const std::vector<std::string> terms = steno::vocabulary_terms(vocabulary);
    require(terms.size() == 4, "four configured terms");
    require(terms[0] == "stenokit" && terms[3] == "ankit", "terms are lowercased in order");

    const std::vector<std::string> labels = steno::label_words(prompt, terms);
    require(labels.size() == 3, "three label words");
    require(
        steno::contains(labels, "language")
            && steno::contains(labels, "en")
            && steno::contains(labels, "terms"),
        "labels are the prompt words outside the vocabulary"
    );

    require(
        steno::vocabulary_terms("New York, Steno.").size() == 3,
        "a multi-word term contributes each word"
    );

    // Triggering.
    require(steno::triggers_verification("Terms in. Terms in.", labels, terms), "label copy triggers");
    require(steno::triggers_verification(" Terms.", labels, terms), "a single label word triggers");
    require(
        steno::triggers_verification(" StenoKit, StenoKit", labels, terms),
        "an all-vocabulary window triggers"
    );
    require(
        !steno::triggers_verification(
            " Let us meet about the schedule tomorrow morning.",
            labels,
            terms
        ),
        "ordinary dictation does not trigger"
    );
    require(
        !steno::triggers_verification(
            " I pushed the StenoKit change and then reviewed four other pull requests.",
            labels,
            terms
        ),
        "one configured term inside a sentence does not trigger"
    );
    require(!steno::triggers_verification(" 42 100", labels, terms), "digits do not trigger");
    require(!steno::triggers_verification("", labels, terms), "empty text does not trigger");

    require(steno::alphabetic_word_count(" Terms in. Terms in.") == 4, "alphabetic words are counted");
    require(steno::alphabetic_word_count(" 1, 2, 3.") == 0, "numbers are not alphabetic words");
    require(steno::same_alphabetic_words(" Terms, Terms, Terms.", "terms terms TERMS"), "same words ignore punctuation and case");
    require(!steno::same_alphabetic_words(" Terms. Terms.", " Terms."), "different counts differ");
}

} // namespace

int main() {
    test_constants();
    test_aggregation();
    test_fabrication_rejects_regardless_of_length();
    test_supported_first_occurrence_with_uncorroborated_run();
    test_genuine_repetition_stands();
    test_vocabulary_and_names();
    test_replacement();
    test_retry_and_preview();
    test_prompt_vocabulary_parsing();
    if (failures != 0) {
        std::cerr << failures << " prompt-verification assertion(s) failed\n";
        return 1;
    }
    std::cout << "prompt-verification decision tests passed\n";
    return 0;
}
