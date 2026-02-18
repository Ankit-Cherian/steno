import Foundation
import ServiceManagement

enum LaunchAtLoginServiceError: Error, LocalizedError {
    case unavailable
    case failed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Launch at login is unavailable on this system."
        case .failed(let underlying):
            return "Unable to update launch at login: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
final class LaunchAtLoginService {
    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginServiceError.unavailable
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LaunchAtLoginServiceError.failed(underlying: error)
        }
    }
}
