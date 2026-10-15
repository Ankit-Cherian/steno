#if os(macOS)
import CoreAudio
import Foundation

/// A microphone or other audio input, identified by its Core Audio UID, which
/// stays the same across reconnections and restarts.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// This is the system input selected in System Settings.
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Which input a capture uses for a saved choice.
public enum InputDeviceSelection: Sendable, Equatable {
    /// No device was chosen; the system input is used.
    case systemInput
    /// The chosen device is connected and is used.
    case device(id: String)
    /// The chosen device is not connected; the system input is used instead.
    case missing(id: String)

    public static func resolve(
        preferredID: String?,
        availableIDs: some Collection<String>
    ) -> InputDeviceSelection {
        guard let preferredID, !preferredID.isEmpty else { return .systemInput }
        return availableIDs.contains(preferredID) ? .device(id: preferredID) : .missing(id: preferredID)
    }

    /// The device a capture records from, or nil for the system input.
    public var deviceID: String? {
        if case .device(let id) = self { return id }
        return nil
    }

    public var isChosenDeviceMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// Reads the audio inputs from Core Audio. Listing devices never opens one.
public enum AudioInputDevices {
    struct Record: Sendable, Equatable {
        var uid: String
        var name: String
    }

    /// The connected inputs, sorted by name, with the system input marked.
    public static func list() -> [AudioInputDevice] {
        let defaultUID = defaultInputDeviceID().flatMap(uid(of:))
        let records = allDeviceIDs()
            .filter(hasInputStreams)
            .compactMap { id -> Record? in
                guard let uid = uid(of: id), let name = name(of: id) else { return nil }
                return Record(uid: uid, name: name)
            }
        return makeList(records, defaultUID: defaultUID)
    }

    static func makeList(_ records: [Record], defaultUID: String?) -> [AudioInputDevice] {
        var seen: Set<String> = []
        var devices: [AudioInputDevice] = []
        for record in records {
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !record.uid.isEmpty, !name.isEmpty, seen.insert(record.uid).inserted else { continue }
            devices.append(AudioInputDevice(id: record.uid, name: name, isDefault: record.uid == defaultUID))
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Core Audio object for a connected input with this UID, or nil when
    /// no such input is connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown, hasInputStreams(deviceID), isAlive(deviceID) else {
            return nil
        }
        return deviceID
    }

    public static func name(of deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value
        else {
            return nil
        }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

/// Calls `onChange` on the main thread when inputs are connected or
/// disconnected, or the system input changes. Observing never opens a device.
@MainActor
public final class AudioInputDeviceObserver {
    public var onChange: (@MainActor () -> Void)?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init() {}

    public func start() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block = Self.makeListener { [weak self] in self?.onChange?() }
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            ) == noErr {
                listeners.append((address, block))
            }
        }
    }

    public func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
        listeners.removeAll()
    }

    /// Built outside the main actor so Core Audio can call it without an
    /// isolation check; it is registered on the main queue.
    private nonisolated static func makeListener(
        _ handler: @escaping @MainActor () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
#endif
