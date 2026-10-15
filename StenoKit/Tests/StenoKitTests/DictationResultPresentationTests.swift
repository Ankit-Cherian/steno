import Foundation
import Testing
@testable import StenoKit

@Suite("What the overlay says after a dictation")
struct DictationResultPresentationTests {
    private static func result(
        _ status: InsertionStatus,
        method: InsertionMethod = .direct,
        pasted: Bool? = nil,
        reason: InsertionCopyReason? = nil,
        historyWarning: String? = nil,
        captureWarning: String? = nil
    ) -> InsertResult {
        var result = InsertResult(
            status: status,
            method: method,
            insertedText: "Hello",
            pasteAttempted: pasted,
            copyReason: reason
        )
        result.historyWarning = historyWarning
        result.captureWarning = captureWarning
        return result
    }

    @Test("Each insertion outcome maps to one overlay result", arguments: [
        (result(.inserted), OverlayResult?.some(.inserted(appName: "Mail", method: .typed))),
        (result(.inserted, method: .accessibility), .inserted(appName: "Mail", method: .accessibility)),
        (result(.copiedOnly, method: .clipboardPaste, pasted: true), .inserted(appName: "Mail", method: .pasted)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .secureField), .copied(.secureField)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .fieldChanged), .copied(.fieldChanged)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .appChanged), .copied(.appChanged)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .appNotResponding), .copied(.appNotResponding)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .accessibilityOff), .copied(.accessibilityOff)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .noTextField), .copied(.noTextField)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .other), .copied(.other)),
        (result(.copiedOnly, method: .clipboardPaste), .copied(.other)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .clipboardChanged), .notPasted),
        (result(.failed, method: .none), .failed(savedInHistory: true)),
        (result(.failed, method: .none, historyWarning: "disk full"), .failed(savedInHistory: false)),
        (result(.inserted, captureWarning: "Mic gone"), .microphoneDisconnected(insertedPartial: true)),
        (result(.copiedOnly, method: .clipboardPaste, pasted: true, captureWarning: "Mic gone"),
         .microphoneDisconnected(insertedPartial: true)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .fieldChanged, captureWarning: "Mic gone"),
         .microphoneDisconnected(insertedPartial: false)),
        (result(.copiedOnly, method: .clipboardPaste, reason: .clipboardChanged, captureWarning: "Mic gone"), .notPasted),
        (result(.noSpeech, method: .none), nil),
    ])
    func mapping(result: InsertResult, expected: OverlayResult?) {
        #expect(DictationResultPresentation.overlayResult(for: result, appName: "Mail") == expected)
    }

    private static let typed = OverlayResult.inserted(appName: "Mail", method: .typed)
    private static let pasted = OverlayResult.inserted(appName: "Terminal", method: .pasted)

    @Test("The success rule", arguments: [
        // A paste is always said in words, whatever the setting.
        (pasted, SuccessNoticeStyle.matters, 0, ResultPresentation.overlay(.result(pasted, showsWords: true))),
        (pasted, .matters, 25, .overlay(.result(pasted, showsWords: true))),
        (pasted, .always, 25, .overlay(.result(pasted, showsWords: true))),
        (pasted, .nothing, 25, .overlay(.result(pasted, showsWords: true))),
        // "Always say where" always uses words.
        (typed, .always, 0, .overlay(.result(typed, showsWords: true))),
        (typed, .always, 400, .overlay(.result(typed, showsWords: true))),
        // "Show nothing" shows no overlay but still announces.
        (typed, .nothing, 0, .silent(announcement: "Inserted into Mail")),
        (typed, .nothing, 400, .silent(announcement: "Inserted into Mail")),
        // "Only when it matters": words for the first 20, then the brief check.
        (typed, .matters, 0, .overlay(.result(typed, showsWords: true))),
        (typed, .matters, 19, .overlay(.result(typed, showsWords: true))),
        (typed, .matters, 20, .overlay(.result(typed, showsWords: false))),
        (typed, .matters, 21, .overlay(.result(typed, showsWords: false))),
    ])
    func successRule(result: OverlayResult, style: SuccessNoticeStyle, shown: Int, expected: ResultPresentation) {
        #expect(DictationResultPresentation.presentation(of: result, style: style, successNoticesShown: shown) == expected)
    }

    @Test("Copies and problems always show words, even with Show nothing", arguments: [
        OverlayResult.copied(.secureField), .notPasted, .failed(savedInHistory: true),
        .microphoneDisconnected(insertedPartial: true), .transcriptionFailed, .microphoneAccessOff,
        .shortcutsUnavailable, .speechModelMissing,
    ])
    func problemsAlwaysShow(result: OverlayResult) {
        for style in SuccessNoticeStyle.allCases {
            #expect(DictationResultPresentation.presentation(of: result, style: style, successNoticesShown: 99)
                == .overlay(.result(result, showsWords: true)))
        }
    }

    @Test("Show nothing without an app name announces Inserted")
    func announcementWithoutApp() {
        #expect(DictationResultPresentation.presentation(
            of: .inserted(appName: nil, method: .typed), style: .nothing, successNoticesShown: 0
        ) == .silent(announcement: "Inserted"))
    }

    @Test("Saved values for After inserting", arguments: [
        (String?.none, SuccessNoticeStyle.matters), ("matters", .matters), ("always", .always),
        ("nothing", .nothing), ("sometimes", .matters),
    ])
    func preferenceValues(raw: String?, expected: SuccessNoticeStyle) {
        #expect(SuccessNoticeStyle(preferenceValue: raw) == expected)
    }

    @Test("Only a successful insertion shown with words counts toward the first 20")
    func countsTowardLimit() {
        #expect(DictationResultPresentation.isSuccessNoticeWithWords(.result(Self.typed, showsWords: true)))
        #expect(DictationResultPresentation.isSuccessNoticeWithWords(.result(Self.pasted, showsWords: true)))
        #expect(!DictationResultPresentation.isSuccessNoticeWithWords(.result(Self.typed, showsWords: false)))
        #expect(!DictationResultPresentation.isSuccessNoticeWithWords(.result(.copied(.other), showsWords: true)))
    }

    private static let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Durations follow the design", arguments: [
        (OverlayState.result(typed, showsWords: false), TimeInterval?.some(0.6)),
        (.result(typed, showsWords: true), 2),
        (.result(pasted, showsWords: true), 2),
        (.result(.copied(.appChanged), showsWords: true), 4),
        (.result(.failed(savedInHistory: true), showsWords: true), 6),
        (.result(.notPasted, showsWords: true), 6),
        (.discarded(undoUntil: reference.addingTimeInterval(5)), 5),
        (.busy(.stillFinishing), 1.6),
        (.transcribing, nil),
        (.listening(handsFree: false, elapsedSeconds: 0), nil),
    ])
    func durations(state: OverlayState, expected: TimeInterval?) {
        // The overlay times every state itself, so this is the one place durations live.
        #expect(OverlayPresentation.make(for: state, now: Self.reference).duration == expected)
    }
}
