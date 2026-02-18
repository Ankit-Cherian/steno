import Foundation
import OSLog
import Security

protocol APIKeyStore: Sendable {
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String?)
}

struct KeychainAPIKeyStore: APIKeyStore {
    private let service = "io.stenoapp.steno"
    private let account = "openai_api_key"
    private static let logger = Logger(subsystem: "io.stenoapp.steno", category: "APIKeyStore")
    private let legacyServices = [
        "com.ankitcherian.steno",
        "com.ankitcherian.whisperclonemac"
    ]

    func loadAPIKey() -> String? {
        if let value = loadKey(service: service) {
            return value
        }

        // Migrate from legacy keychain service names if present.
        for legacyService in legacyServices {
            if let legacyValue = loadKey(service: legacyService) {
                saveKey(legacyValue, service: service)
                deleteKey(service: legacyService)
                return legacyValue
            }
        }

        return nil
    }

    func saveAPIKey(_ key: String?) {
        deleteKey(service: service)

        guard let key else {
            return
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        saveKey(trimmed, service: service)
    }

    private func loadKey(service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error(
                "SecItemCopyMatching failed for service \(service, privacy: .public): \(statusMessage(status), privacy: .public)"
            )
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func saveKey(_ key: String, service: String) {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: Data(key.utf8)
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }

        guard status == errSecDuplicateItem else {
            Self.logger.error(
                "SecItemAdd failed for service \(service, privacy: .public): \(statusMessage(status), privacy: .public)"
            )
            return
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updates: [CFString: Any] = [
            kSecValueData: Data(key.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        guard updateStatus == errSecSuccess else {
            Self.logger.error(
                "SecItemUpdate failed for service \(service, privacy: .public): \(statusMessage(updateStatus), privacy: .public)"
            )
            return
        }
    }

    private func deleteKey(service: String) {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            Self.logger.error(
                "SecItemDelete failed for service \(service, privacy: .public): \(statusMessage(deleteStatus), privacy: .public)"
            )
        }
    }

    private func statusMessage(_ status: OSStatus) -> String {
        if let cfMessage = SecCopyErrorMessageString(status, nil) {
            return cfMessage as String
        }
        return "OSStatus \(status)"
    }
}

final class MemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    init(value: String? = nil) {
        self.value = value
    }

    func loadAPIKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func saveAPIKey(_ key: String?) {
        lock.lock()
        defer { lock.unlock() }
        value = key
    }
}
