#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

public enum MacAudioCaptureError: Error, LocalizedError {
    case failedToCreateRecorder
    case failedToPrepareRecorder
    case failedToStartRecording
    case encodingFailure(details: String?)
    case microphoneStopped(deviceName: String?)
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .failedToCreateRecorder:
            return "Failed to create audio recorder"
        case .failedToPrepareRecorder:
            return "Failed to prepare audio recorder"
        case .failedToStartRecording:
            return "Failed to start audio recording"
        case .encodingFailure(let details):
            if let details, !details.isEmpty {
                return "Audio recording failed during encoding: \(details)"
            }
            return "Audio recording failed during encoding"
        case .microphoneStopped(let deviceName):
            let microphone = deviceName.flatMap { $0.isEmpty ? nil : "The microphone “\($0)”" }
                ?? "The microphone"
            return "\(microphone) stopped during the recording, and the recording couldn't be read."
        case .sessionNotFound:
            return "Recording session not found"
        }
    }
}

/// The recorder operations capture relies on. `AVAudioRecorder` is the
/// production recorder; tests substitute one that never opens a microphone.
@MainActor
protocol CaptureRecorder: AnyObject {
    var isRecording: Bool { get }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
}

extension AVAudioRecorder: CaptureRecorder {}

@MainActor
public final class MacAudioCaptureService: NSObject, AudioCaptureService, @preconcurrency AVAudioRecorderDelegate {
    private var recorders: [SessionID: any CaptureRecorder] = [:]
    private var outputURLs: [SessionID: URL] = [:]
    private var recorderSessionIDs: [ObjectIdentifier: SessionID] = [:]
    private var recorderErrors: [SessionID: MacAudioCaptureError] = [:]
    private var recordingStartedAt: [SessionID: TimeInterval] = [:]
    private var inputDeviceNames: [SessionID: String] = [:]
    private var stoppingSessionIDs: Set<SessionID> = []
    private var interruptions: [SessionID: CaptureInterruption] = [:]

    private let recordingDirectory: URL
    private let makeRecorder: @MainActor (URL, [String: Any]) throws -> any CaptureRecorder
    private let inputDeviceName: @MainActor () -> String?
    private let uptime: @MainActor () -> TimeInterval

    /// Called when a recording stops by itself while its session is still
    /// active, for example because the microphone was disconnected. The
    /// session should be stopped normally so the audio already captured is
    /// transcribed.
    public var onRecorderStoppedEarly: (@MainActor (SessionID) -> Void)?

    public override convenience init() {
        self.init(
            recordingDirectory: FileManager.default.temporaryDirectory,
            makeRecorder: { url, settings in try AVAudioRecorder(url: url, settings: settings) },
            inputDeviceName: { MacAudioCaptureService.defaultInputDeviceName() },
            uptime: { ProcessInfo.processInfo.systemUptime }
        )
    }

    init(
        recordingDirectory: URL,
        makeRecorder: @escaping @MainActor (URL, [String: Any]) throws -> any CaptureRecorder,
        inputDeviceName: @escaping @MainActor () -> String?,
        uptime: @escaping @MainActor () -> TimeInterval
    ) {
        self.recordingDirectory = recordingDirectory
        self.makeRecorder = makeRecorder
        self.inputDeviceName = inputDeviceName
        self.uptime = uptime
        super.init()
    }

