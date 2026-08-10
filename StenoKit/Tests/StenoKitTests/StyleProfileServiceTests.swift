import Testing
@testable import StenoKit

@Test("Remote desktop fallback does not silently enable aggressive filler cleanup")
func remoteDesktopFallbackUsesBalancedFillerPolicy() async {
    let service = StyleProfileService()
    let profile = await service.resolve(
        for: AppContext(
            bundleIdentifier: "com.example.remote",
            appName: "Remote",
            isRemoteDesktop: true
        )
    )

    #expect(profile.fillerPolicy == .balanced)
}

@Test("Explicit app profile may opt into aggressive filler cleanup")
func explicitAppProfileMayUseAggressiveFillerPolicy() async {
    let bundleID = "com.example.remote"
    let explicit = StyleProfile(
        name: "Explicit Aggressive",
        tone: .concise,
        structureMode: .paragraph,
        fillerPolicy: .aggressive,
        commandPolicy: .transform
    )
    let service = StyleProfileService(appProfiles: [bundleID: explicit])

    let resolved = await service.resolve(
        for: AppContext(
            bundleIdentifier: bundleID,
            appName: "Remote",
            isRemoteDesktop: true
        )
    )

    #expect(resolved == explicit)
}
