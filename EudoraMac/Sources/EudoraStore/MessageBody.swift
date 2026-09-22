import Foundation

/// Which parts of a message make up its readable body, in reading order.
///
/// **Why this exists.** Three readers of "the body" — the message view, the text
/// a reply quotes, and the styled text Forward carries — each walked the part
/// tree and kept the *first* text part, then stopped looking. That is right for
/// a message with one body and wrong for one Apple Mail sends every day: text,
/// then an attachment dropped in, then more text, which arrives as three
/// siblings of a `multipart/mixed`:
///
///     multipart/mixed
///     ├── text/plain         "Here is the export:"
///     ├── audio/midi         the attachment
///     └── text/plain         "This crash never happened before …"
///
/// Found 2026sep21: Aaron Andrew Hunt's reply showed only its first line. The
/// rest — the explanation and the link to the fixed build — was in the mailbox
/// all along, and nothing on screen said there was more.
///
/// The search index was never affected: `ContentExtractor` already appends
/// every text part, so the lost text was always findable, just not readable.
///
/// **The rule** is RFC 2046's, applied per container rather than globally:
///
/// - `multipart/alternative` is *one* body said several ways. Pick one.
/// - `multipart/related` is a root plus the resources it refers to. The root is
///   the body; the rest are images for it.
/// - Every other multipart — `mixed`, `report`, `parallel`, and anything
///   unknown — is a sequence, and every body child counts.
/// - Only `text/plain` and `text/html` are body. Other `text/*` parts —
///   `text/calendar` in an invite, `text/rfc822-headers` in a bounce,
///   `text/x-amp-html` in Gmail's AMP mail — are data that happens to be text,
///   and quoting or displaying them raw is the failure, not the goal.
/// - Attachments never count, whatever their type.
///
/// (`message/rfc822` parts are not recursed into by `MIMEParser`, so a digest
/// of forwarded messages contributes nothing here — as it didn't before.)
public enum MessageBody {

    /// Which representation to take from a `multipart/alternative`.
    ///
    /// The message view and Forward want the HTML; a reply quotes plain text.
    /// Applied inside each alternative, never across the whole message — the
    /// old code preferred HTML *globally*, so a message of plain text followed
    /// by a small HTML signature displayed only the signature.
    public enum Preference: Equatable { case html, plain }

    /// One piece of the body, decoded.
    public struct Segment: Equatable {
        public let isHTML: Bool
        public let text: String
        public init(isHTML: Bool, text: String) {
            self.isHTML = isHTML
            self.text = text
        }
    }

    // MARK: - which parts

    /// The leaf parts that make up the body, in reading order.
    public static func leaves(of part: MIMEPart, preferring: Preference) -> [MIMEPart] {
        if part.isAttachment { return [] }
        guard part.isMultipart else {
            return isBodyText(part) ? [part] : []
        }
        switch part.subType {
        case "alternative":
            // RFC 2046 §5.1.4 puts the richest last, so the last acceptable one
            // wins; failing a match on the preference, the last that has any
            // body at all.
            //
            // The match is exact — `plain` means `text/plain`, not "anything but
            // HTML". An invite is `alternative[plain, html, text/calendar]`, and
            // "last non-HTML" picked the calendar and quoted raw iCalendar in the
            // reply. `isBodyText` now keeps such parts out of `options` in the
            // first place; the exact match is the second guard.
            let options = part.children
                .map { leaves(of: $0, preferring: preferring) }
                .filter { !$0.isEmpty }
            let wanted = preferring == .html ? "html" : "plain"
            return options.last(where: { $0.contains { $0.subType == wanted } })
                ?? options.last ?? []
        case "related":
            guard let root = relatedRoot(of: part) else { return [] }
            return leaves(of: root, preferring: preferring)
        default:
            return part.children.flatMap { leaves(of: $0, preferring: preferring) }
        }
    }

    /// A leaf that is readable body text rather than data that is text.
    static func isBodyText(_ p: MIMEPart) -> Bool {
        p.mainType == "text" && (p.subType == "plain" || p.subType == "html")
    }

    /// The root of a `multipart/related`: the child whose Content-ID the
    /// `start` parameter names, or the first child when there is no `start` —
    /// which is RFC 2387's default and what nearly everything sends.
    static func relatedRoot(of part: MIMEPart) -> MIMEPart? {
        if let start = MIMEPart.param("start", in: part.contentTypeRaw) {
            let want = bareCID(start)
            if let named = part.children.first(where: {
                bareCID($0.header("Content-ID") ?? "") == want
            }) {
                return named
            }
        }
        return part.children.first
    }

