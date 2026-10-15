import Foundation
import Testing
@testable import StenoKit

/// A five-minute dictation whose seventh 30 s window the final decode used to
/// lose: with small.en and the request prompt, that window of about a hundred
/// words came back as one word. The audio is synthesized on this machine with
/// the system voice, so no recording is stored; a different voice version can
/// move the window boundaries and avoid the collapse, so the expectations
/// below hold either way. Opt in with STENO_TEST_WINDOW_RECOVERY=1 and the
/// retained helper, model and VAD model variables the other integration tests
/// use. It runs for under a minute with small.en on Apple silicon.
@Test("A long dictation keeps every window of speech through the final decode")
func retainedHelperRecoversLongDictationWindows() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["STENO_TEST_WINDOW_RECOVERY"] == "1",
          let helperPath = environment["STENO_TEST_RETAINED_HELPER"],
          let modelPath = environment["STENO_TEST_WHISPER_MODEL"],
          let vadPath = environment["STENO_TEST_WHISPER_VAD"]
    else {
        return
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-window-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let script = LongDictationScript.sentences
    let audioURL = directory.appendingPathComponent("dictation.wav")
    try LongDictationScript.synthesize(into: audioURL, scratch: directory)

    let fallbackState = WindowRecoveryFallbackState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: URL(fileURLWithPath: helperPath),
            modelPath: URL(fileURLWithPath: modelPath),
            threadCount: 8,
            vadModelPath: URL(fileURLWithPath: vadPath),
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            beamSize: 5,
            bestOf: 5
        ),
        fallback: WindowRecoveryFallbackEngine(state: fallbackState)
    )
    let request = TranscriptionRequest(languageHints: ["en-US"], hotTerms: ["Priya", "Marcus"])
    let transcript = try await engine.transcribe(audioURL: audioURL, request: request)
    await engine.shutdown()
    #expect(await fallbackState.count == 0, "the transcript came from the fallback, not the helper")

    let reference = recoveryComparisonWords(script.joined(separator: " "))
    let hypothesis = recoveryComparisonWords(transcript.text)
    let errorRate = Double(recoveryEditDistance(reference, hypothesis)) / Double(reference.count)
    let coverage = Double(hypothesis.count) / Double(reference.count)
    print("Window recovery dictation: \(reference.count) reference words, \(hypothesis.count) transcript words, word error rate \(String(format: "%.3f", errorRate))")
    #expect(coverage >= 0.9, "the transcript holds \(hypothesis.count) of \(reference.count) words")
    #expect(errorRate <= 0.1, "word error rate \(errorRate)")
    let repetition = longestConsecutiveRepetition(hypothesis)
    #expect(
        !(repetition.phraseWords >= 4 && repetition.repeats >= 3),
        "the transcript repeats a \(repetition.phraseWords)-word phrase \(repetition.repeats) times"
    )
}

private enum LongDictationScript {
    static let body = [
        "Okay so I want you to help me plan out my week because it's getting a little bit out of hand.",
        "On Monday I have the design review with the product team at ten in the morning, and then I have lunch with Priya to talk about the hiring plan.",
        "After that I need to finish the quarterly report, which is mostly done, but the numbers for the west region still need to be checked.",
        "Tuesday is mostly free, except I have a dentist appointment at two thirty, so I can't take any calls between two and four.",
        "I was thinking I could use Tuesday morning to write the proposal for the new onboarding flow.",
        "The proposal needs to cover the three options we talked about last week, the cost of each one, and what we would need from engineering.",
        "Wednesday is the busy day. I have the all hands at nine, then the budget meeting at eleven, and then a one on one with my manager at three.",
        "I also promised Marcus that I would review his pull request before Wednesday evening, so that needs to fit in somewhere.",
        "Thursday I'm traveling to Chicago for the client visit. The flight leaves at seven fifteen in the morning and lands around nine.",
        "The client meeting is at one, and I want to have the slides finished before I get on the plane, ideally on Wednesday night.",
        "Friday I'm back in the office, and I have the retrospective with the team at ten, and then I'd like to block the afternoon for deep work.",
        "One more thing, I need to remember to call my mom on Saturday because it's her birthday, and I still haven't ordered the flowers.",
        "So given all of that, can you put together a schedule that makes sense, and tell me where I'm overcommitted?",
        "Also, if there's anything I should move to the following week, point it out and explain why.",
    ]
    static let ending = [
        "And then on Friday afternoon I have this meeting with the vendor about the contract renewal.",
        "I have this meeting that I keep forgetting about, and I really need to prepare the questions for it.",
        "I have this meeting, and honestly I'm not sure it needs to happen at all, so maybe we can cancel it.",
        "If we cancel it, send the vendor an email on Thursday and ask them to share the pricing in writing instead.",
        "Then I can spend that time finishing the slides and catching up on email.",
        "Thanks, that's everything for now.",
    ]
    static var sentences: [String] { body + body + ending }

