import Foundation
@testable import Steno
import StenoKit

/// The preferences types exactly as the published 1.0.0 release decodes them
/// (`Steno/AppPreferences.swift` and `StenoKit/Models/Profiles.swift` at the
/// 1.0.0 source), with methods that don't affect decoding removed. Model types
/// are strict copies: unknown enum values and missing keys fail, as in 1.0.0,
/// which then replaces the whole file with defaults.
enum Released100Preferences {
    struct Preferences: Codable {
        struct Appearance: Codable {
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

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                mode = try container.decodeIfPresent(StenoAppearanceMode.self, forKey: .mode) ?? .dark
                accent = try container.decodeIfPresent(StenoAccentStyle.self, forKey: .accent) ?? .dodger
                recordHeroStyle = try container.decodeIfPresent(StenoRecordHeroStyle.self, forKey: .recordHeroStyle) ?? .pill
                atmosphereIntensity = try container.decodeIfPresent(Int.self, forKey: .atmosphereIntensity) ?? 100
            }
        }

        struct General: Codable {
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

        struct Hotkeys: Codable {
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

        struct Dictation: Codable {
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
                whisperCLIPath = try container.decode(String.self, forKey: .whisperCLIPath)
                modelPath = try container.decode(String.self, forKey: .modelPath)
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
        }

        struct Insertion: Codable {
            var orderedMethods: [InsertionMethod]

            init(orderedMethods: [InsertionMethod]) {
                self.orderedMethods = orderedMethods
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                orderedMethods = try container.decodeIfPresent([InsertionMethod].self, forKey: .orderedMethods) ?? [.direct, .accessibility, .clipboardPaste]
            }
        }

        struct Media: Codable {
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
    }

    enum StyleTone: String, Codable { case natural, professional, concise, friendly, technical }
    enum StructureMode: String, Codable { case natural, paragraph, bullets, email, command }
    enum FillerPolicy: String, Codable { case minimal, balanced, aggressive }
    enum CommandPolicy: String, Codable { case passthrough, transform }
    enum InsertionMethod: String, Codable { case direct, accessibility, clipboardPaste, none }
    enum PhoneticRecoveryPolicy: String, Codable { case off, properNounEnglish }

    enum Scope: Codable {
        case global
        case app(bundleID: String)
    }

    struct StyleProfile: Codable {
        var name: String
        var tone: StyleTone
        var structureMode: StructureMode
        var fillerPolicy: FillerPolicy
        var commandPolicy: CommandPolicy
    }

    struct LexiconEntry: Codable {
        var term: String
        var preferred: String
        var scope: Scope
        var aliases: [String] = []
        var phoneticRecovery: PhoneticRecoveryPolicy = .off

        enum CodingKeys: String, CodingKey {
            case term, preferred, scope, aliases, phoneticRecovery
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            term = try container.decode(String.self, forKey: .term)
            preferred = try container.decode(String.self, forKey: .preferred)
            scope = try container.decode(Scope.self, forKey: .scope)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            phoneticRecovery = try container.decodeIfPresent(PhoneticRecoveryPolicy.self, forKey: .phoneticRecovery) ?? .off
        }
    }

    struct Snippet: Codable {
        var id: UUID
        var trigger: String
        var expansion: String
        var scope: Scope
    }
}
