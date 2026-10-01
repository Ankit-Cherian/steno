import Foundation

public actor StyleProfileService {
    private var globalProfile: StyleProfile
    private var appProfiles: [String: StyleProfile]

    public init(
        globalProfile: StyleProfile = StyleProfile(
            name: "Default",
            tone: .natural,
            structureMode: .paragraph,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        ),
        appProfiles: [String: StyleProfile] = [:]
    ) {
        self.globalProfile = globalProfile
        self.appProfiles = appProfiles
    }

    public func setGlobalProfile(_ profile: StyleProfile) {
        globalProfile = profile
    }

    public func setProfile(_ profile: StyleProfile, forBundleID bundleID: String) {
        appProfiles[bundleID] = profile
    }

    public func removeProfile(forBundleID bundleID: String) {
        appProfiles.removeValue(forKey: bundleID)
    }

    /// The profile for `app`, with a retired structure replaced by the nearest one that works.
    public func resolve(for app: AppContext) -> StyleProfile {
        if let appProfile = appProfiles[app.bundleIdentifier] {
            return appProfile.withEffectiveStructure
        }

        if app.isIDE {
            return StyleProfile(
                name: "IDE",
                tone: .technical,
                structureMode: .natural,
                fillerPolicy: .balanced,
                commandPolicy: .passthrough
            )
        }

        if app.isRemoteDesktop {
            return StyleProfile(
                name: "Remote Desktop",
                tone: .concise,
                structureMode: .paragraph,
                fillerPolicy: .balanced,
                commandPolicy: .transform
            )
        }

        return globalProfile.withEffectiveStructure
    }
}

public extension StructureMode {
    /// The structures Settings offers. Email and Command never changed the text in a way of their
    /// own, so they are no longer offered. Saved profiles that use them still load.
    static let selectableCases: [StructureMode] = [.natural, .paragraph, .bullets]

    /// The structure cleanup applies: Command always behaved like Natural, and Email's only effect
    /// on its own was Paragraph's sentence capitalization.
    var effective: StructureMode {
        switch self {
        case .email:
            return .paragraph
        case .command:
            return .natural
        case .natural, .paragraph, .bullets:
            return self
        }
    }
}

extension StyleProfile {
    var withEffectiveStructure: StyleProfile {
        var profile = self
        profile.structureMode = structureMode.effective
        return profile
    }
}
