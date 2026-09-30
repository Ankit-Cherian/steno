#if os(macOS)
import AVFoundation
import Foundation

public enum MacAudioCaptureError: Error, LocalizedError {
    case failedToCreateRecorder
    case failedToPrepareRecorder
    case failedToStartRecording
    case encodingFailure(details: String?)
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
        case .sessionNotFound:
            return "Recording session not found"
        }
    }
}

@MainActor
public final class MacAudioCaptureService: NSObject, AudioCaptureService, @preconcurrency AVAudioRecorderDelegate {
    private var recorders: [SessionID: AVAudioRecorder] = [:]
    private var outputURLs: [SessionID: URL] = [:]
    private var recorderSessionIDs: [ObjectIdentifier: SessionID] = [:]
    private var recorderErrors: [SessionID: MacAudioCaptureError] = [:]

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

        var shouldCleanup = true
        defer {
            if shouldCleanup {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        } catch {
            throw MacAudioCaptureError.failedToCreateRecorder
        }
        recorder.delegate = self
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
    }

    public func endCapture(sessionID: SessionID) async throws -> URL {
        guard let recorder = recorders.removeValue(forKey: sessionID),
              let fileURL = outputURLs.removeValue(forKey: sessionID) else {
            throw MacAudioCaptureError.sessionNotFound
        }

        recorder.stop()
        defer {
            recorderSessionIDs.removeValue(forKey: ObjectIdentifier(recorder))
            recorderErrors[sessionID] = nil
        }
        if let captureError = recorderErrors.removeValue(forKey: sessionID) {
            try? FileManager.default.removeItem(at: fileURL)
            throw captureError
        }
        do {
            try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
                source: FileCanonicalWAVByteSource(url: fileURL)
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw MacAudioCaptureError.encodingFailure(details: error.localizedDescription)
        }
        if let captureError = recorderErrors[sessionID] {
            try? FileManager.default.removeItem(at: fileURL)
            throw captureError
        }
        return fileURL
    }

    public func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        guard recorders[sessionID]?.isRecording == true else { return nil }
        return outputURLs[sessionID]
    }

    public func cancelCapture(sessionID: SessionID) async {
        guard let recorder = recorders.removeValue(forKey: sessionID),
              let fileURL = outputURLs.removeValue(forKey: sessionID) else {
            return
        }

        recorder.stop()
        recorderSessionIDs.removeValue(forKey: ObjectIdentifier(recorder))
        recorderErrors[sessionID] = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private nonisolated static let tempAudioPrefix = "steno-audio-"

    private static func tempAudioURL(for sessionID: SessionID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempAudioPrefix)\(sessionID.uuidString)")
            .appendingPathExtension("wav")
    }

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

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        guard let sessionID = recorderSessionIDs[ObjectIdentifier(recorder)] else {
            return
        }
        recorderErrors[sessionID] = .encodingFailure(details: error?.localizedDescription)
    }
}
#endif
