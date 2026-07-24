import Foundation

/// Which way a message went relative to me — the fact the Who column turns into
/// a direction glyph. `fromMe`/`toMe` get the glyph (leading for sent, trailing
/// for received); `selfToSelf` and `neither` get none.
public enum WhoDirection: String, Sendable, Equatable {
    case fromMe      // I sent it
    case toMe        // I received it
    case selfToSelf  // me to me, no other party
    case neither     // neither end is me (mailing list / third-party)
}

/// The resolved Who cell: the name to show (with a `+N` overflow when a send had
/// several recipients), a bare `sortKey` without that suffix so the Who sort
/// clusters a person's sent and received mail, and the direction.
public struct ResolvedWho: Sendable, Equatable {
    public let name: String
    public let sortKey: String
    public let direction: WhoDirection

    public init(name: String, sortKey: String, direction: WhoDirection) {
        self.name = name
        self.sortKey = sortKey
        self.direction = direction
    }
}

/// Deciding, per message, who the *other* party is and which way the message
/// went — given the set of addresses that are me. This replaces the old
/// per-mailbox "outgoing = it's the Out mailbox" guess, which showed my own
/// name in every mixed archive folder.
public enum CorrespondentResolver {

    /// - Parameters are the raw `From`/`To`/`Cc`/`Bcc` header values (nil when
    ///   absent) and the identity set.
    ///
    /// The name is **the first non-me party scanning From → To → Cc → Bcc** —
    /// one rule for every message. That's the sender for mail I received, the
    /// first recipient for mail I sent, and (for a bulk send with me in To and
    /// the audience in Bcc) the first Cc-or-Bcc name. If no party anywhere is
    /// anyone but me, it's a note to self and shows me.
    ///
    /// Direction is decided separately: From is me → `.fromMe`; else I'm a
    /// recipient (To/Cc/Bcc) → `.toMe`; else `.neither`. The `+N` overflow is
    /// added only for my own sends, counting the other recipients.
    public static func resolve(from: String?, to: String?, cc: String?, bcc: String?,
                               me: MeIdentity) -> ResolvedWho {
        let fromMe = me.matches(headerValue: from)

        // The name: first non-me across all four fields, in order.
        guard let first = nonMeEntries(fields: [from, to, cc, bcc], me: me).first else {
            let mine = displayName(HeaderDecoder.decode(from ?? ""))   // only me anywhere
            return ResolvedWho(name: mine, sortKey: mine, direction: .selfToSelf)
        }
        let base = displayName(HeaderDecoder.decode(first))

        let direction: WhoDirection
        var suffix = ""
        if fromMe {
            direction = .fromMe
            // +N counts the other non-me recipients; the first is already shown.
            let recipients = nonMeEntries(fields: [to, cc, bcc], me: me)
            if recipients.count > 1 { suffix = " +\(recipients.count - 1)" }
        } else if me.matches(anyOf: [to, cc, bcc]) {
            direction = .toMe
        } else {
            direction = .neither
        }
        return ResolvedWho(name: base + suffix, sortKey: base, direction: direction)
    }

    /// Non-me entries across the given fields, in order, de-duplicated by address
    /// so the same person listed twice counts once. Entries with no parseable
    /// address (a bare display name) are kept — they may be the only party —
    /// but can't be de-duplicated.
    static func nonMeEntries(fields: [String?], me: MeIdentity) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for field in fields {
            guard let field else { continue }
            for entry in EmailAddress.splitList(field) {
                if let addr = EmailAddress.bareAddress(entry) {
                    if me.contains(address: addr) { continue }     // that's me
                    if !seen.insert(addr).inserted { continue }    // already counted
                }
                out.append(entry)
            }
        }
        return out
    }

    /// `"Steve Dorner <d@x>"` → `"Steve Dorner"`; `"a@b (Name)"` → `"Name"`; else
    /// the address. Strips surrounding quotes. (Kept identical to the copy in
    /// `AppModel`, which will delegate here so the two can't drift.)
    public static func displayName(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lt = s.firstIndex(of: "<") {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
            if let gt = s.firstIndex(of: ">"), s.index(after: lt) < gt {
                return String(s[s.index(after: lt)..<gt])
            }
        }
        if let op = s.firstIndex(of: "("), let cp = s.firstIndex(of: ")"), op < cp {
            let name = s[s.index(after: op)..<cp].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return s
    }
}
