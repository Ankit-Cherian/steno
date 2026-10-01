import Foundation
import ServiceManagement
import StenoKit

enum LaunchAtLoginServiceError: Error, LocalizedError {
    case failed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failed(let underlying):
            return "Unable to update launch at login: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginSystemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openLoginItemsSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginSystemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            throw LaunchAtLoginServiceError.failed(underlying: error)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
