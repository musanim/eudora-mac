import Foundation
import EudoraStore

public struct SearchHit {
    public let mailbox: String
    public let offset: Int
    public let date: String
    public let subject: String
    public let snippet: String
}

// MARK: - Structured query model (Eudora "Find Messages")
//
// These mirror Eudora 7's Find window exactly as Stephen uses it: the four
// "where" fields (Anywhere, Headers, Subject, Date), the five text operators,
// and the four date operators. The UI builds `Criterion`s; the engine turns
// them into SQL over the FTS5 table's stored columns.

/// The "where in the message" field. `date` is handled separately from the
/// three text targets because it uses date operators and a calendar value.
public enum SearchWhere: String, CaseIterable, Identifiable, Sendable {
    case anywhere, headers, subject, date
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .anywhere: return "Anywhere"
        case .headers:  return "Headers"
        case .subject:  return "Subject"
        case .date:     return "Date"
        }
    }
}

/// Text match operators (Anywhere / Headers / Subject).
public enum TextMatchKind: String, CaseIterable, Identifiable, Sendable {
    case contains, doesNotContain, isExactly, isNot, startsWith
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .contains:       return "contains"
        case .doesNotContain: return "does not contain"
        case .isExactly:      return "is"
        case .isNot:          return "is not"
        case .startsWith:     return "starts with"
        }
    }
}

/// Date match operators.
public enum DateMatchKind: String, CaseIterable, Identifiable, Sendable {
    case isOn, isNot, isAfter, isBefore
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .isOn:     return "is"
        case .isNot:    return "is not"
        case .isAfter:  return "is after"
        case .isBefore: return "is before"
        }
    }
}

/// Which stored columns a text target searches.
public enum TextTarget: Sendable {
    case anywhere, headers, subject

    /// FTS5 column names this target scans.
    var columns: [String] {
        switch self {
        case .anywhere: return ["headers", "subject", "body", "attachments", "sender", "recipients"]
        case .headers:  return ["headers"]
        case .subject:  return ["subject"]
        }
    }
}

/// One row of the Find window.
public enum Criterion: Sendable {
    case text(target: TextTarget, op: TextMatchKind, value: String)
    case date(op: DateMatchKind, day: Date)
}

/// A whole Find request: the criteria, how to combine them, the mailbox scope,
/// and a result cap.
public struct SearchQuery: Sendable {
    public var criteria: [Criterion]
    public var matchAll: Bool               // true = Match All (AND), false = Match Any (OR)
    public var mailboxes: Set<String>?      // nil = every mailbox; else only these (by path-id)
    public var limit: Int

    public init(criteria: [Criterion], matchAll: Bool = true,
                mailboxes: Set<String>? = nil, limit: Int = 500) {
        self.criteria = criteria
        self.matchAll = matchAll
        self.mailboxes = mailboxes
        self.limit = limit
    }
}

/// Full-text search over a Eudora tree, backed by SQLite FTS5.
///
/// This is an **app-owned sidecar**: the index lives wherever you point it
/// (a temp file, `:memory:`, or Application Support) — never inside the Eudora
/// tree. It reads through `MailStore`, so it knows nothing about the on-disk
/// format itself. FTS5 gives prefix/phrase/boolean/negation search plus bm25
/// ranking and snippets — a superset of Eudora 7's old X1 engine.
/// `@unchecked Sendable`: holds one SQLite connection. We build it on a
/// background task and then query it on the main actor, but never concurrently
/// — the app hands the finished index to the main actor only after indexing
/// completes — so the single connection is never touched from two threads at
/// once. (The system sqlite3 is serialized-threadsafe regardless.)
public final class SearchIndex: @unchecked Sendable {
    private let db: SQLiteDB

