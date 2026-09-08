// Acoustic support scoring for prompt verification.
//
// Measures, for one hypothesis text, how much the audio of an encoded window
// explains each token beyond what silence explains: the teacher-forced
// log-probability of the token given the window minus the same log-probability
// given an all-zero window, both conditioned only on the task prefix. The
// grouping and thresholds live in steno_prompt_verification.h; this header
// owns everything that touches whisper state. The runtime helper and the
// real-inference test compile the identical scorer.

#ifndef STENO_PROMPT_SCORING_H
#define STENO_PROMPT_SCORING_H

#include "whisper.h"

#include "steno_prompt_verification.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace steno {

// The text context is 448 tokens including the task prefix.
constexpr int kMaximumScoredTokens = 400;

inline int blank_token_id(whisper_context * context) {
    const int end_of_text = whisper_token_eot(context);
    for (int token = 0; token < end_of_text; ++token) {
        const char * text = whisper_token_to_str(context, token);
        if (text != nullptr && std::strcmp(text, " ") == 0) {
            return token;
        }
    }
    return -1;
}

inline double log_sum_exp(const float * row, int count) {
    float maximum = -std::numeric_limits<float>::infinity();
    for (int index = 0; index < count; ++index) {
        maximum = std::max(maximum, row[index]);
    }
    if (!std::isfinite(maximum)) {
        return maximum;
    }
    double total = 0.0;
    for (int index = 0; index < count; ++index) {
        total += std::exp(static_cast<double>(row[index]) - static_cast<double>(maximum));
    }
    return static_cast<double>(maximum) + std::log(total);
}

// The all-zero reference window. It is encoded once per model and reused for
// every scored hypothesis: whisper pads every window to thirty seconds of
// silence, so the reference does not depend on the length of the audio.
class SilentReference {
public:
    SilentReference() = default;
    SilentReference(const SilentReference &) = delete;
    SilentReference & operator=(const SilentReference &) = delete;
    ~SilentReference() { release(); }

    // The encoded reference state for `context`, or nullptr when encoding
    // failed. A different context replaces the previous reference.
    whisper_state * state_for(whisper_context * context, int threads) {
        if (context == nullptr) {
            return nullptr;
        }
        if (state_ != nullptr && owner_ == context) {
            return state_;
        }
        release();
        whisper_state * candidate = whisper_init_state(context);
        if (candidate == nullptr) {
            return nullptr;
        }
        const std::vector<float> silence(static_cast<size_t>(WHISPER_SAMPLE_RATE), 0.0f);
        if (whisper_pcm_to_mel_with_state(
                context,
                candidate,
                silence.data(),
                static_cast<int>(silence.size()),
                threads
            ) != 0
            || whisper_encode_with_state(context, candidate, 0, threads) != 0) {
            whisper_free_state(candidate);
            return nullptr;
        }
        owner_ = context;
        state_ = candidate;
        return state_;
    }

    // Must run before the owning context is freed.
    void release() {
        if (state_ != nullptr) {
            whisper_free_state(state_);
            state_ = nullptr;
        }
        owner_ = nullptr;
    }

private:
    whisper_context * owner_ = nullptr;
    whisper_state * state_ = nullptr;
};

struct HypothesisTokens {
    std::string text;                   // as tokenized, with the leading space
    std::vector<whisper_token> tokens;  // excludes the trailing end-of-text
    std::vector<ByteRange> ranges;      // byte range of each token in `text`
};

// Tokenize a hypothesis the way the decoder emitted it. Segment text already
// carries the decoder's leading space; a second one would tokenize to the
// blank token that step 0 suppresses.
inline bool tokenize_hypothesis(
    whisper_context * context,
    const std::string & text,
    HypothesisTokens & result
) {
    result.text = (!text.empty() && text.front() == ' ') ? text : " " + text;
    result.tokens.assign(static_cast<size_t>(kMaximumScoredTokens), 0);
    const int token_count = whisper_tokenize(
        context,
        result.text.c_str(),
        result.tokens.data(),
        static_cast<int>(result.tokens.size())
    );
    if (token_count <= 0) {
        return false;
    }
    result.tokens.resize(static_cast<size_t>(token_count));
    result.ranges.clear();
    result.ranges.reserve(result.tokens.size());
    size_t cursor = 0;
    for (whisper_token token : result.tokens) {
        const char * piece = whisper_token_to_str(context, token);
        const size_t length = piece == nullptr ? 0 : std::strlen(piece);
        result.ranges.emplace_back(cursor, cursor + length);
        cursor += length;
    }
    return true;
}

