// Real-inference tests for the prompt-verification scorer and decision rules.
//
// Runs the identical scorer the runtime helper compiles against a real model
// and real audio, decodes the prompt-free hypothesis of each fixture the way
// the helper does, then checks the decisions the helper would take. The audio
// is public (whisper.cpp's jfk sample), synthesized on this machine by the
// wrapper script, or generated silence, so the test carries no recording.
//
// Usage: prompt-scoring-tests MODEL FIXTURE_DIR
// FIXTURE_DIR holds jfk.wav, terms_sentence.wav, repeated_terms.wav,
// language_sentence.wav, steno.wav, two_terms.wav, silence.wav (16 kHz mono
// signed 16-bit).

#include "../runtime-helper/steno_prompt_scoring.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;
constexpr int kThreads = 4;

void require(bool condition, const std::string & message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

std::vector<float> read_wave(const std::string & path) {
    std::ifstream input(path, std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
    std::vector<float> samples;
    size_t position = 12;
    while (position + 8 <= bytes.size()) {
        uint32_t size = 0;
        std::memcpy(&size, bytes.data() + position + 4, 4);
        if (std::memcmp(bytes.data() + position, "data", 4) == 0) {
            const size_t count = std::min<size_t>(size, bytes.size() - position - 8) / 2;
            samples.resize(count);
            for (size_t index = 0; index < count; ++index) {
                int16_t value = 0;
                std::memcpy(&value, bytes.data() + position + 8 + index * 2, 2);
                samples[index] = static_cast<float>(value) / 32768.0f;
            }
            return samples;
        }
        position += 8 + size + (size & 1);
    }
    return samples;
}

std::string repeated(const std::string & unit, int count) {
    std::string output;
    for (int index = 0; index < count; ++index) {
        if (index > 0) {
            output += ' ';
        }
        output += unit;
    }
    return output;
}

// The production prompt shape: field labels plus configured terms.
const std::string kPrompt = "Language: en. Terms: Steno, StenoKit, Orion, Turso, Ankit.";
const std::string kVocabulary = "Steno, StenoKit, Orion, Turso, Ankit.";
const std::string kJFK =
    "And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country.";

struct Fixture {
    whisper_context * context = nullptr;
    whisper_state * audio = nullptr;
    whisper_state * silent = nullptr;
    int language_id = -1;
    int blank_token = -1;
    std::vector<std::string> labels;
    std::vector<std::string> terms;
    std::string name;
    std::string prompt_free_text;
    std::vector<std::string> prompt_free_words;

    bool score(const std::string & text, steno::SupportScores & scores) const {
        return steno::score_hypothesis_support(
            context, audio, silent, language_id, kThreads, blank_token, text, labels, terms, scores);
    }

    // The average-log-probability rule the scorer replaced, measured on the
    // same audio so the test records why it was replaced.
    double average_log_probability(const std::string & text) const {
        steno::HypothesisTokens hypothesis;
        std::vector<double> values;
        if (!steno::tokenize_hypothesis(context, text, hypothesis)
            || !steno::teacher_forced_log_probabilities(
                context, audio, language_id, kThreads, blank_token, hypothesis.tokens, values)) {
            return 0.0;
        }
        double total = 0.0;
        for (double value : values) {
            total += value;
        }
        return total / static_cast<double>(values.size());
    }
};

void print_scores(const Fixture & fixture, const char * verdict, const steno::SupportScores & scores,
                  const std::string & text) {
    std::printf("  %-18s %-11s words=%2d other=%6.2f(%2d)", fixture.name.c_str(), verdict,
        static_cast<int>(scores.words.size()), scores.other_word_support, scores.other_word_tokens);
    for (const steno::WordSupport & word : scores.suspect_words) {
        std::printf(" %s:first=%+.2f(x%d)", word.word.c_str(), word.first_occurrence_support, word.occurrences);
    }
    std::printf("  `%s`\n", text.substr(0, 40).c_str());
}

bool scored(const Fixture & fixture, const std::string & text, steno::SupportScores & scores) {
    const bool ok = fixture.score(text, scores);
    require(ok, fixture.name + ": scorable `" + text + "`");
    return ok;
}

// The prompted window keeps its text.
void expect_window_stands(const Fixture & fixture, const std::string & text, const std::string & why) {
    steno::SupportScores scores;
    if (!scored(fixture, text, scores)) {
        return;
    }
    print_scores(fixture, "stands", scores, text);
    require(steno::prompted_window_supported(scores, fixture.prompt_free_words),
        fixture.name + ": window stands, " + why);
}

// The prompted window is rejected because a suspect word is not in the audio.
void expect_unsupported_suspect(const Fixture & fixture, const std::string & text, const std::string & why) {
    steno::SupportScores scores;
    if (!scored(fixture, text, scores)) {
        return;
    }
    print_scores(fixture, "unsupported", scores, text);
    require(!scores.suspect_words.empty(), fixture.name + ": has suspect words, " + why);
    require(!steno::suspect_words_supported(scores), fixture.name + ": suspect words unsupported, " + why);
    require(!steno::prompted_window_supported(scores, fixture.prompt_free_words),
        fixture.name + ": window rejected, " + why);
    require(!steno::replacement_supported(scores, fixture.prompt_free_words),
        fixture.name + ": not acceptable as a replacement either, " + why);
}

// The prompted window is rejected because its repetition is not corroborated.
void expect_uncorroborated_repetition(const Fixture & fixture, const std::string & text, const std::string & why) {
    steno::SupportScores scores;
    if (!scored(fixture, text, scores)) {
        return;
    }
    print_scores(fixture, "inflated", scores, text);
    require(steno::suspect_words_supported(scores), fixture.name + ": first occurrence genuine, " + why);
    require(steno::repeats_suspect_word(scores), fixture.name + ": repeats a suspect word, " + why);
    require(!steno::repetitions_corroborated(scores, fixture.prompt_free_words),
        fixture.name + ": prompt-free decode does not corroborate the repetition, " + why);
    require(!steno::prompted_window_supported(scores, fixture.prompt_free_words),
        fixture.name + ": window rejected, " + why);
}

// A candidate replacement carries no acoustic support.
void expect_unsupported_replacement(const Fixture & fixture, const std::string & text, const std::string & why) {
    steno::SupportScores scores;
    if (!scored(fixture, text, scores)) {
        return;
    }
    print_scores(fixture, "no-replace", scores, text);
    require(!steno::replacement_supported(scores, fixture.prompt_free_words),
        fixture.name + ": replacement unsupported, " + why);
}

void expect_supported_replacement(const Fixture & fixture, const std::string & text, const std::string & why) {
    steno::SupportScores scores;
    if (!scored(fixture, text, scores)) {
        return;
    }
    print_scores(fixture, "replaceable", scores, text);
    require(steno::replacement_supported(scores, fixture.prompt_free_words),
        fixture.name + ": replacement supported, " + why);
}

// The prompted window is rejected for either reason, and no alternative of
// the same text could replace it.
void expect_window_rejected(const Fixture & fixture, const std::string & text, const std::string & why) {
    steno::SupportScores scores;
    if (!scored(fixture, text, scores)) {
        return;
    }
    print_scores(fixture, "rejected", scores, text);
    require(!steno::prompted_window_supported(scores, fixture.prompt_free_words),
        fixture.name + ": window rejected, " + why);
    require(!steno::replacement_supported(scores, fixture.prompt_free_words),
        fixture.name + ": not acceptable as a replacement either, " + why);
}

// Fabricated label runs of every length and spelling are rejected. When the
// audio does not contain the label word at all, the first occurrence itself is
// unsupported, and repetition cannot raise it. When the audio does contain the
// word once, a spelling variant placed first may attach to that occurrence, and
// the uncorroborated repetition rejects the run instead.
void test_fabricated_runs(const Fixture & fixture, bool audio_contains_label) {
    for (int count : {1, 2, 4, 8, 19}) {
        if (audio_contains_label && count == 1) {
            // The audio holds one spoken `terms` and the prompt-free decode
            // hears it, so a lone `Terms.` is not prompt-induced and stands
            // by agreement whatever its position scores.
            steno::SupportScores scores;
            if (scored(fixture, "Terms.", scores)) {
                print_scores(fixture, "agreed", scores, "Terms.");
                require(steno::count_of(fixture.prompt_free_words, "terms") >= 1,
                    fixture.name + ": prompt-free decode hears terms");
                require(steno::prompted_window_supported(scores, fixture.prompt_free_words),
                    fixture.name + ": lone Terms stands by prompt-free agreement");
            }
            continue;
        }
        expect_unsupported_suspect(fixture, repeated("Terms.", count), "Terms x" + std::to_string(count));
    }
    const std::vector<std::string> spellings = {
        "Terms, terms, terms.",
        "TERMS. TERMS. TERMS.",
        "Terms: terms: terms:",
        "Terms Terms Terms Terms",
        "Terms in. Terms in.",
    };
    for (const std::string & spelling : spellings) {
        if (audio_contains_label) {
            expect_window_rejected(fixture, spelling, "spelling variant");
        } else {
            expect_unsupported_suspect(fixture, spelling, "spelling variant");
        }
    }
    expect_unsupported_suspect(fixture, kPrompt, "whole prompt copied");
    expect_unsupported_suspect(fixture, repeated("Steno,", 4) + " Steno.", "configured term run");
}

// The average rule accepted long runs: under the decoder's own text context
// the mean log-probability of a run climbs by several nats as it lengthens,
// although the audio contains none of the words.
void test_average_rule_is_diluted(const Fixture & fixture) {
    const double two = fixture.average_log_probability(repeated("Terms.", 2));
    const double nineteen = fixture.average_log_probability(repeated("Terms.", 19));
    std::printf("  %-18s average log-probability: x2 %.3f  x19 %.3f\n", fixture.name.c_str(), two, nineteen);
    require(nineteen > two + 3.0, fixture.name + ": repetition dilutes the average by more than 3 nats");
}

Fixture load_fixture(whisper_context * context, steno::SilentReference & silent,
                     const std::string & directory, const std::string & name) {
    Fixture fixture;
    fixture.name = name;
    fixture.context = context;
    fixture.silent = silent.state_for(context, kThreads);
    fixture.language_id = whisper_lang_id("en");
    fixture.blank_token = steno::blank_token_id(context);
    fixture.terms = steno::vocabulary_terms(kVocabulary);
    fixture.labels = steno::label_words(kPrompt, fixture.terms);
    std::vector<float> samples = read_wave(directory + "/" + name + ".wav");
    require(!samples.empty(), name + ": fixture audio present");
    if (samples.empty()) {
        return fixture;
    }

    // The prompt-free decode, with the helper's decode parameters.
    whisper_full_params parameters = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    parameters.n_threads = kThreads;
    parameters.no_context = true;
    parameters.no_timestamps = true;
    parameters.print_realtime = false;
    parameters.print_progress = false;
    parameters.print_timestamps = false;
    parameters.print_special = false;
    parameters.language = "en";
    parameters.beam_search.beam_size = 5;
    parameters.temperature_inc = 0.2f;
    parameters.entropy_thold = 2.4f;
    parameters.logprob_thold = -1.0f;
    parameters.no_speech_thold = 0.6f;
    whisper_state * decode_state = whisper_init_state(context);
    require(decode_state != nullptr, name + ": decode state");
    if (decode_state != nullptr) {
        require(whisper_full_with_state(context, decode_state, parameters, samples.data(),
                    static_cast<int>(samples.size())) == 0, name + ": prompt-free decode");
        for (int segment = 0; segment < whisper_full_n_segments_from_state(decode_state); ++segment) {
            const char * text = whisper_full_get_segment_text_from_state(decode_state, segment);
            fixture.prompt_free_text += text == nullptr ? "" : text;
        }
        whisper_free_state(decode_state);
    }
    fixture.prompt_free_words = steno::alphabetic_words(fixture.prompt_free_text, fixture.labels, fixture.terms);
    std::printf("%s: prompt-free `%s` (%zu words)\n", name.c_str(), fixture.prompt_free_text.c_str(),
        fixture.prompt_free_words.size());

    fixture.audio = whisper_init_state(context);
    require(fixture.audio != nullptr, name + ": state");
    if (fixture.audio != nullptr) {
        require(whisper_pcm_to_mel_with_state(context, fixture.audio, samples.data(),
                    static_cast<int>(samples.size()), kThreads) == 0, name + ": mel");
        require(whisper_encode_with_state(context, fixture.audio, 0, kThreads) == 0, name + ": encode");
    }
    return fixture;
}

void release(Fixture & fixture) {
    if (fixture.audio != nullptr) {
        whisper_free_state(fixture.audio);
        fixture.audio = nullptr;
    }
}

} // namespace

int main(int argc, char ** argv) {
    // Keep fixture progress visible when CI pipes stdout into an evidence log.
    std::setvbuf(stdout, nullptr, _IOLBF, BUFSIZ);
    if (argc != 3) {
        std::cerr << "usage: prompt-scoring-tests MODEL FIXTURE_DIR\n";
        return 2;
    }
    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    whisper_context_params parameters = whisper_context_default_params();
    parameters.flash_attn = true;
    whisper_context * context = whisper_init_from_file_with_params_no_state(argv[1], parameters);
    if (context == nullptr) {
        std::cerr << "FAIL: model load\n";
        return 1;
    }
    const std::string directory = argv[2];
    steno::SilentReference silent;
    require(silent.state_for(context, kThreads) != nullptr, "silent reference encodes");
    require(silent.state_for(context, kThreads) == silent.state_for(context, kThreads), "silent reference is reused");

    {
        Fixture jfk = load_fixture(context, silent, directory, "jfk");
        expect_window_stands(jfk, kJFK, "correct public transcript");
        expect_supported_replacement(jfk, kJFK, "correct public transcript as a replacement");
        test_fabricated_runs(jfk, false);
        test_average_rule_is_diluted(jfk);
        // Fabricated run after real speech inside one window: the run's first
        // occurrence is unsupported, and the window as a whole cannot stand.
        expect_unsupported_suspect(jfk, kJFK + " " + repeated("Terms.", 8), "real speech then a run");
        expect_unsupported_suspect(jfk, repeated("Terms.", 8) + " " + kJFK, "a run then real speech");
        expect_unsupported_replacement(jfk, "Thank you for watching.", "unrelated fabrication");
        release(jfk);
    }
    {
        Fixture terms = load_fixture(context, silent, directory, "terms_sentence");
        const std::string reference = "Please read the terms of the rental agreement before you sign anything.";
        expect_window_stands(terms, reference, "genuinely spoken label word in a sentence");
        test_fabricated_runs(terms, true);
        // The audio contains the word once. A run appended to the genuine
        // sentence keeps a genuine first occurrence, so only the prompt-free
        // word count exposes it. The summed-support statistic considered and
        // rejected during design accepted this case: each copy re-attends to
        // the one spoken occurrence and the sum climbs with length.
        for (int count : {2, 4, 8, 19}) {
            expect_uncorroborated_repetition(terms, reference + " " + repeated("Terms.", count),
                "genuine sentence then Terms x" + std::to_string(count));
        }
        release(terms);
    }
    {
        Fixture repeated_terms = load_fixture(context, silent, directory, "repeated_terms");
        expect_window_stands(repeated_terms, "Terms. Terms. Terms.", "genuinely spoken repetition");
        expect_window_stands(repeated_terms, "Terms, Terms, Terms.", "genuinely spoken repetition, comma spelling");
        expect_uncorroborated_repetition(repeated_terms, repeated("Terms.", 19), "run far longer than spoken");
        release(repeated_terms);
    }
    {
        Fixture language = load_fixture(context, silent, directory, "language_sentence");
        expect_window_stands(language, "The language of the quarterly report should stay simple and direct.",
            "genuinely spoken label word");
        expect_unsupported_suspect(language, "Language: en.", "copied field label");
        release(language);
    }
    {
        Fixture steno = load_fixture(context, silent, directory, "steno");
        expect_window_stands(steno, "Steno.", "genuinely spoken configured term alone");
        expect_supported_replacement(steno, "Steno.", "configured term as a vocabulary-retry replacement");
        expect_unsupported_suspect(steno, "Terms.", "label forced onto a spoken term");
        expect_unsupported_suspect(steno, "Terms. Terms.", "label run forced onto a spoken term");
        release(steno);
    }
    {
        Fixture two = load_fixture(context, silent, directory, "two_terms");
        expect_window_stands(two, "StenoKit, Turso.", "two genuinely spoken configured terms");
        expect_unsupported_suspect(two, "Terms. Terms.", "label run forced onto spoken terms");
        release(two);
    }
    {
        Fixture silence = load_fixture(context, silent, directory, "silence");
        test_fabricated_runs(silence, false);
        expect_unsupported_replacement(silence, "Thank you.", "silence fabrication");
        release(silence);
    }

    silent.release();
    whisper_free(context);
    if (failures > 0) {
        std::cerr << failures << " failure(s)\n";
        return 1;
    }
    std::cout << "prompt scoring tests passed\n";
    return 0;
}
