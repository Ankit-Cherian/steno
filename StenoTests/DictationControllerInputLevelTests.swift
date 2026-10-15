import AppKit
import CoreAudio
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@MainActor
@Suite("Input level and microphone in the controller")
struct DictationControllerInputLevelTests {
    // MARK: - Overlay level

    @Test("Levels reach the overlay only while recording, and drop to zero when it is cancelled")
    func levelsStopAfterCancel() async {
        let meter = InputLevelMeter(schedulesTimer: false)
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            coordinator: CaptureTestCoordinator(
                result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused")
            ),
            inputLevelMeter: meter
        )
        defer { controller.teardown() }
        var forwarded: [Float] = []
        controller.inputLevelObserver = { forwarded.append($0) }
        var decibels: Float = -20
        meter.start { decibels }

        // Before any dictation, nothing is forwarded.
        meter.tick(now: 1)
        #expect(forwarded.isEmpty)

        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        meter.tick(now: 2)
        #expect(forwarded.last.map { $0 > 0 } == true)

        controller.cancelActiveRecording()
        #expect(forwarded.last == 0)
        let count = forwarded.count
        decibels = -5
        meter.tick(now: 3)
        meter.tick(now: 4)
        #expect(forwarded.count == count)
    }

    @Test("Levels drop to zero the moment a recording is stopped")
    func levelsStopAfterStop() async {
        let meter = InputLevelMeter(schedulesTimer: false)
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            coordinator: CaptureTestCoordinator(
                result: InsertResult(status: .inserted, method: .accessibility, insertedText: "Words")
            ),
            inputLevelMeter: meter
        )
        defer { controller.teardown() }
        var forwarded: [Float] = []
        controller.inputLevelObserver = { forwarded.append($0) }
        meter.start { -15 }

        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        meter.tick(now: 1)
        #expect(forwarded.last.map { $0 > 0 } == true)

        controller.stopRecording()
        // Synchronously, before transcription or media release run.
        #expect(forwarded.last == 0)
        #expect(!controller.isRecording)
        let count = forwarded.count
        meter.tick(now: 2)
        #expect(forwarded.count == count)
        #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
    }

    @Test("Levels drop to zero the moment a long recording is discarded and held for Undo")
    func levelsStopAfterHeldDiscard() async {
        let meter = InputLevelMeter(schedulesTimer: false)
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            coordinator: CaptureTestCoordinator(
                result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused")
            ),
            inputLevelMeter: meter
        )
        defer { controller.teardown() }
        controller.undoDiscardMinimumRecording = 0
        controller.undoDiscardWindow = .seconds(30)
        var forwarded: [Float] = []
        controller.inputLevelObserver = { forwarded.append($0) }
        var decibels: Float = -20
        meter.start { decibels }

        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        meter.tick(now: 1)
        #expect(forwarded.last.map { $0 > 0 } == true)

        controller.cancelActiveRecording()
        #expect(controller.canUndoDiscard)
        #expect(forwarded.last == 0)
        let count = forwarded.count
        decibels = -5
        meter.tick(now: 2)
        meter.tick(now: 3)
        #expect(forwarded.count == count)
    }

    // MARK: - Microphone test and dictation

    @Test("A press starts capture before a running microphone test is ended")
    func captureStartsBeforeTestEnds() async throws {
        let order = OrderLog()
        let hotkey = FilteringHotkeyService()
        let controller = makeTestDictationController(
            hotkey: hotkey,
            overlay: makeShortcutTestPresenter(),
            coordinator: OrderedCaptureCoordinator(order: order),
            makeMicrophoneTester: { _ in RecordingMicrophoneTester(order: order) }
        )
        defer { controller.teardown() }

        controller.microphone.startTest(deviceID: nil)
        #expect(controller.microphone.isTesting)

        hotkey.press([.option])
        hotkey.holdPastConfirmationWindow()
        #expect(await waitForShortcutCondition { controller.isRecording })
        #expect(!controller.microphone.isTesting)
        let events = order.events
        let captureIndex = try #require(events.firstIndex(of: "capture.start"))
        let testStopIndex = try #require(events.firstIndex(of: "test.stop"))
        #expect(captureIndex < testStopIndex, "\(events)")
        hotkey.press([], after: 1)
    }

    @Test("The microphone test is refused during a dictation and never opens an input")
    func testRefusedDuringDictation() async {
        let sources = SourceLog()
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            coordinator: CaptureTestCoordinator(
                result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused")
            ),
            makeMicrophoneTester: { isDictationActive in
                MacMicrophoneTester(
                    isDictationActive: isDictationActive,
                    makeSource: { _ in sources.make() },
                    resolveDevice: { _ in nil },
                    meter: InputLevelMeter(schedulesTimer: false),
                    autoStopDelay: .seconds(60)
                )
            }
        )
        defer { controller.teardown() }

        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        controller.microphone.startTest(deviceID: nil)
        #expect(!controller.microphone.isTesting)
        #expect(controller.microphone.testError == MicrophoneTestError.dictationActive.localizedDescription)
        #expect(sources.count == 0)

        controller.cancelActiveRecording()
        #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
        controller.microphone.startTest(deviceID: nil)
        #expect(controller.microphone.isTesting)
        #expect(controller.microphone.testError == nil)
        #expect(sources.count == 1)
        controller.microphone.stopTest()
        #expect(!controller.microphone.isTesting)
    }

    @Test("A microphone test leaves History, Insights and media untouched")
    func testLeavesNoTrace() async throws {
        let events = ShortcutEventLog()
        let sources = SourceLog()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoMicTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let usage = UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json"))
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            mediaInterruption: ShortcutTestMediaService(events: events),
            historyStore: history,
            usageAnalyticsStore: usage,
            makeMicrophoneTester: { isDictationActive in
                MacMicrophoneTester(
                    isDictationActive: isDictationActive,
                    makeSource: { _ in sources.make() },
                    resolveDevice: { _ in nil },
                    meter: InputLevelMeter(schedulesTimer: false),
                    autoStopDelay: .milliseconds(30)
                )
            }
        )
        defer { controller.teardown() }

        controller.microphone.startTest(deviceID: nil)
        #expect(controller.microphone.isTesting)
        #expect(await waitForShortcutCondition { !controller.microphone.isTesting })

        #expect(await events.snapshot().isEmpty)
        #expect(await history.recent(limit: 10).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("usage.json").path))
        #expect(controller.recordingLifecycleState == .idle)
        #expect(controller.recentEntries.isEmpty)
    }

    @Test("An isolated preview lists sample inputs and never starts a microphone test")
    func previewHasNoMicrophoneAccess() {
        let controller = DictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            mediaInterruption: IsolatedTestMediaService(),
            systemIntegrationsEnabled: false,
            isIsolatedPreview: true
        )
        defer { controller.teardown() }
        #expect(controller.microphone.isPreview)
        #expect(!controller.microphone.devices.isEmpty)
        controller.microphone.startTest(deviceID: nil)
        #expect(!controller.microphone.isTesting)
    }

    // MARK: - Microphone choice

    @Test("Settings sees the inputs, the saved choice, and a disconnected choice")
    func microphoneChoiceState() async {
        var connected = [
            AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
            AudioInputDevice(id: "usb", name: "USB Desk Mic", isDefault: false),
        ]
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            audioInputDevices: { connected }
        )
        defer { controller.teardown() }
        let microphone = controller.microphone
        #expect(microphone.devices.map(\.id) == ["builtin", "usb"])
        #expect(microphone.followsSystemInput)
        #expect(microphone.activeDevice?.id == "builtin")

        var preferences = controller.preferences
        preferences.recording.inputDeviceID = "usb"
        controller.preferences = preferences
        #expect(microphone.selectedDeviceID == "usb")
        #expect(!microphone.followsSystemInput)
        #expect(microphone.selection == .device(id: "usb"))
        #expect(microphone.activeDevice?.id == "usb")
        #expect(!microphone.isSelectedDeviceMissing)

        // Unplugged while idle.
        connected.removeLast()
        microphone.refreshDevices()
        #expect(microphone.isSelectedDeviceMissing)
        #expect(microphone.selection == .missing(id: "usb"))
        #expect(microphone.selectedDeviceName == "USB Desk Mic")
        #expect(microphone.activeDevice?.id == "builtin")

        preferences.recording.inputDeviceID = nil
        controller.preferences = preferences
        #expect(microphone.followsSystemInput)
        #expect(!microphone.isSelectedDeviceMissing)
    }
}

// MARK: - Test doubles

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] { lock.withLock { storage } }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

actor OrderedCaptureCoordinator: DictationSessionCoordinating {
    let order: OrderLog

    init(order: OrderLog) {
        self.order = order
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        order.append("capture.start")
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        InsertResult(status: .inserted, method: .accessibility, insertedText: "Words")
    }

    func cancel(sessionID: SessionID) async {}

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

@MainActor
final class RecordingMicrophoneTester: MicrophoneTesting {
    let order: OrderLog
    var onLevel: ((Float) -> Void)?
    var onStop: (() -> Void)?
    private(set) var isRunning = false

    init(order: OrderLog) {
        self.order = order
    }

    func start(deviceID: String?) throws {
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        order.append("test.stop")
        onLevel?(0)
        onStop?()
    }
}

@MainActor
final class SourceLog {
    private(set) var count = 0

    func make() -> any MicrophoneLevelSource {
        count += 1
        return SilentLevelSource()
    }
}

@MainActor
private final class SilentLevelSource: MicrophoneLevelSource {
    var currentDecibels: Float? { isRunning ? -160 : nil }
    var onEndedByItself: (@MainActor () -> Void)?
    private(set) var isRunning = false

    func start() throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}
