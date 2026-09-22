import Foundation
@testable import Quail

/// An in-memory `SecretStore` so `AppStateTests` never touches the real
/// Keychain. A real Keychain round-trip isn't exercised anywhere in this
/// suite: an ad-hoc-signed test binary gets a fresh code signature on every
/// build, and the Keychain ACL that grants an app access to its own items
/// is tied to that signature — so a second run can trigger a blocking
/// "<app> wants to use your confidential information" prompt with no way
/// to answer it non-interactively. `Keychain` itself is a thin,
/// stdlib-only wrapper over `Security`; see its doc comment.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func set(_ value: String, account: String) throws {
        lock.withLock { storage[account] = value }
    }

    func get(account: String) throws -> String? {
        lock.withLock { storage[account] }
    }

    func delete(account: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: account) }
    }
}
