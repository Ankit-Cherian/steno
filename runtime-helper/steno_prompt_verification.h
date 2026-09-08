// Acoustic verification of prompt-conditioned recognition output.
//
// A recognition prompt conditions the decoder on text. When the acoustic
// evidence inside a decoded window is weak, the decoder can emit that prompt
// text instead of speech. The rules below decide whether the prompt words a
// window repeats are acoustically supported.
//
// Support is measured per token as the teacher-forced log-probability of the
// token given the window's audio minus the same log-probability given silent
// (all-zero) audio, both conditioned only on the task prefix and the preceding
// hypothesis text. A token the audio does not explain scores about the same
// either way, so its support is near zero; a token the audio does explain
// gains several nats.
//
// Two facts about repetition shape the rules. First, an average
// log-probability cannot judge a run of copies: under the decoder's own text
// context each further copy grows cheap, so a long enough run passes any
// average threshold whether or not the audio contains the word. Second, the
// support measure above cannot count copies either: once the text context
// predicts the next copy, silence predicts it too, so later copies of a
// genuinely repeated word and later copies of a fabricated run both score near
// zero. The rules therefore judge the first occurrence of each suspect word by
// its support, and judge repetition by corroboration from the prompt-free
// decode of the same audio, which hears the same number of words when the
// repetition was spoken and fewer when it was not.
//
// Everything in this header is pure: no whisper state, no I/O, no allocation
// beyond the returned containers. The runtime helper and the unit tests
// compile the identical rules.