    public func beginCapture(sessionID: SessionID) async throws {
        let fileURL = tempAudioURL(for: sessionID)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        var shouldCleanup = true
        defer {
            if shouldCleanup {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        let recorder: any CaptureRecorder
        do {
            recorder = try makeRecorder(fileURL, settings)
        } catch {
            throw MacAudioCaptureError.failedToCreateRecorder
        }
        (recorder as? AVAudioRecorder)?.delegate = self
        guard recorder.prepareToRecord() else {
            throw MacAudioCaptureError.failedToPrepareRecorder
        }

        guard recorder.record() else {
            throw MacAudioCaptureError.failedToStartRecording
        }

        shouldCleanup = false
        recorders[sessionID] = recorder
        outputURLs[sessionID] = fileURL
        recorderSessionIDs[ObjectIdentifier(recorder)] = sessionID
        recorderErrors[sessionID] = nil
        recordingStartedAt[sessionID] = uptime()
        // Read after recording has started so the lookup never delays it. It
        // names the device if the recording later stops by itself.
        if let name = inputDeviceName() {
            inputDeviceNames[sessionID] = name
        }
    }

    public func endCapture(sessionID: SessionID) async throws -> URL {
        guard let recorder = recorders.removeValue(forKey: sessionID),
              let fileURL = outputURLs.removeValue(forKey: sessionID) else {
            throw MacAudioCaptureError.sessionNotFound
        }

        stoppingSessionIDs.insert(sessionID)
        recorder.stop()
        let elapsedSeconds = recordingStartedAt.removeValue(forKey: sessionID).map { uptime() - $0 }
        let deviceName = inputDeviceNames.removeValue(forKey: sessionID)
        defer {
            recorderSessionIDs.removeValue(forKey: ObjectIdentifier(recorder))
            recorderErrors[sessionID] = nil
            stoppingSessionIDs.remove(sessionID)
        }
        do {
            if let captureError = recorderErrors.removeValue(forKey: sessionID) {
                throw captureError
            }
            let recordedSamples: UInt64
            do {
                recordedSamples = try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
                    source: FileCanonicalWAVByteSource(url: fileURL)
                )
            } catch {
                if interruptions[sessionID] != nil {
                    throw MacAudioCaptureError.microphoneStopped(deviceName: deviceName)
                }
                throw MacAudioCaptureError.encodingFailure(details: error.localizedDescription)
            }
            if let captureError = recorderErrors[sessionID] {
                throw captureError
            }
            if interruptions[sessionID] == nil,
               let elapsedSeconds,
               CaptureInterruption.isRecordingMuchShorter(
                   recordedSamples: recordedSamples,
                   elapsedSeconds: elapsedSeconds
               ) {
                interruptions[sessionID] = CaptureInterruption(
                    reason: .recordingShorterThanElapsed,
                    deviceName: deviceName
                )
            }
        } catch {
            interruptions[sessionID] = nil
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        return fileURL
    }

    public func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        guard recorders[sessionID]?.isRecording == true else { return nil }
        return outputURLs[sessionID]
    }

    public func takeCaptureInterruption(sessionID: SessionID) async -> CaptureInterruption? {
        interruptions.removeValue(forKey: sessionID)
    }

    public func cancelCapture(sessionID: SessionID) async {
        interruptions[sessionID] = nil
        guard let recorder = recorders.removeValue(forKey: sessionID),
              let fileURL = outputURLs.removeValue(forKey: sessionID) else {
            return
        }

        stoppingSessionIDs.insert(sessionID)
        recorder.stop()
        stoppingSessionIDs.remove(sessionID)
        recorderSessionIDs.removeValue(forKey: ObjectIdentifier(recorder))
        recorderErrors[sessionID] = nil
        recordingStartedAt[sessionID] = nil
        inputDeviceNames[sessionID] = nil
        interruptions[sessionID] = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Records a recorder that finished while its session was still active,
    /// or that reported an unsuccessful finish, and tells the owner so the
    /// session can end. The file is kept: what was recorded is transcribed.
    func recorderDidFinish(_ recorder: AnyObject, successfully: Bool) {
        guard let sessionID = recorderSessionIDs[ObjectIdentifier(recorder)] else {
            return
        }
        let stoppedBySteno = stoppingSessionIDs.contains(sessionID)
        guard !stoppedBySteno || !successfully else { return }
        if interruptions[sessionID] == nil {
            interruptions[sessionID] = CaptureInterruption(
                reason: .recorderStopped,
                deviceName: inputDeviceNames[sessionID]
            )
        }
        if !stoppedBySteno {
            onRecorderStoppedEarly?(sessionID)
        }
    }

    private func tempAudioURL(for sessionID: SessionID) -> URL {
        recordingDirectory
            .appendingPathComponent("\(Self.tempAudioPrefix)\(sessionID.uuidString)")
            .appendingPathExtension("wav")
    }

    /// The name of the current default input device, from Core Audio.
    nonisolated static func defaultInputDeviceName() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr,
            deviceID != kAudioObjectUnknown
        else {
            return nil
        }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let name
        else {
            return nil
        }
        let value = name.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    private nonisolated static let tempAudioPrefix = "steno-audio-"

    /// Deletes recordings left behind when Steno quit without finishing a
    /// session, for example after a crash or a force quit. Every normal path
    /// deletes its own recording, and no session exists at launch, so only
    /// files named exactly as this service names them, and older than
    /// `minimumAge`, are removed. Returns the removed files.
    @discardableResult
    public nonisolated static func removeStaleRecordings(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan minimumAge: TimeInterval = 5 * 60,
        now: Date = Date()
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var removed: [URL] = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(tempAudioPrefix),
                  url.pathExtension == "wav",
                  UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(tempAudioPrefix.count))) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > minimumAge
            else {
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url)
            }
        }
        return removed
    }

    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        recorderDidFinish(recorder, successfully: flag)
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        guard let sessionID = recorderSessionIDs[ObjectIdentifier(recorder)] else {
            return
        }
        recorderErrors[sessionID] = .encodingFailure(details: error?.localizedDescription)
    }
}
#endif
