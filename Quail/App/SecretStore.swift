import Foundation
import Security

/// A place to put exactly the two secrets Quail ever needs: the llama.cpp
/// API key now, an HF token in Phase 2. Never the JSON config — see
/// AGENTS.md and `Config.swift`.
///
/// Abstracted behind a protocol (rather than calling `Keychain` directly)
/// so `AppState` can be tested against `FakeSecretStore` with no real
/// Keychain access — see that type's doc comment for why a real Keychain
/// round-trip isn't exercised in the test suite.
protocol SecretStore: Sendable {
    func set(_ value: String, account: String) throws
    func get(account: String) throws -> String?
    func delete(account: String) throws
}

/// Thin wrapper over Keychain Services (`kSecClassGenericPassword`), scoped
/// to Quail's own service name so it never collides with another app's
/// items.
struct Keychain: SecretStore {
    enum KeychainError: Error, Sendable, Equatable {
        case unexpectedStatus(OSStatus)
    }

    private let service = "com.datoos.quail"

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let addQuery = query(account: account).merging(
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
            uniquingKeysWith: { _, new in new }
        )

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError.unexpectedStatus(addStatus)
        }

        let updateStatus = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func get(account: String) throws -> String? {
        let getQuery = query(account: account).merging(
            [
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ],
            uniquingKeysWith: { _, new in new }
        )

        var result: AnyObject?
        let status = SecItemCopyMatching(getQuery as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Touches nothing — every operation is a silent no-op (`get` returns
/// `nil`). For `AppDelegate`'s `appState` specifically, when this process
/// is hosting `QuailTests` (`TEST_HOST` genuinely launches a live
/// Quail.app to run the test bundle inside): confirmed that a real
/// `Keychain()` there was popping a macOS "Quail wants to access your
/// keychain" authorization prompt on every single `xcodebuild test` run
/// — ad-hoc signing means every build gets a fresh signature, which
/// Keychain treats as a new, unrecognized requester for whatever real API
/// key `Config.apiKeyEnabled` has stored. No test ever reads this
/// `AppDelegate`-owned `AppState` — every test builds its own with
/// `FakeSecretStore` — so there's nothing to lose by keeping this one
/// inert.
struct NullSecretStore: SecretStore {
    func set(_: String, account _: String) throws {}
    func get(account _: String) throws -> String? {
        nil
    }

    func delete(account _: String) throws {}
}
