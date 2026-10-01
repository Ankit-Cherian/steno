import Foundation

/// One ordered piece of the canonical 16 kHz, mono, signed 16-bit PCM capture.
public struct LivePCMFrame: Sendable, Equatable {
    public var sequenceNumber: UInt64
    public var sampleOffset: UInt64
    public var pcmS16LE: Data

    public var sampleCount: Int {
        pcmS16LE.count / MemoryLayout<Int16>.size
    }

    public init(
        sequenceNumber: UInt64,
        sampleOffset: UInt64,
        pcmS16LE: Data
    ) {
        self.sequenceNumber = sequenceNumber
        self.sampleOffset = sampleOffset
        self.pcmS16LE = pcmS16LE
    }
}

/// Exact byte-level accounting for all PCM emitted by a live capture stream.
public struct LivePCMStreamSummary: Sendable, Equatable {
    public var sampleCount: UInt64
    public var byteCount: UInt64
    public var frameCount: UInt64
    public var fnv1a64: UInt64

    public init(
        sampleCount: UInt64,
        byteCount: UInt64,
        frameCount: UInt64,
        fnv1a64: UInt64
    ) {
        self.sampleCount = sampleCount
        self.byteCount = byteCount
        self.frameCount = frameCount
        self.fnv1a64 = fnv1a64
    }
}

public enum CanonicalWAVPollState: Sendable, Equatable {
    case waitingForHeader
    case streaming
    case draining
    case finalized(LivePCMStreamSummary)
    case cancelled
    case staleSession
}

public struct CanonicalWAVPoll: Sendable, Equatable {
    public var frames: [LivePCMFrame]
    public var state: CanonicalWAVPollState

    public init(frames: [LivePCMFrame], state: CanonicalWAVPollState) {
        self.frames = frames
        self.state = state
    }
}

/// Deterministic digest used to prove that streamed PCM exactly matches the
/// canonical WAV payload. The digest is over the PCM bytes, in file order.
public enum LivePCMDigest {
    public static let fnv1a64OffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let fnv1a64Prime: UInt64 = 0x0000_0100_0000_01b3

    public static func fnv1a64(_ bytes: Data) -> UInt64 {
        updateFNV1a64(fnv1a64OffsetBasis, with: bytes)
    }

    static func updateFNV1a64(_ digest: UInt64, with bytes: Data) -> UInt64 {
        bytes.reduce(into: digest) { partialResult, byte in
            partialResult ^= UInt64(byte)
            partialResult &*= fnv1a64Prime
        }
    }
}

/// A recording that ended before Steno stopped it, or that holds much less
/// audio than the time it ran. Whatever was recorded is still transcribed;
/// the message tells the user that part of what they said may be missing.
public struct CaptureInterruption: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The recorder stopped by itself, for example because the
        /// microphone was disconnected.
        case recorderStopped
        /// The recording is much shorter than the time it ran.
        case recordingShorterThanElapsed
    }

    public var reason: Reason
    /// The input device in use when the recording started, when known.
    public var deviceName: String?

    public init(reason: Reason, deviceName: String? = nil) {
        self.reason = reason
        self.deviceName = deviceName
    }

    public var message: String {
        let device = deviceName.flatMap { $0.isEmpty ? nil : "“\($0)”" }
        switch reason {
        case .recorderStopped:
            let microphone = device.map { "The microphone \($0)" } ?? "The microphone"
            return "\(microphone) stopped during the recording. Only what you said before it stopped was transcribed."
        case .recordingShorterThanElapsed:
            let recording = device.map { "The recording from \($0)" } ?? "The recording"
            return "\(recording) is shorter than the time it ran. The microphone may have stopped, so part of what you said may be missing."
        }
    }

    /// Whether a canonical 16 kHz recording holding `recordedSamples` is much
    /// shorter than the `elapsedSeconds` it ran. Start-up latency and short
    /// presses stay well inside both margins.
    public static func isRecordingMuchShorter(
        recordedSamples: UInt64,
        sampleRate: Double = 16_000,
        elapsedSeconds: TimeInterval
    ) -> Bool {
        let missingSeconds = elapsedSeconds - Double(recordedSamples) / sampleRate
        return missingSeconds >= 2 && missingSeconds >= elapsedSeconds * 0.25
    }
}
