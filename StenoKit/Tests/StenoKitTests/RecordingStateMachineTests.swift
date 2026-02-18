import Testing
@testable import StenoKit

@Test("RecordingStateMachine enforces hands-free toggle start/stop semantics")
func recordingStateMachineHandsFreeToggle() {
    var machine = RecordingStateMachine()

    let first = machine.handleHandsFreeToggle()
    #expect(first == .start(mode: .handsFree))
    #expect(machine.state == .recordingHandsFree)

    let second = machine.handleHandsFreeToggle()
    #expect(second == .stop(mode: .handsFree))
    #expect(machine.state == .transcribing)

    let blocked = machine.handleHandsFreeToggle()
    switch blocked {
    case .ignore(let reason):
        #expect(!reason.isEmpty)
    default:
        Issue.record("Expected toggle to be ignored during transcribing")
    }

    machine.markTranscriptionCompleted()
    #expect(machine.state == .idle)
}

@Test("RecordingStateMachine keeps Option hold-to-talk independent")
func recordingStateMachineOptionFlow() {
    var machine = RecordingStateMachine()

    let start = machine.handleOptionKeyDown()
    #expect(start == .start(mode: .pressToTalk))
    #expect(machine.state == .recordingPressToTalk)

    let ignoreToggle = machine.handleHandsFreeToggle()
    switch ignoreToggle {
    case .ignore(let reason):
        #expect(!reason.isEmpty)
    default:
        Issue.record("Expected hands-free toggle to be ignored during Option recording")
    }

    let stop = machine.handleOptionKeyUp()
    #expect(stop == .stop(mode: .pressToTalk))
    #expect(machine.state == .transcribing)

    machine.markTranscriptionFailed()
    #expect(machine.state == .idle)
}
