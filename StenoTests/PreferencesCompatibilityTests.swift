import AppKit
import Foundation
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Preferences compatibility. A 1.1 file read by the frozen 1.0.0 decoder, a 1.0.1
/// file with every cleanup raw value read by 1.1, and the Cleanup labels that write those values.
@Suite("Preferences compatibility", .serialized)
struct PreferencesCompatibilityTests {
    // MARK: Helpers

    private static func makeDirectory(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefs-compat-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func scopeKey(_ scope: Released100Preferences.Scope) -> String {
        switch scope {
        case .global: "g"
        case .app(let id): "a:\(id)"
        }
    }

    private static func scopeKey(_ scope: StenoKit.Scope) -> String {
        switch scope {
        case .global: "g"
        case .app(let id): "a:\(id)"
        }
    }

    private static func profile100(_ p: Released100Preferences.StyleProfile) -> [String] {
        [p.name, p.tone.rawValue, p.structureMode.rawValue, p.fillerPolicy.rawValue, p.commandPolicy.rawValue]
    }

    private static func profile11(_ p: StyleProfile) -> [String] {
        [p.name, p.tone.rawValue, p.structureMode.rawValue, p.fillerPolicy.rawValue, p.commandPolicy.rawValue]
    }

    /// The labels of `value`'s stored properties that still hold the same value as `defaults`.
    /// A section with any left is not fully non-default, so the test would not prove that field.
    private static func fieldsAtDefault<T>(_ value: T, _ defaults: T) -> [String] {
        zip(Mirror(reflecting: value).children, Mirror(reflecting: defaults).children)
            .filter { String(describing: $0.0.value) == String(describing: $0.1.value) }
            .compactMap { $0.0.label }
    }

    /// Every 1.0 and every 1.1 setting at a value other than its default.
    private static func everyFieldNonDefault(in dir: URL, handsFreeKey: UInt16?) -> AppPreferences {
        let cli = dir.appendingPathComponent("whisper-cli").path
        let model = dir.appendingPathComponent("ggml-x.bin").path
        let vad = dir.appendingPathComponent("vad.bin").path
        // Existing paths are kept as they are by normalize() (WhisperRuntimePathRepair).
        for path in [cli, model, vad] { FileManager.default.createFile(atPath: path, contents: Data()) }

        var p = AppPreferences.default
        p.appearance = .init(mode: .light, accent: .rose, recordHeroStyle: .ring, atmosphereIntensity: 40, showsLineNumbers: false)
        p.general = .init(launchAtLoginEnabled: true, showDockIcon: false, showOnboarding: false, successNoticesShown: 9)
        p.hotkeys = .init(optionPressToTalkEnabled: false, handsFreeGlobalKeyCode: handsFreeKey)
        p.dictation = .init(
            whisperCLIPath: cli, modelPath: model, threadCount: 3, vadEnabled: false, vadModelPath: vad,
            showLiveTranscriptWhileRecording: true, useNearbyTextForContinuation: true)
        p.insertion = .init(orderedMethods: [.clipboardPaste, .accessibility, .direct])
        p.media = .init(pauseDuringHandsFree: false, pauseDuringPressToTalk: false)
        p.recording = .init(
            inputDeviceID: "AppleUSBAudioEngine:V:M:1:1", afterInserting: "always",
            pasteLastShortcut: "control+option+command+9")
        p.lexiconEntries = [
            LexiconEntry(
                term: "kube control", preferred: "kubectl", scope: .app(bundleID: "com.example.Editor"),
                aliases: ["cube control"], phoneticRecovery: .properNounEnglish),
            LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global),
        ]
        p.globalStyleProfile = StyleProfile(
            name: "Default", tone: .technical, structureMode: .bullets, fillerPolicy: .aggressive, commandPolicy: .passthrough)
        p.appStyleProfiles = [
            "com.example.Mail": StyleProfile(
                name: "App Override", tone: .professional, structureMode: .email, fillerPolicy: .minimal, commandPolicy: .transform),
            "com.example.Term": StyleProfile(
                name: "App Override", tone: .concise, structureMode: .command, fillerPolicy: .aggressive, commandPolicy: .passthrough),
        ]
        p.snippets = [
            Snippet(
                id: UUID(uuidString: "6E0F5D3C-4E7A-4B41-9E0C-1B0D2C3A4B5C")!, trigger: "sig", expansion: "Best,\nSam",
                scope: .app(bundleID: "com.apple.mail")),
            Snippet(id: UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!, trigger: "addr", expansion: "1 Example Street"),
        ]
        return p
    }

