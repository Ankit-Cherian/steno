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
            accent: StenoAccentStyle = .dodger,
            recordHeroStyle: StenoRecordHeroStyle = .pill,
            atmosphereIntensity: Int = 100
        ) {
            self.mode = mode
            self.accent = accent
            self.recordHeroStyle = recordHeroStyle
            self.atmosphereIntensity = atmosphereIntensity
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = try container.decodeIfPresent(StenoAppearanceMode.self, forKey: .mode) ?? .dark
            accent = try container.decodeIfPresent(StenoAccentStyle.self, forKey: .accent) ?? .dodger
            recordHeroStyle = try container.decodeIfPresent(StenoRecordHeroStyle.self, forKey: .recordHeroStyle) ?? .pill
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            optionPressToTalkEnabled = try container.decodeIfPresent(Bool.self, forKey: .optionPressToTalkEnabled) ?? true
            handsFreeGlobalKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .handsFreeGlobalKeyCode) ?? 79
        }
    }

    struct Dictation: Codable, Sendable, Equatable {
        var whisperCLIPath: String
        var modelPath: String
        var threadCount: Int
        var vadEnabled: Bool
        var vadModelPath: String

        init(whisperCLIPath: String, modelPath: String, threadCount: Int, vadEnabled: Bool = true, vadModelPath: String? = nil) {
            self.whisperCLIPath = whisperCLIPath
            self.modelPath = modelPath
            self.threadCount = threadCount
            self.vadEnabled = vadEnabled
            self.vadModelPath = vadModelPath ?? WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: modelPath)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            whisperCLIPath = try container.decode(String.self, forKey: .whisperCLIPath)
            modelPath = try container.decode(String.self, forKey: .modelPath)
            threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount) ?? 6
            vadEnabled = try container.decodeIfPresent(Bool.self, forKey: .vadEnabled) ?? true
            let savedVAD = try container.decodeIfPresent(String.self, forKey: .vadModelPath)
            vadModelPath = savedVAD ?? WhisperRuntimeConfiguration.defaultVADModelPath(relativeTo: modelPath)
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
                    whisperCLIPath: vendorRoot.appendingPathComponent("build/bin/whisper-cli").path,
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

            var candidates: [URL] = [
                home.appendingPathComponent("vendor/whisper.cpp", isDirectory: true),
                cwd.appendingPathComponent("vendor/whisper.cpp", isDirectory: true),
                cwd.appendingPathComponent("../vendor/whisper.cpp", isDirectory: true),
                cwd.appendingPathComponent("../Steno/vendor/whisper.cpp", isDirectory: true)
            ]

            let localProjects = home.appendingPathComponent("Desktop/LocalProjects", isDirectory: true)
            if let projectDirs = try? fileManager.contentsOfDirectory(
                at: localProjects,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                candidates.append(contentsOf: projectDirs.map {
                    $0.appendingPathComponent("vendor/whisper.cpp", isDirectory: true)
                })
            }

            return candidates.first { candidate in
                fileManager.fileExists(atPath: candidate.appendingPathComponent("build/bin/whisper-cli").path)
                    && fileManager.fileExists(atPath: candidate.appendingPathComponent("models/ggml-small.en.bin").path)
            }
        }
    }

    struct Insertion: Codable, Sendable, Equatable {
        var orderedMethods: [InsertionMethod]

        init(orderedMethods: [InsertionMethod]) {
            self.orderedMethods = orderedMethods
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            orderedMethods = try container.decodeIfPresent([InsertionMethod].self, forKey: .orderedMethods) ?? [.direct, .accessibility, .clipboardPaste]
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
        let defaultCLIPath = bundledRuntime?.whisperCLIPath ?? "\(vendorRoot)/build/bin/whisper-cli"
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
