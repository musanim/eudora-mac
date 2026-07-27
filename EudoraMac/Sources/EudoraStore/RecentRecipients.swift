import Foundation

/// The recently-used recipients that back the To/Cc/Bcc auto-fill in the
/// composer. Ordered most-recently-used first, keyed for identity on the bare
/// email address so "Bob Smith <bob@x.com>" and a later bare "bob@x.com" are the
/// same person and don't both linger.
///
/// Pure and `Codable` so it can live in the testable library; the app owns the
/// UserDefaults persistence and decides what feeds it (only addresses sent *to*,
/// per the design).
public struct RecentRecipients: Codable, Equatable, Sendable {
    /// Most-recently-used first. Each is a full recipient as the user typed it in
    /// To — "Name <addr>" or a bare address — so completion can offer the name.
    public private(set) var entries: [String]

    /// A soft cap so the list can't grow without bound over years of use.
    public static let maxEntries = 1000

    public init(entries: [String] = []) { self.entries = entries }

    /// Record a recipient as just-used: move it to the front, de-duplicating on
    /// the bare address (case-insensitive). Blank or address-less input is
    /// ignored, so a stray comma or a lone display name never enters the list.
    public mutating func record(_ recipient: String) {
        let trimmed = recipient.trimmingCharacters(in: .whitespaces)
        let key = Self.addressKey(trimmed)
        guard !key.isEmpty, key.contains("@") else { return }
        entries.removeAll { Self.addressKey($0) == key }
        entries.insert(trimmed, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    /// Matches for the token the user is typing, most-recently-used first. An
    /// entry matches when its address, its whole display name, or any word of
    /// the name begins with `prefix` (case-insensitive) — so "bob", "smith" and
    /// "bob@" all find "Bob Smith <bob@x.com>". An empty prefix matches nothing.
    public func matches(prefix: String) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return [] }
        return entries.filter { Self.entry($0, matchesPrefix: p) }
    }

    /// Forget a recipient (the composer's Delete-in-the-dropdown action). Keyed
    /// on the address, so it removes the entry whatever name it was stored under.
    public mutating func remove(_ recipient: String) {
        let key = Self.addressKey(recipient)
        guard !key.isEmpty else { return }
        entries.removeAll { Self.addressKey($0) == key }
    }

    // MARK: matching helpers

    /// The bare, lowercased email address — the entry's identity. Inside `<>`
    /// when present, otherwise the trimmed token.
    static func addressKey(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let lt = t.firstIndex(of: "<"), let gt = t.firstIndex(of: ">"), lt < gt {
            return String(t[t.index(after: lt)..<gt])
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        return t.lowercased()
    }

    /// The display name (before `<`), unquoted and lowercased; empty for a bare
    /// address.
    static func displayName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let lt = t.firstIndex(of: "<") else { return "" }
        return String(t[..<lt])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            .lowercased()
    }

    static func entry(_ entry: String, matchesPrefix p: String) -> Bool {
        if addressKey(entry).hasPrefix(p) { return true }
        let name = displayName(entry)
        if name.hasPrefix(p) { return true }
        for word in name.split(whereSeparator: { " .,".contains($0) }) where word.hasPrefix(p) {
            return true
        }
        return false
    }
}