    /// Saves `p` with the 1.1 store and reads the file with the frozen 1.0.0 decoder, field by field.
    private static func expectReadsBackIn100(
        _ p: AppPreferences, in dir: URL, handsFreeIn100: UInt16, fileHoldsNullKey: Bool
    ) async throws {
        let defaults = AppPreferences.default
        // A field the test left at its default would pass for the wrong reason.
        #expect(fieldsAtDefault(p.appearance, defaults.appearance) == [], "appearance left at default")
        #expect(fieldsAtDefault(p.general, defaults.general) == [], "general left at default")
        #expect(fieldsAtDefault(p.hotkeys, defaults.hotkeys) == [], "hotkeys left at default")
        #expect(fieldsAtDefault(p.dictation, defaults.dictation) == [], "dictation left at default")
        #expect(fieldsAtDefault(p.insertion, defaults.insertion) == [], "insertion left at default")
        #expect(fieldsAtDefault(p.media, defaults.media) == [], "media left at default")
        #expect(fieldsAtDefault(p.recording, defaults.recording) == [], "recording left at default")
        #expect(p.lexiconEntries != defaults.lexiconEntries)
        #expect(p.globalStyleProfile != defaults.globalStyleProfile)
        #expect(p.appStyleProfiles != defaults.appStyleProfiles)
        #expect(p.snippets != defaults.snippets)

        let url = dir.appendingPathComponent("preferences.json")
        let store = AppPreferencesStore(storageURL: url)
        let result = await store.save(p)
        try #require((try? result.get()) != nil, "the 1.1 store could not save")
        var e = p
        e.normalize()
        #expect(e == p, "normalize() changed a non-default value, so the comparison below would not prove it")

        let data = try Data(contentsOf: url)
        let file = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The 1.1 fields really are in the file.
        #expect(file["recording"] != nil, "no recording section in the file")
        #expect((file["appearance"] as? [String: Any])?["showsLineNumbers"] != nil)
        #expect((file["general"] as? [String: Any])?["successNoticesShown"] != nil)
        if fileHoldsNullKey {
            #expect((file["hotkeys"] as? [String: Any])?["handsFreeGlobalKeyCode"] is NSNull, "a Disabled key is not written as null")
        }

        // The frozen 1.0.0 decoder must not throw.
        let r = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: data)

        #expect(r.appearance.mode.rawValue == e.appearance.mode.rawValue, "appearance.mode")
        #expect(r.appearance.accent.rawValue == e.appearance.accent.rawValue, "appearance.accent")
        #expect(r.appearance.recordHeroStyle.rawValue == e.appearance.recordHeroStyle.rawValue, "appearance.recordHeroStyle")
        #expect(r.appearance.atmosphereIntensity == e.appearance.atmosphereIntensity, "appearance.atmosphereIntensity")

        #expect(r.general.launchAtLoginEnabled == e.general.launchAtLoginEnabled, "general.launchAtLoginEnabled")
        #expect(r.general.showDockIcon == e.general.showDockIcon, "general.showDockIcon")
        #expect(r.general.showOnboarding == e.general.showOnboarding, "general.showOnboarding")

        #expect(r.hotkeys.optionPressToTalkEnabled == e.hotkeys.optionPressToTalkEnabled, "hotkeys.optionPressToTalkEnabled")
        #expect(r.hotkeys.handsFreeGlobalKeyCode == handsFreeIn100, "hotkeys.handsFreeGlobalKeyCode")

        #expect(r.dictation.whisperCLIPath == e.dictation.whisperCLIPath, "dictation.whisperCLIPath")
        #expect(r.dictation.modelPath == e.dictation.modelPath, "dictation.modelPath")
        #expect(r.dictation.threadCount == e.dictation.threadCount, "dictation.threadCount")
        #expect(r.dictation.vadEnabled == e.dictation.vadEnabled, "dictation.vadEnabled")
        #expect(r.dictation.vadModelPath == e.dictation.vadModelPath, "dictation.vadModelPath")
        #expect(r.dictation.showLiveTranscriptWhileRecording == e.dictation.showLiveTranscriptWhileRecording, "dictation.showLive")
        #expect(r.dictation.useNearbyTextForContinuation == e.dictation.useNearbyTextForContinuation, "dictation.nearbyText")

