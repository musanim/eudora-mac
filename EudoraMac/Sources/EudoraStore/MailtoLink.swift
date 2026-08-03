import Foundation

/// A `mailto:` URL, taken apart into the fields of a new message (RFC 6068).
///
/// These arrive from outside the app — a click in Chrome, a "contact us" link,
/// an `Open` from another program — which makes them the one input to the
/// composer that no part of Eudora wrote. Everything here is therefore treated
/// as hostile until proved otherwise, and two rules follow from that:
///
/// **Only known fields are honoured.** RFC 6068 permits arbitrary headers in the
/// query string, and a `mailto:` claiming `?from=...` or `?bcc=...` from an
/// untrusted page is a way to send mail that looks like it came from you, or to
/// add a silent recipient you never see. `to`, `cc`, `subject` and `body` are
/// taken; `bcc` is deliberately *not*, because it is the one field the composer
/// doesn't show prominently and so the one a reader would miss. Everything else
/// is dropped.
///
/// **CR and LF are stripped from every value.** A newline in a decoded field is
/// header injection: `mailto:a@b?subject=hi%0ABcc:%20thief@evil` becomes a
/// genuine extra header the moment the message is assembled. There is no
/// legitimate newline in an address or a subject, so they are removed rather
/// than escaped — except in the body, where newlines are the point and only
/// carriage returns are normalised.
public struct MailtoLink: Equatable, Sendable {
    public var to: [String] = []
    public var cc: [String] = []
    public var subject: String = ""
    public var body: String = ""

    /// Fields present in the URL that were deliberately ignored, lowercased —
    /// `bcc`, `from`, `reply-to` and anything else. The caller can mention them;
    /// silently dropping a `bcc` a user could see in the link would be its own
    /// small deception.
    public var ignoredFields: [String] = []

    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && subject.isEmpty && body.isEmpty
    }

    /// Query keys that become message fields. Lowercased at the comparison.
    static let honouredFields: Set<String> = ["to", "cc", "subject", "body"]

    /// Parse. Returns nil for anything that isn't a `mailto:` URL.
    ///
    /// Note this does *not* validate the addresses. A `mailto:` with a malformed
    /// recipient should still open a composer with the text in the To field,
    /// where it can be seen and corrected — refusing outright would leave the
    /// user with a link that does nothing and no idea why.
    public static func parse(_ url: URL) -> MailtoLink? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }

        var link = MailtoLink()

        // Worked on the raw string throughout, decoding only the leaf values.
        // The order matters twice over: splitting the recipient list *before*
        // decoding is what keeps a `%2C` inside `"Doe%2C Jane" <j@x>` from
        // becoming a separator, and decoding exactly once is what stops `%2520`
        // turning into a space.
        let raw = url.absoluteString
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let afterScheme = raw[raw.index(after: colon)...]

        link.to = addressList(afterScheme.prefix(while: { $0 != "?" }))

        let query = afterScheme.drop(while: { $0 != "?" }).dropFirst()
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let halves = pair.split(separator: "=", maxSplits: 1,
                                    omittingEmptySubsequences: false)
            let key = percentDecoded(String(halves[0])).lowercased()
                .trimmingCharacters(in: .whitespaces)
            let rawValue = halves.count > 1 ? halves[1] : ""
            guard honouredFields.contains(key) else {
                if !key.isEmpty, !link.ignoredFields.contains(key) {
                    link.ignoredFields.append(key)
                }
                continue
            }
            switch key {
            case "to":      link.to += addressList(rawValue)
            case "cc":      link.cc += addressList(rawValue)
            case "subject": link.subject = singleLine(percentDecoded(String(rawValue)))
            case "body":    link.body = bodyText(percentDecoded(String(rawValue)))
            default:        break
            }
        }
        // Caps, for robustness rather than safety — nothing here sends without
        // the user pressing Send, and every field is visible before they do.
        // They exist so a pathological link produces a composer that can still
        // be read and closed.
        link.to = Array(link.to.prefix(maxRecipients))
        link.cc = Array(link.cc.prefix(maxRecipients))
        link.subject = String(link.subject.prefix(maxSubjectLength))
        link.body = String(link.body.prefix(maxBodyLength))
        return link
    }

    static let maxRecipients = 50
    static let maxSubjectLength = 1_000
    static let maxBodyLength = 64_000

    /// A comma-separated recipient list: split raw, then decode each piece,
    /// trim, and drop the empties.
    static func addressList<S: StringProtocol>(_ raw: S) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { singleLine(percentDecoded(String($0))).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Flatten to one line: header injection is the whole risk here, and a CR or
    /// LF is never legitimate in an address or a subject.
    ///
    /// Newlines become a *space* rather than vanishing. Deleting them would join
    /// `hi` and `Bcc: thief@evil` into `hiBcc: thief@evil` — the text is
    /// harmless once it can't fold, but running the words together disguises
    /// what the link tried to do at exactly the moment it should be obvious. A
    /// space is also what a legitimately folded header would have collapsed to.
    ///
    /// Tabs fold to a space for the same reason: they are whitespace that can
    /// also continue a folded header, and neither an address nor a subject has a
    /// legitimate one.
    ///
    /// The other removals are characters that cannot be seen and so can only
    /// mislead: the remaining C0 and C1 controls, DEL, and the bidirectional
    /// overrides, which can make a To field read right-to-left and show an
    /// address that isn't the one there.
    static func singleLine(_ s: String) -> String {
        // CRLF first, so a Windows line ending becomes one space rather than two.
        var scalars = String.UnicodeScalarView()
        for scalar in s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                scalars.append(" ")
            case 0..<0x20, 0x7F...0x9F,             // C0, DEL, C1
                 0x200E, 0x200F, 0x202A...0x202E,   // bidi marks and overrides
                 0x2066...0x2069:                   // bidi isolates
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The body keeps its newlines — they are the content — but is normalised to
    /// `\n` so the composer sees what it sees from every other source.
    static func bodyText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Percent-decoding, with `+` left alone.
    ///
    /// This is the one place a mailto differs from a web form and it matters
    /// here more than anywhere: RFC 6068 spells a space `%20`, and `+` is a
    /// literal plus. Treating `+` as a space — which form decoders do, and which
    /// several mail clients get wrong — would turn `first+tag@example.com` into
    /// `first tag@example.com` and quietly break every address using the tag
    /// convention.
    static func percentDecoded(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}
