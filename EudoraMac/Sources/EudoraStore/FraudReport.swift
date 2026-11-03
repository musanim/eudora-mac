import Foundation

/// The kinds of fraud Eudora knows how to report, each with its own destination
/// and wording.
///
/// **Grown case by case, from real mail** (2026nov03). Stephen brings a kind of
/// fraud when one arrives; a new case is added only once its recognizer has been
/// checked against the archive — both that it catches the examples and that it
/// flags nothing else. Kinds with no recognizer are still offered on the menu,
/// for Stephen to name by hand.
public enum FraudKind: String, CaseIterable, Sendable {
    /// Mail pretending to come from the US Patent and Trademark Office — fake
    /// "cancellation", "abandonment", "examination appointment" and
    /// "verification" notices about a trademark application. Reported to the
    /// USPTO's own scam desk.
    case usptoImpersonation
    /// Phishing that fits no more specific kind. Reported to the Anti-Phishing
    /// Working Group, which takes any phishing message forwarded as an
    /// attachment.
    case phishing

    /// What the Report Fraud submenu calls it.
    public var menuTitle: String {
        switch self {
        case .usptoImpersonation: return "USPTO impersonation"
        case .phishing:           return "Other phishing (APWG)"
        }
    }

    /// Where the report goes, before the scammer's own address is added.
    public var destination: String {
        switch self {
        case .usptoImpersonation: return "Trademark Scams <TMScams@uspto.gov>"
        case .phishing:           return "reportphishing@apwg.org"
        }
    }

    public var reportSubject: String {
        switch self {
        case .usptoImpersonation: return "PTO scam (original email attached)"
        case .phishing:           return "Phishing report (original email attached)"
        }
    }

    /// **Whether the scammer is copied on the report.** Stephen's choice for the
    /// USPTO case, so they know he is onto them — accepted knowing that the
    /// address is often fake and the copy will bounce; revisit if the bounces
    /// get irritating.
    ///
    /// Not for general phishing. Phishing routinely forges the From of a real,
    /// innocent party (a bank, a shop, a stranger whose address was harvested),
    /// so "copy the sender" there would mostly mail the victim of the forgery.
    /// The USPTO case is safer because the recognizer only fires on a sender that
    /// is *not* the USPTO, and these scams send from their own lookalike domains
    /// and throwaway Gmail accounts to collect replies.
    public var copiesScammer: Bool {
        switch self {
        case .usptoImpersonation: return true
        case .phishing:           return false
        }
    }
}

/// A report ready to become a draft: recipients, subject and body. The original
/// message travels as an attachment, which the app adds — this type knows
/// nothing about mailboxes.
public struct FraudReport: Equatable, Sendable {
    /// Header-ready entries, destination first.
    public var to: [String]
    public var subject: String
    public var body: String
}

/// Recognizing fraud from a message's headers, and assembling the report.
///
/// Pure functions over a parsed message, so every case can be pinned by a test
/// without a mailbox.
public enum FraudRecognizer {

    /// The kinds this message is recognizably an instance of. Empty means
    /// "nothing recognized", not "not fraud" — the menu still offers every kind.
    ///
    /// `me` excludes Stephen's own mail: his replies to a scammer quote the
    /// scammer's subject and would otherwise match.
    public static func recognize(_ part: MIMEPart, me: MeIdentity) -> Set<FraudKind> {
        // The *raw* header for anything about the address: decoding first can
        // turn an encoded display name into a comma or a `<…>` that was never
        // there. The decoded form is only for reading the name.
        let from = part.header("From") ?? ""
        if me.matches(headerValue: from) { return [] }
        var kinds: Set<FraudKind> = []
        if isUSPTOImpersonation(from: from,
                                subject: HeaderDecoder.decode(part.header("Subject") ?? ""),
                                topAuthenticationResults: part.header("Authentication-Results")) {
            kinds.insert(.usptoImpersonation)
        }
        return kinds
    }

    // MARK: USPTO impersonation

    /// Says it is the USPTO, in the sender's name, its domain or the subject.
    ///
    /// Deliberately wide: the narrowing is done by `isGenuineUSPTO`, so a false
    /// claim here costs nothing on genuine mail. Measured 2026nov03 against every
    /// mailbox mentioning "uspto" or "trademark": all fifteen known scams claim
    /// by one of these routes, and nothing that claims and isn't signed by
    /// uspto.gov turned out to be anything but a scam.
    static let claimPattern =
        #"\bUSPTO\b|patent\s+(and|&)\s+trademark|trademark\s+(office|center|filing|department|examin)"#

    /// A subject about a trademark application in the way these scams phrase it,
    /// for the senders whose name claims nothing (`allenthomas@…legal.com`).
    /// "Serial number" on its own needs the USPTO's eight digits after it, or
    /// every lost-licence-key email would match.
    static let subjectPattern =
        #"trademark.{0,40}(serial|application|registration|cancell|abandon|renewal)|serial\s+(no\.?|number)\s*:?\s*\d{8}\b"#