        #expect(r.insertion.orderedMethods.map(\.rawValue) == e.insertion.orderedMethods.map(\.rawValue), "insertion.orderedMethods")
        #expect(r.media.pauseDuringHandsFree == e.media.pauseDuringHandsFree, "media.pauseDuringHandsFree")
        #expect(r.media.pauseDuringPressToTalk == e.media.pauseDuringPressToTalk, "media.pauseDuringPressToTalk")

        func lexicon100(_ entries: [Released100Preferences.LexiconEntry]) -> [[String]] {
            entries.map { [$0.term, $0.preferred, scopeKey($0.scope), $0.aliases.joined(separator: "|"), $0.phoneticRecovery.rawValue] }
        }
        func lexicon11(_ entries: [LexiconEntry]) -> [[String]] {
            entries.map { [$0.term, $0.preferred, scopeKey($0.scope), $0.aliases.joined(separator: "|"), $0.phoneticRecovery.rawValue] }
        }
        #expect(lexicon100(r.lexiconEntries) == lexicon11(e.lexiconEntries), "lexiconEntries")
        #expect(profile100(r.globalStyleProfile) == profile11(e.globalStyleProfile), "globalStyleProfile")
        #expect(r.appStyleProfiles.mapValues(profile100) == e.appStyleProfiles.mapValues(profile11), "appStyleProfiles")
        func snippets100(_ items: [Released100Preferences.Snippet]) -> [[String]] {
            items.map { [$0.id.uuidString, $0.trigger, $0.expansion, scopeKey($0.scope)] }
        }
        func snippets11(_ items: [Snippet]) -> [[String]] {
            items.map { [$0.id.uuidString, $0.trigger, $0.expansion, scopeKey($0.scope)] }
        }
        #expect(snippets100(r.snippets) == snippets11(e.snippets), "snippets")

