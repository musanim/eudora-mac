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

    /// Every address that appears anywhere in a block of free text, in order of
    /// first appearance, without duplicates.
    ///
    /// Unlike `addresses(in:)`, which parses a *header* and can rely on comma
    /// separation and `<>` forms, this scans prose: a forwarded message's quoted
    /// headers, a signature block, a line of a reply chain. Used for filing
    /// suggestions when a message's own headers name nobody but the user —
    /// forwards to oneself, notes to self — where the person the message is
    /// actually *about* is only mentioned in the body.
    ///
    /// Pragmatic, and deliberately conservative at the edges: an address must
    /// have an `@` with something either side, a dot in the domain, and it stops
    /// at the punctuation that ordinarily ends one in running text. Trailing
    /// stops and the `>` of a quoted `<addr>` are trimmed. Anything odd is
    /// dropped rather than guessed at — a wrong address here costs a wasted
    /// query term, but a *plausible* wrong one could suggest the wrong mailbox.
    public static func scan(inText text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        // Characters that can appear inside an address. Everything else is a
        // boundary — including `<`, `>`, quotes, commas and whitespace.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-@")
        for token in text.unicodeScalars.split(whereSeparator: { !allowed.contains($0) }) {
            var candidate = String(String.UnicodeScalarView(token)).lowercased()
            // An HTML entity clinging to the end: a forward's quoted headers
            // arrive as `&lt;name@example.com&gt;`, and this is fed the *raw*
            // message bytes, entities and all. `&` is legal atext so it stays
            // inside the token, and the only boundary in `…com&gt;` is the `;` —
            // which left the domain as `example.com&gt` and the address useless
            // to look up. It is not legal in a *domain*, only in a local part,
            // so anything from the first `&` after the `@` is markup.
            if let at = candidate.firstIndex(of: "@"),
               let amp = candidate[candidate.index(after: at)...].firstIndex(of: "&") {
                candidate = String(candidate[..<amp])
            }
            // Prose punctuation clinging to the end: "write to a@b.com."
            while let last = candidate.last, last == "." || last == "-" || last == "_" {
                candidate.removeLast()
            }
            let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty, !parts[1].isEmpty,
                  parts[1].contains("."),
                  !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            found.append(candidate)
        }
        return found
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