    /// One voice at a dictation pace, pauses of 0.3, 0.8 and 6 s in turn, a
    /// closing passage that fades to a low level, and 8 s of trailing room
    /// noise.
    static func synthesize(into output: URL, scratch: URL) throws {
        let all = sentences
        var samples: [Int16] = []
        var noise = UInt32(2)
        let pauses = [300, 800, 6000]
        for (index, sentence) in all.enumerated() {
            let clip = scratch.appendingPathComponent("sentence-\(index).wav")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [
                "-v", "Samantha", "-r", "160", "-o", clip.path,
                "--file-format=WAVE", "--data-format=LEI16@16000", sentence,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw WindowRecoveryFixtureError.synthesisFailed(index)
            }
            let endingIndex = index - (all.count - ending.count)
            let gain = endingIndex >= 0 ? max(0.12, 1.0 - Double(endingIndex) * 0.15) : 1.0
            for sample in try pcmSamples(of: clip) {
                samples.append(Int16(clamping: Int((Double(sample) * gain).rounded(.towardZero))))
            }
            let pauseMS = index == all.count - 1 ? 8000 : pauses[index % pauses.count]
            for _ in 0..<(16 * pauseMS) {
                noise = noise &* 1_103_515_245 &+ 12_345
                samples.append(Int16(Int((noise >> 16) % 61) - 30))
            }
        }
        try writeWAV(samples, to: output)
    }

    static func pcmSamples(of url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        var position = 12
        while position + 8 <= data.count {
            let identifier = String(decoding: data[position..<(position + 4)], as: UTF8.self)
            let size = data[(position + 4)..<(position + 8)].enumerated().reduce(0) { total, byte in
                total | (Int(byte.element) << (8 * byte.offset))
            }
            if identifier == "data" {
                let end = min(data.count, position + 8 + size)
                var samples: [Int16] = []
                samples.reserveCapacity((end - position - 8) / 2)
                var index = position + 8
                while index + 1 < end {
                    samples.append(Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8)))
                    index += 2
                }
                return samples
            }
            position += 8 + size + (size & 1)
        }
        throw WindowRecoveryFixtureError.missingAudio
    }

    static func writeWAV(_ samples: [Int16], to url: URL) throws {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(payload)
        for sample in samples { append(UInt16(bitPattern: sample)) }
        try data.write(to: url)
    }
}

private enum WindowRecoveryFixtureError: Error {
    case synthesisFailed(Int)
    case missingAudio
}

private func recoveryComparisonWords(_ text: String) -> [String] {
    let numbers = [
        "1": "one", "2": "two", "3": "three", "4": "four", "7": "seven", "9": "nine",
        "10": "ten", "11": "eleven", "15": "fifteen", "30": "thirty",
    ]
    let lowered = text.lowercased().unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
    }
    return String(lowered).split(separator: " ").map { numbers[String($0)] ?? String($0) }
}

private func recoveryEditDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
    guard !hypothesis.isEmpty else { return reference.count }
    var row = Array(0...hypothesis.count)
    for (index, word) in reference.enumerated() {
        var previous = row[0]
        row[0] = index + 1
        for column in 1...hypothesis.count {
            let current = row[column]
            row[column] = min(row[column] + 1, row[column - 1] + 1, previous + (word == hypothesis[column - 1] ? 0 : 1))
            previous = current
        }
    }
    return row[hypothesis.count]
}

private func longestConsecutiveRepetition(_ words: [String]) -> (phraseWords: Int, repeats: Int) {
    var best = (phraseWords: 0, repeats: 0)
    guard words.count >= 2 else { return best }
    for phrase in 1...min(32, words.count / 2) {
        var start = 0
        while start + 2 * phrase <= words.count {
            var repeats = 1
            while start + (repeats + 1) * phrase <= words.count,
                  words[(start + repeats * phrase)..<(start + (repeats + 1) * phrase)] == words[start..<(start + phrase)] {
                repeats += 1
            }
            if repeats >= 2, phrase * repeats > best.phraseWords * best.repeats {
                best = (phrase, repeats)
            }
            start += 1
        }
    }
    return best
}

private actor WindowRecoveryFallbackState {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct WindowRecoveryFallbackEngine: TranscriptionEngine {
    let state: WindowRecoveryFallbackState

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        await state.record()
        return RawTranscript(text: "fallback")
    }
}
