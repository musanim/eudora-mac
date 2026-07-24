import Foundation

/// A cheap per-message read for the message list — the correspondent and date
/// headers, and whether the message carries an attachment — without building the
/// whole MIME tree.
///
/// **Why not just parse.** The list needs only Who, Date and the paperclip.
/// Who and Date are single headers. The paperclip is the one thing that would
/// otherwise force a full parse of every message, which on a 20K-message mailbox
/// costs seconds of body scanning and tree-building for information three
/// columns wide.
///
/// So the full parse is done **only** for a genuine multipart message — a
/// `multipart/*` whose boundary delimiter actually appears in the body, which is
/// the ~3% of a real Trash that Eudora did not flatten. Everything else —
/// flattened received mail, plain messages, the 60%-odd that *claim* multipart
/// but were flattened to a single leaf — is settled from the top headers plus a
/// marker scan of the raw body. Checked against 22,577 real messages, the fast
/// path's attachment verdict is byte-for-byte identical to the full parse's.
public struct MessageDigest: Sendable {
    /// Raw header values, undecoded — the caller decodes and formats. Nil when
    /// the header is absent. `cc`/`bcc` join `to` when asking "am I a recipient?"
    /// — I may sit only in the Cc — and feed the "me appears nowhere" scan that
    /// surfaces addresses the identity set is still missing.
    public let from: String?
    public let to: String?
    public let cc: String?
    public let bcc: String?
    public let date: String?
    public let hasAttachment: Bool

    public static func parse(_ message: [UInt8]) -> MessageDigest {
        let (headerBytes, bodyBytes) = MIMEParser.splitHeaderBody(message)
        let headers = MIMEParser.parseHeaders(headerBytes)
        func header(_ name: String) -> String? {
            let lower = name.lowercased()
            for h in headers where h.name.lowercased() == lower { return h.value }
            return nil
        }
        let contentType = header("Content-Type") ?? "text/plain"
        let disposition = header("Content-Disposition")

        let hasAttachment: Bool
        if isRealMultipart(contentType: contentType, body: bodyBytes) {
            // The structure genuinely needs walking — parse it the full way and
            // ask exactly what enrichment used to ask.
            let part = MIMEParser.parse(message)
            hasAttachment = part.walk().contains { $0.isAttachment }
                || DetachedAttachment.isPresent(in: part)
        } else {
            hasAttachment = DetachedAttachment.markerPresent(inRawBody: bodyBytes)
                || headerDeclaresAttachment(contentType: contentType, disposition: disposition)
        }
        return MessageDigest(from: header("From"), to: header("To"),
                             cc: header("Cc"), bcc: header("Bcc"),
                             date: header("Date"), hasAttachment: hasAttachment)
    }

    /// A `multipart/*` whose boundary delimiter is really in the body — the mark
    /// of a message Eudora didn't flatten. Only these take the slow path; a
    /// header claiming multipart with no delimiters is a flattened leaf.
    static func isRealMultipart(contentType: String, body: [UInt8]) -> Bool {
        let type = contentType.split(separator: ";").first
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard type.hasPrefix("multipart/"),
              let boundary = MIMEPart.param("boundary", in: contentType) else { return false }
        return Bytes.find(Array(("--" + boundary).utf8), in: body) != nil
    }

    /// Attachment declared in the top headers, matching `MIMEPart.isAttachment`
    /// for a single-part message: a filename (Content-Disposition `filename` or
    /// Content-Type `name`), or a Content-Disposition of `attachment`.
    static func headerDeclaresAttachment(contentType: String, disposition: String?) -> Bool {
        if let disposition {
            if disposition.lowercased().contains("attachment") { return true }
            if MIMEPart.paramValue("filename", in: disposition) != nil { return true }
        }
        return MIMEPart.paramValue("name", in: contentType) != nil
    }
}
