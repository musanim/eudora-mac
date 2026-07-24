import Foundation

/// Pulling bare addresses out of RFC-822 `From`/`To`/`Cc` header values, so the
/// Who column can ask "is this end me?" and "who is the other party?".
///
/// Deliberately pragmatic, not a full RFC-5322 parser: it handles the forms real
/// mail actually uses — `local@domain`, `Display Name <local@domain>`,
/// `local@domain (Comment)`, and quoted display names that contain commas
/// (`"Doe, Jane" <j@x>`) — and drops anything with no `@` (group syntax,
/// name-only entries). The address is lowercased; the display name is discarded.
public enum EmailAddress {

    /// Every bare, normalized address in an address-list header, in order.
    /// Entries that carry no address (`undisclosed-recipients:;`, a name with
    /// no `<addr>`) are dropped rather than represented.
    public static func addresses(in headerValue: String) -> [String] {
        splitList(headerValue).compactMap(bareAddress)
    }

    /// The single normalized `local@domain` inside one address entry, or nil if
    /// it holds none. `"Steve Dorner <D@X.com>"` → `"d@x.com"`;
    /// `"a@b.com (Steve)"` → `"a@b.com"`; `"Steve Dorner"` → nil.
    public static func bareAddress(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespaces)
        // A `<addr>` wins outright — the display name (which may itself hold an
        // `@` or a comma) is whatever sits outside the brackets and is ignored.
        if let lt = s.firstIndex(of: "<"),
           let gt = s[s.index(after: lt)...].firstIndex(of: ">") {
            s = String(s[s.index(after: lt)..<gt])
        } else if let paren = s.firstIndex(of: "(") {
            // No brackets: a trailing `(Comment)` is the only other name form.
            s = String(s[..<paren])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
             .lowercased()
        // A real address has an `@` and no internal whitespace; anything else
        // is a name we failed to strip, and not an address.
        guard s.contains("@"), !s.contains(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        return s
    }

    /// Split an address-list header into entries on commas and semicolons —
    /// but only those outside quotes and angle brackets, so the comma in a
    /// quoted display name (`"Doe, Jane" <j@x>`) doesn't tear one address into
    /// two. Entries are trimmed; empties dropped.
    static func splitList(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var angle = 0
        for ch in s {
            switch ch {
            case "\"":
                inQuote.toggle(); cur.append(ch)
            case "<" where !inQuote:
                angle += 1; cur.append(ch)
            case ">" where !inQuote:
                if angle > 0 { angle -= 1 }
                cur.append(ch)
            case ",", ";":
                if inQuote || angle > 0 { cur.append(ch) }
                else { out.append(cur); cur = "" }
            default:
                cur.append(ch)
            }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
