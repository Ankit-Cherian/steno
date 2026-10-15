// Unit tests for the defective-window rules. The header is pure, so these
// tests compile without the whisper library. The window texts are real final
// decodes: Large V3 Turbo and small.en windows from long read, meeting and
// synthesized dictations decoded the way the app decodes them (beam 5, voice
// activity detection, the request prompt), next to ordinary windows of the
// same recordings and spoken repetitions that must be kept.

#include "../runtime-helper/steno_window_recovery.h"

#include <cmath>
#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;

void require(bool condition, const std::string & message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

using steno::WindowDefect;

std::vector<std::string> words(const std::string & text) {
    return steno::comparison_words(text);
}

WindowDefect classify(const std::string & text, const std::string & previous, double seconds = 30.0) {
    return steno::classify_window(words(text), words(previous), seconds);
}

// An ordinary 30 s window of read speech and the window that followed it.
const std::string kReadWindow =
    " leaning his shoulders against the partition of the tent, and remained thus, his face buried in "
    "his hands, with heaving chest and restless limbs. This has indeed been a harassing day, continued "
    "the young man, his eyes fixed upon his friend. You will be frank with me? I always am. Can you "
    "imagine why Buckingham has been so violent? I suspect. It is you who are mistaken, Rowell. I have "
    "read his distress in his eyes, in his every gesture and action the whole day. I can perceive love,";
const std::string kCollapsedAfterRead = " but, and I can see you who I am.";
const std::string kCopiedCollapse = " I can see you who I am. I can see you who I am.";

// A synthesized dictation window that looped and dropped what followed.
const std::string kDictationLoop =
    " I'm traveling to Chicago. I'm traveling to Chicago for the client visit. I'm traveling to "
    "Chicago for the client visit. I'm traveling to Chicago for the client visit. I'm traveling to "
    "Chicago for the client visit. The flight leaves at 7. 15 in the morning and lands around 9. The "
    "client meeting is at 1, and I want to have the slides finished before I get on the plane, ideally "
    "on Wednesday night. Friday I'm back in the office, and I have the retrospective with the team at "
    "10, and then I'd like to block the afternoon for deep work. One more thing, I need to remember to "
    "call my mom on Saturday because it's her birthday, and I still haven't ordered the flowers. So "
    "given all of that, can you put";
// The same window decoded again in pieces.
const std::string kDictationRecovered =
    " I'm traveling to Chicago for the client visit. The flight leaves at 7.15 in the morning and "
    "lands around 9. The client meeting is at 1, and I want to have the slides finished before I get on "
    "the plane, ideally on Wednesday night. Friday I'm back in the office, and I have the retrospective "
    "with the team at 10, and then I'd like to block the afternoon for deep work. One more thing, I "
    "need to remember to call my mom on Saturday because it's her birthday, and I still haven't "
    "ordered the flowers. So given all of that, can you put together a schedule that makes sense, and "
    "tell me where I'm overcommitted?";

// Meeting speech that looped, then the next window copied the loop.
const std::string kMeetingLoop =
    " We've seen Lyman alpha forest. We've seen Lyman alpha forest. We've seen Lyman alpha forest.";
const std::string kMeetingCopy = " We've seen Lyman alpha forest. We've seen Lyman alpha forest.";

// Read speech whose loop is followed by ordinary words.
const std::string kReadLoop =
    " I heard a noise behind. I heard a noise behind. I heard a noise behind. I turned and saw Kaffir, "
    "his black eyes shining, while in his hand, while in his hand he held a gleaming knife. He lifted "
    "it above his head, as if to strike, but I had the strength of ten men, and I hurled him from me.";

// Spoken repetitions and lists that must never be treated as loops.
const std::string kSpokenTerms = " Terms, Terms, Terms. Those are the exact words on the card.";
const std::string kSpokenNo = " No, no, no, no, no. That is not what I asked for.";
const std::string kSpokenList =
    " For the trip I need socks, socks, shirts, a charger, a charger cable, and the passport. Then "
    "milk, eggs, bread, milk, eggs, bread, coffee and tea. Item one, item two, item three.";
const std::string kSpokenRestart =
    " I think we should, I think we should move the meeting to Thursday, because the vendor is out "
    "on Friday and the team asked for more time.";
const std::string kSpokenPhraseThreeTimes =
    " I have this meeting, I have this meeting, I have this meeting.";

void test_words() {
    const std::vector<std::string> split = words(" I'm back in the office, and I'd like 7.15 caf\xc3\xa9!");
    const std::vector<std::string> expected = {"i'm", "back", "in", "the", "office", "and", "i'd", "like", "7", "15", "caf\xc3\xa9"};
    require(split == expected, "comparison words lowercase ASCII, keep apostrophes and multi-byte letters");
    require(words("").empty(), "empty text has no words");
}

void test_repetition() {
    const steno::Repetition loop = steno::longest_repetition(words(kDictationLoop));
    require(loop.phrase_words == 8 && loop.repeats == 4, "dictation loop is the eight-word phrase four times");
    require(steno::is_repetition_loop(loop), "dictation loop is a loop");
    require(steno::is_repetition_loop(steno::longest_repetition(words(kMeetingLoop))), "meeting loop is a loop");
    require(steno::is_repetition_loop(steno::longest_repetition(words(kReadLoop))), "read loop is a loop");

    for (const std::string * text : {&kSpokenTerms, &kSpokenNo, &kSpokenList, &kSpokenRestart, &kReadWindow, &kDictationRecovered}) {
        require(!steno::is_repetition_loop(steno::longest_repetition(words(*text))),
            "spoken repetition or ordinary text is not a loop: " + text->substr(0, 40));
    }
    const steno::Repetition terms = steno::longest_repetition(words(kSpokenTerms));
    require(terms.phrase_words == 1 && terms.repeats == 3, "three spoken Terms are one word three times");
    // Three deliberate copies of a four-word phrase reach the loop rule; the
    // recovery rule below keeps them because a fresh decode hears them too.
    require(steno::is_repetition_loop(steno::longest_repetition(words(kSpokenPhraseThreeTimes))),
        "a four-word phrase three times reaches the loop rule");
    require(steno::words_without_repeats(words(kDictationLoop)) == words(kDictationLoop).size() - 24,
        "collapsing the loop removes three copies of eight words");
}

void test_classification() {
    require(classify(kDictationLoop, kReadWindow) == WindowDefect::RepetitionLoop, "dictation loop window");
    require(classify(kMeetingLoop, kReadWindow) == WindowDefect::RepetitionLoop, "meeting loop window");
    require(classify(kMeetingCopy, kMeetingLoop) == WindowDefect::CopiesPreviousWindow, "meeting copy window");
    require(classify(kCopiedCollapse, kCollapsedAfterRead) == WindowDefect::CopiesPreviousWindow, "collapsed copy window");
    require(classify(kCopiedCollapse, kCopiedCollapse) == WindowDefect::CopiesPreviousWindow, "identical consecutive windows");
    require(classify(kCollapsedAfterRead, kReadWindow) == WindowDefect::MissingSpeech, "nine words for 30 s of speech");
    require(classify(kReadWindow, "") == WindowDefect::None, "ordinary read window");
    require(classify(kDictationRecovered, kReadWindow) == WindowDefect::None, "ordinary dictation window");
    require(classify(kSpokenTerms, "", 5.3) == WindowDefect::None, "spoken Terms recording");
    require(classify(kSpokenNo, "", 4.0) == WindowDefect::None, "spoken no recording");
    require(classify(kSpokenList, "", 12.0) == WindowDefect::None, "spoken list recording");
    require(classify(kSpokenRestart, "", 9.0) == WindowDefect::None, "restarted clause");
    // A short final window or a short recording is never judged sparse.
    require(classify(" Thanks.", kReadWindow, 4.9) == WindowDefect::None, "short final window");
    require(classify(" Thanks, that's everything for now.", kReadWindow, 5.0) == WindowDefect::None,
        "five words in five seconds is not sparse");
    require(classify(" Thanks.", kReadWindow, 5.0) == WindowDefect::MissingSpeech, "one word in five seconds is sparse");
    // A window that repeats one sentence of the previous window is not a copy.
    require(classify(" I can perceive love, and the rest of the evening passed quietly in the tent while the "
                     "young man watched the shadows move across the grass outside.",
                     kReadWindow, 10.0) == WindowDefect::None, "one shared phrase is not a copy");
}

void test_replacement() {
    require(steno::recovery_replaces(WindowDefect::RepetitionLoop, words(kDictationLoop), words(kDictationRecovered), words(kReadWindow), {}),
        "recovered dictation replaces the loop");
    require(!steno::recovery_replaces(WindowDefect::RepetitionLoop, words(kSpokenPhraseThreeTimes), words(kSpokenPhraseThreeTimes), {}, {}),
        "a repetition the fresh decode also hears is kept");
    require(!steno::recovery_replaces(WindowDefect::RepetitionLoop, words(kDictationLoop), words(" I'm traveling to Chicago."), {}, {}),
        "a recovery that loses the loop's surrounding words is rejected");
    require(steno::recovery_replaces(WindowDefect::CopiesPreviousWindow, words(kCopiedCollapse), words(kReadWindow), words(kCollapsedAfterRead), {}),
        "recovered speech replaces a copied window");
    require(steno::recovery_replaces(WindowDefect::MissingSpeech, words(kCollapsedAfterRead), words(kReadWindow), {}, {}),
        "recovered speech replaces a sparse window");
    require(!steno::recovery_replaces(WindowDefect::MissingSpeech, words(kCollapsedAfterRead), words(" Thank you. Thank you."), {}, {}),
        "a few hallucinated words do not replace a sparse window");
    require(!steno::recovery_replaces(WindowDefect::MissingSpeech, words(" one two three four five six seven eight nine ten"),
        words(" one two three four five six seven eight nine ten eleven twelve thirteen fourteen"), {}, {}),
        "recovery needs a clear gain in words");
    require(!steno::recovery_replaces(WindowDefect::CopiesPreviousWindow, words(kCopiedCollapse), {}, {}, {}),
        "an empty recovery never replaces");
    require(!steno::recovery_replaces(WindowDefect::MissingSpeech, words(kCollapsedAfterRead), words(kDictationLoop), {}, {}),
        "a looping recovery never replaces");
    require(!steno::recovery_replaces(WindowDefect::None, words(kReadWindow), words(kDictationRecovered), {}, {}),
        "a sound window is never replaced");
}

// Recovery prompts its first piece with the end of the window before. On audio
// with little speech the decoder can answer with that prompt, which is the
// previous window's text again and not recovered speech.
void test_echoed_prompt_is_rejected() {
    const std::string tail = kReadWindow.substr(kReadWindow.size() - 200);
    const std::string echo = tail.substr(tail.find(' ') + 1);
    require(words(echo).size() >= 30, "the echoed prompt is long enough to pass the word-gain rule");
    require(classify(echo, kReadWindow) == WindowDefect::CopiesPreviousWindow, "an echoed prompt is a copy of the previous window");
    require(!steno::recovery_replaces(WindowDefect::MissingSpeech, words(" you"), words(echo), words(kReadWindow), words(echo)),
        "an echo of the previous window never replaces a sparse window");
    require(!steno::recovery_replaces(WindowDefect::CopiesPreviousWindow, words(kCopiedCollapse), words(echo), words(kReadWindow), words(echo)),
        "an echo of the previous window never replaces a copying window");
    // The window before may itself have been replaced, so the prompt is the
    // recovered text and the originally decoded previous window differs.
    require(!steno::recovery_replaces(WindowDefect::MissingSpeech, words(" you"), words(echo), words(kCollapsedAfterRead), words(echo)),
        "an echo of the prompt never replaces a sparse window");
    require(steno::recovery_replaces(WindowDefect::MissingSpeech, words(" you"), words(kDictationRecovered), words(kReadWindow), words(echo)),
        "recovered speech that does not echo the previous window still replaces it");
}

void test_pieces() {
    const size_t rate = 16000;
    std::vector<float> audio(30 * rate, 0.5f);
    // Pauses at 7 s and 16 s; the rest is loud.
    for (size_t index = 7 * rate; index < 7 * rate + rate / 5; ++index) {
        audio[index] = 0.0f;
    }
    for (size_t index = 16 * rate; index < 16 * rate + rate / 5; ++index) {
        audio[index] = 0.0f;
    }
    const auto pieces = steno::recovery_pieces(audio.data(), audio.size(), 10 * rate, rate / 10, 2 * rate);
    require(pieces.size() == 4, "a 30 s window splits into four pieces of at most 10 s");
    require(!pieces.empty() && pieces.front().first == 0 && pieces.back().second == audio.size(), "pieces cover the window");
    for (size_t index = 0; index < pieces.size(); ++index) {
        require(pieces[index].second - pieces[index].first <= 10 * rate || index + 1 == pieces.size(),
            "every piece but the last is at most 10 s");
        if (index > 0) {
            require(pieces[index].first == pieces[index - 1].second, "pieces are contiguous");
        }
    }
    require(pieces.size() > 1 && pieces[0].second > 7 * rate && pieces[0].second < 7 * rate + rate / 5,
        "the first cut falls inside the 7 s pause");
    require(pieces.size() > 1 && pieces[1].second > 16 * rate && pieces[1].second < 16 * rate + rate / 5,
        "the second cut falls inside the 16 s pause");

    const std::vector<float> short_audio(9 * rate, 0.5f);
    const auto single = steno::recovery_pieces(short_audio.data(), short_audio.size(), 10 * rate, rate / 10, 2 * rate);
    require(single.size() == 1 && single[0].first == 0 && single[0].second == short_audio.size(), "a short window is one piece");

    const std::vector<float> with_tail(11 * rate, 0.5f);
    const auto merged = steno::recovery_pieces(with_tail.data(), with_tail.size(), 10 * rate, rate / 10, 2 * rate);
    require(!merged.empty() && merged.back().second == with_tail.size(), "pieces end at the window end");
    require(steno::recovery_pieces(audio.data(), 0, 10 * rate, rate / 10, 2 * rate).empty(), "no audio has no pieces");
}

} // namespace

int main() {
    test_words();
    test_repetition();
    test_classification();
    test_replacement();
    test_echoed_prompt_is_rejected();
    test_pieces();
    if (failures != 0) {
        std::cerr << failures << " window-recovery check(s) failed\n";
        return 1;
    }
    std::cout << "Window-recovery checks passed\n";
    return 0;
}
