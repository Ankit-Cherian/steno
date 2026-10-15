import AppKit
import StenoKit

/// Everything the status menu shows, read from the controller each time the menu opens.
struct MenuBarSnapshot: Equatable {
    var lifecycle: RecordingLifecycleState = .idle
    var isRecording = false
    var recordingStartedAt: Date?
    /// Newest first.
    var entries: [TranscriptEntry] = []
    var microphoneDenied = false
    var pasteShortcut: GlobalShortcut?
    var canPasteLast = false
    /// A dictation History couldn't save, which Copy Last and Paste Last still reach.
    var hasUnsavedLast = false
    /// A long recording was just discarded and can still be restored.
    var canUndoDiscard = false
    var devices: [InputDeviceOption] = []
    var selectedDeviceID: String?
    /// Which dictation shortcuts are on, so the header names a key that works.
    var shortcuts = TodayShortcuts(optionHold: true, handsFreeKey: nil)

    var iconState: MenuBarIconState {
        MenuBarIconState.derive(lifecycle: lifecycle, isRecording: isRecording, microphoneDenied: microphoneDenied)
    }

    var isListening: Bool { iconState == .recording }
}

/// A menu command, independent of AppKit so the menu's contents can be tested.
enum MenuBarAction: Equatable {
    case startDictation
    case stop
    case discard
    case undoDiscard
    case copyLatest
    case copyEntry(UUID)
    case pasteLast
    case selectMicrophone(String?)
    case turnOnMicrophone
    case openSteno
    case openSettings
    case quit
}

struct MenuBarItemSpec: Equatable {
    enum Kind: Equatable {
        case header
        case separator
        case action(MenuBarAction)
        case submenu([MenuBarItemSpec])
    }

    var title: String = ""
    var keyEquivalent: String = ""
    var modifiers: NSEvent.ModifierFlags = .command
    var isEnabled = true
    var isChecked = false
    /// A dictation shown as one line: its time, then its text.
    var entry: TranscriptEntry?
    var kind: Kind

    static var separator: MenuBarItemSpec { MenuBarItemSpec(kind: .separator) }

    static func == (lhs: MenuBarItemSpec, rhs: MenuBarItemSpec) -> Bool {
        lhs.title == rhs.title && lhs.keyEquivalent == rhs.keyEquivalent
            && lhs.modifiers.rawValue == rhs.modifiers.rawValue && lhs.isEnabled == rhs.isEnabled
            && lhs.isChecked == rhs.isChecked && lhs.entry?.id == rhs.entry?.id && lhs.kind == rhs.kind
    }
}

enum MenuBarMenuModel {
    /// The status menu: header, recording controls while listening, recent dictations, then commands.
    static func items(for snapshot: MenuBarSnapshot) -> [MenuBarItemSpec] {
        var items: [MenuBarItemSpec] = [MenuBarItemSpec(kind: .header)]
        if snapshot.isListening {
            items.append(.separator)
            items.append(MenuBarItemSpec(title: "Stop", keyEquivalent: "", kind: .action(.stop)))
            items.append(MenuBarItemSpec(title: "Discard", keyEquivalent: "", kind: .action(.discard)))
        } else if snapshot.canUndoDiscard {
            items.append(.separator)
            items.append(MenuBarItemSpec(title: "Undo Discard", keyEquivalent: "", kind: .action(.undoDiscard)))
        }
        // The newest saved dictation is listed here too when an unsaved one is the latest.
        let recent = (snapshot.hasUnsavedLast ? snapshot.entries[...] : snapshot.entries.dropFirst()).prefix(3)
        if !recent.isEmpty {
            items.append(.separator)
            for entry in recent {
                items.append(MenuBarItemSpec(title: title(for: entry), entry: entry, kind: .action(.copyEntry(entry.id))))
            }
        }
        items.append(.separator)
        let hasLatest = !snapshot.entries.isEmpty || snapshot.hasUnsavedLast
        items.append(MenuBarItemSpec(
            title: "Copy Last Dictation", keyEquivalent: "c", modifiers: [.command, .shift],
            isEnabled: hasLatest, kind: .action(.copyLatest)
        ))
        let paste = snapshot.pasteShortcut?.menuKeyEquivalent
        items.append(MenuBarItemSpec(
            title: "Paste Last Dictation", keyEquivalent: paste?.key ?? "", modifiers: paste?.modifiers ?? [],
            isEnabled: hasLatest && snapshot.canPasteLast, kind: .action(.pasteLast)
        ))
        items.append(MenuBarItemSpec(title: "Microphone", kind: .submenu(microphoneItems(for: snapshot))))
        items.append(.separator)
        items.append(MenuBarItemSpec(title: "Open Steno", keyEquivalent: "o", kind: .action(.openSteno)))
        items.append(MenuBarItemSpec(title: "Settings…", keyEquivalent: ",", kind: .action(.openSettings)))
        items.append(.separator)
        items.append(MenuBarItemSpec(title: "Quit Steno", keyEquivalent: "q", kind: .action(.quit)))
        return items
    }

    static func microphoneItems(for snapshot: MenuBarSnapshot) -> [MenuBarItemSpec] {
        var items = [MenuBarItemSpec(
            title: "Follow the System Input",
            isChecked: snapshot.selectedDeviceID == nil,
            kind: .action(.selectMicrophone(nil))
        )]
        if !snapshot.devices.isEmpty {
            items.append(.separator)
            for device in snapshot.devices {
                items.append(MenuBarItemSpec(
                    title: device.name,
                    isEnabled: !snapshot.isListening,
                    isChecked: snapshot.selectedDeviceID == device.id,
                    kind: .action(.selectMicrophone(device.id))
                ))
            }
        }
        return items
    }

    /// One line of a dictation for the menu: its words, shortened.
    static func title(for entry: TranscriptEntry, limit: Int = 44) -> String {
        let text = (entry.cleanText.isEmpty ? entry.rawText : entry.cleanText)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The controller calls a menu command makes.
@MainActor
protocol MenuBarCommandTarget: AnyObject {
    var recentEntries: [TranscriptEntry] { get }
    func stopRecording()
    func cancelActiveRecording()
    func toggleHandsFree()
    func copyEntry(_ entry: TranscriptEntry)
    func copyLastDictation()
    func undoDiscard()
    func requestMicrophonePermission()
    func openMicrophoneSettings()
    var microphonePermissionStatus: PermissionDiagnostics.AccessStatus { get }
}

extension DictationController: MenuBarCommandTarget {}

/// Runs menu commands against the controller and the app.
@MainActor
struct MenuBarCommandRunner {
    let target: MenuBarCommandTarget
    var pasteLast: () -> Void
    var selectMicrophone: (String?) -> Void
    var openSteno: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    func run(_ action: MenuBarAction) {
        switch action {
        case .startDictation: target.toggleHandsFree()
        case .stop: target.stopRecording()
        case .discard: target.cancelActiveRecording()
        case .undoDiscard: target.undoDiscard()
        case .copyLatest: target.copyLastDictation()
        case .copyEntry(let id):
            if let entry = target.recentEntries.first(where: { $0.id == id }) { target.copyEntry(entry) }
        case .pasteLast: pasteLast()
        case .selectMicrophone(let id): selectMicrophone(id)
        case .turnOnMicrophone:
            if target.microphonePermissionStatus == .unknown {
                target.requestMicrophonePermission()
            } else {
                target.openMicrophoneSettings()
            }
        case .openSteno: openSteno()
        case .openSettings: openSettings()
        case .quit: quit()
        }
    }
}
