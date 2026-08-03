import Foundation
import AppKit
import EudoraStore

/// Takes and releases the lock on the open Eudora tree.
///
/// The decision logic lives in `TreeLockFile` (EudoraStore, tested). This is the
/// part that can't be tested in the sandbox: touching the filesystem, asking
/// AppKit whether a pid is alive, and quitting.
///
/// Scope note. The single-instance guard in `AppDelegate` stops two copies of
/// *this app*; this stops two copies opening the *same tree*, which is not the
/// same question. It is also the only one of the two that would notice a Eudora
/// 7 running against the same folder — except that it wouldn't, because 7 uses a
/// different lock name and knows nothing about this one. Recorded honestly on
/// `TreeLockFile.filename`.
@MainActor
enum TreeLock {
    /// The tree this process currently holds, if any.
    private static var held: URL?

    /// What happened when the lock was taken, for the caller to report.
    enum Outcome {
        case took
        /// Taken, but the previous holder left it behind — the last run ended
        /// without releasing it, so it may have died mid-write.
        case tookStale(TreeLockFile)
        /// The user was asked and chose not to open the tree.
        case declined
    }

    /// Take the lock on `root`, asking only when the answer isn't provable.
    ///
    /// Returns `.declined` when the tree should not be opened.
    static func take(root: URL) -> Outcome {
        // The previously-held tree is remembered, not just dropped. Releasing
        // first and asking questions later meant that declining to open a locked
        // folder left the tree *already open* with no lock on it — File ▸ Open,
        // "Don't Open", and the protection was gone for the rest of the session
        // while the old tree stayed on screen and in use.
        let previous = held
        releaseIfHeld()

        let url = TreeLockFile.url(in: root)
        let existing = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap(TreeLockFile.init(parsing:))
        let ours = Bundle.main.bundleIdentifier ?? "com.stephen.eudora.app"

        let verdict = TreeLockFile.verdict(
            for: existing,
            ourPID: ProcessInfo.processInfo.processIdentifier,
            ourBundleID: ours,
            bundleIDOfRunningProcess: { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            })

        switch verdict {
        case .takeIt(let wasStale):
            write(to: url, ours: ours)
            held = root
            // The banner, not a dialog. A stale lock is worth telling the user
            // about — it means the previous run ended badly — but it is not a
            // question, because the evidence already answered it. Prompting
            // here would recreate the Eudora 7 misery one dialog at a time.
            return wasStale && existing != nil ? .tookStale(existing!) : .took

        case .heldByLiveEudora(let lock):
            // Unreachable after the single-instance guard, which is why it says
            // so rather than trying to be clever.
            return ask(
                title: "Another Eudora is using this folder.",
                body: "A running Eudora (process \(lock.pid)) holds the lock on "
                    + "\(root.lastPathComponent). Opening it in a second copy can lose "
                    + "mail: both copies rewrite the same mailbox files.\n\n"
                    + "This shouldn't be possible — the other copy should have been "
                    + "brought forward instead. Opening anyway is not recommended.",
                proceedTitle: "Open Anyway",
                root: root, url: url, ours: ours, restoring: previous)

        case .heldByUnknownProcess(let lock):
            return ask(
                title: "This folder is locked by another program.",
                body: "The lock was taken by process \(lock.pid)"
                    + (lock.bundleID.isEmpty ? "" : " (\(lock.bundleID))")
                    + ", which is still running but isn't Eudora. Almost certainly the "
                    + "old process ended and something unrelated was given its process "
                    + "number — in which case it is safe to continue.\n\n"
                    + "Continuing will replace the lock.",
                proceedTitle: "Continue",
                root: root, url: url, ours: ours, restoring: previous)
        }
    }

    /// Release the lock, if this process holds one.
    ///
    /// Deliberately does not check the file's contents first: if we believe we
    /// hold it, removing it is right, and a lock left behind is worse than one
    /// removed twice. Called from `applicationWillTerminate` and before taking a
    /// new tree's lock.
    static func releaseIfHeld() {
        guard let root = held else { return }
        try? FileManager.default.removeItem(at: TreeLockFile.url(in: root))
        held = nil
    }

    // MARK: -

    /// Best-effort, and knowingly so: the write is `try?`, and `held` is set
    /// regardless. On a read-only tree the app therefore believes it is
    /// protected when it isn't. Acceptable for a personal build against a local
    /// folder; worth knowing before this is trusted on a network volume.
    private static func write(to url: URL, ours: String) {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let lock = TreeLockFile(pid: ProcessInfo.processInfo.processIdentifier,
                                bundleID: ours,
                                note: "Eudora \(version)")
        try? lock.serialized().write(to: url, atomically: true, encoding: .utf8)
    }

    private static func ask(title: String, body: String, proceedTitle: String,
                            root: URL, url: URL, ours: String,
                            restoring previous: URL?) -> Outcome {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = body
        // "Don't Open" first, so it is the default button and Return is the safe
        // answer. The rule this file exists to serve is that a lock you can't
        // disprove is a lock you respect.
        alert.addButton(withTitle: "Don't Open")
        alert.addButton(withTitle: proceedTitle)
        guard alert.runModal() == .alertSecondButtonReturn else {
            // Put the previous tree's lock back. It was released on the way in,
            // and that tree is still open and still being written to.
            if let previous {
                write(to: TreeLockFile.url(in: previous), ours: ours)
                held = previous
            }
            return .declined
        }
        write(to: url, ours: ours)
        held = root
        return .took
    }
}
