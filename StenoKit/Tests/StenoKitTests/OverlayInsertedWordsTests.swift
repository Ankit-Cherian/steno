import Testing
@testable import StenoKit

@Suite("Words offered to the overlay after an insertion")
struct OverlayInsertedWordsTests {
    private let inserted = OverlayState.result(.inserted(appName: "Mail", method: .typed), showsWords: true)

    private func insertResult(_ text: String, concealed: Bool? = nil, paste: Bool = false) -> InsertResult {
        InsertResult(
            status: paste ? .copiedOnly : .inserted, method: paste ? .clipboardPaste : .accessibility, insertedText: text,
            pasteAttempted: paste ? true : nil, copyIsConcealed: concealed
        )
    }

    @Test("The words line is the first line with words, trimmed and bounded")
    func firstLine() {
        #expect(DictationResultPresentation.insertedWordsLine(of: "  Move the meeting.  \nSecond line") == "Move the meeting.")
        #expect(DictationResultPresentation.insertedWordsLine(of: "\n\n  Later line  ") == "Later line")
        #expect(DictationResultPresentation.insertedWordsLine(of: "   \n ") == nil)
        #expect(DictationResultPresentation.insertedWordsLine(of: "") == nil)
        #expect(DictationResultPresentation.insertedWordsLine(of: nil) == nil)
        let long = String(repeating: "word ", count: 200)
        #expect((DictationResultPresentation.insertedWordsLine(of: long) ?? "").count <= DictationResultPresentation.overlayWordsLimit)
    }

    @Test("The controller offers words only for an insertion the After inserting rule says in words")
    func offeredWords() {
        let said = insertResult("Move the planning meeting to Friday")
        #expect(DictationResultPresentation.overlayWords(for: said, state: inserted) == "Move the planning meeting to Friday")
        let pasted = OverlayState.result(.inserted(appName: "Terminal", method: .pasted), showsWords: true)
        #expect(DictationResultPresentation.overlayWords(for: insertResult("ls -la", paste: true), state: pasted) == "ls -la")
        // The brief confirmation ("Only when it matters", after the first twenty) shows no words.
        let brief = OverlayState.result(.inserted(appName: "Mail", method: .typed), showsWords: false)
        #expect(DictationResultPresentation.overlayWords(for: said, state: brief) == nil)
        // A secure-field or concealed copy never does, and neither does a result with no words.
        #expect(DictationResultPresentation.overlayWords(for: insertResult("hunter2", concealed: true), state: inserted) == nil)
        #expect(DictationResultPresentation.overlayWords(for: insertResult("hunter2", concealed: true, paste: true), state: pasted) == nil)
        #expect(DictationResultPresentation.overlayWords(for: insertResult("  \n "), state: inserted) == nil)
        // Copies and problems never carry words.
        for state in [OverlayState.result(.copied(.secureField), showsWords: true), .result(.copied(.other), showsWords: true),
                      .result(.failed(savedInHistory: true), showsWords: true), .result(.notPasted, showsWords: true),
                      .transcribing, .noSpeechDetected] {
            #expect(DictationResultPresentation.overlayWords(for: said, state: state) == nil, "\(state)")
        }
    }

    @Test("Show nothing shows nothing: the presentation is silent, so no words are offered")
    func showNothing() {
        let result = OverlayResult.inserted(appName: "Mail", method: .typed)
        let presentation = DictationResultPresentation.presentation(of: result, style: .nothing, successNoticesShown: 0)
        guard case .silent = presentation else { Issue.record("expected a silent presentation"); return }
        // Only Always and Only when it matters (while it still names the app) say words.
        for style in [SuccessNoticeStyle.always, .matters] {
            guard case .overlay(let state) = DictationResultPresentation.presentation(of: result, style: style, successNoticesShown: 0) else {
                Issue.record("expected an overlay"); return
            }
            #expect(DictationResultPresentation.overlayWords(for: insertResult("Hello there"), state: state) == "Hello there")
        }
        guard case .overlay(let late) = DictationResultPresentation.presentation(
            of: result, style: .matters, successNoticesShown: DictationResultPresentation.wordsNoticeLimit
        ) else { Issue.record("expected an overlay"); return }
        #expect(DictationResultPresentation.overlayWords(for: insertResult("Hello there"), state: late) == nil)
    }
}
