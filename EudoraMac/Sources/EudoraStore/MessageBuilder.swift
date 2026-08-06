import Foundation

/// A message the user composed, ready to be assembled into RFC-822 bytes for
/// SMTP and for write-back into the Out mailbox. Format-only; no networking.
public struct OutgoingMessage: Sendable {
    /// A file attached to an outgoing message. The bytes travel with the draft
    /// (read when the file is dropped in), so a saved-and-reopened draft keeps its
    /// attachments and none can go missing between attaching and sending.
    public struct Attachment: Sendable, Hashable, Identifiable {
        public var id: String        // stable within a draft, for list identity
        public var filename: String
        public var mimeType: String  // "" → application/octet-stream
        public var data: Data
        public init(id: String = UUID().uuidString,
                    filename: String, mimeType: String, data: Data) {
            self.id = id
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    public var fromName: String
    public var fromAddress: String
    public var to: [String]           // each may be "Name <addr>" or "addr"
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String           // plain-text, UTF-8
    public var attachments: [Attachment]

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
                attachments: [Attachment] = [],
                inReplyTo: String? = nil, references: [String] = []) {
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.htmlBody = htmlBody
        self.attachments = attachments
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

    /// Assemble the full RFC-822 message (CRLF line endings, UTF-8). Returns the
    /// bytes plus the Message-ID and Date used (handy for write-back / threading).
    ///
    /// - Parameter includeBcc: whether to emit a `Bcc:` header. Off by default —
    ///   the copy transmitted to recipients must not carry it, or the blind copy
    ///   wouldn't be blind (the Bcc'd addresses still receive the message via the
    ///   SMTP envelope, `envelopeRecipients`). The *local* Out copy sets this on,
    ///   so a sent or drafted message keeps a record of who was blind-copied — as
    ///   Eudora did, and as "Send Again" needs.
    /// - Parameter boundary: the MIME boundary, for tests that need the bytes to
    ///   be deterministic. Ignored unless `htmlBody` is set; nil means generate
    ///   one, which is what every caller outside the tests does.
    public func rfc822(date: Date = Date(), messageID: String? = nil,
                       includeBcc: Bool = false,
                       boundary: String? = nil)
        -> (data: Data, messageID: String, dateHeader: String) {

        let mid = messageID ?? generatedMessageID(date: date)
        let dateHeader = Self.dateFormatter.string(from: date)

        var headers: [String] = []
        headers.append("Date: \(dateHeader)")
        headers.append("From: \(Self.formatAddress(name: fromName, address: fromAddress))")
        if !to.isEmpty  { headers.append("To: \(to.map(Self.encodeAddress).joined(separator: ", "))") }
        if !cc.isEmpty  { headers.append("Cc: \(cc.map(Self.encodeAddress).joined(separator: ", "))") }
        if includeBcc, !bcc.isEmpty {
            headers.append("Bcc: \(bcc.map(Self.encodeAddress).joined(separator: ", "))")
        }
        headers.append("Subject: \(Self.encodeHeaderText(subject))")
        headers.append("Message-ID: \(mid)")
        if let ir = inReplyTo { headers.append("In-Reply-To: \(ir)") }
        if !references.isEmpty { headers.append("References: \(references.joined(separator: " "))") }
        headers.append("MIME-Version: 1.0")

        let CRLF = "\r\n"
        let bodyText: String

        if !attachments.isEmpty {
            // Attachments present: wrap everything in multipart/mixed. The first
            // part is the message body — itself a multipart/alternative when the
            // user styled it, otherwise a plain text/plain entity — followed by
            // one part per file. A message with no attachments never takes this
            // branch, so the two below stay byte-for-byte what they always were.
            let mixed = boundary ?? Self.generatedBoundary()
            headers.append("Content-Type: multipart/mixed; boundary=\"\(mixed)\"")

            let bodyPart: String
            if let html = htmlBody, !html.isEmpty {
                let alt = Self.generatedBoundary()
                bodyPart = "Content-Type: multipart/alternative; boundary=\"\(alt)\"" + CRLF + CRLF
                    + "--\(alt)" + CRLF + Self.textEntity(body, subtype: "plain") + CRLF
                    + "--\(alt)" + CRLF + Self.textEntity(html, subtype: "html") + CRLF
                    + "--\(alt)--"
            } else {
                bodyPart = Self.textEntity(body, subtype: "plain")
            }

            var parts = "--\(mixed)" + CRLF + bodyPart + CRLF
            for att in attachments {
                parts += "--\(mixed)" + CRLF + Self.attachmentEntity(att) + CRLF
            }
            parts += "--\(mixed)--" + CRLF
            bodyText = parts
        } else if let html = htmlBody, !html.isEmpty {
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

    /// One attachment part: its Content-Type / -Transfer-Encoding / -Disposition
    /// headers, the blank line, and the base64 payload wrapped at 76 columns —
    /// with **no** trailing line ending (the caller adds the CRLF before the next
    /// delimiter, per RFC 2046, exactly as `textEntity` does).
    static func attachmentEntity(_ att: Attachment) -> String {
        let CRLF = "\r\n"
        let name = encodeHeaderText(att.filename)
        let type = att.mimeType.isEmpty ? "application/octet-stream" : att.mimeType
        var out = "Content-Type: \(type); name=\"\(name)\"" + CRLF
        out += "Content-Transfer-Encoding: base64" + CRLF
        out += "Content-Disposition: attachment; filename=\"\(name)\"" + CRLF + CRLF
        out += att.data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
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
        return "\(quotedIfNeeded(encodeHeaderText(n))) <\(a)>"
    }

    /// Pass an address entry through, encoding a leading display name if needed.
    static func encodeAddress(_ entry: String) -> String {
        let s = entry.trimmingCharacters(in: .whitespaces)
        guard let lt = s.firstIndex(of: "<") else { return s } // bare address
        let name = unquotedDisplayName(String(s[..<lt]))
        let addr = s[lt...]
        if name.isEmpty { return String(addr) }
        return "\(quotedIfNeeded(encodeHeaderText(name))) \(addr)"
    }

    /// A display name as the user means it: outer quotes removed and the
    /// quoted-string escapes undone.
    ///
    /// The inverse of `quotedIfNeeded`, and it exists so the two compose. A name
    /// that merely had its quotes stripped would be re-escaped on the way back
    /// out, and since this app reads its own sent mail — reply, reopen a draft,
    /// Send Again — the escapes would double on every pass. Real senders make
    /// this concrete: `"Catherine Krick \(via Dropbox\)"` is a Dropbox
    /// notification, one of 106 backslash-bearing display names in Stephen's
    /// mail, and without this it grows a pair of backslashes every round trip.
    ///
    /// The lone `'` trim on the quoted branch keeps Outlook's doubly-quoted
    /// `"'Matias Help Desk'"` reducing exactly as it always did.
    static func unquotedDisplayName(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else {
            return s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " '"))
    }

    /// Quote a display name that holds a character a reader would otherwise
    /// take for structure — the comma above all.
    ///
    /// This is not cosmetic. `encodeAddress` strips the quotes off an incoming
    /// `"Andrews, Cody" <a@b.com>`, and without putting them back the header
    /// goes out as `To: Andrews, Cody <a@b.com>` — which every conforming
    /// reader parses as *two* recipients. Delivery still succeeds, because the
    /// SMTP envelope is built from `addressOnly` and never sees the name, so
    /// the damage is invisible until the copy saved in Out is reopened: the
    /// composer reads that header back, splits the now-unquoted comma, and the
    /// send fails on a recipient the user never typed.
    ///
    /// Never quotes an RFC 2047 encoded-word: quoting one stops it decoding,
    /// and its base64 alphabet cannot contain a special in any case. Tested at
    /// both ends, so an ordinary ASCII name that merely opens `=?` isn't let
    /// through unquoted.
    ///
    /// The period is deliberately **not** in the set, though RFC 5322 lists it
    /// among `specials`. It turns up in ordinary names constantly — an initial,
    /// `Jr.`, `Inc.` — and no reader splits an address list on it, so including
    /// it would put quotes around a large share of the display names this app
    /// writes, to fix nothing. Every other character here genuinely misleads a
    /// parser.
    static func quotedIfNeeded(_ name: String) -> String {
        let specials = "()<>[]:;@\\,\""
        guard !(name.hasPrefix("=?") && name.hasSuffix("?=")),
              name.contains(where: { specials.contains($0) })
        else { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// One address-list entry with its display name quoted if it needs it —
    /// `Doe, Jane <j@x>` → `"Doe, Jane" <j@x>`. A bare address, an empty name,
    /// and an already-quoted name all pass through untouched.
    ///
    /// For text on its way *into* a recipient field, where an unquoted comma
    /// would later be read as a separator. The header-assembly path uses
    /// `encodeAddress`, which quotes as part of encoding.
    ///
    /// Unquotes before re-quoting, which makes it idempotent — applying it twice
    /// gives what applying it once did. A cheaper "does it already start and end
    /// with a quote?" test looks equivalent and isn't: `"Smith", and "Jones"`
    /// passes it, and would then be left with its separating comma bare.
    public static func quotingDisplayName(_ entry: String) -> String {
        let s = entry.trimmingCharacters(in: .whitespaces)
        guard let lt = s.firstIndex(of: "<") else { return s } // bare address
        let name = unquotedDisplayName(String(s[..<lt]))
        guard !name.isEmpty else { return s }
        return "\(quotedIfNeeded(name)) \(s[lt...])"
    }

    /// RFC 2047 B-encode a header value if it contains non-ASCII; else verbatim.
    static func encodeHeaderText(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.value < 128 }) { return text }
        let b64 = Data(text.utf8).base64EncodedString()
        return "=?utf-8?B?\(b64)?="
    }

    /// Split a From field — "Name <addr>" or a bare "addr" — into its display
    /// name and address, for building a message from an edited From string. The
    /// name is stripped of surrounding quotes; a field with no `<` is taken to be
    /// a bare address with no name.
    public static func splitFrom(_ s: String) -> (name: String, address: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let lt = t.firstIndex(of: "<") else { return ("", t) }
        return (unquotedDisplayName(String(t[..<lt])), addressOnly(t))
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