    private static func bareCID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t<>\"")).lowercased()
    }

    /// The body as decoded segments.
    ///
    /// **When nothing qualifies as body**, the old rule applies: the first
    /// `text/*` leaf that isn't an attachment, whatever its subtype. A message
    /// whose only text is `text/enriched` displayed that before, and should
    /// not now display nothing.
    ///
    /// **A plain segment that is only whitespace is dropped when there are
    /// others**: Apple Mail sometimes sends an empty text part between two
    /// attachments, and keeping it would put a gap in the middle of the message.
    /// Plain only, deliberately — an HTML piece that is nothing but an `<img>`
    /// parses to no text at all, and a newsletter that is one image and a text
    /// footer would otherwise have lost the image. One segment is never
    /// filtered, so an empty message still says so, and the single-body case
    /// does no extra work.
    public static func segments(of part: MIMEPart, preferring: Preference) -> [Segment] {
        var chosen = leaves(of: part, preferring: preferring)
        if chosen.isEmpty,
           let first = part.walk().first(where: {
               !$0.isMultipart && !$0.isAttachment && $0.mainType == "text"
           }) {
            chosen = [first]
        }
        let all = chosen.map { p in
            Segment(isHTML: p.subType == "html",
                    text: CharsetDecoder.smartDecode(p.decodedPayload(), declared: p.charset).text)
        }
        guard all.count > 1 else { return all }
        let substantial = all.filter {
            $0.isHTML || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return substantial.isEmpty ? Array(all.prefix(1)) : substantial
    }

    // MARK: - putting them together

    /// The segments as one plain-text body.
    ///
    /// HTML segments go through `RichTextHTML.parse`, not a tag stripper: a
    /// stripper removes the tags and leaves `&amp;` and `&#39;` behind, and it
    /// turns every `<br>` and `<p>` into a single space so a long quote arrives
    /// as one unbroken paragraph. (That was a real bug in reply quoting, fixed
    /// earlier; the reasoning moved here with the code.)
    ///
    /// **One segment comes back exactly as it was decoded**, untrimmed, so that
    /// every message with a single body — nearly all of them — quotes byte for
    /// byte as it did before this existed. Only a message with several pieces is
    /// reshaped: each trimmed of trailing whitespace, then joined with one blank
    /// line, which is where the attachment used to sit.
    public static func combinedPlain(_ segments: [Segment]) -> String {
        let texts = segments.map { $0.isHTML ? RichTextHTML.parse($0.text).plainText : $0.text }
        guard texts.count > 1 else { return texts.first ?? "" }
        return texts.enumerated().map { i, t in
            i == texts.count - 1 ? t : trimmedTrailing(t)
        }.joined(separator: "\n\n")
    }

    /// The segments as one HTML body, for a reader that renders HTML.
    ///
    /// **One HTML segment comes back untouched** — no wrapper, no extraction —
    /// so the common case renders exactly as it did. Several are stitched: each
    /// HTML segment contributes what lies inside its `<body>`, and the `<style>`
    /// blocks from every head are carried to the front, because a sender like
    /// Outlook puts the look of the whole message there.
    ///
    /// **Plain pieces become `<br>`-separated lines with `&nbsp;` for runs of
    /// space**, not a `white-space: pre-wrap` block. The web view honours
    /// `pre-wrap` on any element; `RichTextHTML.parse`, which is how Forward
    /// reads this, honours it only on `<body>`, and flattened a plain piece to
    /// one paragraph. `<br>` and `&nbsp;` mean the same thing to both.
    ///
    /// Known and accepted: CSS hoisted from one piece applies to all of them,
    /// and a piece's `<body>` attributes (`bgcolor`, `text=`) are not carried.
    /// Both matter only when a message has several pieces, which is exactly
    /// when the alternative was not showing them at all.
    public static func combinedHTML(_ segments: [Segment]) -> String {
        if segments.count == 1, segments[0].isHTML { return segments[0].text }
        var styles: [String] = []
        var bodies: [String] = []
        for s in segments {
            if s.isHTML {
                let clean = withoutComments(s.text)
                styles += styleBlocks(in: clean)
                bodies.append(bodyContent(of: clean))
            } else {
                bodies.append("<div>" + plainAsHTML(s.text) + "</div>")
            }
        }
        return "<html><head>" + styles.joined(separator: "\n") + "</head><body>"
            + bodies.joined(separator: "\n<br>\n")
            + "</body></html>"
    }

    // MARK: - helpers

    static func trimmedTrailing(_ s: String) -> String {
        var t = s
        while let last = t.last, last.isWhitespace { t.removeLast() }
        return t
    }

    /// Plain text as HTML that survives both the web view and
    /// `RichTextHTML.parse`. This is `RichTextHTML.encode` — the composer's own
    /// encoder, which already solves exactly this: `<br>` per line, the first
    /// space of a run real so lines still wrap, the rest and any leading space
    /// held open with `&nbsp;`, markup characters escaped, CR folded to LF.
    /// There was briefly a second copy of it here.
    static func plainAsHTML(_ text: String) -> String {
        RichTextHTML.encode(trimmedTrailing(text))
    }

    /// HTML with its comments removed, so that neither a `<body>` nor a
    /// `<style>` inside one — Outlook's `<!--[if mso]>` blocks are full of both
    /// — is mistaken for the real thing.
    static func withoutComments(_ html: String) -> String {
        html.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
    }

    /// Everything after `<body …>`, minus the closing `</body>` and `</html>`.
    ///
    /// Everything after, and not only up to `</body>`: list managers append
    /// their footer after the close tag, and a browser shows it. With no
    /// `<body>` at all — a fragment, which some mailers send — the head and the
    /// `<html>` tags are removed and the rest kept.
    ///
    /// `<body(\s…)?>` rather than `<body…>`, so that `<bodyx>` is not a body.
    static func bodyContent(of html: String) -> String {
        let tailTags = "(?i)</body\\s*>|</html\\s*>"
        if let open = html.range(of: "<body(\\s[^>]*)?>",
                                 options: [.regularExpression, .caseInsensitive]) {
            return String(html[open.upperBound...])
                .replacingOccurrences(of: tailTags, with: "", options: .regularExpression)
        }
        return html
            .replacingOccurrences(of: "(?is)<head(\\s[^>]*)?>.*?</head\\s*>", with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?i)</?html(\\s[^>]*)?>", with: "",
                                  options: .regularExpression)
    }

    static func styleBlocks(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<style(\\s[^>]*)?>.*?</style\\s*>",
                                                options: [.caseInsensitive,
                                                          .dotMatchesLineSeparators])
        else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
