import Foundation
import EudoraStore

/// Persists the identity set (the addresses that are "me", behind the Who
/// column) in UserDefaults — a small JSON blob, the same mechanism as
/// `ViewStateStore`. Stored **globally**, not per Eudora folder: who you are
/// doesn't change with which mail tree you happen to open.
enum MeIdentityStore {
    /// Versioned so a later format change can't collide with an older build's blob.
    private static let key = "meIdentity.v1"

    static func load() -> MeIdentity {
        guard let blob = UserDefaults.standard.data(forKey: key),
              let identity = try? JSONDecoder().decode(MeIdentity.self, from: blob) else {
            return MeIdentity()
        }
        return identity
    }

    static func save(_ identity: MeIdentity) {
        guard let blob = try? JSONEncoder().encode(identity) else { return }
        UserDefaults.standard.set(blob, forKey: key)
    }
}