    static func isUSPTOImpersonation(from: String, subject: String,
                                     topAuthenticationResults: String?) -> Bool {
        let name = HeaderDecoder.decode(OutgoingMessage.splitFrom(from).name)
        let domain = domainOf(senderAddress(from) ?? "")
        let claims = matches(claimPattern, name)
            || domain.contains("uspto")
            || matches(claimPattern, subject)
            || matches(subjectPattern, subject)
        guard claims else { return false }
        return !isGenuineUSPTO(domain: domain, topAuthenticationResults: topAuthenticationResults)
    }

    /// Sent from uspto.gov, and signed by it.
    ///
    /// **The domain alone proves nothing** — a From line is whatever the sender
    /// typed — so a uspto.gov address must also carry a passing DKIM signature
    /// for uspto.gov or a subdomain. Every genuine USPTO message in the archive
    /// does, whatever service actually sent it (Amazon SES, Salesforce, Qualtrics).
    ///
    /// **Only the topmost `Authentication-Results` is trusted.** It is the one
    /// Stephen's own provider prepended on receipt; anything below it arrived
    /// with the message and could have been written by the scammer.
    ///
    /// No `Authentication-Results` at all counts as genuine for a uspto.gov
    /// address. That is old mail — 2000-2004, before providers added the
    /// header — and every provider adds it now, so a forger cannot use the gap.
    static func isGenuineUSPTO(domain: String, topAuthenticationResults: String?) -> Bool {
        guard inDomain(domain, "uspto.gov") else { return false }
        guard let ar = topAuthenticationResults else { return true }
        // The parenthesised comment some servers put after the verdict —
        // `dkim=pass (2048-bit key; unprotected)` — may hold a semicolon, so it
        // is stepped over rather than left to end the clause. And the domain
        // must *end* at uspto.gov: `\b` would also accept `uspto.gov-mail.example`.
        return matches(#"dkim=pass(\s*\([^)]*\))?[^;]*header\.d=([a-z0-9-]+\.)*uspto\.gov(?![a-z0-9.-])"#, ar)
    }

    // MARK: the report

    /// The report for `kind` about this message.
    ///
    /// The scammer, when copied, is the From address and a differing Reply-To —
    /// Reply-To is where these scams collect answers, and From is the face they
    /// show. Neither is added if it is one of Stephen's own addresses, or in the
    /// destination's own domain — a forged `no-reply@uspto.gov` is the agency
    /// being impersonated, not the scammer, and copying it would only mail the
    /// agency twice.
    public static func report(_ kind: FraudKind, for part: MIMEPart, me: MeIdentity) -> FraudReport {
        var to = [kind.destination]
        if kind.copiesScammer {
            let agency = domainOf(EmailAddress.bareAddress(kind.destination) ?? "")
            var seen: Set<String> = []
            for header in ["From", "Reply-To"] {
                // Split raw: decoding first can turn an encoded name into a
                // comma, and so one entry into two.
                for entry in EmailAddress.splitList(part.header(header) ?? "") {
                    guard let bare = senderAddress(entry),
                          !me.contains(address: bare),
                          !inDomain(domainOf(bare), agency),
                          seen.insert(bare).inserted else { continue }
                    // **The bare address, no display name.** A scammer's name is
                    // decoration at best and a weapon at worst: an encoded one can
                    // decode to a comma (a phantom recipient), and the commonest
                    // spoof writes a second, real-looking address into it, which
                    // the composer's own parser — first `<` wins — would mail.
                    to.append(bare)
                }
            }
        }
        return FraudReport(to: to, subject: kind.reportSubject,
                           body: "The original message is attached.\n")
    }

    // MARK: helpers

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func domainOf(_ address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return address[address.index(after: at)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t<>\"'"))
            .lowercased()
    }

    /// The address in one From-style entry, taken from the **last** `<…>`.
    ///
    /// `EmailAddress.bareAddress` takes the first, which is right for ordinary
    /// mail and wrong for the commonest spoof there is:
    /// `"USPTO <notice@uspto.gov>" <scam@gmail.com>` — a real-looking address
    /// written into the display name, with the real one after it. The address
    /// the mail actually came from is always the last.
    static func senderAddress(_ entry: String) -> String? {
        if let gt = entry.lastIndex(of: ">"),
           let lt = entry[..<gt].lastIndex(of: "<") {
            return EmailAddress.bareAddress(String(entry[lt...gt]))
        }
        return EmailAddress.bareAddress(entry)
    }

    /// `domain` is `base` or a subdomain of it.
    private static func inDomain(_ domain: String, _ base: String) -> Bool {
        !base.isEmpty && (domain == base || domain.hasSuffix("." + base))
    }
}
