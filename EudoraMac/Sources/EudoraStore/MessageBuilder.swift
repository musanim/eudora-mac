import Foundation

/// A message the user composed, ready to be assembled into RFC-822 bytes for
/// SMTP and for write-back into the Out mailbox. Format-only; no networking.
public struct OutgoingMessage: Sendable {
    public var fromName: String
    public var fromAddress: String
    public var to: [String]           // each may be "Name <addr>" or "addr"
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String           // plain-text, UTF-8

    /// The HTML alternative, when the user actually formatted something.
    ///
    /// **Nil is a guarantee, not a default.** A message with no styling must
    /// assemble to byte-for-byte what this type produced before rich text
    /// existed: a single `text/plain` entity, no boundary, no parts. Anything
    /// else would change every plain message this app has ever sent for the sake
    /// of a feature the sender didn't use — and would rewrite the records
    /// already sitting in Out the next time they were saved.
    ///
    /// So the caller must set this **only** when `RichText.isStyled` is true,
    /// and `rfc822` branches on it rather than on "is there rich text in the
    /// composer", which is always yes. `body` stays the plain-text alternative
    /// and stays authoritative; the HTML is the extra.
    public var htmlBody: String?

    public var inReplyTo: String?     // Message-ID being replied to (with <>)
    public var references: [String]   // References chain (each with <>)

    public init(fromName: String, fromAddress: String,
                to: [String], cc: [String] = [], bcc: [String] = [],
                subject: String, body: String, htmlBody: String? = nil,
                inReplyTo: String? = nil, references: [String] = []) {
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.htmlBody = htmlBody
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Envelope recipients for SMTP `RCPT TO` — addresses only, incl. Bcc.
    public var envelopeRecipients: [String] {
        (to + cc + bcc).map { Self.addressOnly($0) }.filter { !$0.isEmpty }
    }

    /// Envelope sender for SMTP `MAIL FROM`.
    public var envelopeSender: String { Self.addressOnly(fromAddress) }

    // MARK: assembly

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f
    }()

    public func generatedMessageID(date: Date = Date()) -> String {
        let domain = fromAddress.split(separator: "@").last.map(String.init) ?? "localhost"
        return "<\(UUID().uuidString)@\(domain)>"
    }

    /// Assemble the full RFC-822 message (CRLF line endings, UTF-8). Bcc is
    /// intentionally omitted from the headers. Returns the bytes plus the
    /// Message-ID and Date used (handy for write-back / threading).
    ///
    /// - Parameter boundary: the MIME boundary, for tests that need the bytes to
    ///   be deterministic. Ignored unless `htmlBody` is set; nil means generate
    ///   one, which is what every caller outside the tests does.
    public func rfc822(date: Date = Date(), messageID: String? = nil,
                       boundary: String? = nil)
        -> (data: Data, messageID: String, dateHeader: String) {

        let mid = messageID ?? generatedMessageID(date: date)
        let dateHeader = Self.dateFormatter.string(from: date)

        var headers: [String] = []
        headers.append("Date: \(dateHeader)")
        headers.append("From: \(Self.formatAddress(name: fromName, address: fromAddress))")
        if !to.isEmpty  { headers.append("To: \(to.map(Self.encodeAddress).joined(separator: ", "))") }
        if !cc.isEmpty  { headers.append("Cc: \(cc.map(Self.encodeAddress).joined(separator: ", "))") }
        headers.append("Subject: \(Self.encodeHeaderText(subject))")
        headers.append("Message-ID: \(mid)")
        if let ir = inReplyTo { headers.append("In-Reply-To: \(ir)") }
        if !references.isEmpty { headers.append("References: \(references.joined(separator: " "))") }
        headers.append("MIME-Version: 1.0")

        let CRLF = "\r\n"
        let bodyText: String

        if let html = htmlBody, !html.isEmpty {
            // Styled: plain text first, HTML second. Order is not cosmetic —
            // RFC 2046 §5.1.4 has the *last* alternative be the richest, and
            // that is how readers choose which one to show.
            let mark = boundary ?? Self.generatedBoundary()
            headers.append("Content-Type: multipart/alternative; boundary=\"\(mark)\"")
            // No top-level Content-Transfer-Encoding: multipart defaults to 7bit
            // and each part declares its own.
            bodyText = "--\(mark)" + CRLF
                + Self.textEntity(body, subtype: "plain") + CRLF
                + "--\(mark)" + CRLF
                + Self.textEntity(html, subtype: "html") + CRLF
                + "--\(mark)--" + CRLF
        } else {
            // Unstyled: exactly the bytes this produced before rich text
            // existed. See the note on `htmlBody` — this branch is a
            // compatibility guarantee and should not be "tidied" into the one
            // above.
            let bodyIsASCII = body.unicodeScalars.allSatisfy { $0.value < 128 }
            headers.append("Content-Type: text/plain; charset=\(bodyIsASCII ? "us-ascii" : "utf-8")")
            if bodyIsASCII {
                headers.append("Content-Transfer-Encoding: 7bit")
                bodyText = Self.normalizeCRLF(body)
            } else {
                headers.append("Content-Transfer-Encoding: quoted-printable")
                bodyText = QuotedPrintable.encodeBody(body)
            }
        }

        let full = headers.joined(separator: CRLF) + CRLF + CRLF + bodyText
        return (Data(full.utf8), mid, dateHeader)
    }

