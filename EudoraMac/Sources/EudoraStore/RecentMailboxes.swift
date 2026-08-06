import Foundation

/// The mailboxes mail has most recently been filed into — what the sidebar's
/// Recents row lists.
///
/// The same MRU shape as `RecentRecipients`, with one difference that drives
/// everything here: entries retire by **age**, not by count. Stephen's reading
/// of the list is "where have I been putting things lately", so a mailbox last
/// filed to four months ago is noise however few entries sit above it, and a
/// long tail of *recent* ones is not — the menu is allowed to run off the bottom
/// of the screen. There is therefore no `maxEntries` here on purpose.
///
/// **Entries hold a `MailboxItem.ID`, and that is what makes renaming free.**
/// An id is the path of descmap *filenames* ("PEOPLE.fol/H.FOL/Holger
/// Gehring.mbx"), while a rename rewrites only the descmap line's display field
/// (see `AppModel.renameTreeItem`) — so a renamed mailbox keeps its id and the
/// display name is resolved fresh each time the menu is built. Nothing here has
/// to notice a rename happened. A mailbox that has been deleted simply fails to
/// resolve and drops off the menu.
///
/// (`SidebarExpansion`'s doc comment says a rename changes an id. That was true
/// before rename was display-only; it isn't now.)
///
/// Pure and `Codable` so it can live in the testable library; the app owns the
/// persistence — this rides in `ViewState`, per Eudora folder, because an id
/// means nothing in a different tree.
public struct RecentMailboxes: Codable, Equatable, Sendable {

    /// One filing: which mailbox, and when it last received mail.
    public struct Entry: Codable, Equatable, Sendable {
        /// A `MailboxItem.ID` — the path-style key of descmap filenames.
        public let id: String
        /// When mail was last moved into this mailbox.
        public let movedAt: Date

        public init(id: String, movedAt: Date) {
            self.id = id
            self.movedAt = movedAt
        }
    }

    /// Most recently filed-to first. Expired entries may still be present: they
    /// are dropped on the next `record` and filtered out by `ids(now:)`, so a
    /// list nothing has been added to for a year reads as empty without anything
    /// having to write to disk to make it so.
    public private(set) var entries: [Entry]

    /// How long an entry stays on the list. Stephen's number, and expected to be
    /// tuned — it is a `let` in one place for exactly that reason.
    public static let maxAgeDays = 100

    static var maxAge: TimeInterval { TimeInterval(maxAgeDays) * 24 * 60 * 60 }

    /// `entries` is sorted newest-first on the way in rather than trusted.
    /// `record` maintains that order by construction, but a decoded blob and the
    /// one-time seed both arrive from outside, and an out-of-order list would
    /// show a stale mailbox at the top of the menu — a wrong answer that looks
    /// like a right one.
    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.movedAt > $1.movedAt }
    }

    /// Record that mail was just filed into `id`: it becomes the newest entry,
    /// replacing any older sighting of the same mailbox.
    ///
    /// `at` is a parameter so the tests — and the one-time seed built from
    /// mailbox modification times — can supply a date; callers in the app pass
    /// nothing.
    public mutating func record(_ id: String, at date: Date = Date()) {
        guard !id.isEmpty else { return }
        entries.removeAll { $0.id == id }
        entries.insert(Entry(id: id, movedAt: date), at: 0)
        // Pruning on write, not only on read: this is the one moment the list is
        // being saved anyway, so it is the cheapest place to stop dead entries
        // accumulating in the blob forever.
        prune(now: date)
    }

    /// The live list, newest first — what the Recents menu shows, before display
    /// names are resolved against the current tree.
    public func ids(now: Date = Date()) -> [String] {
        entries.filter { !Self.isExpired($0, now: now) }.map(\.id)
    }

    /// Drop everything past `maxAgeDays`.
    public mutating func prune(now: Date = Date()) {
        entries.removeAll { Self.isExpired($0, now: now) }
    }

    /// An entry with a `movedAt` in the future is **not** expired. Clock changes
    /// and a restore from backup both produce them, and the failure that matters
    /// is dropping a mailbox the user filed to this morning.
    static func isExpired(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.movedAt) > maxAge
    }

    // MARK: - Codable

    /// Encoded as a bare array, the way `SidebarExpansion` is, so the stored
    /// `ViewState` blob doesn't carry a redundant "entries" wrapper.
    ///
    /// Decoding routes through `init(entries:)` rather than assigning the array
    /// straight across, so the newest-first invariant is re-established on load.
    /// The synthesized decoder would not have done that, and a hand-edited or
    /// seeded blob is exactly the case where it matters.
    public init(from decoder: Decoder) throws {
        let list = try decoder.singleValueContainer().decode([Entry].self)
        self.init(entries: list)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}
