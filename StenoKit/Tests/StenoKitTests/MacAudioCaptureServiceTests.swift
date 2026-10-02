#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@Test("The launch sweep removes only stale Steno recordings")
func launchSweepRemovesOnlyStaleRecordings() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRecordingSweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let now = Date()
    let old = now.addingTimeInterval(-60 * 60)
    func file(_ name: String, modified: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("RIFF".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    let stale = try file("steno-audio-\(UUID().uuidString).wav", modified: old)
    let staleLowercase = try file("steno-audio-\(UUID().uuidString.lowercased()).wav", modified: old)
    let fresh = try file("steno-audio-\(UUID().uuidString).wav", modified: now.addingTimeInterval(-30))
    let otherApp = try file("other-audio-\(UUID().uuidString).wav", modified: old)
    let notUUID = try file("steno-audio-notes.wav", modified: old)
    let otherExtension = try file("steno-audio-\(UUID().uuidString).wav.txt", modified: old)
    let transcript = try file("steno-audio-\(UUID().uuidString).txt", modified: old)
    let staleDirectory = directory.appendingPathComponent("steno-audio-\(UUID().uuidString).wav", isDirectory: true)
    try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: staleDirectory.path)
    let linkTarget = try file("keep-target.wav", modified: old)
    let staleLink = directory.appendingPathComponent("steno-audio-\(UUID().uuidString).wav")
    try FileManager.default.createSymbolicLink(at: staleLink, withDestinationURL: linkTarget)

    let removed = MacAudioCaptureService.removeStaleRecordings(
        in: directory,
        olderThan: 5 * 60,
        now: now
    )

    #expect(Set(removed.map(\.lastPathComponent)) == [stale.lastPathComponent, staleLowercase.lastPathComponent])
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(!FileManager.default.fileExists(atPath: staleLowercase.path))
    for kept in [fresh, otherApp, notUUID, otherExtension, transcript, staleDirectory, linkTarget] {
        #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent)")
    }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: staleLink.path)) != nil)
}

@Test("The launch sweep tolerates a missing directory")
func launchSweepToleratesMissingDirectory() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRecordingSweepMissing-\(UUID().uuidString)", isDirectory: true)
    #expect(MacAudioCaptureService.removeStaleRecordings(in: missing, olderThan: 60, now: Date()).isEmpty)
}

// MARK: - A recorder that stops on its own

@MainActor
@Test("A recorder that stops on its own keeps its audio and reports that the microphone stopped")
func recorderStoppingOnItsOwnKeepsAudio() async throws {
    let fixture = CaptureServiceFixture(deviceName: "USB Desk Mic")
    let sessionID = SessionID()
    var stoppedEarly: [SessionID] = []
    fixture.service.onRecorderStoppedEarly = { stoppedEarly.append($0) }

    try await fixture.service.beginCapture(sessionID: sessionID)
    let recorder = try #require(fixture.recorders.last)
    recorder.pcmByteCount = 16_000 * 2
    fixture.uptime += 1
    // The device disappears: the recorder finalizes its file and stops.
    recorder.stop()
    fixture.service.recorderDidFinish(recorder, successfully: true)
    #expect(stoppedEarly == [sessionID])
    #expect(await fixture.service.canonicalCaptureURL(sessionID: sessionID) == nil)

    fixture.uptime += 4
    let url = try await fixture.service.endCapture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url).count == 44 + 16_000 * 2)

    let interruption = try #require(await fixture.service.takeCaptureInterruption(sessionID: sessionID))
    #expect(interruption.reason == .recorderStopped)
    #expect(interruption.deviceName == "USB Desk Mic")
    #expect(interruption.message.contains("microphone “USB Desk Mic” stopped"))
    #expect(await fixture.service.takeCaptureInterruption(sessionID: sessionID) == nil)
}

@MainActor
@Test("A recorder that reports an unsuccessful finish on stop is reported without losing audio")
func unsuccessfulFinishOnStopIsReported() async throws {
    let fixture = CaptureServiceFixture(deviceName: nil)
    let sessionID = SessionID()
    var stoppedEarly: [SessionID] = []
    fixture.service.onRecorderStoppedEarly = { stoppedEarly.append($0) }

    try await fixture.service.beginCapture(sessionID: sessionID)
    let recorder = try #require(fixture.recorders.last)
    recorder.pcmByteCount = 8_000
    recorder.onStop = { [weak service = fixture.service] recorder in
        service?.recorderDidFinish(recorder, successfully: false)
    }
    let url = try await fixture.service.endCapture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(stoppedEarly.isEmpty)
    let interruption = try #require(await fixture.service.takeCaptureInterruption(sessionID: sessionID))
    #expect(interruption.reason == .recorderStopped)
    #expect(interruption.message == "The microphone stopped during the recording. Only what you said before it stopped was transcribed.")
}

@MainActor
@Test("A normal stop reports nothing, and a successful finish during stop is not an interruption")
func normalStopReportsNothing() async throws {
    let fixture = CaptureServiceFixture(deviceName: "MacBook Pro Microphone")
    let sessionID = SessionID()
    var stoppedEarly: [SessionID] = []
    fixture.service.onRecorderStoppedEarly = { stoppedEarly.append($0) }

    try await fixture.service.beginCapture(sessionID: sessionID)
    let recorder = try #require(fixture.recorders.last)
    recorder.pcmByteCount = 3 * 16_000 * 2
    recorder.onStop = { [weak service = fixture.service] recorder in
        service?.recorderDidFinish(recorder, successfully: true)
    }
    fixture.uptime += 3
    let url = try await fixture.service.endCapture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(stoppedEarly.isEmpty)
    #expect(await fixture.service.takeCaptureInterruption(sessionID: sessionID) == nil)
    // A late callback for a session that already ended is ignored.
    fixture.service.recorderDidFinish(recorder, successfully: false)
    #expect(await fixture.service.takeCaptureInterruption(sessionID: sessionID) == nil)
}

