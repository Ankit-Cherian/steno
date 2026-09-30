import Foundation
import StenoKit

struct AppPreferences: Codable, Sendable, Equatable {
    struct Appearance: Codable, Sendable, Equatable {
        var mode: StenoAppearanceMode
        var accent: StenoAccentStyle
        var recordHeroStyle: StenoRecordHeroStyle
        var atmosphereIntensity: Int

        init(
            mode: StenoAppearanceMode = .dark,
            accent: StenoAccentStyle = .citron,
            recordHeroStyle: StenoRecordHeroStyle = .pill,
            atmosphereIntensity: Int = 100
        ) {
            self.mode = mode
            self.accent = accent
            self.recordHeroStyle = recordHeroStyle
            self.atmosphereIntensity = atmosphereIntensity
        }

        /// Files written before appearance settings existed keep the original accent.
        static let legacy = Appearance(mode: .dark, accent: .dodger, recordHeroStyle: .pill, atmosphereIntensity: 100)

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = try container.decodeLenientlyIfPresent(StenoAppearanceMode.self, forKey: .mode, fallback: .dark) ?? .dark
            accent = try container.decodeLenientlyIfPresent(StenoAccentStyle.self, forKey: .accent, fallback: .citron) ?? .dodger
            recordHeroStyle = try container.decodeLenientlyIfPresent(
                StenoRecordHeroStyle.self,
                forKey: .recordHeroStyle,
                fallback: .pill
            ) ?? .pill
            atmosphereIntensity = try container.decodeIfPresent(Int.self, forKey: .atmosphereIntensity) ?? 100
        }

