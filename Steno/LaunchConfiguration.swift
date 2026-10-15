import Foundation
import StenoKit

/// What the running copy of the app is configured with, resolved once at launch.
struct LaunchConfiguration: Sendable {
    /// Where every store keeps its files.
    var storage: StenoStorageRoot
    /// Whether the app may register itself as a login item.
    var managesLaunchAtLogin: Bool

    /// The configuration of this process, resolved on first use.
    static let current = resolve(bundle: .main)

    static func resolve(bundle: Bundle) -> LaunchConfiguration {
        #if STENO_ACCEPTANCE
        return LaunchConfiguration(
            storage: AcceptanceConfiguration.storageRoot(bundle: bundle),
            managesLaunchAtLogin: AcceptanceConfiguration.managesLaunchAtLogin
        )
        #else
        return LaunchConfiguration(storage: .release(), managesLaunchAtLogin: true)
        #endif
    }
}
