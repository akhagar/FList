import Foundation
import Security

struct BarcodeLookupConfiguration: Codable, Equatable, Sendable {
    var saveMyCartAPIKey: String

    static let empty = BarcodeLookupConfiguration(saveMyCartAPIKey: "")

    var hasAnyKey: Bool {
        !saveMyCartAPIKey.isEmpty
    }

    var normalized: BarcodeLookupConfiguration {
        BarcodeLookupConfiguration(
            saveMyCartAPIKey: saveMyCartAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func validated(
        using validateKey: (String) async throws -> Void = { try await BarcodeLookupService.validateSaveMyCartAPIKey($0) }
    ) async throws -> BarcodeLookupConfiguration {
        let configuration = normalized
        // Removing a key must still work offline or after its quota is exhausted.
        if configuration.hasAnyKey {
            try await validateKey(configuration.saveMyCartAPIKey)
        }
        try Task.checkCancellation()
        return configuration
    }
}

enum BarcodeLookupCredentials {
    private static let service = "com.tocnet.FList.barcode-lookup"

    static func load(for scope: String) -> BarcodeLookupConfiguration {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let configuration = try? JSONDecoder().decode(BarcodeLookupConfiguration.self, from: data)
        else {
            return .empty
        }
        return configuration.normalized
    }

    static func save(_ configuration: BarcodeLookupConfiguration, for scope: String) throws {
        let configuration = configuration.normalized
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope
        ]

        guard configuration.hasAnyKey else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = try JSONEncoder().encode(configuration)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String?
                ?? "The barcode lookup key couldn't be saved."
        }
    }
}
