import Foundation
import ServiceManagement

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
final class LaunchAtLoginService {
    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp

        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    return
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else {
                switch service.status {
                case .notRegistered, .notFound:
                    return
                case .enabled, .requiresApproval:
                    try service.unregister()
                @unknown default:
                    try service.unregister()
                }
            }
        } catch {
            throw LaunchAtLoginServiceError.failed(underlying: error)
        }
    }
}
