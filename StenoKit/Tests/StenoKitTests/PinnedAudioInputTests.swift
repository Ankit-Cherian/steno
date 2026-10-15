#if os(macOS)
import AVFoundation
import Foundation
import Testing
@testable import StenoKit

@Suite("Chosen-device capture file")
struct CanonicalWAVFileWriterTests {
    private static var captureSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ] }

    @Test("Device audio is converted to the 16 kHz mono capture format the pipeline reads",
          arguments: [(48_000.0, AVAudioChannelCount(2)), (44_100.0, 1), (24_000.0, 1), (16_000.0, 1)])
    func writesCanonicalCapture(sampleRate: Double, channels: AVAudioChannelCount) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-writer-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let writer = try CanonicalWAVFileWriter(url: url, settings: Self.captureSettings, inputFormat: inputFormat)

        // One second in tap-sized buffers.
        let bufferFrames = AVAudioFrameCount(1_024)
        var written = 0
        while written < Int(sampleRate) {
            let buffer = try #require(Self.sine(format: inputFormat, frames: bufferFrames, offset: written))
            writer.append(buffer)
            written += Int(bufferFrames)
        }
        writer.finish()
        // A buffer after finishing is ignored.
        writer.append(try #require(Self.sine(format: inputFormat, frames: bufferFrames, offset: 0)))

        let samples = try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
            source: FileCanonicalWAVByteSource(url: url)
        )
        let expected = Double(written) / sampleRate * 16_000
        #expect(abs(Double(samples) - expected) < 400, "\(samples) samples, expected about \(expected)")

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test("The live preview can read the file while it is still being written")
    func readableWhileRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-writer-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let writer = try CanonicalWAVFileWriter(url: url, settings: Self.captureSettings, inputFormat: inputFormat)
        for chunk in 0..<24 {
            writer.append(try #require(Self.sine(format: inputFormat, frames: 1_024, offset: chunk * 1_024)))
        }

        let sessionID = SessionID()
        let streamer = try CanonicalWAVFrameStreamer(sessionID: sessionID, audioURL: url, maximumFramesPerPoll: 64)
        var streamedBytes = 0
        let poll = try await streamer.poll(sessionID: sessionID)
        streamedBytes += poll.frames.reduce(0) { $0 + $1.pcmS16LE.count }
        #expect(poll.state == .streaming)
        #expect(streamedBytes > 0)

        writer.finish()
        var final = try await streamer.finalize(sessionID: sessionID)
        streamedBytes += final.frames.reduce(0) { $0 + $1.pcmS16LE.count }
        while case .draining = final.state {
            final = try await streamer.drain(sessionID: sessionID)
            streamedBytes += final.frames.reduce(0) { $0 + $1.pcmS16LE.count }
        }
        guard case .finalized(let summary) = final.state else {
            Issue.record("Expected a finalized stream, got \(final.state)")
            return
        }
        #expect(UInt64(streamedBytes) == summary.byteCount)
        let samples = try await CanonicalWAVFrameStreamer.validateFinalizedCapture(
            source: FileCanonicalWAVByteSource(url: url)
        )
        #expect(summary.byteCount == samples * 2)
    }

    @Test("Power reads about -3 dBFS for a full-scale sine and -160 for digital silence")
    func powerReading() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let sine = try #require(Self.sine(format: format, frames: 4_800, offset: 0, amplitude: 1))
        let decibels = try #require(AudioPowerReading.decibels(of: sine))
        #expect(abs(decibels - -3.01) < 0.1)

        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        silence.frameLength = 480
        #expect(AudioPowerReading.decibels(of: silence) == -160)

        let reading = AudioPowerReading()
        #expect(reading.decibels == nil)
        reading.record(sine)
        #expect(reading.decibels.map { abs($0 - -3.01) < 0.1 } == true)
    }

    private static func sine(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        offset: Int,
        amplitude: Float = 0.25
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                let t = Float(offset + frame) / Float(format.sampleRate)
                channels[channel][frame] = amplitude * sin(2 * .pi * 440 * t)
            }
        }
        return buffer
    }
}
#endif