    // Column order matters for snippet()/bm25(): indexed text columns are
    // headers, sender, recipients, subject, body, attachments. `epoch` is an
    // UNINDEXED sortable date (seconds since 1970) used by Date criteria;
    // `date` keeps the raw header string for display.
    private static let createSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
        mailbox UNINDEXED,
        offset UNINDEXED,
        date UNINDEXED,
        epoch UNINDEXED,
        headers,
        sender,
        recipients,
        subject,
        body,
        attachments,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    """

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec(Self.createSQL)
    }

    /// Wipe and rebuild the whole index from the store. `progress`, if given, is
    /// called as `(mailboxesDone, mailboxesTotal)` — throttled to ~100 calls —
    /// so a caller can drive a progress bar. The caller runs this off the main
    /// thread; the callback is invoked on that same (background) thread.
    public func rebuild(from store: MailStore,
                        progress: ((Int, Int) -> Void)? = nil) throws {
        try db.exec("DELETE FROM messages;")
        try db.exec("BEGIN;")
        let insert = try db.prepare("""
        INSERT INTO messages
            (mailbox, offset, date, epoch, headers, sender, recipients, subject, body, attachments)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """)
        let mailboxes = store.allMailboxes()
        let total = mailboxes.count
        let step = max(1, total / 100)
        for (i, mailbox) in mailboxes.enumerated() {
            for message in store.loadMessages(at: mailbox.base) {
                let c = ContentExtractor.extract(message.part)
                insert.reset()
                insert.bind(1, mailbox.name)
                insert.bind(2, message.record.offset)
                insert.bind(3, c.date)
                insert.bind(4, c.epoch)
                insert.bind(5, c.headers)
                insert.bind(6, c.sender)
                insert.bind(7, c.recipients)
                insert.bind(8, c.subject)
                insert.bind(9, c.body)
                insert.bind(10, c.attachments)
                try insert.execute()
            }
            let done = i + 1
            if let progress, done == total || done % step == 0 {
                progress(done, total)
            }
        }
        try db.exec("COMMIT;")
    }

    /// Run an FTS5 query. Supports words, "phrases", prefix*, AND/OR/NOT, and
    /// column filters like `subject:baidarka`.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let stmt = try db.prepare("""
        SELECT mailbox, offset, date, subject,
               snippet(messages, -1, '[', ']', '…', 12)
        FROM messages
        WHERE messages MATCH ?
        ORDER BY bm25(messages)
        LIMIT ?;
        """)
        stmt.bind(1, query)
        stmt.bind(2, limit)

        var hits: [SearchHit] = []
        while stmt.step() {
            hits.append(SearchHit(mailbox: stmt.text(0),
                                  offset: stmt.int(1),
                                  date: stmt.text(2),
                                  subject: stmt.text(3),
                                  snippet: stmt.text(4)))
        }
        return hits
    }

    // MARK: - Structured search (the Find window)

    private enum Bind { case text(String); case int(Int) }

    /// Escape a user string for a LIKE pattern (so % and _ become literal).
    /// Paired with `ESCAPE '\'` in the SQL.
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Run a structured Find query. Uses LIKE/comparison predicates over the
    /// stored columns (Eudora-faithful substring semantics) rather than FTS5
    /// MATCH, and builds its own snippet. An FTS5-accelerated fast path for the
    /// common "contains" case is a later optimisation — the index is already
    /// shaped for it.
    public func search(_ query: SearchQuery) throws -> [SearchHit] {
        var binds: [Bind] = []
        var fragments: [String] = []

        for c in query.criteria {
            if let (sql, b) = Self.predicate(for: c) {
                fragments.append(sql)
                binds.append(contentsOf: b)
            }
        }

        // No usable criteria → match everything in scope.
        let criteriaSQL: String
        if fragments.isEmpty {
            criteriaSQL = "1"
        } else {
            let joiner = query.matchAll ? " AND " : " OR "
            criteriaSQL = "(" + fragments.joined(separator: joiner) + ")"
        }

        var whereSQL = criteriaSQL
        if let boxes = query.mailboxes, !boxes.isEmpty {
            let placeholders = Array(repeating: "?", count: boxes.count).joined(separator: ",")
            whereSQL += " AND mailbox IN (\(placeholders))"
            binds.append(contentsOf: boxes.map { Bind.text($0) })
        }

        let sql = """
        SELECT mailbox, offset, date, subject, body
        FROM messages
        WHERE \(whereSQL)
        ORDER BY CAST(epoch AS INTEGER) DESC, rowid ASC
        LIMIT ?;
        """
        binds.append(.int(query.limit))

        let stmt = try db.prepare(sql)
        var pos: Int32 = 1
        for b in binds {
            switch b {
            case .text(let t): stmt.bind(pos, t)
            case .int(let i):  stmt.bind(pos, i)
            }
            pos += 1
        }

        let term = Self.firstTextValue(query.criteria)
        var hits: [SearchHit] = []
        while stmt.step() {
            let body = stmt.text(4)
            hits.append(SearchHit(mailbox: stmt.text(0),
                                  offset: stmt.int(1),
                                  date: stmt.text(2),
                                  subject: stmt.text(3),
                                  snippet: Self.snippet(from: body, around: term)))
        }
        return hits
    }

    /// Build one predicate `(...)` and its bindings for a criterion. Returns nil
    /// for a text criterion with an empty value (which would otherwise match
    /// every row).
    private static func predicate(for c: Criterion) -> (String, [Bind])? {
        switch c {
        case .text(let target, let op, let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let esc = escapeLike(trimmed)
            let cols = target.columns

            let pattern: String
            let negate: Bool
            switch op {
            case .contains:       pattern = "%\(esc)%"; negate = false
            case .doesNotContain: pattern = "%\(esc)%"; negate = true
            case .startsWith:     pattern = "\(esc)%";  negate = false
            case .isExactly:      pattern = esc;         negate = false
            case .isNot:          pattern = esc;         negate = true
            }

            let ors = cols.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            let binds = cols.map { _ in Bind.text(pattern) }
            var sql = "(\(ors))"
            if negate { sql = "(NOT \(sql))" }
            return (sql, binds)

        case .date(let op, let day):
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: day)
            let start = Int(dayStart.timeIntervalSince1970)
            let next = Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
                            .timeIntervalSince1970)
            let e = "CAST(epoch AS INTEGER)"
            switch op {
            case .isOn:
                return ("(\(e) > 0 AND \(e) >= ? AND \(e) < ?)", [.int(start), .int(next)])
            case .isNot:
                return ("(\(e) > 0 AND NOT (\(e) >= ? AND \(e) < ?))", [.int(start), .int(next)])
            case .isAfter:
                return ("(\(e) > 0 AND \(e) >= ?)", [.int(next)])
            case .isBefore:
                return ("(\(e) > 0 AND \(e) < ?)", [.int(start)])
            }
        }
    }

    /// The first non-empty text value among the criteria, used to centre the
    /// generated snippet.
    private static func firstTextValue(_ criteria: [Criterion]) -> String? {
        for c in criteria {
            if case .text(_, _, let v) = c {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// A ~160-char body preview, centred on the first match of `term`.
    private static func snippet(from body: String, around term: String?) -> String {
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let window = 160
        guard let term, !term.isEmpty,
              let r = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(window))
        }
        let lead = 40
        let startOffset = max(0, flat.distance(from: flat.startIndex, to: r.lowerBound) - lead)
        let startIdx = flat.index(flat.startIndex, offsetBy: startOffset)
        let slice = flat[startIdx...].prefix(window)
        let prefixEllipsis = startOffset > 0 ? "…" : ""
        let suffixEllipsis = flat.distance(from: startIdx, to: flat.endIndex) > window ? "…" : ""
        return prefixEllipsis + String(slice) + suffixEllipsis
    }

    /// True if the on-disk table has the current column set. An index written by
    /// an older build (before `headers`/`epoch` existed) lacks these columns and
    /// must be rebuilt rather than reused.
    public func hasCurrentSchema() -> Bool {
        (try? db.prepare("SELECT headers, epoch FROM messages LIMIT 0;")) != nil
    }

    /// Number of indexed messages (mostly for tests/diagnostics).
    public func count() throws -> Int {
        let stmt = try db.prepare("SELECT count(*) FROM messages;")
        return stmt.step() ? stmt.int(0) : 0
    }
}