@MainActor
@Test("A recording much shorter than the time it ran is reported")
func recordingShorterThanElapsedIsReported() async throws {
    let fixture = CaptureServiceFixture(deviceName: "AirPods Pro")
    let sessionID = SessionID()
    try await fixture.service.beginCapture(sessionID: sessionID)
    let recorder = try #require(fixture.recorders.last)
    // An empty payload after ten seconds, as when the recorder died without
    // ever patching its data length.
    recorder.pcmByteCount = 0
    fixture.uptime += 10
    let url = try await fixture.service.endCapture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: url) }

    let interruption = try #require(await fixture.service.takeCaptureInterruption(sessionID: sessionID))
    #expect(interruption.reason == .recordingShorterThanElapsed)
    #expect(interruption.message.contains("“AirPods Pro”"))
}

@MainActor
@Test("A recorder that stops on its own with an unreadable file fails with the microphone message")
func recorderStoppedWithUnreadableFileFails() async throws {
    let fixture = CaptureServiceFixture(deviceName: "USB Desk Mic")
    let sessionID = SessionID()
    try await fixture.service.beginCapture(sessionID: sessionID)
    let recorder = try #require(fixture.recorders.last)
    recorder.writesValidFile = false
    recorder.stop()
    fixture.service.recorderDidFinish(recorder, successfully: false)

    do {
        _ = try await fixture.service.endCapture(sessionID: sessionID)
        Issue.record("endCapture should fail")
    } catch {
        #expect(error.localizedDescription.contains("microphone “USB Desk Mic” stopped"))
    }
    #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
    #expect(await fixture.service.takeCaptureInterruption(sessionID: sessionID) == nil)
}

@MainActor
@Test("Cancel discards a recorded interruption")
func cancelDiscardsInterruption() async throws {
    let fixture = CaptureServiceFixture(deviceName: nil)
    let sessionID = SessionID()
    try await fixture.service.beginCapture(sessionID: sessionID)
    let recorder = try #require(fixture.recorders.last)
    recorder.stop()
    fixture.service.recorderDidFinish(recorder, successfully: true)
    await fixture.service.cancelCapture(sessionID: sessionID)

    #expect(await fixture.service.takeCaptureInterruption(sessionID: sessionID) == nil)
    #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
}

@Test("Only a recording much shorter than the time it ran counts as short")
func shortRecordingThreshold() {
    #expect(CaptureInterruption.isRecordingMuchShorter(recordedSamples: 0, elapsedSeconds: 10))
    #expect(CaptureInterruption.isRecordingMuchShorter(recordedSamples: 16_000 * 6, elapsedSeconds: 10))
    #expect(!CaptureInterruption.isRecordingMuchShorter(recordedSamples: 16_000 * 9, elapsedSeconds: 10))
    // Short presses and small start-up gaps are never reported.
    #expect(!CaptureInterruption.isRecordingMuchShorter(recordedSamples: 0, elapsedSeconds: 1.5))
    #expect(!CaptureInterruption.isRecordingMuchShorter(recordedSamples: 16_000 * 55, elapsedSeconds: 60))
    #expect(CaptureInterruption.isRecordingMuchShorter(recordedSamples: 16_000 * 40, elapsedSeconds: 60))
}

@MainActor
private final class CaptureServiceFixture {
    let directory: URL
    var recorders: [FakeCaptureRecorder] = []
    var uptime: TimeInterval = 100
    private(set) var service: MacAudioCaptureService!

    init(deviceName: String?) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoCaptureServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = MacAudioCaptureService(
            recordingDirectory: directory,
            makeRecorder: { [unowned self] url, _ in
                let recorder = FakeCaptureRecorder(url: url)
                self.recorders.append(recorder)
                return recorder
            },
            inputDeviceName: { deviceName },
            uptime: { [unowned self] in self.uptime }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FakeCaptureRecorder: CaptureRecorder {
    let url: URL
    var pcmByteCount = 0
    var writesValidFile = true
    var onStop: ((FakeCaptureRecorder) -> Void)?
    private(set) var isRecording = false

    init(url: URL) {
        self.url = url
    }

    func prepareToRecord() -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: Self.wav(pcmByteCount: 0, declaredDataBytes: 0))
    }

    func record() -> Bool {
        isRecording = true
        return true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        let bytes = writesValidFile
            ? Self.wav(pcmByteCount: pcmByteCount, declaredDataBytes: pcmByteCount)
            : Self.wav(pcmByteCount: 10, declaredDataBytes: 99)
        try? bytes.write(to: url)
        onStop?(self)
    }

    private static func wav(pcmByteCount: Int, declaredDataBytes: Int) -> Data {
        var data = Data("RIFF".utf8)
        append(UInt32(36 + pcmByteCount), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(16_000), to: &data)
        append(UInt32(32_000), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(declaredDataBytes), to: &data)
        data.append(Data(count: pcmByteCount))
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
#endif
