// Detection of decoded windows that lost the speech they hold.
//
// The final decode runs without timestamp tokens, so whisper.cpp decodes the
// prepared audio in fixed 30 s windows and always advances a whole window,
// whatever the decoder emitted. It also conditions each window on the text
// decoded for the previous one. Two failures follow, and nothing inside
// whisper.cpp notices either of them:
//
// - A repetition loop. The decoder repeats a phrase and then ends the window
//   early. Its entropy check only looks at the last 32 tokens, and repeated
//   text is cheap under the decoder's own context, so a loop that is followed
//   by a few ordinary words, or that stops on its own, passes every fallback
//   threshold. The speech after the loop is never decoded.
// - A collapsed window. The decoder copies the previous window's text, or
//   ends after a few words, for a window full of speech. Once one window
//   degenerates, the next window is conditioned on the degenerate text and
//   usually degenerates too, so the rest of a long dictation can collapse
//   into copies of one phrase.
//
// The runtime helper classifies every decoded window with the rules below and
// decodes a defective window again in short pieces without the previous
// window's text. The recovered text replaces the window only when it is
// clearly better by the same rules, so a window whose speech really repeats
// keeps its original text.
//
// Everything in this header is pure: no whisper state and no I/O. The runtime
// helper and the unit tests compile the identical rules.

#ifndef STENO_WINDOW_RECOVERY_H
#define STENO_WINDOW_RECOVERY_H

#include <algorithm>
#include <cstddef>
#include <set>
#include <string>
#include <vector>