#ifndef STENO_PROMPT_VERIFICATION_H
#define STENO_PROMPT_VERIFICATION_H

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace steno {

// Frozen decision constants, in nats.
//
// kMinimumFirstOccurrenceSupport applies to the summed support of the tokens
// of the first occurrence of one suspect word (a prompt label word or a
// configured term). Measured genuine first occurrences: 7.4-14.6 for label
// words in sentences, headings and spoken repetitions across two models and
// eight synthesized voices, including a 30 dB quieter copy; 12.7-22.4 for
// configured terms spoken alone. Measured fabricated first occurrences, where
// the audio holds silence, unrelated speech, a low television, or a configured
// term the label merely resembles: -2.2 to +4.4. A label forced onto a
// near-homophone the speaker actually said ("turns", "germs", "firms") scores
// like a genuine occurrence, which is a recognition substitution rather than
// a fabrication and is outside these rules.
//
// kMinimumWordSupport applies to the mean support of the remaining word tokens
// of a hypothesis offered as a replacement. Measured genuine speech averages
// 1.8-6.2 nats per word token across quiet, short and ordinary recordings;
// measured fabricated text averages between -1.3 and +0.5.
//
// kMinimumReplacementSupport applies to the total support of the other words
// of a hypothesis offered as a replacement, when it has any. A replacement
// introduces text the prompted decode never produced, so a single short word
// is not enough evidence for it: the decoder prefers filler such as `so` over
// silence on broadband noise by about 6 nats with no speech present. Suspect
// words use their own support check, with an agreement exception when the
// prompt-free decode independently contains the same word and count. A
// configured term the user declared is the vocabulary retry's purpose (`Ankit.`
// alone on small.en measured 8.3). Measured genuine other-word totals: `Can
// you imagine?` 11.3, `Everyone or anything?` 15.3, `So I think it should`
// 16.5, a retained full sentence 95; noise filler `so` 5.4-6.2, `Mm.` on an
// uncertain 1 s boundary 8.6.
constexpr double kMinimumFirstOccurrenceSupport = 5.0;
constexpr double kMinimumWordSupport = 1.0;
constexpr double kMinimumReplacementSupport = 10.0;

// Rejected preview windows carry the prompt-free hypothesis. Set this to false
// to emit an empty provisional hypothesis for a rejected preview window
// instead. Final transcription is unaffected either way.
constexpr bool kPreviewSubstitutesPromptFreeText = true;

enum class WordGroup {
    Label,
    Vocabulary,
};

// One distinct suspect word of a hypothesis: how often it occurs and how much
// the audio supports its first occurrence.
struct WordSupport {
    std::string word;  // lowercased, possessive stripped
    WordGroup group = WordGroup::Label;
    int occurrences = 0;
    double first_occurrence_support = 0.0;
};

// Support statistics for one hypothesis. Tokens that spell no word
// (punctuation, end-of-text) are scored but excluded from every statistic,
// because their probability follows the text rather than the audio.
struct SupportScores {
    int scored_tokens = 0;
    std::vector<std::string> words;          // alphabetic words, lowercased, in order
    std::vector<WordSupport> suspect_words;  // in order of first appearance
    int other_word_tokens = 0;
    double other_word_support = 0.0;  // mean over word tokens of other words
};

// True when the first occurrence of every suspect word is acoustically
// supported. A hypothesis without suspect words passes trivially.
inline bool suspect_words_supported(const SupportScores & scores) {
    for (const WordSupport & word : scores.suspect_words) {
        if (word.first_occurrence_support < kMinimumFirstOccurrenceSupport) {
            return false;
        }
    }
    return true;
}

// True when some suspect word occurs more than once, so the hypothesis needs
// the prompt-free decode to corroborate the repetition.
inline bool repeats_suspect_word(const SupportScores & scores) {
    for (const WordSupport & word : scores.suspect_words) {
        if (word.occurrences > 1) {
            return true;
        }
    }
    return false;
}

inline int count_of(const std::vector<std::string> & values, const std::string & value) {
    int count = 0;
    for (const std::string & candidate : values) {
        if (candidate == value) {
            ++count;
        }
    }
    return count;
}

// A repeated suspect word is corroborated when the prompt-free decode of the
// same audio heard it as often, or when the decodes carry the same number of
// words and the prompt-free decode spells one consistent word in every slot
// the hypothesis fills with the suspect word (a spoken repetition the
// prompt-free decode misheard the same way each time). A fabricated run adds
// words the prompt-free decode did not hear, and a loop that consumed real
// speech leaves slots the prompt-free decode fills with different words.
inline bool repetition_corroborated(
    const std::vector<std::string> & hypothesis_words,
    const std::vector<std::string> & prompt_free_words,
    const std::string & word
) {
    if (count_of(prompt_free_words, word) >= count_of(hypothesis_words, word)) {
        return true;
    }
    if (hypothesis_words.size() != prompt_free_words.size()) {
        return false;
    }
    std::string spelled;
    for (size_t index = 0; index < hypothesis_words.size(); ++index) {
        if (hypothesis_words[index] != word) {
            continue;
        }
        if (spelled.empty()) {
            spelled = prompt_free_words[index];
        } else if (prompt_free_words[index] != spelled) {
            return false;
        }
    }
    return !spelled.empty();
}

inline bool repetitions_corroborated(
    const SupportScores & scores,
    const std::vector<std::string> & prompt_free_words
) {
    for (const WordSupport & word : scores.suspect_words) {
        if (word.occurrences > 1
            && !repetition_corroborated(scores.words, prompt_free_words, word.word)) {
            return false;
        }
    }
    return true;
}

inline bool other_words_supported(const SupportScores & scores) {
    return scores.other_word_tokens == 0 || scores.other_word_support >= kMinimumWordSupport;
}

// One suspect word of a hypothesis stands when the prompt-free decode of the
// same audio heard it at least as often, because text the decoder produces
// without the prompt was not induced by the prompt. Otherwise its first
// occurrence must be acoustically supported and, when it is repeated, the
// repetition must be corroborated.
inline bool suspect_word_stands(
    const SupportScores & scores,
    const WordSupport & word,
    const std::vector<std::string> & prompt_free_words
) {
    if (count_of(prompt_free_words, word.word) >= word.occurrences) {
        return true;
    }
    if (word.first_occurrence_support < kMinimumFirstOccurrenceSupport) {
        return false;
    }
    return word.occurrences == 1
        || repetition_corroborated(scores.words, prompt_free_words, word.word);
}

// The prompted window stands when every suspect word stands. A window whose
// suspect words are all supported and none repeated stands without the
// prompt-free decode (see suspect_words_supported and repeats_suspect_word);
// `prompt_free_words` is consulted for every other window.
inline bool prompted_window_supported(
    const SupportScores & scores,
    const std::vector<std::string> & prompt_free_words
) {
    for (const WordSupport & word : scores.suspect_words) {
        if (!suspect_word_stands(scores, word, prompt_free_words)) {
            return false;
        }
    }
    return true;
}

// Total support of a hypothesis's other (non-suspect) word tokens.
inline double other_word_total_support(const SupportScores & scores) {
    return scores.other_word_support * scores.other_word_tokens;
}

// A hypothesis offered in place of a rejected window must carry words, have its
// suspect words supported and corroborated like the prompted window, and have
// its other words supported both on average and in total, so a short filler
// word the decoder prefers on noise cannot replace a rejected window.
inline bool replacement_supported(
    const SupportScores & scores,
    const std::vector<std::string> & prompt_free_words
) {
    if (scores.words.empty()) {
        return false;
    }
    return prompted_window_supported(scores, prompt_free_words)
        && other_words_supported(scores)
        && (scores.other_word_tokens == 0
            || other_word_total_support(scores) >= kMinimumReplacementSupport);
}

// A rejected final window may be retried once against a vocabulary-only
// prompt, which keeps configured spellings available without offering label
// text to copy. Previews have no second tier.
inline bool attempts_vocabulary_retry(bool is_preview, bool has_vocabulary) {
    return !is_preview && has_vocabulary;
}

// Word boundaries. Bytes outside this set separate words, so punctuation,
// whitespace and multi-byte sequences all end a word. Vocabulary matching is
// therefore permissive at the edges, which keeps a configured term exempt from
// absolute scoring even when it is wrapped in unusual punctuation.
inline bool is_word_byte(unsigned char byte) {
    return (byte >= 'a' && byte <= 'z')
        || (byte >= 'A' && byte <= 'Z')
        || (byte >= '0' && byte <= '9')
        || byte == '\'';
}

inline unsigned char lowercase_byte(unsigned char byte) {
    return byte >= 'A' && byte <= 'Z' ? static_cast<unsigned char>(byte - 'A' + 'a') : byte;
}

using ByteRange = std::pair<size_t, size_t>;

inline std::vector<ByteRange> word_ranges(const std::string & text) {
    std::vector<ByteRange> ranges;
    size_t index = 0;
    while (index < text.size()) {
        if (!is_word_byte(static_cast<unsigned char>(text[index]))) {
            ++index;
            continue;
        }
        const size_t start = index;
        while (index < text.size() && is_word_byte(static_cast<unsigned char>(text[index]))) {
            ++index;
        }
        size_t end = index;
        // A leading or trailing apostrophe is punctuation, not part of the word.
        size_t trimmed_start = start;
        while (trimmed_start < end && text[trimmed_start] == '\'') {
            ++trimmed_start;
        }
        while (end > trimmed_start && text[end - 1] == '\'') {
            --end;
        }
        if (trimmed_start < end) {
            ranges.emplace_back(trimmed_start, end);
        }
    }
    return ranges;
}

inline std::string lowercased(const std::string & value) {
    std::string output(value.size(), '\0');
    for (size_t index = 0; index < value.size(); ++index) {
        output[index] = static_cast<char>(lowercase_byte(static_cast<unsigned char>(value[index])));
    }
    return output;
}

inline std::vector<std::string> words(const std::string & text) {
    std::vector<std::string> output;
    for (const ByteRange & range : word_ranges(text)) {
        output.push_back(lowercased(text.substr(range.first, range.second - range.first)));
    }
    return output;
}

inline bool contains_letter(const std::string & value) {
    for (char character : value) {
        const unsigned char byte = static_cast<unsigned char>(character);
        if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z')) {
            return true;
        }
    }
    return false;
}

