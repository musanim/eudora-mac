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
/// address, so it can be read, grepped or hand-edited outside the app. Lines
/// starting `#` and lines that don't parse are skipped, never fatal.
public struct FailedAddresses: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// Bare, lowercased; the key.
        public let address: String
        /// When the failure happened, as the report's own date gave it.
        public let date: Date
        public let status: String
        public let diagnostic: String

        public init(address: String, date: Date, status: String, diagnostic: String) {
            self.address = address.lowercased()
            self.date = date
            self.status = status
            self.diagnostic = diagnostic
        }
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Record a failure. A later failure of the same address replaces an
    /// earlier one; an earlier one never replaces a later — a report filed in
    /// by hand from years back must not hide this month's.
    public mutating func record(_ entry: Entry) {
        if let existing = entries[entry.address], existing.date > entry.date { return }
        entries[entry.address] = entry
    }

    /// Forget an address — it turned out to work after all.
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

    /// Parse the file's contents.
    public init(fileText: String) {
        for raw in fileText.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard !line.hasPrefix("#") else { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2,
                  let address = EmailAddress.bareAddress(fields[0]),
                  let date = Self.dateFormat.date(from: fields[1])
                             ?? Self.dateFormatNoZone.date(from: fields[1]) else { continue }
            record(Entry(address: address, date: date,
                         status: fields.count > 2 ? fields[2] : "",
                         diagnostic: fields.count > 3 ? fields[3] : ""))
        }
    }

    /// The file's contents, sorted by address so a diff of two versions reads.
    public var fileText: String {
        var out = "# Addresses that bounced as no longer existing. Written by Eudora;\n"
        out += "# safe to edit. Columns: address, date, status, diagnostic (tab-separated).\n"
        for key in entries.keys.sorted() {
            guard let e = entries[key] else { continue }
            let fields = [e.address, Self.dateFormat.string(from: e.date),
                          Self.clean(e.status), Self.clean(e.diagnostic)]
            out += fields.joined(separator: "\t") + "\n"
        }
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
    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    static let dateFormatNoZone: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
