#if os(macOS)
import Accelerate
import AVFoundation
import CoreAudio
import Foundation

enum PinnedAudioInputError: Error {
    case inputUnavailable
    case deviceUnavailable
    case noInputFormat
}

/// An audio engine input that records from one device, or from the system
/// input when no device is given. Unlike `AVAudioRecorder`, which always
/// records from the system input, it can follow a microphone chosen in Steno
/// without changing the system setting.
///
/// The input reports when it ends by itself: the device was disconnected or
/// its configuration changed, which stops the engine.
@MainActor
final class PinnedAudioInput {
    private let engine = AVAudioEngine()
    private let deviceID: AudioDeviceID?
    private var hasTap = false
    private var configurationObserver: NSObjectProtocol?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private(set) var isRunning = false

    var onEndedByItself: (@MainActor () -> Void)?

    init(deviceID: AudioDeviceID?) {
        self.deviceID = deviceID
    }

    /// Selects the device and returns the format its taps deliver.
    func prepareFormat() throws -> AVAudioFormat {
        if let deviceID {
            guard let unit = engine.inputNode.audioUnit else {
                throw PinnedAudioInputError.inputUnavailable
            }
            var device = deviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw PinnedAudioInputError.deviceUnavailable }
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PinnedAudioInputError.noInputFormat
        }
        return format
    }

    /// Installs the block that receives each buffer. The block runs on an
    /// audio thread, so it must be built outside the main actor.
    func install(tap: @escaping AVAudioNodeTapBlock, format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tap)
        hasTap = true
        engine.prepare()
    }

    func start() throws {
        try engine.start()
        isRunning = true
        observeEnd()
    }

    func stop() {
        stopObserving()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
        isRunning = false
    }

    private func endedByItself() {
        guard isRunning else { return }
        stop()
        onEndedByItself?()
    }

    private func observeEnd() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endedByItself() }
        }
        guard let deviceID else { return }
        var address = Self.aliveAddress
        let block = Self.makeAliveListener(deviceID: deviceID) { [weak self] in
            self?.endedByItself()
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block) == noErr {
            aliveListener = block
        }
    }

    private func stopObserving() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let aliveListener, let deviceID {
            var address = Self.aliveAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, aliveListener)
            self.aliveListener = nil
        }
    }

    private static let aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private nonisolated static func makeAliveListener(
        deviceID: AudioDeviceID,
        _ handler: @escaping @MainActor () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated {
                if !AudioInputDevices.isAlive(deviceID) { handler() }
            }
        }
    }
}

/// The most recent power of an input, in dBFS, written from the audio thread
/// and read by the level meter.
final class AudioPowerReading: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Float?

    var decibels: Float? { lock.withLock { latest } }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let decibels = Self.decibels(of: buffer) else { return }
        lock.withLock { latest = decibels }
    }

    /// The RMS power of the first channel in dBFS; -160 for digital silence.
    static func decibels(of buffer: AVAudioPCMBuffer) -> Float? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        let stride = buffer.stride
        var rms: Float = 0
        vDSP_rmsqv(channel, stride, &rms, vDSP_Length(frames))
        guard rms.isFinite, rms > 0 else { return -160 }
        return max(20 * log10(rms), -160)
    }
}

/// Converts input buffers to the capture format and writes them to a WAV
/// file. Safe to call from the audio thread; `finish` closes the file.
final class CanonicalWAVFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init(url: URL, settings: [String: Any], inputFormat: AVAudioFormat) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat) else {
            throw PinnedAudioInputError.noInputFormat
        }
        converter.downmix = true
        self.file = file
        self.converter = converter
        self.outputFormat = file.processingFormat
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            convertAndWrite(buffer, endOfStream: false)
        }
    }

    /// Writes what the converter still holds and closes the file.
    func finish() {
        lock.withLock {
            guard file != nil else { return }
            convertAndWrite(nil, endOfStream: true)
            if #available(macOS 15.0, *) {
                file?.close()
            }
            file = nil
            converter = nil
        }
    }

    private func convertAndWrite(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) {
        guard let file, let converter else { return }
        let inputFrames = Double(buffer?.frameLength ?? 0)
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let feed = ConverterFeed(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feed.next(inputStatus, endOfStream: endOfStream)
        }
        guard status != .error, output.frameLength > 0 else { return }
        try? file.write(from: output)
    }
}

/// Hands one buffer to a converter, then reports that no more data is ready
/// (or that the stream ended).
private final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer?) {
        self.buffer = buffer
    }

    func next(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>,
        endOfStream: Bool
    ) -> AVAudioBuffer? {
        if let buffer {
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = endOfStream ? .endOfStream : .noDataNow
        return nil
    }
}

/// Records a chosen input device to the capture file, with the same format
/// and file layout as the system-input recorder.
@MainActor
final class PinnedDeviceCaptureRecorder: CaptureRecorder {
    private let url: URL
    private let settings: [String: Any]
    private let input: PinnedAudioInput
    private let power = AudioPowerReading()
    private var writer: CanonicalWAVFileWriter?
    private(set) var isRecording = false
    var isMeteringEnabled = false

    /// Called when the recording stops without `stop()`, for example because
    /// the device was disconnected. What was recorded stays in the file.
    var onStoppedByItself: (@MainActor (PinnedDeviceCaptureRecorder) -> Void)?

    init(url: URL, settings: [String: Any], deviceID: AudioDeviceID) {
        self.url = url
        self.settings = settings
        self.input = PinnedAudioInput(deviceID: deviceID)
        input.onEndedByItself = { [weak self] in
            guard let self, self.isRecording else { return }
            self.isRecording = false
            self.writer?.finish()
            self.writer = nil
            self.onStoppedByItself?(self)
        }
    }

    func prepareToRecord() -> Bool {
        do {
            let format = try input.prepareFormat()
            let writer = try CanonicalWAVFileWriter(url: url, settings: settings, inputFormat: format)
            input.install(tap: Self.makeTap(writer: writer, power: power), format: format)
            self.writer = writer
            return true
        } catch {
            return false
        }
    }

    func record() -> Bool {
        guard writer != nil else { return false }
        do {
            try input.start()
            isRecording = true
            return true
        } catch {
            return false
        }
    }

    func stop() {
        input.stop()
        isRecording = false
        writer?.finish()
        writer = nil
    }

    func updateMeters() {}

    func averagePower(forChannel channelNumber: Int) -> Float {
        power.decibels ?? -160
    }

    private nonisolated static func makeTap(
        writer: CanonicalWAVFileWriter,
        power: AudioPowerReading
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            power.record(buffer)
            writer.append(buffer)
        }
    }
}
#endif
