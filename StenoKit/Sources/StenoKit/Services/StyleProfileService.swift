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

    public func resolve(for app: AppContext) -> StyleProfile {
        if let appProfile = appProfiles[app.bundleIdentifier] {
            return appProfile
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
                fillerPolicy: .aggressive,
                commandPolicy: .transform
            )
        }

        return globalProfile
    }
}