namespace steno {

// Frozen decision constants, calibrated on final decodes of 124 recordings
// (read, meeting and synthesized speech from 2 s to 5 min, including six
// multi-window dictations) with Large V3 Turbo and small.en and three request
// prompts, decoded the way the app decodes them.
//
// A repetition loop is a phrase repeated back to back at least
// kLoopMinimumRepeats times covering at least kLoopMinimumRepeatedWords words.
// The measured loops repeated a 2 to 10 word phrase 3 to 9 times, 12 to 90
// words in all. In windows that were not defective the longest back-to-back
// repetition was 9 words; speech repeats short phrases ("no, no, no",
// "Terms, Terms, Terms") well below the rule. A phrase deliberately spoken
// three times can reach it, and the replacement rule below keeps it.
constexpr size_t kLoopMinimumRepeats = 3;
constexpr size_t kLoopMinimumRepeatedWords = 12;
constexpr size_t kLoopMaximumPhraseWords = 32;

// A window copies the previous window when at least kMinimumCopiedFraction of
// its kCopiedPhraseWords-word phrases also occur in the previous window's
// text. Measured copying windows shared 50 to 100 percent of their phrases
// with the window before; consecutive windows that were not defective shared
// at most 11 percent.
constexpr size_t kCopiedPhraseWords = 4;
constexpr double kMinimumCopiedFraction = 0.5;

// A window misses speech when it yields fewer than kMinimumWordsPerSecond
// words per second of prepared audio. With voice activity detection the
// prepared audio has its silence removed. Measured collapsed windows yielded
// 0.03 to 0.9 words per second and their recovered decodes 2.3 to 3.5. Other
// full windows yielded 1.7 to 3.9 on Large V3 Turbo. Some small.en windows
// yielded 1.0 to 1.3; those inspected had ended early, which this rule does
// not catch, and raising it would decode slow but complete speech twice.
// Windows shorter than kMinimumSparseWindowSeconds, such as most final
// windows, are never judged sparse.
constexpr double kMinimumWordsPerSecond = 1.0;
constexpr double kMinimumSparseWindowSeconds = 5.0;

// A recovered window replaces a sparse or copying window only when it holds at
// least kMinimumRecoveredWordGain more words and at least
// kMinimumRecoveredWordRatio times as many words, so a few words decoded from
// noise never replace a short window. A loop is replaced when the recovered
// text is not itself a loop and keeps at least kMinimumLoopRecoveryRatio of the
// words the looping window holds once its repeats are collapsed. A repetition
// that was really spoken is heard again by the recovery decode, so the window
// keeps its original text.
constexpr size_t kMinimumRecoveredWordGain = 8;
constexpr double kMinimumRecoveredWordRatio = 1.5;
constexpr double kMinimumLoopRecoveryRatio = 0.9;

enum class WindowDefect {
    None,
    RepetitionLoop,
    CopiesPreviousWindow,
    MissingSpeech,
};

inline const char * window_defect_name(WindowDefect defect) {
    switch (defect) {
    case WindowDefect::None: return "none";
    case WindowDefect::RepetitionLoop: return "loop";
    case WindowDefect::CopiesPreviousWindow: return "copy";
    case WindowDefect::MissingSpeech: return "sparse";
    }
    return "none";
}

// Words for comparison: ASCII letters and digits are lowercased, apostrophes
// stay inside words, other ASCII bytes separate words, and bytes of multi-byte
// characters belong to the word they appear in.
inline std::vector<std::string> comparison_words(const std::string & text) {
    std::vector<std::string> output;
    std::string current;
    for (const char character : text) {
        const unsigned char byte = static_cast<unsigned char>(character);
        if (byte >= 'A' && byte <= 'Z') {
            current.push_back(static_cast<char>(byte - 'A' + 'a'));
        } else if ((byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9')
            || byte == '\'' || byte >= 0x80) {
            current.push_back(static_cast<char>(byte));
        } else if (!current.empty()) {
            output.push_back(current);
            current.clear();
        }
    }
    if (!current.empty()) {
        output.push_back(current);
    }
    return output;
}

// The longest run of one phrase repeated back to back.
struct Repetition {
    size_t start = 0;
    size_t phrase_words = 0;
    size_t repeats = 0;

    size_t repeated_words() const { return phrase_words * repeats; }
};

inline Repetition longest_repetition(const std::vector<std::string> & words) {
    Repetition best;
    const size_t maximum_phrase = std::min(kLoopMaximumPhraseWords, words.size() / 2);
    for (size_t phrase = 1; phrase <= maximum_phrase; ++phrase) {
        for (size_t start = 0; start + 2 * phrase <= words.size(); ++start) {
            size_t repeats = 1;
            while (start + (repeats + 1) * phrase <= words.size()
                && std::equal(
                    words.begin() + static_cast<std::ptrdiff_t>(start),
                    words.begin() + static_cast<std::ptrdiff_t>(start + phrase),
                    words.begin() + static_cast<std::ptrdiff_t>(start + repeats * phrase))) {
                ++repeats;
            }
            if (repeats >= 2 && phrase * repeats > best.repeated_words()) {
                best.start = start;
                best.phrase_words = phrase;
                best.repeats = repeats;
            }
        }
    }
    return best;
}

inline bool is_repetition_loop(const Repetition & repetition) {
    return repetition.repeats >= kLoopMinimumRepeats
        && repetition.repeated_words() >= kLoopMinimumRepeatedWords;
}

// Words a looping window holds once its longest repetition is collapsed to
// one copy.
inline size_t words_without_repeats(const std::vector<std::string> & words) {
    const Repetition repetition = longest_repetition(words);
    if (repetition.repeats < 2) {
        return words.size();
    }
    return words.size() - (repetition.repeats - 1) * repetition.phrase_words;
}

// The share of a window's phrases that also occur in the previous window.
inline double copied_fraction(
    const std::vector<std::string> & words,
    const std::vector<std::string> & previous
) {
    if (words.size() < kCopiedPhraseWords || previous.size() < kCopiedPhraseWords) {
        return 0.0;
    }
    std::set<std::vector<std::string>> earlier;
    for (size_t index = 0; index + kCopiedPhraseWords <= previous.size(); ++index) {
        earlier.emplace(
            previous.begin() + static_cast<std::ptrdiff_t>(index),
            previous.begin() + static_cast<std::ptrdiff_t>(index + kCopiedPhraseWords)
        );
    }
    size_t shared = 0;
    const size_t phrases = words.size() - kCopiedPhraseWords + 1;
    for (size_t index = 0; index < phrases; ++index) {
        const std::vector<std::string> phrase(
            words.begin() + static_cast<std::ptrdiff_t>(index),
            words.begin() + static_cast<std::ptrdiff_t>(index + kCopiedPhraseWords)
        );
        if (earlier.count(phrase) != 0) {
            ++shared;
        }
    }
    return static_cast<double>(shared) / static_cast<double>(phrases);
}

// Classifies one decoded window. `previous` is the text decoded for the window
// before it, which conditioned this window, or empty when there was none.
inline WindowDefect classify_window(
    const std::vector<std::string> & words,
    const std::vector<std::string> & previous,
    double window_seconds
) {
    if (is_repetition_loop(longest_repetition(words))) {
        return WindowDefect::RepetitionLoop;
    }
    if (copied_fraction(words, previous) >= kMinimumCopiedFraction) {
        return WindowDefect::CopiesPreviousWindow;
    }
    if (window_seconds >= kMinimumSparseWindowSeconds
        && static_cast<double>(words.size()) < kMinimumWordsPerSecond * window_seconds) {
        return WindowDefect::MissingSpeech;
    }
    return WindowDefect::None;
}

// True when the recovered decode of a defective window should replace it.
// `previous` is the text decoded for the window before it and `prompt` is the
// text that conditioned the first recovery piece (empty when it had none). The
// decoder can answer a piece of near-silent audio by repeating its prompt, so
// a recovery that copies either of them is the copy defect again and never
// replaces the window.
inline bool recovery_replaces(
    WindowDefect defect,
    const std::vector<std::string> & original,
    const std::vector<std::string> & recovered,
    const std::vector<std::string> & previous,
    const std::vector<std::string> & prompt
) {
    if (defect == WindowDefect::None || recovered.empty()
        || is_repetition_loop(longest_repetition(recovered))
        || copied_fraction(recovered, previous) >= kMinimumCopiedFraction
        || copied_fraction(recovered, prompt) >= kMinimumCopiedFraction) {
        return false;
    }
    if (defect == WindowDefect::RepetitionLoop) {
        return static_cast<double>(recovered.size())
            >= kMinimumLoopRecoveryRatio * static_cast<double>(words_without_repeats(original));
    }
    return recovered.size() >= original.size() + kMinimumRecoveredWordGain
        && static_cast<double>(recovered.size())
            >= kMinimumRecoveredWordRatio * static_cast<double>(original.size());
}

// Piece boundaries for decoding one window again. Each piece ends at the
// quietest `frame` samples, by sum of squares, in the second half of the
// `maximum_piece` samples that follow its start, so pieces start at pauses
// where the audio has any. A remainder shorter than `minimum_tail` joins the
// previous piece instead of becoming a piece of its own.
inline std::vector<std::pair<size_t, size_t>> recovery_pieces(
    const float * samples,
    size_t count,
    size_t maximum_piece,
    size_t frame,
    size_t minimum_tail
) {
    std::vector<std::pair<size_t, size_t>> pieces;
    if (count == 0 || maximum_piece == 0 || frame == 0) {
        return pieces;
    }
    const size_t step = std::max<size_t>(1, frame / 2);
    size_t start = 0;
    while (count - start > maximum_piece) {
        const size_t lower = start + maximum_piece / 2;
        const size_t upper = start + maximum_piece;
        size_t cut = upper;
        double quietest = -1.0;
        for (size_t position = lower; position + frame <= upper; position += step) {
            double energy = 0.0;
            for (size_t index = position; index < position + frame; ++index) {
                energy += static_cast<double>(samples[index]) * static_cast<double>(samples[index]);
            }
            if (quietest < 0.0 || energy < quietest) {
                quietest = energy;
                cut = position + frame / 2;
            }
        }
        pieces.emplace_back(start, cut);
        start = cut;
    }
    if (!pieces.empty() && count - start < minimum_tail) {
        pieces.back().second = count;
    } else {
        pieces.emplace_back(start, count);
    }
    return pieces;
}

} // namespace steno

#endif
