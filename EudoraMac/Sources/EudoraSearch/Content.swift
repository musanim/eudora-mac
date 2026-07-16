import Foundation
import EudoraStore

/// The indexable projection of one message.
struct MessageContent {
    let sender: String
    let recipients: String
    let subject: String
    let date: String        // raw Date header, kept for display
    let epoch: Int          // parsed Date as seconds since 1970 (0 if unparseable)
    let headers: String     // the full raw header block ("Name: value" per line)
    let body: String
    let attachments: String
}

enum ContentExtractor {
    /// Pull searchable text out of a parsed message: decoded text parts,
    /// tag-stripped HTML, attachment filenames, the raw header block, and a
    /// sortable date.
    static func extract(_ part: MIMEPart) -> MessageContent {
        let sender = HeaderDecoder.decode(part.header("From") ?? "")
        let to = HeaderDecoder.decode(part.header("To") ?? "")
        let cc = HeaderDecoder.decode(part.header("Cc") ?? "")
        let subject = HeaderDecoder.decode(part.header("Subject") ?? "")
        let date = part.header("Date") ?? ""

        // The full header block, so "Headers contains X" can match any header
        // line (From/To/Cc/Subject/Date and every X-* line), not just the few
        // fields we parse out. Values are raw (not RFC-2047 decoded), matching
        // what's literally on the wire.
        let headers = part.headers
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")

        var bodyParts: [String] = []
        var attachments: [String] = []

        for p in part.walk() {
            if p.isMultipart { continue }
            if p.isAttachment {
                if let f = p.filename { attachments.append(f) }
                continue
            }
            if p.mainType == "text" {
                let decoded = CharsetDecoder.smartDecode(p.decodedPayload(), declared: p.charset)
                bodyParts.append(p.subType == "html" ? stripHTML(decoded.text) : decoded.text)
            }
        }

        let recipients = [to, cc].filter { !$0.isEmpty }.joined(separator: " ")
        return MessageContent(sender: sender,
                              recipients: recipients,
                              subject: subject,
                              date: date,
                              epoch: RFC822Date.epoch(date),
                              headers: headers,
                              body: bodyParts.joined(separator: "\n"),
                              attachments: attachments.joined(separator: " "))
    }

    /// Crude but effective tag stripper for indexing HTML-only mail.
    static func stripHTML(_ html: String) -> String {
        var out = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; out.append(" "); continue }
            if !inTag { out.append(ch) }
        }
        return out
    }
}

/// Parses an RFC-822 `Date:` header into seconds-since-1970 for range queries.
/// Returns 0 when the header is missing or in a form we don't recognise; such
/// messages are simply excluded from date-based search predicates.
enum RFC822Date {
    // Common on-the-wire variants: with/without the leading weekday, a numeric
    // offset or an obsolete alphabetic zone (GMT/UT/EST…), and no-timezone forms
    // (assumed GMT). en_US_POSIX keeps month/day names locale-stable.
    private static let formats: [String] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss",   // no zone → GMT (see timeZone below)
        "d MMM yyyy HH:mm:ss",
        "EEE, d MMM yyyy HH:mm",
        "d MMM yyyy HH:mm",
    ]

    private static let parsers: [DateFormatter] = formats.map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Default zone for the no-zone formats; an explicit Z/zzz in the input
        // overrides this, so it's harmless for the zoned formats.
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = fmt
        return f
    }

    static func epoch(_ header: String) -> Int {
        var h = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return 0 }
        // Strip a trailing zone comment like "+0000 (GMT)" or "-0800 (PST)",
        // which DateFormatter won't match and which is very common in real mail.
        if h.hasSuffix(")"), let open = h.range(of: "(", options: .backwards) {
            h = String(h[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        for p in parsers {
            if let d = p.date(from: h) { return Int(d.timeIntervalSince1970) }
        }
        return 0
    }
}
