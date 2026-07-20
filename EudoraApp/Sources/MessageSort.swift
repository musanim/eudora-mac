import Foundation

/// Which column the message list is ordered by.
///
/// `status` and `attachment` are the two halves of the single leading glyph
/// column — Eudora 7 had them as separate sortable columns, and they still sort
/// separately here even though they share a column for layout reasons (see
/// `HeaderIcon`); the click's x position picks between them.
///
/// The raw values are persisted in `ViewState`, so renaming a case would quietly
/// drop every saved sort. Add cases, don't rename them.
enum MessageSortColumn: String, Codable, Sendable, CaseIterable {
    case status
    case attachment
    case who
    case date
    case subject

    /// For the Sort menu, which has no header art to point at.
    var title: String {
        switch self {
        case .status:     return "Status"
        case .attachment: return "Attachment"
        case .who:        return "Who"
        case .date:       return "Date"
        case .subject:    return "Subject"
        }
    }

    /// True for columns the background enrichment pass fills in, and which
    /// therefore hold provisional values until it finishes. Only these are worth
    /// re-sorting when it does.
    var dependsOnEnrichment: Bool {
        switch self {
        case .who, .date, .attachment: return true
        case .status, .subject:        return false
        }
    }
}

/// How the message list is ordered: a column and a direction.
///
/// Absent (`nil` wherever this is optional) means **mailbox order** — the order
/// the TOC lists, which is what Eudora shows in an unsorted mailbox and what
/// this app did before sorting existed. Clicking a header toggles between the
/// two directions and never returns to mailbox order; Mailbox ▸ Sort ▸ Mailbox
/// Order is the way back.
struct MessageSort: Equatable, Codable, Sendable {
    var column: MessageSortColumn
    var ascending: Bool

    /// The order rows are put in.
    ///
    /// Sorted on the main actor, deliberately, at all three call sites: a header
    /// click, the moment a listing arrives, and once more when enrichment
    /// finishes. Hopping to a background task to reorder an array already in
    /// memory would add a visible beat to the click — the one interaction that
    /// has to feel immediate — and would need its own generation guard against
    /// the listing and enrichment tasks that also write `rows`.
    ///
    /// That puts a sort of the whole mailbox inside the same main-actor turn that
    /// publishes a new listing, which is the turn the two-phase listing design
    /// exists to keep short. It is affordable only because every comparison below
    /// is cheap — see `compareText`, and don't make one expensive without
    /// re-checking that. On the largest mailbox here (22,515 rows) this is on the
    /// order of 300,000 of them.
    static func apply(_ sort: MessageSort?, to rows: [MessageRow]) -> [MessageRow] {
        guard let sort else { return rows }
        return rows.sorted { a, b in
            let order = compare(a, b, by: sort.column)
            if order != .orderedSame {
                return sort.ascending ? (order == .orderedAscending)
                                      : (order == .orderedDescending)
            }
            // Ties fall back to mailbox order, in *both* directions — so
            // reversing a sort doesn't also reverse the runs of equal keys, which
            // on a column like Who would shuffle each correspondent's mail for no
            // reason the user asked for. It also makes the order total, which
            // `sorted(by:)` requires and does not itself provide (it is not a
            // stable sort).
            return a.id < b.id
        }
    }

    private static func compare(_ a: MessageRow,
                                _ b: MessageRow,
                                by column: MessageSortColumn) -> ComparisonResult {
        switch column {
        case .status:
            // Unread first when ascending: the reason to sort by status at all is
            // to bring unread mail together. The remaining glyphs (R, F, →, Q, S,
            // and blank for plain read mail) then sort among themselves as text.
            let ra = statusRank(a), rb = statusRank(b)
            if ra != rb { return ra < rb ? .orderedAscending : .orderedDescending }
            return compareText(a.statusGlyph, b.statusGlyph)

        case .attachment:
            if a.hasAttachment == b.hasAttachment { return .orderedSame }
            return a.hasAttachment ? .orderedAscending : .orderedDescending

        case .who:
            return compareText(a.who, b.who)

        case .subject:
            return compareText(a.subject, b.subject)

        case .date:
            // An undated message sorts as if it were very old, so it collects at
            // the top ascending and the bottom descending. Treating "unknown" as
            // a value rather than a special case keeps the order total; there are
            // few enough of them that a cleverer rule wouldn't earn its keep.
            let da = a.sortDate ?? .distantPast
            let db = b.sortDate ?? .distantPast
            if da == db { return .orderedSame }
            return da < db ? .orderedAscending : .orderedDescending
        }
    }

    /// Unread first, then everything else.
    private static func statusRank(_ row: MessageRow) -> Int { row.isUnread ? 0 : 1 }

    /// Case-insensitive, but **not** localized.
    ///
    /// `localizedCaseInsensitiveCompare` walks ICU's collator, and a 22,515-row
    /// mailbox costs on the order of 300,000 comparisons per sort — all of them
    /// on the main actor, in the middle of a click. The non-localized form is a
    /// far shorter path. What is given up is locale-correct ordering of accented
    /// and non-Latin names, which for this fixture (twenty-five years of English
    /// correspondence, sorted on Windows Eudora before that) is not a trade worth
    /// paying for. If it ever matters, the fix is to sort off the main actor
    /// rather than to make this comparator slower.
    private static func compareText(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive])
    }
}