// Teacher-forced log-probability of every hypothesis token, plus end-of-text,
// against the window currently encoded in `state`. The mask mirrors the
// decoder's own suppression: every special or timestamp token above
// end-of-text, plus end-of-text and the blank token at the first step.
inline bool teacher_forced_log_probabilities(
    whisper_context * context,
    whisper_state * state,
    int language_id,
    int threads,
    int blank_token,
    const std::vector<whisper_token> & hypothesis,
    std::vector<double> & log_probabilities
) {
    std::vector<whisper_token> prefix;
    prefix.push_back(whisper_token_sot(context));
    if (whisper_is_multilingual(context) != 0) {
        if (language_id < 0) {
            return false;
        }
        prefix.push_back(whisper_token_lang(context, language_id));
        prefix.push_back(whisper_token_transcribe(context));
    }
    prefix.push_back(whisper_token_not(context));

    std::vector<whisper_token> tokens = hypothesis;
    tokens.push_back(whisper_token_eot(context));

    const int vocabulary_size = whisper_n_vocab(context);
    const int end_of_text = whisper_token_eot(context);
    if (vocabulary_size <= end_of_text) {
        return false;
    }
    if (whisper_decode_with_state(
            context,
            state,
            prefix.data(),
            static_cast<int>(prefix.size()),
            0,
            threads
        ) != 0) {
        return false;
    }
    const float * row = whisper_get_logits_from_state(state)
        + static_cast<size_t>(prefix.size() - 1) * static_cast<size_t>(vocabulary_size);
    int past = static_cast<int>(prefix.size());
    std::vector<float> masked(static_cast<size_t>(vocabulary_size));
    log_probabilities.clear();
    log_probabilities.reserve(tokens.size());
    for (size_t index = 0; index < tokens.size(); ++index) {
        std::memcpy(masked.data(), row, static_cast<size_t>(vocabulary_size) * sizeof(float));
        for (int token = end_of_text + 1; token < vocabulary_size; ++token) {
            masked[static_cast<size_t>(token)] = -std::numeric_limits<float>::infinity();
        }
        if (index == 0) {
            masked[static_cast<size_t>(end_of_text)] = -std::numeric_limits<float>::infinity();
            if (blank_token >= 0) {
                masked[static_cast<size_t>(blank_token)] = -std::numeric_limits<float>::infinity();
            }
        }
        const double normalizer = log_sum_exp(masked.data(), vocabulary_size);
        const double logit = static_cast<double>(masked[static_cast<size_t>(tokens[index])]);
        if (!std::isfinite(logit) || !std::isfinite(normalizer)) {
            return false;
        }
        log_probabilities.push_back(logit - normalizer);
        if (index + 1 < tokens.size()) {
            const whisper_token current = tokens[index];
            if (whisper_decode_with_state(context, state, &current, 1, past, threads) != 0) {
                return false;
            }
            past += 1;
            row = whisper_get_logits_from_state(state);
        }
    }
    return true;
}

// Acoustic support of one hypothesis against the window encoded in
// `audio_state`, relative to the silent reference. Returns false when the
// hypothesis cannot be scored; the caller then keeps the decoder's text.
inline bool score_hypothesis_support(
    whisper_context * context,
    whisper_state * audio_state,
    whisper_state * silent_state,
    int language_id,
    int threads,
    int blank_token,
    const std::string & text,
    const std::vector<std::string> & labels,
    const std::vector<std::string> & terms,
    SupportScores & result
) {
    HypothesisTokens hypothesis;
    if (!tokenize_hypothesis(context, text, hypothesis)) {
        return false;
    }
    std::vector<double> with_audio;
    std::vector<double> with_silence;
    if (!teacher_forced_log_probabilities(
            context, audio_state, language_id, threads, blank_token, hypothesis.tokens, with_audio)
        || !teacher_forced_log_probabilities(
            context, silent_state, language_id, threads, blank_token, hypothesis.tokens, with_silence)) {
        return false;
    }
    // Both vectors carry one extra entry for end-of-text, which overlaps no
    // word and so contributes to no statistic.
    std::vector<double> support(with_audio.size());
    for (size_t index = 0; index < support.size(); ++index) {
        support[index] = with_audio[index] - with_silence[index];
    }
    result = aggregate_support(hypothesis.text, hypothesis.ranges, support, labels, terms);
    return true;
}

} // namespace steno

#endif // STENO_PROMPT_SCORING_H