inline int alphabetic_word_count(const std::string & text) {
    int count = 0;
    for (const std::string & word : words(text)) {
        if (contains_letter(word)) {
            ++count;
        }
    }
    return count;
}

inline bool contains(const std::vector<std::string> & values, const std::string & value) {
    for (const std::string & candidate : values) {
        if (candidate == value) {
            return true;
        }
    }
    return false;
}

// The vocabulary prompt is the configured hot terms joined by ", " and closed
// with a period. Splitting it back into words avoids parsing the recognition
// prompt grammar inside the runtime helper, and a multi-word term contributes
// each of its words.
inline std::vector<std::string> vocabulary_terms(const std::string & vocabulary_prompt) {
    std::vector<std::string> terms;
    for (const std::string & word : words(vocabulary_prompt)) {
        if (contains_letter(word) && !contains(terms, word)) {
            terms.push_back(word);
        }
    }
    return terms;
}

// Every word of the recognition prompt that is not a configured term. These are
// the strings a weak decode can copy: the field labels and any application
// name the prompt carries.
inline std::vector<std::string> label_words(
    const std::string & prompt,
    const std::vector<std::string> & terms
) {
    std::vector<std::string> labels;
    for (const std::string & word : words(prompt)) {
        if (!contains(terms, word) && !contains(labels, word) && contains_letter(word)) {
            labels.push_back(word);
        }
    }
    return labels;
}

// Verify a window only when it repeats prompt label text, or when it is made
// almost entirely of configured terms. Ordinary dictation pays nothing.
inline bool triggers_verification(
    const std::string & text,
    const std::vector<std::string> & labels,
    const std::vector<std::string> & terms
) {
    int alphabetic = 0;
    int vocabulary = 0;
    for (const std::string & word : words(text)) {
        if (!contains_letter(word)) {
            continue;
        }
        ++alphabetic;
        if (contains(labels, word)) {
            return true;
        }
        if (contains(terms, word)) {
            ++vocabulary;
        }
    }
    return alphabetic > 0 && vocabulary * 2 >= alphabetic;
}

