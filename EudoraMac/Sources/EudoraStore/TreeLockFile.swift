import Foundation

/// The on-disk lock that says "a Eudora is using this tree", and the rules for
/// deciding whether to believe it.
///
/// Eudora 7 had one of these (`OWNER.LOK`) and it was a menace: it survived
/// every crash and every force-quit, and clearing it meant knowing it existed,
/// knowing where it lived, and deleting a file by hand. Stephen kept a shortcut
/// to the folder on his desktop for exactly that. The lesson isn't "don't lock";
/// it's that **a lock has to carry enough evidence to be disproved
/// automatically.** A bare marker file can only ever be cleared by a human,
/// because a bare marker file cannot tell "in use" from "left behind".
///
/// So this one records who holds it. Given a pid, a later run can ask the system
/// whether that process is still alive *and* still Eudora, and in the
/// overwhelmingly common case — the previous run crashed — answer its own
/// question and carry on without asking.
///
/// The file format is deliberately plain text, one `key=value` per line: it is
/// the sort of thing that gets looked at with `cat` at an inconvenient moment.
/// Unknown keys are ignored, so a later version can add fields without a
/// migration.
public struct TreeLockFile: Equatable, Sendable {
    /// The pid that wrote it.
    public let pid: Int32
    /// The bundle identifier of the writer, so a pid that has been recycled into
    /// some unrelated program can be told from a genuine Eudora.
    public let bundleID: String
    /// When it was taken, for the human reading the message.
    public let started: Date
    /// Free text — app version — purely so the message can say what wrote it.
    ///
    /// Single-line by contract: the format is one `key=value` per line, so a
    /// newline here would silently truncate on the way back in.
    public let note: String

    public init(pid: Int32, bundleID: String, started: Date = Date(), note: String = "") {
        self.pid = pid
        self.bundleID = bundleID
        self.started = started
        self.note = note
    }

    /// The lock's filename inside the Eudora folder.
    ///
    /// **Not** `OWNER.LOK`. Eudora 7 may still be run against a copy of this
    /// tree, and taking its lock name would either block it or, worse, have it
    /// silently clear ours. Different names means the two can at least detect
    /// their own kind; it does not make them aware of each other, which is a
    /// limitation worth knowing rather than papering over.
    public static let filename = "eudora8.lock"

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    // MARK: text form

    public func serialized() -> String {
        """
        pid=\(pid)
        bundle=\(bundleID)
        started=\(ISO8601DateFormatter().string(from: started))
        note=\(note)
        """
    }

    public init?(parsing text: String) {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[line.startIndex..<eq])] =
                String(line[line.index(after: eq)...])
        }
        // pid is the only field worth failing over: without it there is nothing
        // to check, and a lock that can't be checked is the Eudora 7 problem all
        // over again. Everything else degrades to a default.
        guard let pidText = fields["pid"], let pid = Int32(pidText) else { return nil }
        self.pid = pid
        self.bundleID = fields["bundle"] ?? ""
        self.started = fields["started"].flatMap {
            ISO8601DateFormatter().date(from: $0)
        } ?? Date.distantPast
        self.note = fields["note"] ?? ""
    }

    // MARK: the decision

    /// What a newly-starting Eudora should do about a lock it has found.
    public enum Verdict: Equatable, Sendable {
        /// No lock, or one provably left behind by a process that is gone. Take
        /// it and carry on — but say so, because a stale lock means the last run
        /// ended badly and the tree may have been mid-write.
        case takeIt(wasStale: Bool)
        /// Held by a live process claiming to be Eudora. After the
        /// single-instance guard this should be unreachable; if it happens, it
        /// is something the user has to decide about, because proceeding could
        /// corrupt the tree.
        case heldByLiveEudora(TreeLockFile)
        /// Held by a live process that is *not* a Eudora — a recycled pid is
        /// overwhelmingly likely, but "overwhelmingly likely" is not "certain",
        /// so this is the one case that asks.
        case heldByUnknownProcess(TreeLockFile)
    }

    /// Decide, given a way to ask about a process.
    ///
    /// `bundleIDOfRunningProcess` returns the bundle identifier of the live
    /// **application** with that pid, or nil when there is none. Injected rather
    /// than called directly so the decision is testable without spawning
    /// anything: on the app side it is `NSRunningApplication`.
    ///
    /// Note "application" rather than "process", and don't be tempted to swap in
    /// `kill(pid, 0)`. Most pids on a system belong to daemons and helpers that
    /// are not registered applications, and resolving those to nil is exactly
    /// what's wanted: a real Eudora is always a registered app, so a recycled
    /// pid inherited by some daemon resolves to "gone" and the lock is taken
    /// silently, instead of raising a dialog about a process that has nothing to
    /// do with mail.
    public static func verdict(
        for lock: TreeLockFile?,
        ourPID: Int32,
        ourBundleID: String,
        bundleIDOfRunningProcess: (Int32) -> String?
    ) -> Verdict {
        guard let lock else { return .takeIt(wasStale: false) }
        // Our own lock, written by this very process — reopening a tree we
        // already hold. Checked first so the decision doesn't depend on the
        // caller having successfully deleted the file on the way in: that
        // removal is best-effort, and without this a read-only volume or a
        // restored-from-backup file would have the app raise a modal accusing
        // itself of being a rival.
        if lock.pid == ourPID { return .takeIt(wasStale: false) }
        guard let running = bundleIDOfRunningProcess(lock.pid) else {
            // The holder is gone. This is the common case by a wide margin —
            // a crash, a force-quit, a debugger stop — and it is exactly the
            // case Eudora 7 made a human problem.
            return .takeIt(wasStale: true)
        }
        return running == ourBundleID || running == lock.bundleID
            ? .heldByLiveEudora(lock)
            : .heldByUnknownProcess(lock)
    }
}
