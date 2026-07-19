import Foundation

/// Where the user left off, remembered across launches.
///
/// This is deliberately a single Codable blob rather than one UserDefaults key
/// per remembered thing: view state accumulates (sort order, column widths,
/// expanded folders, window frame…), and a new field costs one line here.
///
/// **Adding a field:** decode it with `decodeIfPresent` in `init(from:)` below.
/// Swift's synthesized decoder does *not* fall back to a property's default
/// value — a missing key throws — so a synthesized `init(from:)` plus the
/// `try?` at the call site would silently wipe every existing saved blob the
/// first time a field was added.
///
/// State is stored **per Eudora folder**, keyed by root path. Opening a
/// different tree gets its own selection rather than inheriting one whose
/// mailbox names may not even exist.
struct ViewState: Codable {
    /// Sidebar selection: a `MailboxItem.ID` (path-style, e.g. "Projects/Music").
    var selectedMailbox: String?

    /// Per-mailbox message selection, so returning to a mailbox returns to the
    /// message you were reading there.
    ///
    /// The value is the message's **byte offset in the .mbx**, not its 1-based
    /// index. An index is a position, and positions shift the moment anything
    /// earlier in the mailbox is deleted or compacted away — restoring one would
    /// quietly select a different message. An offset either still names a record
    /// or doesn't, so a stale entry degrades to "no selection".
    var selectedMessageOffsetByMailbox: [String: Int] = [:]

    /// Per-mailbox scroll position, as the index of the topmost visible row.
    ///
    /// A row index rather than a byte offset (unlike the selection above) is a
    /// considered trade: resolving an offset means reading the whole .mbx, which
    /// on a 625 MB Trash is exactly the cost this app has been removing. A scroll
    /// position also fails softly — after a deletion the list is off by a row,
    /// which nobody notices, whereas a selection off by one shows the wrong
    /// message. The index is clamped to the row count on restore.
    var scrollTopRowByMailbox: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedMailbox = try c.decodeIfPresent(String.self, forKey: .selectedMailbox)
        selectedMessageOffsetByMailbox =
            try c.decodeIfPresent([String: Int].self, forKey: .selectedMessageOffsetByMailbox) ?? [:]
        scrollTopRowByMailbox =
            try c.decodeIfPresent([String: Int].self, forKey: .scrollTopRowByMailbox) ?? [:]
    }
}

/// Loads and saves `ViewState` in UserDefaults.
///
/// Saving is cheap (a small JSON blob) and happens on every selection change,
/// which is fine at this size; UserDefaults coalesces writes to disk itself. If
/// this ever grows large enough to matter, the fix is to debounce here rather
/// than at the call sites.
enum ViewStateStore {
    /// Versioned so a format change can't collide with blobs written by an older
    /// build. v2 changed the remembered message from a 1-based index to a byte
    /// offset — same type, different meaning, so it needed a new key.
    private static let key = "viewState.v2"

    static func load(forRoot root: String) -> ViewState {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let blob = all[root] as? Data,
              let state = try? JSONDecoder().decode(ViewState.self, from: blob) else {
            return ViewState()
        }
        return state
    }

    static func save(_ state: ViewState, forRoot root: String) {
        guard let blob = try? JSONEncoder().encode(state) else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[root] = blob
        UserDefaults.standard.set(all, forKey: key)
    }
}