// Classify one word of a hypothesis. A possessive form of a suspect word
// counts as that word. Label words take precedence over configured terms so a
// word that is both is judged in the stricter role.
struct WordClass {
    bool alphabetic = false;
    bool suspect = false;
    WordGroup group = WordGroup::Label;
    std::string canonical;  // lowercased; possessive stripped for suspect words
};

inline WordClass classify_word(
    const std::string & lowercased_word,
    const std::vector<std::string> & labels,
    const std::vector<std::string> & terms
) {
    WordClass result;
    result.alphabetic = contains_letter(lowercased_word);
    result.canonical = lowercased_word;
    const std::string possessive = "'s";
    if (!contains(labels, result.canonical) && !contains(terms, result.canonical)
        && result.canonical.size() > possessive.size()
        && result.canonical.compare(
            result.canonical.size() - possessive.size(), possessive.size(), possessive) == 0) {
        result.canonical.resize(result.canonical.size() - possessive.size());
    }
    if (contains(labels, result.canonical)) {
        result.suspect = true;
        result.group = WordGroup::Label;
    } else if (contains(terms, result.canonical)) {
        result.suspect = true;
        result.group = WordGroup::Vocabulary;
    } else {
        result.canonical = lowercased_word;
    }
    return result;
}

// The alphabetic words of a text in the form SupportScores::words uses, so a
// prompt-free decode can be compared with a scored hypothesis.
inline std::vector<std::string> alphabetic_words(
    const std::string & text,
    const std::vector<std::string> & labels,
    const std::vector<std::string> & terms
) {
    std::vector<std::string> output;
    for (const std::string & word : words(text)) {
        const WordClass classified = classify_word(word, labels, terms);
        if (classified.alphabetic) {
            output.push_back(classified.canonical);
        }
    }
    return output;
}

// Aggregate per-token support into SupportScores. `token_ranges` are the byte
// ranges the hypothesis tokens occupy in `text` and `token_support` the support
// of each token, in the same order. A token contributes to the word whose
// range it overlaps; tokens that overlap no word contribute to no statistic.
inline SupportScores aggregate_support(
    const std::string & text,
    const std::vector<ByteRange> & token_ranges,
    const std::vector<double> & token_support,
    const std::vector<std::string> & labels,
    const std::vector<std::string> & terms
) {
    SupportScores scores;
    scores.scored_tokens = static_cast<int>(token_support.size());
    double other_total = 0.0;
    for (const ByteRange & range : word_ranges(text)) {
        const WordClass word = classify_word(
            lowercased(text.substr(range.first, range.second - range.first)), labels, terms);
        if (!word.alphabetic) {
            continue;
        }
        scores.words.push_back(word.canonical);
        double support = 0.0;
        int tokens = 0;
        for (size_t index = 0; index < token_ranges.size() && index < token_support.size(); ++index) {
            const ByteRange & token = token_ranges[index];
            if (token.first < range.second && range.first < token.second) {
                support += token_support[index];
                ++tokens;
            }
        }
        if (!word.suspect) {
            other_total += support;
            scores.other_word_tokens += tokens;
            continue;
        }
        bool seen = false;
        for (WordSupport & existing : scores.suspect_words) {
            if (existing.word == word.canonical) {
                ++existing.occurrences;
                seen = true;
                break;
            }
        }
        if (!seen) {
            WordSupport entry;
            entry.word = word.canonical;
            entry.group = word.group;
            entry.occurrences = 1;
            entry.first_occurrence_support = support;
            scores.suspect_words.push_back(entry);
        }
    }
    if (scores.other_word_tokens > 0) {
        scores.other_word_support = other_total / scores.other_word_tokens;
    }
    return scores;
}

// Two hypotheses spell the same words when their alphabetic words agree in
// order, ignoring case and punctuation. An alternative that spells the
// prompted window's words carries no independent evidence for them.
inline bool same_alphabetic_words(const std::string & lhs, const std::string & rhs) {
    std::vector<std::string> left;
    for (const std::string & word : words(lhs)) {
        if (contains_letter(word)) {
            left.push_back(word);
        }
    }
    std::vector<std::string> right;
    for (const std::string & word : words(rhs)) {
        if (contains_letter(word)) {
            right.push_back(word);
        }
    }
    return left == right;
}

} // namespace steno

#endif // STENO_PROMPT_VERIFICATION_H
