import Foundation
import StenoKit

/// One drafted setting: the row label shown in Settings and how to tell whether a draft changed it.
struct SettingsField: Identifiable, Sendable {
    let id: String
    let title: String
    let section: SettingsSection
    let isChanged: @Sendable (AppPreferences, AppPreferences) -> Bool

    init<Value: Equatable & Sendable>(
        _ id: String,
        _ title: String,
        in section: SettingsSection,
        _ read: @escaping @Sendable (AppPreferences) -> Value
    ) {
        self.id = id
        self.title = title
        self.section = section
        isChanged = { read($0) != read($1) }
    }
}

/// Every drafted setting and every searchable row of the Settings window.
enum SettingsCatalog {
    /// Drafted settings in page order. Appearance applies immediately and is not listed.
    static let fields: [SettingsField] = [
        SettingsField("option", "Hold Option to dictate", in: .recording) { $0.hotkeys.optionPressToTalkEnabled },
        SettingsField("handsFreeKey", "Hands-free key", in: .recording) { $0.hotkeys.handsFreeGlobalKeyCode },
        SettingsField("pasteLast", "Paste last dictation", in: .recording) { $0.recording.pasteLastShortcut },
        SettingsField("liveTranscript", "Show live transcript", in: .recording) { $0.dictation.showLiveTranscriptWhileRecording },
        SettingsField("afterInserting", "After inserting", in: .recording) { $0.afterInserting },
        SettingsField("nearbyText", "Use nearby text for continuation", in: .recording) { $0.dictation.useNearbyTextForContinuation },
        SettingsField("input", "Input", in: .microphone) { $0.inputDeviceID },
        SettingsField("model", "Speech model", in: .engine) { $0.dictation.modelPath },
        SettingsField("skipSilence", "Skip silence", in: .engine) { $0.dictation.vadEnabled },
        SettingsField("advanced", "Advanced", in: .engine) {
            [$0.dictation.whisperCLIPath, $0.dictation.vadModelPath, String($0.dictation.threadCount)]
        },
        SettingsField("pauseHold", MediaSettingsSection.holdLabel, in: .media) { $0.media.pauseDuringPressToTalk },
        SettingsField("pauseHandsFree", "Pause during hands-free dictation", in: .media) { $0.media.pauseDuringHandsFree },
        SettingsField("layout", "Layout", in: .cleanup) { $0.globalStyleProfile.structureMode },
        SettingsField("filler", "Filler words", in: .cleanup) { $0.globalStyleProfile.fillerPolicy },
        SettingsField("commands", "Slash commands", in: .cleanup) { $0.globalStyleProfile.commandPolicy },
        SettingsField("appStyles", "For specific apps", in: .cleanup) { $0.appStyleProfiles },
        SettingsField("corrections", "Word corrections", in: .corrections) { $0.lexiconEntries },
        SettingsField("snippets", "Text shortcuts", in: .shortcuts) { $0.snippets },
        SettingsField("insertion", "Insertion order", in: .output) { $0.insertion.orderedMethods },
        SettingsField("login", "Open at login", in: .general) { $0.general.launchAtLoginEnabled },
        SettingsField("dock", "Show in the Dock", in: .general) { $0.general.showDockIcon },
        SettingsField("guide", "Show the setup guide", in: .general) { $0.general.showOnboarding },
    ]

    /// The drafted settings that differ between `saved` and `draft`.
    static func changes(from saved: AppPreferences, to draft: AppPreferences) -> [SettingsField] {
        fields.filter { $0.isChanged(saved, draft) }
    }

    /// The draft bar's description of pending changes.
    static func summary(of changes: [SettingsField]) -> String {
        switch changes.count {
        case 0: return "No unsaved changes"
        case 1: return "1 unsaved change: \(changes[0].title)"
        case 2, 3: return "\(changes.count) unsaved changes: \(changes.map(\.title).joined(separator: ", "))"
        default: return "\(changes.count) unsaved changes"
        }
    }

    struct SearchRow: Sendable, Equatable {
        let section: SettingsSection
        let title: String
        let terms: String
    }

    /// Rows that sidebar search can find, with words a person might type for each.
    static let searchRows: [SearchRow] = [
        .init(section: .recording, title: "Hold Option to dictate", terms: "shortcut key press talk hold option"),
        .init(section: .recording, title: "Hands-free key", terms: "function key f13 f18 f20 toggle hotkey"),
        .init(section: .recording, title: "Paste last dictation", terms: "shortcut paste last"),
        .init(section: .recording, title: "Show live transcript", terms: "preview words overlay"),
        .init(section: .recording, title: "After inserting", terms: "overlay notice inserted where"),
        .init(section: .recording, title: "Use nearby text for continuation", terms: "context spacing capitals cursor"),
        .init(section: .microphone, title: "Input", terms: "microphone device input mic"),
        .init(section: .microphone, title: "Test", terms: "test level microphone"),
        .init(section: .microphone, title: "Follow the system input", terms: "system default microphone"),
        .init(section: .engine, title: "Speech model", terms: "model whisper download small medium large base"),
        .init(section: .engine, title: "Skip silence", terms: "voice detection vad silence noise"),
        .init(section: .engine, title: "Test setup", terms: "test check"),
        .init(section: .engine, title: "Advanced", terms: "path threads whisper-cli"),
        .init(section: .media, title: MediaSettingsSection.holdLabel, terms: "music video pause media option press talk"),
        .init(section: .media, title: "Pause during hands-free dictation", terms: "music video pause media"),
        .init(section: .cleanup, title: "Layout", terms: "paragraphs bullets structure"),
        .init(section: .cleanup, title: "Filler words", terms: "um uh like filler"),
        .init(section: .cleanup, title: "Slash commands", terms: "command slash / keep raw pass through"),
        .init(section: .cleanup, title: "For specific apps", terms: "app override profile"),
        .init(section: .corrections, title: "Word corrections", terms: "misheard spelling lexicon correct word"),
        .init(section: .shortcuts, title: "Text shortcuts", terms: "snippet expansion phrase"),
        .init(section: .output, title: "Inserting text", terms: "type accessibility paste clipboard order"),
        .init(section: .permissions, title: "Microphone", terms: "permission access privacy"),
        .init(section: .permissions, title: "Accessibility", terms: "permission access privacy insert"),
        .init(section: .permissions, title: "Input Monitoring", terms: "permission keyboard shortcut"),
        .init(section: .appearance, title: "Appearance", terms: "light dark system mode theme"),
        .init(section: .general, title: "Open at login", terms: "login startup launch"),
        .init(section: .general, title: "Show in the Dock", terms: "dock icon menu bar"),
        .init(section: .general, title: "Show the setup guide", terms: "onboarding welcome guide"),
        .init(section: .general, title: "History", terms: "delete history data"),
    ]

    /// Sections with rows matching `query`, in sidebar order, each with its matching row titles.
    /// An empty query returns nothing; the sidebar then shows every section.
    static func search(_ query: String) -> [(section: SettingsSection, rows: [String])] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return SettingsSection.allCases.compactMap { section in
            let rows = searchRows.filter { row in
                guard row.section == section else { return false }
                let haystack = "\(section.title) \(row.title) \(row.terms)".lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            return rows.isEmpty ? nil : (section, rows.map(\.title))
        }
    }
}