        mutating func normalize() {
            atmosphereIntensity = max(0, min(100, atmosphereIntensity))
        }
    }

    struct General: Codable, Sendable, Equatable {
        var launchAtLoginEnabled: Bool
        var showDockIcon: Bool
        var showOnboarding: Bool

        init(launchAtLoginEnabled: Bool, showDockIcon: Bool, showOnboarding: Bool) {
            self.launchAtLoginEnabled = launchAtLoginEnabled
            self.showDockIcon = showDockIcon
            self.showOnboarding = showOnboarding
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
            showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
            showOnboarding = try container.decodeIfPresent(Bool.self, forKey: .showOnboarding) ?? false
        }
    }

    struct Hotkeys: Codable, Sendable, Equatable {
        var optionPressToTalkEnabled: Bool
        var handsFreeGlobalKeyCode: UInt16?

        init(optionPressToTalkEnabled: Bool, handsFreeGlobalKeyCode: UInt16? = 79) {
            self.optionPressToTalkEnabled = optionPressToTalkEnabled
            self.handsFreeGlobalKeyCode = handsFreeGlobalKeyCode
        }

        private enum CodingKeys: String, CodingKey {
            case optionPressToTalkEnabled
            case handsFreeGlobalKeyCode
        }

        /// A present null means the user chose Disabled; an absent key is a
        /// file from before that choice existed and keeps the F18 default.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            optionPressToTalkEnabled = try container.decodeIfPresent(Bool.self, forKey: .optionPressToTalkEnabled) ?? true
            if !container.contains(.handsFreeGlobalKeyCode) {
                handsFreeGlobalKeyCode = 79
            } else if try container.decodeNil(forKey: .handsFreeGlobalKeyCode) {
                handsFreeGlobalKeyCode = nil
            } else {
                handsFreeGlobalKeyCode = try container.decode(UInt16.self, forKey: .handsFreeGlobalKeyCode)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(optionPressToTalkEnabled, forKey: .optionPressToTalkEnabled)
            try container.encode(handsFreeGlobalKeyCode, forKey: .handsFreeGlobalKeyCode)
        }
    }

    struct Dictation: Codable, Sendable, Equatable {
        var whisperCLIPath: String
        var modelPath: String
        var threadCount: Int
        var vadEnabled: Bool
        var vadModelPath: String
        var showLiveTranscriptWhileRecording: Bool
        var useNearbyTextForContinuation: Bool

        init(
            whisperCLIPath: String,
            modelPath: String,
            threadCount: Int,
            vadEnabled: Bool = true,
            vadModelPath: String? = nil,
            showLiveTranscriptWhileRecording: Bool = false,
            useNearbyTextForContinuation: Bool = false
        ) {
            self.whisperCLIPath = whisperCLIPath
            self.modelPath = modelPath
            self.threadCount = threadCount
            self.vadEnabled = vadEnabled
            self.vadModelPath = vadModelPath ?? WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: modelPath)
            self.showLiveTranscriptWhileRecording = showLiveTranscriptWhileRecording
            self.useNearbyTextForContinuation = useNearbyTextForContinuation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let savedCLIPath = try container.decodeIfPresent(String.self, forKey: .whisperCLIPath)
            let savedModelPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
            if let savedCLIPath, let savedModelPath {
                whisperCLIPath = savedCLIPath
                modelPath = savedModelPath
            } else {
                // A missing path is repaired to the bundled runtime on normalize.
                let defaults = AppPreferences.default.dictation
                whisperCLIPath = savedCLIPath ?? defaults.whisperCLIPath
                modelPath = savedModelPath ?? defaults.modelPath
            }
            threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount) ?? 6
            vadEnabled = try container.decodeIfPresent(Bool.self, forKey: .vadEnabled) ?? true
            let savedVAD = try container.decodeIfPresent(String.self, forKey: .vadModelPath)
            vadModelPath = savedVAD ?? WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: modelPath)
            showLiveTranscriptWhileRecording = try container.decodeIfPresent(
                Bool.self,
                forKey: .showLiveTranscriptWhileRecording
            ) ?? false
            useNearbyTextForContinuation = try container.decodeIfPresent(
                Bool.self,
                forKey: .useNearbyTextForContinuation
            ) ?? false
        }

        mutating func updateModelPath(_ newModelPath: String) {
            vadModelPath = WhisperRuntimeConfiguration.syncedVADModelPath(
                currentVADModelPath: vadModelPath,
                previousModelPath: modelPath,
                newModelPath: newModelPath
            )
            modelPath = newModelPath
        }

        mutating func repairPathsIfNeeded() {
            let fileManager = FileManager.default
            let bundledRuntime = BundledWhisperRuntime.resolvedPaths(bundle: .main, fileManager: fileManager)
            let vendorRuntime = Self.detectedVendorRoot().map { vendorRoot in
                WhisperRuntimePathCandidates(
                    whisperCLIPath: Self.detectedVendorCLIPath(
                        for: vendorRoot,
                        fileManager: fileManager
                    ),
                    modelPath: vendorRoot.appendingPathComponent("models/ggml-small.en.bin").path,
                    vadModelPath: vendorRoot.appendingPathComponent("models/ggml-silero-v6.2.0.bin").path
                )
            }
            let repaired = WhisperRuntimePathRepair.repairedSelection(
                current: .init(
                    whisperCLIPath: whisperCLIPath,
                    modelPath: modelPath,
                    vadModelPath: vadModelPath
                ),
                bundled: bundledRuntime.map {
                    WhisperRuntimePathCandidates(
                        whisperCLIPath: $0.whisperCLIPath,
                        modelPath: $0.modelPath,
                        vadModelPath: $0.vadModelPath
                    )
                },
                vendor: vendorRuntime,
                fileExists: fileManager.fileExists(atPath:)
            )

            whisperCLIPath = repaired.whisperCLIPath
            modelPath = repaired.modelPath
            vadModelPath = repaired.vadModelPath
        }

        private static func detectedVendorRoot() -> URL? {
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser
            let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

            return vendorRootCandidates(homeDirectory: home, currentDirectory: cwd).first { candidate in
                let canonicalCLI = candidate.appendingPathComponent("build-steno/bin/whisper-cli").path
                let legacyCLI = candidate.appendingPathComponent("build/bin/whisper-cli").path
                return (fileManager.fileExists(atPath: canonicalCLI)
                    || fileManager.fileExists(atPath: legacyCLI))
                    && fileManager.fileExists(atPath: candidate.appendingPathComponent("models/ggml-small.en.bin").path)
            }
        }

        static func vendorRootCandidates(
            homeDirectory: URL,
            currentDirectory: URL
        ) -> [URL] {
            [
                homeDirectory.appendingPathComponent("vendor/whisper.cpp", isDirectory: true),
                currentDirectory.appendingPathComponent("vendor/whisper.cpp", isDirectory: true),
                currentDirectory.appendingPathComponent("../vendor/whisper.cpp", isDirectory: true),
                currentDirectory.appendingPathComponent("../Steno/vendor/whisper.cpp", isDirectory: true)
            ]
        }

        private static func detectedVendorCLIPath(
            for vendorRoot: URL,
            fileManager: FileManager
        ) -> String {
            let canonical = vendorRoot.appendingPathComponent("build-steno/bin/whisper-cli").path
            if fileManager.fileExists(atPath: canonical) {
                return canonical
            }
            return vendorRoot.appendingPathComponent("build/bin/whisper-cli").path
        }
    }

    struct Insertion: Codable, Sendable, Equatable {
        var orderedMethods: [InsertionMethod]

        init(orderedMethods: [InsertionMethod]) {
            self.orderedMethods = orderedMethods
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let saved = try container.decodeIfPresent([String].self, forKey: .orderedMethods) else {
                orderedMethods = [.direct, .accessibility, .clipboardPaste]
                return
            }
            // Methods this build doesn't know are dropped; normalize() keeps clipboard paste.
            orderedMethods = saved.compactMap(InsertionMethod.init(rawValue:))
            if orderedMethods.count != saved.count {
                decoder.recordReplacedValue()
            }
        }
    }

    struct Media: Codable, Sendable, Equatable {
        var pauseDuringHandsFree: Bool
        var pauseDuringPressToTalk: Bool

        init(pauseDuringHandsFree: Bool = true, pauseDuringPressToTalk: Bool = true) {
            self.pauseDuringHandsFree = pauseDuringHandsFree
            self.pauseDuringPressToTalk = pauseDuringPressToTalk
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pauseDuringHandsFree = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringHandsFree) ?? true
            pauseDuringPressToTalk = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringPressToTalk) ?? true
        }
    }

    var appearance: Appearance
    var general: General
    var hotkeys: Hotkeys
    var dictation: Dictation
    var insertion: Insertion
    var media: Media

    var lexiconEntries: [LexiconEntry]
    var globalStyleProfile: StyleProfile
    var appStyleProfiles: [String: StyleProfile]
    var snippets: [Snippet]

    static var `default`: AppPreferences {
        let bundledRuntime = BundledWhisperRuntime.resolvedPaths()
        let vendorRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("vendor/whisper.cpp", isDirectory: true)
            .path
        let defaultCLIPath = bundledRuntime?.whisperCLIPath ?? "\(vendorRoot)/build-steno/bin/whisper-cli"
        let defaultModelPath = bundledRuntime?.modelPath ?? "\(vendorRoot)/models/ggml-small.en.bin"
        let defaultVADPath = bundledRuntime?.vadModelPath

        return AppPreferences(
            appearance: .init(),
            general: .init(
                launchAtLoginEnabled: false,
                showDockIcon: true,
                showOnboarding: true
            ),
            hotkeys: .init(
                optionPressToTalkEnabled: true,
                handsFreeGlobalKeyCode: 79
            ),
            dictation: .init(
                whisperCLIPath: defaultCLIPath,
                modelPath: defaultModelPath,
                threadCount: 6,
                vadEnabled: true,
                vadModelPath: defaultVADPath
            ),
            insertion: .init(orderedMethods: [.direct, .accessibility, .clipboardPaste]),
            media: .init(pauseDuringHandsFree: true, pauseDuringPressToTalk: true),
            lexiconEntries: [
                LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global),
                LexiconEntry(term: "steno kit", preferred: "StenoKit", scope: .global)
            ],
            globalStyleProfile: .init(
                name: "Default",
                tone: .natural,
                structureMode: .paragraph,
                fillerPolicy: .balanced,
                commandPolicy: .transform
            ),
            appStyleProfiles: [:],
            snippets: []
        )
    }

    mutating func normalize() {
        appearance.normalize()
        dictation.repairPathsIfNeeded()
        let supported: Set<InsertionMethod> = [.direct, .accessibility, .clipboardPaste]
        var seen: Set<InsertionMethod> = []
        var normalized: [InsertionMethod] = []

        for method in insertion.orderedMethods where supported.contains(method) && !seen.contains(method) {
            normalized.append(method)
            seen.insert(method)
        }

        if !seen.contains(.clipboardPaste) {
            normalized.append(.clipboardPaste)
        }

        insertion.orderedMethods = normalized
        dictation.threadCount = max(1, min(16, dictation.threadCount))
    }
}

