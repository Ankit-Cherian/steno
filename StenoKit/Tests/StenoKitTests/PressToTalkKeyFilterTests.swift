import Foundation
import Testing
@testable import StenoKit

@Suite("Press-to-talk key filter")
struct PressToTalkKeyFilterTests {
    private typealias Filter = PressToTalkKeyFilter
    private let window = PressToTalkKeyFilter.defaultConfirmationDelay

    @Test("Option held alone starts capture at once and confirms after the window")
    func optionAloneDictates() {
        var filter = Filter()
        #expect(filter.handle(.modifiersChanged([.option]), at: 10) == [.start])
        #expect(filter.confirmationDeadline == 10 + window)
        #expect(filter.handle(.confirmationDeadline, at: 10 + window) == [.confirm])
        #expect(filter.handle(.modifiersChanged([]), at: 12) == [.stop])
        #expect(filter.phase == .idle)
    }

    @Test("Option+Arrow and Option+Delete are discarded")
    func optionWithKeyIsDiscarded() {
        // Arrow and Delete arrive as ordinary key-downs while Option is held.
        var filter = Filter()
        #expect(filter.handle(.modifiersChanged([.option]), at: 10) == [.start])
        #expect(filter.handle(.keyDown, at: 10.06) == [.discard])
        #expect(filter.handle(.confirmationDeadline, at: 10 + window) == [])
        #expect(filter.handle(.keyDown, at: 10.2) == [])
        #expect(filter.handle(.modifiersChanged([]), at: 10.3) == [])
        #expect(filter.phase == .idle)
    }

    @Test("A key pressed after the window still discards the recording")
    func slowShortcutIsDiscarded() {
        // Option+L types @ on many layouts; people often pause before the key.
        var filter = Filter()
        _ = filter.handle(.modifiersChanged([.option]), at: 10)
        #expect(filter.handle(.confirmationDeadline, at: 10 + window) == [.confirm])
        #expect(filter.handle(.keyDown, at: 10.4) == [.discard])
        #expect(filter.handle(.modifiersChanged([]), at: 10.5) == [])
    }

    @Test("Cmd+Option+I never starts when the other modifier is already down")
    func otherModifierFirstNeverStarts() {
        var filter = Filter()
        #expect(filter.handle(.modifiersChanged([.command]), at: 10) == [])
        #expect(filter.handle(.modifiersChanged([.command, .option]), at: 10.05) == [])
        #expect(filter.handle(.keyDown, at: 10.1) == [])
        // Releasing Cmd first leaves Option alone, but this press stays a shortcut.
        #expect(filter.handle(.modifiersChanged([.option]), at: 10.2) == [])
        #expect(filter.handle(.confirmationDeadline, at: 10.4) == [])
        #expect(filter.handle(.modifiersChanged([]), at: 10.5) == [])
        #expect(filter.phase == .idle)
    }

    @Test("Option then Cmd, Shift, or Control is discarded")
    func modifierAddedAfterOptionIsDiscarded() {
        for other: Filter.Modifiers in [.command, .shift, .control] {
            var filter = Filter()
            #expect(filter.handle(.modifiersChanged([.option]), at: 10) == [.start])
            #expect(filter.handle(.modifiersChanged([.option, other]), at: 10.04) == [.discard])
            #expect(filter.handle(.keyDown, at: 10.08) == [])
            #expect(filter.handle(.modifiersChanged([]), at: 10.2) == [])
        }
    }

    @Test("A quick Option tap is discarded")
    func quickTapIsDiscarded() {
        var filter = Filter()
        #expect(filter.handle(.modifiersChanged([.option]), at: 10) == [.start])
        #expect(filter.handle(.modifiersChanged([]), at: 10.08) == [.discard])
        #expect(filter.phase == .idle)
    }

    @Test("Option-click is discarded")
    func optionClickIsDiscarded() {
        var filter = Filter()
        _ = filter.handle(.modifiersChanged([.option]), at: 10)
        #expect(filter.handle(.pointerDown, at: 10.05) == [.discard])
    }

    @Test("A release after the window counts even when the deadline was not processed yet")
    func lateDeadlineStillStops() {
        var filter = Filter()
        _ = filter.handle(.modifiersChanged([.option]), at: 10)
        #expect(filter.handle(.modifiersChanged([]), at: 10.4) == [.confirm, .stop])
    }

    @Test("Modifiers added during a confirmed dictation wait for a key before discarding")
    func modifierDuringDictationDoesNotDiscard() {
        var filter = Filter()
        _ = filter.handle(.modifiersChanged([.option]), at: 10)
        _ = filter.handle(.confirmationDeadline, at: 10 + window)
        #expect(filter.handle(.modifiersChanged([.option, .shift]), at: 11) == [])
        #expect(filter.handle(.pointerDown, at: 11.5) == [])
        #expect(filter.handle(.modifiersChanged([.option]), at: 12) == [])
        #expect(filter.handle(.modifiersChanged([]), at: 13) == [.stop])
    }

    @Test("A deadline that fires early does not confirm")
    func earlyDeadlineDoesNotConfirm() {
        var filter = Filter()
        _ = filter.handle(.modifiersChanged([.option]), at: 10)
        #expect(filter.handle(.confirmationDeadline, at: 10.05) == [])
        #expect(filter.handle(.confirmationDeadline, at: 10 + window) == [.confirm])
    }

    @Test("Keys and clicks without Option do nothing")
    func eventsWithoutOptionAreIgnored() {
        var filter = Filter()
        #expect(filter.handle(.keyDown, at: 10) == [])
        #expect(filter.handle(.pointerDown, at: 10.1) == [])
        #expect(filter.handle(.modifiersChanged([.shift]), at: 10.2) == [])
        #expect(filter.handle(.modifiersChanged([]), at: 10.3) == [])
        #expect(filter.phase == .idle)
    }
}

@Test("An Option shortcut cancels only an Option recording")
func optionShortcutCancelsOnlyPressToTalk() {
    var machine = RecordingStateMachine()
    #expect(machine.handleOptionKeyDown() == .start(mode: .pressToTalk))
    #expect(machine.handleOptionShortcut() == .cancel(mode: .pressToTalk))
    #expect(machine.state == .idle)

    for state: RecordingLifecycleState in [.idle, .recordingHandsFree, .transcribing] {
        var other = RecordingStateMachine(initialState: state)
        guard case .ignore = other.handleOptionShortcut() else {
            Issue.record("Expected \(state) to ignore an Option shortcut")
            continue
        }
        #expect(other.state == state)
    }
}
