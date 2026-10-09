//
//  KeychainStore.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation
import Security
import OSLog

private let keychainLogger = Logger(subsystem: "CharacterAI", category: "Keychain")

struct KeychainStore {
    private let service = "com.kodymorrison.CharacterAI"

    func save(
        _ data: Data,
        forKey key: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        // Updating an existing item first avoids a failed SecItemAdd followed
        // by SecItemUpdate. Both calls can trigger a Keychain authorization
        // prompt on macOS, so the common save path should perform just one.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.operationFailed(updateStatus)
        }

        let addStatus = SecItemAdd(
            query.merging(
                attributes,
                uniquingKeysWith: { _, new in new }
            ) as CFDictionary,
            nil
        )
        if addStatus == errSecDuplicateItem {
            // A concurrent save may have created the item after our update.
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.operationFailed(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError.operationFailed(addStatus)
        }
    }
    
    func loadData(
        forKey key: String
    ) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?

        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            keychainLogger.error("Keychain data read failed (OSStatus \(status, privacy: .public))")
            throw KeychainError.operationFailed(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        return data
    }

    func delete(
        forKey key: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(
            query as CFDictionary
        )

        guard status == errSecSuccess ||
              status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }
}

enum KeychainError: Error {
    case invalidData
    case operationFailed(OSStatus)
}
