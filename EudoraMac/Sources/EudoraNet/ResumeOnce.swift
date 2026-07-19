import Foundation

/// A tiny thread-safe "do this exactly once" latch, for bridging a callback that
/// may fire more than once (e.g. `NWConnection.stateUpdateHandler`) to a single
/// `CheckedContinuation.resume`. Being a lock-guarded reference type (rather than
/// a captured mutable `var`), it's safe to use inside the `@Sendable` state
/// handler — which also satisfies the Swift 6 language mode.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns `true` on the first call only, `false` on every call after.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
