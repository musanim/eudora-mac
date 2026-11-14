import Foundation

/// Addresses that bounced as gone, so the composer can warn before they are
/// tried again.
///
/// Stephen's, 2026nov14: most of the bounces from the MAM4U announcement are
/// for people he will never write to again and who have no mailbox of their
/// own — but if he ever does, he wants to be told the address failed last
/// time, and when.
///
/// Pure, like `RecentRecipients`; the app owns the file. **The file is plain
/// tab-separated text** — address, date, status, diagnostic — one line per
/// address, so it can be read, grepped or hand-edited outside the app. The
/// natural hand edit, an address alone on a line, counts as an entry with no
/// date. Lines that aren't entries — comments, and anything this can't read —
/// are **kept as they were** and written back after the entries, so a rewrite
/// never eats what Stephen typed.
public struct FailedAddresses: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// Bare, lowercased; the key.
        public let address: String
        /// When the failure happened; nil for an address added by hand without
        /// one.
        public let date: Date?
        public let status: String
        public let diagnostic: String

        public init(address: String, date: Date?, status: String, diagnostic: String) {
            self.address = address.lowercased()
            self.date = date
            self.status = status
            self.diagnostic = diagnostic
        }

        /// A diagnostic with a forwarding note added — the one place the
        /// note's form is decided, so `forwardedTo` can find it again.
        public static func diagnostic(_ text: String, forwardedTo: String?) -> String {
            guard let forwardedTo else { return text }
            return text + " [forwarded to \(forwardedTo)]"
        }

        /// The address it was forwarded to and failed at, if the diagnostic
        /// carries that note. Shown beside the address: a forwarder or alias
        /// with one dead target is not the same as a dead address.
        public var forwardedTo: String? {
            guard let r = diagnostic.range(of: "[forwarded to "),
                  let end = diagnostic[r.upperBound...].firstIndex(of: "]") else { return nil }
            return String(diagnostic[r.upperBound..<end])
        }
    }

    public private(set) var entries: [String: Entry] = [:]

    /// Lines of the file that aren't entries, in order, verbatim.
    public private(set) var otherLines: [String] = []

    public init() {}

    /// Record a failure. A later failure of the same address replaces an
    /// earlier one; an earlier one never replaces a later — a report filed in
    /// by hand from years back must not hide this month's. An undated entry
    /// counts as earliest.
    public mutating func record(_ entry: Entry) {
        if let existing = entries[entry.address],
           (existing.date ?? .distantPast) > (entry.date ?? .distantPast) { return }
        entries[entry.address] = entry
    }

    /// Forget an address — it turned out to work after all. Takes a bare
    /// address or a "Name <address>" entry.
    public mutating func remove(_ recipient: String) {
        guard let address = EmailAddress.bareAddress(recipient) else { return }
        entries[address] = nil
    }

    /// The recorded failure for one address entry ("Name <a@b.com>" or a bare
    /// address), if any.
    public func failure(for recipient: String) -> Entry? {
        guard let address = EmailAddress.bareAddress(recipient) else { return nil }
        return entries[address]
    }

    // MARK: - the file

    /// The two comment lines `fileText` writes first. Not kept as "other"
    /// lines when read back, or every rewrite would add another copy.
    static let headerLines = [
        "# Addresses that bounced as no longer existing. Written by Eudora; safe to edit.",
        "# Columns: address, date, status, diagnostic (tab-separated). An address alone also counts.",
    ]

    /// Parse the file's contents.
    public init(fileText: String) {
        for raw in fileText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if Self.headerLines.contains(line) { continue }
            if let entry = Self.entry(fromLine: line) {
                record(entry)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                otherLines.append(line)
            }
        }
    }

    /// One entry line, or nil if the line isn't one. The date may be given in
    /// full, without its zone, as a day alone, or not at all.
    static func entry(fromLine line: String) -> Entry? {
        guard !line.hasPrefix("#") else { return nil }
        let fields = line.components(separatedBy: "\t")
        // A bare address, or "Name <address>" with nothing after the ">".
        // Anything else is a note that happens to contain an address
        // ("note: <bob@x.com> works again"), kept as written, not read as one.
        let first = fields[0].trimmingCharacters(in: .whitespaces)
        guard !first.contains(" ") || first.hasSuffix(">"),
              let address = EmailAddress.bareAddress(first) else { return nil }
        var date: Date?
        if fields.count > 1 {
            let d = fields[1].trimmingCharacters(in: .whitespaces)
            if !d.isEmpty {
                guard let parsed = dateFormat.date(from: d) ?? dateFormatNoZone.date(from: d)
                                   ?? dayFormat.date(from: d) else { return nil }
                date = parsed
            }
        }
        return Entry(address: address, date: date,
                     status: fields.count > 2 ? fields[2] : "",
                     diagnostic: fields.count > 3 ? fields[3] : "")
    }

    /// The file's contents: the header, the entries sorted by address so a
    /// diff of two versions reads, then the kept lines.
    public var fileText: String {
        var out = Self.headerLines.joined(separator: "\n") + "\n"
        for key in entries.keys.sorted() {
            guard let e = entries[key] else { continue }
            let fields = [e.address, e.date.map { Self.dateFormat.string(from: $0) } ?? "",
                          Self.clean(e.status), Self.clean(e.diagnostic)]
            out += fields.joined(separator: "\t") + "\n"
        }
        for line in otherLines { out += line + "\n" }
        return out
    }

    /// One field on one line: tabs and line breaks would break the format.
    static func clean(_ s: String) -> String {
        s.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\t")))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `2026-11-14 13:05:00 -0800`: local time, for reading, but with the
    /// offset, so a daylight-saving change or a move to another zone can't
    /// shift or collide what was stored. A hand-typed date without the offset
    /// is read as local time.
    static let dateFormat: DateFormatter = formatter("yyyy-MM-dd HH:mm:ss Z")
    static let dateFormatNoZone: DateFormatter = formatter("yyyy-MM-dd HH:mm:ss")
    static let dayFormat: DateFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