extension AppPreferences {
    /// Decodes each section on its own. A missing section uses its default; a
    /// section, word correction, text shortcut or app profile that can't be read
    /// falls back or is skipped without affecting the rest of the file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences.default
        appearance = Self.section(.appearance, in: container) ?? .legacy
        general = Self.section(.general, in: container) ?? defaults.general
        hotkeys = Self.section(.hotkeys, in: container) ?? defaults.hotkeys
        dictation = Self.section(.dictation, in: container) ?? defaults.dictation
        insertion = Self.section(.insertion, in: container) ?? defaults.insertion
        media = Self.section(.media, in: container) ?? defaults.media
        lexiconEntries = Self.section(.lexiconEntries, in: container, as: LossyArray<LexiconEntry>.self)?
            .elements ?? defaults.lexiconEntries
        globalStyleProfile = Self.section(.globalStyleProfile, in: container) ?? defaults.globalStyleProfile
        appStyleProfiles = Self.section(.appStyleProfiles, in: container, as: LossyDictionary<StyleProfile>.self)?
            .values ?? defaults.appStyleProfiles
        snippets = Self.section(.snippets, in: container, as: LossyArray<Snippet>.self)?
            .elements ?? defaults.snippets
    }

    private static func section<T: Decodable>(
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        as type: T.Type = T.self
    ) -> T? {
        guard container.contains(key) else { return nil }
        do {
            return try container.decode(T.self, forKey: key)
        } catch {
            try? container.superDecoder(forKey: key).recordReplacedValue()
            return nil
        }
    }
}