        // Nothing is absent on the 1.0.0 side except the three 1.1 fields, and nothing 1.0.0
        // writes is missing from the 1.1 file.
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        var onlyIn11: [String: Set<String>] = ["<top>": Set(file.keys).subtracting(reencoded.keys)]
        var onlyIn100: [String: Set<String>] = ["<top>": Set(reencoded.keys).subtracting(file.keys)]
        for section in ["appearance", "general", "hotkeys", "dictation", "insertion", "media"] {
            let fileKeys = Set((file[section] as? [String: Any] ?? [:]).keys)
            let oldKeys = Set((reencoded[section] as? [String: Any] ?? [:]).keys)
            onlyIn11[section] = fileKeys.subtracting(oldKeys)
            onlyIn100[section] = oldKeys.subtracting(fileKeys)
        }
        #expect(
            onlyIn11 == ["<top>": ["recording"], "appearance": ["showsLineNumbers"], "general": ["successNoticesShown"],
                         "hotkeys": [], "dictation": [], "insertion": [], "media": []],
            "keys only the 1.1 file has: \(onlyIn11)")
        #expect(
            onlyIn100 == ["<top>": [], "appearance": [], "general": [], "hotkeys": [], "dictation": [], "insertion": [], "media": []],
            "keys 1.0.0 writes that the 1.1 file lacks: \(onlyIn100)")

        // And 1.1 itself reads the file back unchanged.
        let again = await AppPreferencesStore(storageURL: url).load()
        #expect(again == e, "1.1 does not read its own file back unchanged")
    }

    // MARK: 1.1 file read by 1.0.0

    @Test("A 1.1 file with every 1.0 and 1.1 setting changed reads back field by field in the frozen 1.0.0 decoder")
    func everySettingWrittenBy11ReadsBackInThe100Decoder() async throws {
        let dir = try Self.makeDirectory("c1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Self.everyFieldNonDefault(in: dir, handsFreeKey: 105)
        try await Self.expectReadsBackIn100(p, in: dir, handsFreeIn100: 105, fileHoldsNullKey: false)
    }

    @Test("A hands-free key set to Disabled is the only value 1.0.0 reads differently (as F18); every other field still matches")
    func aDisabledHandsFreeKeyIsTheOnlyAllowedLossIn100() async throws {
        let dir = try Self.makeDirectory("c1-disabled")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Self.everyFieldNonDefault(in: dir, handsFreeKey: nil)
        try await Self.expectReadsBackIn100(p, in: dir, handsFreeIn100: 79, fileHoldsNullKey: true)
    }

    // MARK: 1.0.1 cleanup values

    private static func rawTranscript(_ text: String) -> RawTranscript {
        RawTranscript(
            text: text, segments: [TranscriptSegment(startMS: 0, endMS: 2_000, text: text, confidence: 0.93)],
            avgConfidence: 0.93, durationMS: 2_000)
    }

    @Test("A 1.0.1 file with every Layout and Filler raw value loads without a notice, cleans like the literal profile, and is written back unchanged")
    func everyStoredCleanupValueLoadsCleansAndIsWrittenBackUnchanged() async throws {
        let structures = ["natural", "paragraph", "bullets", "email", "command"]
        let fillers = ["minimal", "balanced", "aggressive"]
        let tones = ["natural", "professional", "concise", "friendly", "technical"]
        let commands = ["passthrough", "transform"]
        // Latin script only: PhraseMatchPlanner changed for CJK and Thai after 1.0.1.
        let inputs = [
            "um so we should uh ship it on friday you know and basically I mean it is kind of done",
            "I think, um, this should, you know, ship today. Buy milk, eggs; bread. Then call Sam.",
            "like I said it is sort of fine. What kind of car is that?",
            "please open stenoh and check the build",
        ]

        var profiles: [String: [String: String]] = [:]
        var index = 0
        for structure in structures {
            for filler in fillers {
                profiles["com.example.app\(index)"] = [
                    "name": "App Override", "tone": tones[index % tones.count], "structureMode": structure,
                    "fillerPolicy": filler, "commandPolicy": commands[index % commands.count],
                ]
                index += 1
            }
        }
        #expect(profiles.count == 15)
        let global = [
            "name": "Default", "tone": "natural", "structureMode": "bullets", "fillerPolicy": "aggressive",
            "commandPolicy": "transform",
        ]

        // A 1.0.1-shaped file: today's encoding of the defaults, without the 1.1-only keys, with the
        // two style sections replaced by the literal strings above.
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences.default)) as? [String: Any])
        object.removeValue(forKey: "recording")
        var appearance = try #require(object["appearance"] as? [String: Any])
        appearance.removeValue(forKey: "showsLineNumbers")
        object["appearance"] = appearance
        var general = try #require(object["general"] as? [String: Any])
        general.removeValue(forKey: "successNoticesShown")
        object["general"] = general
        object["globalStyleProfile"] = global
        object["appStyleProfiles"] = profiles

        let dir = try Self.makeDirectory("c2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preferences.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)

        let store = AppPreferencesStore(storageURL: url)
        let loaded = await store.load()
        #expect(await store.takeRecoveryNotices().isEmpty, "loading the 1.0.1 file raised a recovery notice")

        // The raw strings survive the load.
        #expect(loaded.globalStyleProfile.structureMode.rawValue == "bullets")
        #expect(loaded.globalStyleProfile.fillerPolicy.rawValue == "aggressive")
        #expect(loaded.appStyleProfiles.count == 15)
        for (id, d) in profiles {
            let p = try #require(loaded.appStyleProfiles[id], "no profile for \(id)")
            #expect(
                [p.tone.rawValue, p.structureMode.rawValue, p.fillerPolicy.rawValue, p.commandPolicy.rawValue]
                    == [d["tone"]!, d["structureMode"]!, d["fillerPolicy"]!, d["commandPolicy"]!],
                "\(id) was changed by loading")
        }

        // The same wiring as DictationRuntimeFactory.makeStyleProfileService.
        let service = StyleProfileService(globalProfile: loaded.globalStyleProfile, appProfiles: loaded.appStyleProfiles)
        let lexicon = PersonalLexicon(entries: loaded.lexiconEntries)
        let engine = RuleBasedCleanupEngine()
        for (id, d) in profiles.sorted(by: { $0.key < $1.key }) {
            let resolved = await service.resolve(for: AppContext(bundleIdentifier: id, appName: "A"))
            let structure = try #require(StructureMode(rawValue: d["structureMode"]!))
            let literal = StyleProfile(
                name: d["name"]!, tone: try #require(StyleTone(rawValue: d["tone"]!)),
                structureMode: structure.effective,
                fillerPolicy: try #require(FillerPolicy(rawValue: d["fillerPolicy"]!)),
                commandPolicy: try #require(CommandPolicy(rawValue: d["commandPolicy"]!)))
            #expect(resolved == literal, "\(id) resolves to \(resolved), not the literal \(literal)")
            // Email behaves as Paragraph and Command as Natural.
            if structure == .email { #expect(resolved.structureMode == .paragraph, "\(id): email") }
            if structure == .command { #expect(resolved.structureMode == .natural, "\(id): command") }

            for text in inputs {
                let fromFile = try await engine.cleanup(raw: Self.rawTranscript(text), profile: resolved, lexicon: lexicon).text
                let fromLiteral = try await engine.cleanup(raw: Self.rawTranscript(text), profile: literal, lexicon: lexicon).text
                #expect(fromFile == fromLiteral, "\(id) cleans differently from the literal profile")

                // What the raw string means for the text: only Thorough (aggressive) removes these
                // fillers; Light and Balanced keep them, and nothing keeps "like" or "you know" out.
                let lowered = fromFile.lowercased()
                let thorough = d["fillerPolicy"] == "aggressive"
                if text == inputs[0] {
                    for kept in ["um so", "uh ship", "basically", "kind of"] {
                        #expect(lowered.contains(kept) == !thorough, "\(id) \(d["fillerPolicy"]!): \(kept) in \(fromFile.debugDescription)")
                    }
                }
                if text == inputs[1] { #expect(lowered.contains("you know"), "\(id): you know in \(fromFile.debugDescription)") }
                if text == inputs[2] {
                    #expect(lowered.contains("like i said"), "\(id): like in \(fromFile.debugDescription)")
                    #expect(lowered.contains("kind of car"), "\(id): kind of car in \(fromFile.debugDescription)")
                }
                if text == inputs[3] {
                    #expect(fromFile.contains("Steno") && !lowered.contains("stenoh"), "\(id): lexicon in \(fromFile.debugDescription)")
                }

                // Tone never changes the output.
                for tone in StyleTone.allCases {
                    var toned = literal
                    toned.tone = tone
                    let out = try await engine.cleanup(raw: Self.rawTranscript(text), profile: toned, lexicon: lexicon).text
                    #expect(out == fromLiteral, "tone \(tone) changed the output of \(id)")
                }

                // A saved Email cleans as Paragraph and a saved Command as Natural.
                if structure == .email {
                    var asParagraph = literal
                    asParagraph.structureMode = .paragraph
                    let out = try await engine.cleanup(raw: Self.rawTranscript(text), profile: asParagraph, lexicon: lexicon).text
                    #expect(out == fromFile, "email did not clean as paragraph (\(id))")
                }
                if structure == .command {
                    var asNatural = literal
                    asNatural.structureMode = .natural
                    let out = try await engine.cleanup(raw: Self.rawTranscript(text), profile: asNatural, lexicon: lexicon).text
                    #expect(out == fromFile, "command did not clean as natural (\(id))")
                }
            }
        }

        // An unrelated 1.1 save writes the same raw strings back.
        var edited = loaded
        edited.general.showDockIcon.toggle()
        let saved = await store.save(edited)
        try #require((try? saved.get()) != nil, "the unrelated save failed")
        let out = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((out["appStyleProfiles"] as? [String: [String: String]]) == profiles, "per-app profile strings were rewritten by an unrelated save")
        #expect((out["globalStyleProfile"] as? [String: String]) == global, "the global profile strings were rewritten by an unrelated save")
    }

    // MARK: Cleanup labels

    @Test("The Layout and Filler words labels are paired with the 1.0.1 raw values")
    func labelTablesPairEachLabelWithItsRawValue() {
        #expect(
            CleanupStyleSettingsSection.fillers.map { "\($0.0.rawValue)=\($0.1)" }
                == ["minimal=Light", "balanced=Balanced", "aggressive=Thorough"])
        #expect(
            CleanupStyleSettingsSection.layouts.map { "\($0.0.rawValue)=\($0.1)" }
                == ["natural=As spoken", "paragraph=Paragraphs", "bullets=Bullets"])
        #expect(CleanupStyleSettingsSection.layouts.map(\.0) == StructureMode.selectableCases)
    }

    typealias F = TransitionFixtures

    @MainActor
    private func cleanupHost(_ saved: AppPreferences) -> (TransitionHost, SettingsSession, DictationController) {
        let controller = F.sampleController()
        controller.preferences = saved
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: saved), section: .cleanup)
        let host = TransitionHost(size: CGSize(width: 860, height: 1_000), controller: controller) {
            SettingsView(session: session)
        }
        return (host, session, controller)
    }

    @MainActor
    private func selectedLabel(_ host: TransitionHost, group: String) -> String? {
        let radios = host.nodes(under: host.node { $0.role == "AXRadioGroup" && $0.name == group })
            .filter { $0.role == "AXRadioButton" }
        return radios.first { $0.number == 1 }?.name
    }

    @MainActor
    private func popupTitles(_ host: TransitionHost, label: String) -> [String] {
        host.views(NSPopUpButton.self).filter { $0.accessibilityLabel() == label }.map { $0.titleOfSelectedItem ?? "" }
    }

    private static func encodedProfile(_ preferences: AppPreferences, key: String?) throws -> [String: String] {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        if let key {
            let profiles = try #require(object["appStyleProfiles"] as? [String: [String: String]])
            return try #require(profiles[key])
        }
        return try #require(object["globalStyleProfile"] as? [String: String])
    }

    static let picks: [(String, String, String)] = [
        ("Layout", "As spoken", "natural"), ("Layout", "Paragraphs", "paragraph"), ("Layout", "Bullets", "bullets"),
        ("Filler words", "Light", "minimal"), ("Filler words", "Balanced", "balanced"), ("Filler words", "Thorough", "aggressive"),
    ]

    @Test("Picking a Layout or Filler words label everywhere stores the 1.0.1 raw value, and an unrelated pick leaves a saved Email layout alone",
          arguments: PreferencesCompatibilityTests.picks)
    @MainActor
    func globalPickWritesTheRawValue(group: String, label: String, raw: String) async throws {
        var saved = F.sampleController().preferences
        // Start from a value that differs from the target so the pick makes a change. For a
        // Filler pick the saved layout is Email, which must not be rewritten.
        saved.globalStyleProfile.structureMode = group == "Layout" ? (raw == "natural" ? .bullets : .natural) : .email
        saved.globalStyleProfile.fillerPolicy = group == "Filler words" ? (raw == "minimal" ? .aggressive : .minimal) : .balanced
        let (host, session, _) = cleanupHost(saved)
        defer { host.close() }
        await host.settle { host.node(named: group) != nil }
        let before = try #require(selectedLabel(host, group: group), "no choice is marked in \(group)")
        #expect(before != label, "\(label) is already the saved \(group)")
        if group == "Filler words" {
            #expect(selectedLabel(host, group: "Layout") == "Paragraphs", "a saved Email layout is not shown as Paragraphs")
        }

        try await host.selectSegment(label)
        let g = session.draft.preferences.globalStyleProfile
        #expect((group == "Layout" ? g.structureMode.rawValue : g.fillerPolicy.rawValue) == raw)
        if group == "Filler words" { #expect(g.structureMode == .email, "the filler pick rewrote the saved Email layout to \(g.structureMode)") }
        if group == "Layout" { #expect(g.fillerPolicy == .balanced, "the layout pick changed the filler policy") }

        let stored = try Self.encodedProfile(session.draft.preferences, key: nil)
        #expect(stored[group == "Layout" ? "structureMode" : "fillerPolicy"] == raw, "the encoded value is not \(raw): \(stored)")
    }

    @Test("Picking a Layout or Filler words label in an app row stores the 1.0.1 raw value, and an unrelated pick leaves a saved Command layout alone",
          arguments: PreferencesCompatibilityTests.picks)
    @MainActor
    func appRowPickWritesTheRawValue(group: String, label: String, raw: String) async throws {
        let bundleID = "com.apple.Notes"
        var saved = F.sampleController().preferences
        let structure: StructureMode = group == "Layout" ? (raw == "natural" ? .bullets : .natural) : .command
        let filler: FillerPolicy = group == "Filler words" ? (raw == "minimal" ? .aggressive : .minimal) : .balanced
        saved.appStyleProfiles = [
            bundleID: StyleProfile(name: "App Override", tone: .technical, structureMode: structure, fillerPolicy: filler, commandPolicy: .passthrough),
        ]
        let (host, session, _) = cleanupHost(saved)
        defer { host.close() }
        // SwiftUI names the menus only once the accessibility tree has been read.
        await host.settle { host.node(named: group) != nil && !popupTitles(host, label: group).isEmpty }
        let titles = popupTitles(host, label: group)
        try #require(!titles.isEmpty, "no \(group) menu in the app row; popups: \(host.views(NSPopUpButton.self).map { $0.accessibilityLabel() ?? "-" })")
        if group == "Filler words" {
            #expect(popupTitles(host, label: "Layout") == ["As spoken"], "a saved Command layout is not shown as As spoken: \(popupTitles(host, label: "Layout"))")
        }

        try await host.choose(menuItem: label) { $0.accessibilityLabel() == group }
        let p = try #require(session.draft.preferences.appStyleProfiles[bundleID])
        #expect((group == "Layout" ? p.structureMode.rawValue : p.fillerPolicy.rawValue) == raw)
        if group == "Filler words" { #expect(p.structureMode == .command, "the filler pick rewrote the saved Command layout to \(p.structureMode)") }
        if group == "Layout" { #expect(p.fillerPolicy == .balanced, "the layout pick changed the filler policy") }
        #expect(p.tone == .technical && p.commandPolicy == .passthrough, "the pick changed the tone or command policy")

        let stored = try Self.encodedProfile(session.draft.preferences, key: bundleID)
        #expect(stored[group == "Layout" ? "structureMode" : "fillerPolicy"] == raw, "the encoded value is not \(raw): \(stored)")
    }

    @Test("A saved Email or Command layout is shown as Paragraphs or As spoken and survives an unrelated Slash commands pick")
    @MainActor
    func savedEmailAndCommandLayoutsAreShownAsTheirEffectiveLayoutAndKeptUntilAnotherIsPicked() async throws {
        let bundleID = "com.apple.Notes"
        var saved = F.sampleController().preferences
        saved.globalStyleProfile.structureMode = .email
        saved.globalStyleProfile.commandPolicy = .transform
        let emailApp = "com.apple.TextEdit"
        saved.appStyleProfiles = [
            bundleID: StyleProfile(name: "App Override", tone: .natural, structureMode: .command, fillerPolicy: .balanced, commandPolicy: .transform),
            emailApp: StyleProfile(name: "App Override", tone: .natural, structureMode: .email, fillerPolicy: .balanced, commandPolicy: .transform),
        ]
        let (host, session, _) = cleanupHost(saved)
        defer { host.close() }
        await host.settle { host.node(named: "Layout") != nil && popupTitles(host, label: "Layout").count == 2 }
        #expect(selectedLabel(host, group: "Layout") == "Paragraphs", "global Email is shown as \(String(describing: selectedLabel(host, group: "Layout")))")
        #expect(popupTitles(host, label: "Layout").sorted() == ["As spoken", "Paragraphs"], "app-row Command and Email are shown as \(popupTitles(host, label: "Layout"))")

        try await host.selectSegment("Keep as spoken")
        let after = session.draft.preferences
        #expect(after.globalStyleProfile.commandPolicy == .passthrough, "the pick did not take")
        #expect(after.globalStyleProfile.structureMode == .email, "an unrelated pick rewrote the global Email layout")
        #expect(after.appStyleProfiles[bundleID]?.structureMode == .command, "an unrelated pick rewrote the app Command layout")
        #expect(after.appStyleProfiles[emailApp]?.structureMode == .email, "an unrelated pick rewrote the app Email layout")
    }
}
