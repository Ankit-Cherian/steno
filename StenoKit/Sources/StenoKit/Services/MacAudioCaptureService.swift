#if os(macOS)
import AVFoundation
import Foundation

public enum MacAudioCaptureError: Error, LocalizedError {
    case failedToCreateRecorder
    case failedToStartRecording
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .failedToCreateRecorder:
            return "Failed to create audio recorder"
        case .failedToStartRecording:
            return "Failed to start audio recording"
        case .sessionNotFound:
            return "Recording session not found"
        }
    }
}

@MainActor
public final class MacAudioCaptureService: NSObject, AudioCaptureService {
    private var recorders: [SessionID: AVAudioRecorder] = [:]
    private var outputURLs: [SessionID: URL] = [:]

    public override init() {
        super.init()
    }

    public func beginCapture(sessionID: SessionID) async throws {
        let fileURL = Self.tempAudioURL(for: sessionID)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw MacAudioCaptureError.failedToStartRecording
        }

        recorders[sessionID] = recorder
        outputURLs[sessionID] = fileURL
    }

    public func endCapture(sessionID: SessionID) async throws -> URL {
        guard let recorder = recorders.removeValue(forKey: sessionID),
              let fileURL = outputURLs.removeValue(forKey: sessionID) else {
            throw MacAudioCaptureError.sessionNotFound
        }

        recorder.stop()
        return fileURL
    }

    public func cancelCapture(sessionID: SessionID) async {
        guard let recorder = recorders.removeValue(forKey: sessionID),
              let fileURL = outputURLs.removeValue(forKey: sessionID) else {
            return
        }

        recorder.stop()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func tempAudioURL(for sessionID: SessionID) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-audio-\(sessionID.uuidString).wav")
    }
}
#endif
