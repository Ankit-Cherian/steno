import Foundation
import Testing
@testable import Steno

@Suite("Recording preferences")
struct RecordingPreferencesTests {
    @Test("New installs follow the system input")
    func defaultFollowsSystem() {
        #expect(AppPreferences.default.recording.inputDeviceID == nil)
    }

    @Test("A chosen microphone round-trips", arguments: ["BuiltInMicrophoneDevice", "AppleUSBAudioEngine:Vendor:Mic:1234:1"])
    func roundTrip(deviceID: String) throws {
        var preferences = AppPreferences.default
        preferences.recording.inputDeviceID = deviceID
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded.recording.inputDeviceID == deviceID)
        #expect(decoded == preferences)
    }

    @Test("Following the system input writes no device")
    func followSystemWritesNoDevice() throws {
        let data = try JSONEncoder().encode(AppPreferences.default)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("inputDeviceID"))
        #expect(try JSONDecoder().decode(AppPreferences.self, from: data).recording.inputDeviceID == nil)
    }

    @Test("A file without the recording section follows the system input")
    func missingSection() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        #expect(decoded.recording.inputDeviceID == nil)
    }

    @Test("An unreadable recording section falls back without affecting the rest")
    func unreadableSection() throws {
        let data = Data(#"{"recording":{"inputDeviceID":42},"media":{"pauseDuringHandsFree":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded.recording.inputDeviceID == nil)
        #expect(decoded.media.pauseDuringHandsFree == false)
    }

    @Test("An empty saved choice is normalized to following the system input")
    func emptyNormalizes() {
        var preferences = AppPreferences.default
        preferences.recording.inputDeviceID = ""
        preferences.normalize()
        #expect(preferences.recording.inputDeviceID == nil)
    }

    @Test("Release 1.0.0 reads a file that names a microphone")
    func releasedDecoderReadsChosenDevice() throws {
        var preferences = AppPreferences.default
        preferences.recording.inputDeviceID = "BuiltInMicrophoneDevice"
        preferences.media.pauseDuringPressToTalk = false
        let data = try JSONEncoder().encode(preferences)
        #expect(String(data: data, encoding: .utf8)?.contains("\"inputDeviceID\"") == true)

        let released = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: data)
        #expect(released.media.pauseDuringPressToTalk == false)
        #expect(released.dictation.modelPath == preferences.dictation.modelPath)

        let legacy = try JSONDecoder().decode(LegacyV0110Preferences.self, from: data)
        #expect(legacy.media.pauseDuringPressToTalk == false)
    }
}
