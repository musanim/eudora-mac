import Foundation

/// Which pending-blacklist list a newly blacklisted address belongs on.
///
/// Two, because the two mail paths are blocked in two different places by hand
/// and neither can see the other's list: mail for musanim.com is filtered by
/// TigerTech, and mail for gmail.com by a Gmail filter. Blacklisting is one
/// gesture either way; only the drain differs.
public enum BlacklistBucket: String, Codable, Sendable, CaseIterable {
    /// Drained into the ISP's blocklist — TigerTech, which receives musanim.com.
    case isp
    /// Drained into a Gmail filter's From field.
    case gmail
}

/// Deciding which list a blacklisted sender goes on, from the headers of the
/// message being blacklisted.
///
/// **The question is which of Stephen's addresses the message was sent to**, not
/// who sent it — the sender is the thing being blocked, and it says nothing
/// about which mail system needs to be told.
public enum BlacklistRouting {

    /// The headers worth asking, in the order they are asked.
    ///
    /// **Delivery headers first, and that ordering is the whole design.** `To`
    /// is what the *sender* typed and is frequently not Stephen at all: spam is
    /// routinely Bcc'd, and mailing lists put their own address there. Counted
    /// over the real archive, `To` carries 561 @aol.com, 323 @googlegroups.com
    /// and a long tail besides — every one of those a message that arrived at
    /// one of his two addresses while naming neither.
    ///
    /// `Delivered-To` and `X-Original-To` are written by the receiving server
    /// and say where the message actually landed, which is exactly the question.
    /// Also measured rather than assumed: across In and Trash, `Delivered-To`
    /// carries 19,794 @musanim.com and 3,619 @gmail.com, and `X-Original-To`
    /// another 19,801 @musanim.com. A minority of messages carry neither, which
    /// is why `To`/`Cc` remain as a fallback and why there is a last resort
    /// below them.
    public static let deliveryHeaders = ["Delivered-To", "X-Original-To", "Envelope-To"]
    public static let recipientHeaders = ["To", "Cc"]

    /// Which lists this message's sender should be added to.
    ///
    /// `deliveredTo` are the values of `deliveryHeaders`, `recipients` those of
    /// `recipientHeaders` — passed in rather than read here so this stays a pure
    /// function over strings and can be tested without a mailbox.
    ///
    /// **Never returns empty.** When nothing matches — no delivery header, and a
    /// `To` naming only a mailing list — the answer is *both* lists, and that
    /// asymmetry is deliberate. A spurious line on one list is a line Stephen
    /// deletes while draining it, thirty seconds of annoyance. A missing line is
    /// spam that keeps arriving and gives no sign why. So the failure mode is
    /// chosen rather than defaulted into.
    public static func buckets(deliveredTo: [String?],
                               recipients: [String?],
                               ispDomains: Set<String>,
                               gmailDomains: Set<String>) -> Set<BlacklistBucket> {
        let isp = normalize(ispDomains)
        let gmail = normalize(gmailDomains)

        // Delivery first, and *exclusively* when it answers: a message that
        // landed at gmail.com but was addressed to a musanim.com list belongs on
        // the Gmail list alone. Merging the two would put it on both and make
        // the fallback pointless.
        let byDelivery = match(deliveredTo, isp: isp, gmail: gmail)
        if !byDelivery.isEmpty { return byDelivery }

        let byRecipient = match(recipients, isp: isp, gmail: gmail)
        if !byRecipient.isEmpty { return byRecipient }

        return Set(BlacklistBucket.allCases)
    }

    /// The buckets named by one set of header values.
    ///
    /// A single header can name both — Stephen is occasionally in `To` at one
    /// address and `Cc` at the other — and both are then returned, which is the
    /// right answer rather than a tie to break.
    private static func match(_ headers: [String?],
                              isp: Set<String>,
                              gmail: Set<String>) -> Set<BlacklistBucket> {
        var out: Set<BlacklistBucket> = []
        for header in headers {
            guard let header else { continue }
            // `addresses(in:)` returns bare, lowercased addresses, so the domain
            // comparison below needs no further normalizing on this side.
            for address in EmailAddress.addresses(in: header) {
                guard let domain = domain(of: address) else { continue }
                if isp.contains(domain) { out.insert(.isp) }
                if gmail.contains(domain) { out.insert(.gmail) }
            }
        }
        return out
    }

    /// The domain part of an already-bare address.
    ///
    /// `lastIndex`, not `firstIndex`: a quoted local part may legally contain an
    /// `@`, and the domain is always what follows the final one.
    static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = String(address[address.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }

    /// Configured domains lowercased and stripped of a leading `@`, so a rule may
    /// be written either way without it silently never matching.
    private static func normalize(_ domains: Set<String>) -> Set<String> {
        Set(domains.map {
            var d = $0.trimmingCharacters(in: .whitespaces).lowercased()
            if d.hasPrefix("@") { d.removeFirst() }
            return d
        }.filter { !$0.isEmpty })
    }
}
