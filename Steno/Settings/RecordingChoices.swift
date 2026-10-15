import AppKit
import StenoKit

/// "After inserting" in Recording settings. Raw values match `recording.afterInserting`.
enum AfterInsertingChoice: String, CaseIterable, Identifiable, Sendable {
    case matters
    case always
    case nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matters: "Only when it matters"
        case .always: "Always say where"
        case .nothing: "Show nothing"
        }
    }
}

/// The chords Settings offers for Paste Last Dictation, each saved as `GlobalShortcut` text.
enum PasteLastShortcutChoices {
    struct Option: Identifiable, Equatable {
        /// The saved text; nil means no shortcut.
        let value: String?
        let title: String

        var id: String { value ?? "none" }
    }

    /// Control and Option, with or without Command, on V.
    static let candidates: [GlobalShortcut] = [
        GlobalShortcut(keyCode: 9, modifiers: [.control, .option]),
        GlobalShortcut(keyCode: 9, modifiers: [.control, .option, .command]),
    ].compactMap { $0 }

    /// None, then every candidate that is not a problem and does not use the hands-free key. A
    /// saved shortcut that is no longer offered stays listed, so the picker always shows what is
    /// saved; the row's message says what is wrong with it.
    static func options(handsFreeKeyCode: UInt16?, saved: String?) -> [Option] {
        var options = [Option(value: nil, title: "None")]
        for shortcut in candidates where !shortcut.collides(withHandsFreeKeyCode: handsFreeKeyCode) {
            options.append(Option(value: shortcut.preferenceValue, title: shortcut.displayName))
        }
        if let saved, !saved.isEmpty, !options.contains(where: { $0.value == saved }) {
            let title = GlobalShortcut(preferenceValue: saved)?.displayName ?? "Unavailable shortcut"
            options.append(Option(value: saved, title: title))
        }
        return options
    }
}

extension GlobalShortcut {
    /// The key equivalent and modifiers a menu item shows for this shortcut, or nil when the key
    /// is neither a letter nor a function key.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if let letter { return (String(letter), flags) }
        guard let index = HandsFreeKey.functionKeys.firstIndex(where: { $0.keyCode == keyCode }),
              let scalar = Unicode.Scalar(UInt32(NSF1FunctionKey) + UInt32(index)) else { return nil }
        return (String(Character(scalar)), flags)
    }
}

extension AppPreferences {
    /// The chosen microphone; nil follows the system input.
    var inputDeviceID: String? {
        get { recording.inputDeviceID }
        set { recording.inputDeviceID = newValue?.isEmpty == true ? nil : newValue }
    }

    var afterInserting: AfterInsertingChoice {
        get { recording.afterInserting.flatMap(AfterInsertingChoice.init(rawValue:)) ?? .matters }
        set { recording.afterInserting = newValue == .matters ? nil : newValue.rawValue }
    }
}

/// A microphone as Settings and the menu bar list it. Mirrors `AudioInputDevice`.
struct InputDeviceOption: Identifiable, Equatable, Sendable {
    /// Core Audio UID.
    let id: String
    let name: String
    let isDefault: Bool

    init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    init(_ device: AudioInputDevice) {
        self.init(id: device.id, name: device.name, isDefault: device.isDefault)
    }
}

/// An isolated microphone test: never writes a file or touches History, Insights or media.
/// Mirrors `MicrophoneTesting`.
@MainActor
protocol MicrophoneTestRunning: AnyObject {
    func start(deviceID: String?) throws
    func stop()
    var onLevel: ((Float) -> Void)? { get set }
    /// Called once when a test ends, however it ends.
    var onStop: (() -> Void)? { get set }
}

/// Runs the Microphone page's test through the controller's microphone model, which owns the
/// isolated tester. It refuses during a dictation, stops by itself after 5 seconds, and stops when
/// a dictation starts or the input goes away.
@MainActor
final class ControllerMicrophoneTest: MicrophoneTestRunning {
    struct StartFailure: LocalizedError {
        let errorDescription: String?
    }

    private let microphone: MicrophoneSettingsModel

    init(microphone: MicrophoneSettingsModel) {
        self.microphone = microphone
        microphone.onTestStopped = { [weak self] in self?.onStop?() }
    }

    var onLevel: ((Float) -> Void)? {
        didSet { microphone.onTestLevel = onLevel }
    }
    var onStop: (() -> Void)?

    func start(deviceID: String?) throws {
        microphone.startTest(deviceID: deviceID)
        guard microphone.isTesting else {
            throw StartFailure(errorDescription: microphone.testError)
        }
    }

    func stop() {
        microphone.stopTest()
    }
}
