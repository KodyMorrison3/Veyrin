//
//  KeychainStore.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation
import Security

struct KeychainStore {
    private let service = "com.kodymorrison.CharacterAI"

    func save(
        _ value: String,
        forKey key: String
    ) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemAdd(
            query.merging(
                attributes,
                uniquingKeysWith: { _, new in new }
            ) as CFDictionary,
            nil
        )

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )

            guard updateStatus == errSecSuccess else {
                throw KeychainError.operationFailed(
                    updateStatus
                )
            }

            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
    }

    func load(
        forKey key: String
    ) throws -> String? {
        print("KEYCHAIN LOAD:", key)

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

        print("KEYCHAIN STATUS:", key, status)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }

        guard let data = result as? Data,
              let value = String(
                  data: data,
                  encoding: .utf8
              ) else {
            throw KeychainError.invalidData
        }

        return value
    }
    
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

        let status = SecItemAdd(
            query.merging(
                attributes,
                uniquingKeysWith: { _, new in new }
            ) as CFDictionary,
            nil
        )

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )

            guard updateStatus == errSecSuccess else {
                throw KeychainError.operationFailed(updateStatus)
            }

            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
    }
    
    func loadData(
        forKey key: String
    ) throws -> Data? {
        print("KEYCHAIN LOAD:", key)

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

        print("KEYCHAIN STATUS:", key, status)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
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