    /// One `text/*` body part: its two headers, the blank line, and the encoded
    /// content — with **no** trailing line ending.
    ///
    /// The caller adds the CRLF before the next delimiter, because per RFC 2046
    /// that line ending belongs to the boundary and not to the part. Folding it
    /// in here would append a phantom blank line to every part's content.
    static func textEntity(_ text: String, subtype: String) -> String {
        let CRLF = "\r\n"
        let isASCII = text.unicodeScalars.allSatisfy { $0.value < 128 }
        var out = "Content-Type: text/\(subtype); charset=\(isASCII ? "us-ascii" : "utf-8")" + CRLF
        if isASCII {
            out += "Content-Transfer-Encoding: 7bit" + CRLF + CRLF
            out += normalizeCRLF(text)
        } else {
            out += "Content-Transfer-Encoding: quoted-printable" + CRLF + CRLF
            out += QuotedPrintable.encodeBody(text)
        }
        return out
    }

    /// A boundary that cannot occur in either part.
    ///
    /// A UUID rather than a scan of the content for a clashing string: the
    /// probability of collision is nil, and a scan is one more thing that could
    /// be subtly wrong on the message where it mattered.
    static func generatedBoundary() -> String {
        "=_Eudora_\(UUID().uuidString)"
    }

    // MARK: helpers

    /// "Name <addr>" or, if name is empty, just "addr". Encodes the name per
    /// RFC 2047 when it contains non-ASCII.
    static func formatAddress(name: String, address: String) -> String {
        let a = addressOnly(address)
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return a }
        return "\(encodeHeaderText(n)) <\(a)>"
    }

    /// Pass an address entry through, encoding a leading display name if needed.
    static func encodeAddress(_ entry: String) -> String {
        let s = entry.trimmingCharacters(in: .whitespaces)
        guard let lt = s.firstIndex(of: "<") else { return s } // bare address
        let name = String(s[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let addr = s[lt...]
        if name.isEmpty { return String(addr) }
        return "\(encodeHeaderText(name)) \(addr)"
    }

    /// RFC 2047 B-encode a header value if it contains non-ASCII; else verbatim.
    static func encodeHeaderText(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.value < 128 }) { return text }
        let b64 = Data(text.utf8).base64EncodedString()
        return "=?utf-8?B?\(b64)?="
    }

    /// The address inside <> if present, else the trimmed token.
    static func addressOnly(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let lt = t.firstIndex(of: "<"), let gt = t.firstIndex(of: ">"), lt < gt {
            return String(t[t.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Normalize any lone LFs to CRLF so a 7bit body is well-formed.
    static func normalizeCRLF(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var prev: Character = "\0"
        for ch in s {
            if ch == "\n" && prev != "\r" { out.append("\r") }
            out.append(ch)
            prev = ch
        }
        return out
    }
}
