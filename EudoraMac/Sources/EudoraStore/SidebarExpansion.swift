import Foundation

/// Which sidebar folders are open.
///
/// This exists because `OutlineGroup` keeps expansion inside `NSOutlineView`
/// with no public way to read or write it. Two separate symptoms came out of
/// that: quitting with a group open brought it back closed, and the `.id()`
/// rebuild that guards the sidebar against a reparenting crash reset expansion
/// mid-session as well — so creating a mailbox closed the tree under you.
/// Owning the set here is what makes both survivable; the sidebar is built from
/// `DisclosureGroup`s bound to this rather than from an `OutlineGroup`.
///
/// **Only open folders are stored.** Absent and closed are the same state, which
/// is why nothing here needs to know the full set of folders to answer
/// `isExpanded` — the same choice `ViewState.atBottomByMailbox` makes.
///
/// Ids are the path-style `MailboxItem.ID` the rest of the view state uses
/// ("Projects/Music"), and that has a consequence worth stating plainly: a
/// rename or a move changes an id, so a renamed folder comes back collapsed.
/// That matches how remembered sort and scroll position already behave, since
/// they are keyed the same way and lost the same way. Remapping ids in one of
/// the three and not the others would be harder to reason about than losing it
/// in all three.
///
/// Pure and `Codable` so it can live in the testable library; the app owns the
/// UserDefaults persistence (see `ViewState`) and decides when to prune.
public struct SidebarExpansion: Codable, Equatable, Sendable {
    /// The ids of every folder currently open.
    public private(set) var expandedIDs: Set<String>

    public init(expandedIDs: Set<String> = []) {
        self.expandedIDs = expandedIDs
    }

    public func isExpanded(_ id: String) -> Bool {
        expandedIDs.contains(id)
    }

    /// Open or close one folder. An empty id is ignored rather than stored: the
    /// tree walk uses `""` for the root's parent, and a `""` entry would be a
    /// row nothing can ever draw or clear.
    public mutating func setExpanded(_ id: String, _ isExpanded: Bool) {
        guard !id.isEmpty else { return }
        if isExpanded {
            expandedIDs.insert(id)
        } else {
            expandedIDs.remove(id)
        }
    }

    /// Forget every id that isn't in `present`.
    ///
    /// The caller passes the folder ids the tree actually holds. Deleting,
    /// renaming and moving a folder all either retire a path-derived id or
    /// change it, so one intersection on save covers all three without each
    /// mutation site having to remember to clean up after itself.
    ///
    /// The caller is responsible for not calling this with a tree that hasn't
    /// finished loading — an empty `present` empties the set.
    public mutating func retain(idsIn present: Set<String>) {
        expandedIDs.formIntersection(present)
    }

    // MARK: - Codable

    /// Encoded as a bare, **sorted** array.
    ///
    /// Sorted because `Set`'s iteration order varies between processes (the hash
    /// seed is per-process), so an unsorted encode would produce a different
    /// blob each launch for identical state. That would defeat the equality
    /// check the app uses to skip no-op saves, and would make a diff of the
    /// stored defaults unreadable.
    public init(from decoder: Decoder) throws {
        let ids = try decoder.singleValueContainer().decode([String].self)
        expandedIDs = Set(ids)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(expandedIDs.sorted())
    }
}
