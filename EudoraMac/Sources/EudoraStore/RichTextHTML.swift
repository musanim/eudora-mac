import Foundation

/// The wire format for a styled composed body: `RichText` ⇄ HTML.
///
/// **Generation is the contract; parsing is best-effort.** What this writes is
/// what a recipient sees and what a saved draft is rebuilt from, so it is small,
/// fixed, and round-trips exactly. What it *reads* is, in the general case,
/// arbitrary mail HTML — reopening a draft that real Eudora 7 (or anything else)
/// wrote into Out. That half is deliberately tolerant and deliberately lossy: it
/// recovers font, size, colour, bold and italic and throws the rest away,
/// because that is the whole of what the composer can express.
///
/// This is **not** a display path. Received mail is rendered by `BodyRenderer`
/// into a `WKWebView` under the no-network policy; nothing here is involved in
/// showing someone else's message, and nothing here should grow to be.
///
/// ### The dialect: legacy presentational HTML, because Eudora
///
/// Generation emits `<b>`/`<i>`, `<font face size color>` and `<br>` — HTML 3.2
/// presentational markup — **not** CSS. Eudora 7's built-in renderer ignores
/// `<span style>` and `white-space` entirely and drops to the plain alternative
/// when that is all a message's styling is; a first attempt using CSS arrived at
/// Eudora unstyled for exactly that reason. This dialect is what Eudora itself
/// emits and what its renderer reads.
///
/// The cost is whitespace: `<br>` collapses tabs to spaces and drops a line's
/// trailing spaces, where a `white-space: pre` body would have kept them.
/// Leading indentation and interior runs of spaces are held open with `&nbsp;`,
/// so what remains lost is invisible — and a font face declares no *local*
/// display face on the wire (Stephen's screen font is a personal choice; a run
/// with no chosen face is left to the recipient's default rather than imposed).
public enum RichTextHTML {

    // MARK: - generation
    //
    // **Eudora-dialect HTML, deliberately not CSS.** Eudora 7's built-in HTML
    // renderer understands only legacy presentational markup — `<b>`, `<i>`,
    // `<font face size color>`, `<br>`. It ignores CSS `<span style>` and
    // `white-space` completely, so a message that expresses its styling that way
    // shows in Eudora as the *plain* alternative, unstyled. This was found the
    // hard way: a styled test message arrived plain until the generator was
    // rewritten to match what Eudora itself emits (confirmed against real
    // Eudora-authored mail in the archive). The tolerant parser already reads
    // this dialect, so drafts still round-trip.

    /// The complete HTML document for a styled body.
    ///
    /// An embedded image becomes `<img src="cid:…">`, referring to a part of
    /// the same message — see `OutgoingMessage.rfc822`, which puts those parts
    /// in a `multipart/related` alongside this HTML. No `width`/`height` is
    /// written: the bytes carry the size the user pasted, and pinning it here
    /// would fight every reader's own scaling.
    public static func html(from rich: RichText) -> String {
        var body = ""
        for run in rich.runs {
            if let image = run.image {
                body += "<img src=\"cid:\(attrEscape(image.id))\" alt=\"\">"
            } else {
                body += wrap(encode(run.text), style: run.style)
            }
        }
        return prologue + body + epilogue
    }

    /// Everything before the first character of the body.
    ///
    /// Content sits flush against `<body>` and `</body>` — no newline on either
    /// side. Whitespace adjacent to the content there would be read back in (a
    /// `<br>`-based body still collapses stray whitespace, but flush is simplest
    /// and matches what Eudora emits).
    static let prologue =
        "<html>\n"
        + "<head>\n"
        + "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">\n"
        + "</head>\n<body>"

    static let epilogue = "</body>\n</html>"

    /// The HTML `<font size>` scale, 1…7, in points — the buckets the parser
    /// maps back. Matches `fontTagSize`.
    static let fontSizeScale: [Double] = [8, 10, 12, 14, 18, 24, 36]

    /// Wrap one run's text in the tags its style needs: a `<font>` for face,
    /// size and colour, then `<i>` and `<b>` outside it.
    static func wrap(_ inner: String, style: RichTextStyle) -> String {
        var attrs = ""
        if let face = style.face { attrs += " face=\"" + attrEscape(face) + "\"" }
        // Size goes in the `size` attribute (1…7) that Eudora reads, plus an
        // exact `font-size` style that Eudora ignores but modern clients — and
        // our own parser — use, so a non-bucket size like 13pt survives a round
        // trip instead of snapping to the nearest bucket.
        var sizeStyle = ""
        if let size = style.size {
            attrs += " size=\"\(htmlFontSize(size))\""
            sizeStyle = " style=\"font-size: " + points(size) + "pt\""
        }
        if let color = style.color { attrs += " color=\"" + color.hex + "\"" }

        var s = inner
        if !attrs.isEmpty { s = "<font" + attrs + sizeStyle + ">" + s + "</font>" }
        if style.italic { s = "<i>" + s + "</i>" }
        if style.bold { s = "<b>" + s + "</b>" }
        return s
    }

    /// The nearest `<font size>` bucket (1…7) for a point size.
    static func htmlFontSize(_ size: Double) -> Int {
        var best = 0
        for i in 1..<fontSizeScale.count
        where abs(fontSizeScale[i] - size) < abs(fontSizeScale[best] - size) { best = i }
        return best + 1
    }

    /// A point size without a pointless `.0`.
    static func points(_ size: Double) -> String {
        let rounded = (size * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// Escape a value for a double-quoted attribute.
    static func attrEscape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Encode run text as HTML content: `<br>` for newlines, `&nbsp;` to hold a
    /// run of spaces (or a leading space) open against HTML's whitespace
    /// collapsing, and the three markup characters escaped.
    ///
    /// A single interior space stays a real space so lines can still wrap. Tabs
    /// are treated as spaces; trailing spaces at a line's end collapse away —
    /// both invisible losses a `<br>`-based body can't avoid, and neither
    /// affects the styling or the visible text. CR is folded to LF first so the
    /// same body encodes identically whichever line ending the editor handed
    /// over.
    static func encode(_ raw: String) -> String {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out = ""
        out.reserveCapacity(text.count + 16)
        var lineStart = true
        var prevSpace = false
        for ch in text {
            switch ch {
            case "\n":
                out += "<br>"
                lineStart = true
                prevSpace = false
            case " ", "\t":
                out += (lineStart || prevSpace) ? "&nbsp;" : " "
                lineStart = false
                prevSpace = true
            case "&": out += "&amp;"; lineStart = false; prevSpace = false
            case "<": out += "&lt;"; lineStart = false; prevSpace = false
            case ">": out += "&gt;"; lineStart = false; prevSpace = false
            default: out.append(ch); lineStart = false; prevSpace = false
            }
        }
        return out
    }

    // MARK: - parsing

    /// Recover a styled body from HTML.
    ///
    /// Never fails and never throws: the worst outcome for unrecognisable input
    /// is the text with no styling, which is still the message. Everything
    /// outside `<body>` is dropped, as are `<head>`, `<style>`, `<script>` and
    /// `<title>` contents — this must never surface markup as if it were text.
    /// Parse a body, resolving any `<img>` it contains through `image`.
    ///
    /// The resolver takes the raw `src` and returns the bytes, or nil to leave
    /// the image out. It exists because a `cid:` reference can only be answered
    /// by the *message* the HTML came from — the sibling MIME parts — which this
    /// function cannot see. `AppModel.styledBody` supplies it; the no-argument
    /// overload keeps every other caller (forwarding, the tests) unchanged, and
    /// drops images rather than inventing them.
    public static func parse(_ source: String) -> RichText {
        parse(source, image: { _ in nil })
    }

    public static func parse(_ source: String,
                             image resolve: (String) -> RichTextImage?) -> RichText {
        // Fold line endings first: CR and CRLF in an HTML input stream are a
        // single line break (per the spec), and a part on the wire arrives with
        // CRLF endings, so this keeps a `<pre>`-mode read of foreign HTML from
        // surfacing literal CRs — and mirrors the fold `encode` does on the way
        // out.
        let chars = Array(source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"))
        let (start, end, preformatted) = bodyRange(chars)

        var out: [RichTextRun] = []
        var buffer = ""
        // The innermost frame's style is the one in force. The base frame is
        // never popped, so `stack` is never empty.
        var stack: [Frame] = [Frame(name: "", style: .plain)]

        func lastChar() -> Character? { buffer.last ?? out.last?.text.last }

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(RichTextRun(buffer, style: stack[stack.count - 1].style))
            buffer = ""
        }

        func appendText(_ s: String) {
            guard !preformatted else { buffer += s; return }
            // Collapsing mode: HTML's own whitespace rules, near enough. Runs of
            // spaces, tabs and newlines become one space; whitespace at the very
            // start, or straight after a line break, disappears. U+00A0 is not
            // whitespace here — that is the point of it, and `&nbsp;` is how old
            // mail indents.
            for ch in s {
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                    guard let previous = lastChar() else { continue }
                    if previous == " " || previous == "\n" { continue }
                    buffer.append(" ")
                } else {
                    buffer.append(ch)
                }
            }
        }

        func appendBreak() {
            if !preformatted { while buffer.last == " " { buffer.removeLast() } }
            buffer.append("\n")
        }

        /// A line break unless we are already at the start of one. Used for
        /// block-level elements, whose opening *and* closing tags both call it,
        /// so it has to be idempotent.
        func ensureBreak() {
            guard let previous = lastChar() else { return }   // nothing yet
            if previous != "\n" { appendBreak() }
        }

        var i = start
        while i < end {
            let ch = chars[i]
            guard ch == "<" else {
                // Entity decoding works on a whole text chunk, so gather one.
                var j = i
                while j < end, chars[j] != "<" { j += 1 }
                appendText(decodeEntities(String(chars[i..<j])))
                i = j
                continue
            }

            // Comments and declarations carry nothing we want.
            if let next = skipComment(chars, i, end) { i = next; continue }

            guard let (tag, next) = scanTag(chars, i, end) else {
                // A bare "<" that isn't a tag. Real mail does this; treat it as
                // the character it plainly is.
                appendText("<")
                i += 1
                continue
            }
            i = next

            if Self.dropped.contains(tag.name) {
                if !tag.isClose, !tag.isSelfClosing, !Self.void.contains(tag.name) {
                    i = skipElement(chars, from: i, to: end, name: tag.name)
                }
                continue
            }

            if tag.isClose {
                // Pop back through the most recent frame with this name. Stray
                // closers (`</td>` with no `<td>`) are ignored rather than
                // unwinding the stack, which unbalanced mail HTML would
                // otherwise do on nearly every message.
                if let depth = stack.lastIndex(where: { $0.name == tag.name }), depth > 0 {
                    flush()
                    stack.removeSubrange(depth...)
                }
                if Self.block.contains(tag.name) { ensureBreak() }
                continue
            }

            // An image resolves to a run of its own. Before the `void` test
            // below, which would otherwise skip it, and after the close-tag
            // handling, since `</img>` carries no source.
            if tag.name == "img", let src = tag.attributes["src"],
               let resolved = resolve(src) {
                flush()
                out.append(RichTextRun(image: resolved))
                continue
            }

            if tag.name == "br" { appendBreak(); continue }
            if Self.block.contains(tag.name) { ensureBreak() }
            if Self.void.contains(tag.name) || tag.isSelfClosing { continue }

            var style = stack[stack.count - 1].style
            apply(tag, to: &style)
            if style != stack[stack.count - 1].style { flush() }
            stack.append(Frame(name: tag.name, style: style))
        }
        flush()

        // `&nbsp;` was kept as U+00A0 through parsing so runs of them wouldn't
        // collapse. In a collapsing document that is all it was for — old mail
        // indents with it — and a non-breaking space that looks exactly like a
        // space but doesn't behave like one is a nuisance to edit, so flatten
        // it now that spacing is settled.
        //
        // **Only in collapsing mode.** A preformatted document is one of ours,
        // where indentation is written as real spaces and `&nbsp;` is never
        // emitted — so a U+00A0 in one is a character the author actually typed,
        // and flattening it would mean a draft came back different from how it
        // was saved.
        guard !preformatted else { return RichText(runs: out) }
        return RichText(runs: out.map { run in
            // An image run passes through untouched. Rebuilding it with the
            // text initialiser would drop its `image` and leave a bare U+FFFC
            // behind — every picture lost on reopen, and a stray glyph in the
            // plain alternative where it had been.
            guard !run.isImage else { return run }
            return RichTextRun(run.text.replacingOccurrences(of: "\u{00A0}", with: " "),
                               style: run.style)
        })
    }

    private struct Frame {
        let name: String
        let style: RichTextStyle
    }

    /// Elements whose *contents* are not text. Their children are skipped whole.
    static let dropped: Set<String> = ["head", "style", "script", "title", "meta", "link"]

    /// Elements with no closing tag.
    static let void: Set<String> = ["br", "img", "hr", "meta", "link", "input", "area",
                                    "base", "col", "embed", "source", "wbr", "param", "track"]

    /// Elements that start their content on a new line.
    static let block: Set<String> = ["p", "div", "blockquote", "pre", "li", "ul", "ol",
                                     "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
                                     "hr", "dd", "dt", "dl", "figure", "section", "article",
                                     "header", "footer", "address", "center", "form"]

    /// Fold one tag's styling into the style it inherits.
    static func apply(_ tag: Tag, to style: inout RichTextStyle) {
        switch tag.name {
        case "b", "strong": style.bold = true
        case "i", "em", "cite", "var", "address": style.italic = true
        case "font":
            if let face = tag.attributes["face"], let family = firstFamily(face) {
                style.face = family
            }
            if let color = tag.attributes["color"], let parsed = RichTextColor.parse(color) {
                style.color = parsed
            }
            if let size = tag.attributes["size"], let pt = fontTagSize(size) {
                style.size = pt
            }
        default: break
        }
        // An inline `style` attribute wins over the tag's own meaning — a
        // `<b style="font-weight: normal">` says what it means.
        if let css = tag.attributes["style"] { applyCSS(css, to: &style) }
    }

    /// Apply a CSS declaration list, ignoring everything the composer can't say.
    static func applyCSS(_ css: String, to style: inout RichTextStyle) {
        for declaration in css.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let property = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()

            switch property {
            case "font-weight":
                if let numeric = Int(lower) { style.bold = numeric >= 600 }
                else if lower == "bold" || lower == "bolder" { style.bold = true }
                else if lower == "normal" || lower == "lighter" { style.bold = false }
            case "font-style":
                if lower == "italic" || lower == "oblique" { style.italic = true }
                else if lower == "normal" { style.italic = false }
            case "color":
                if let parsed = RichTextColor.parse(value) { style.color = parsed }
            case "font-family":
                if let family = firstFamily(value) { style.face = family }
            case "font-size":
                if let pt = cssSize(lower) { style.size = pt }
            default:
                break
            }
        }
    }

    /// The first family in a font stack, unquoted. Generic families are ignored:
    /// `sans-serif` is not a face the font panel can show as chosen.
    static func firstFamily(_ list: String) -> String? {
        for candidate in list.split(separator: ",") {
            var name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2,
               (name.hasPrefix("'") && name.hasSuffix("'")) || (name.hasPrefix("\"") && name.hasSuffix("\"")) {
                name = String(name.dropFirst().dropLast())
            }
            if name.isEmpty { continue }
            let generic: Set<String> = ["serif", "sans-serif", "monospace", "cursive",
                                        "fantasy", "system-ui", "ui-sans-serif", "ui-serif",
                                        "ui-monospace", "-apple-system", "inherit", "initial"]
            if generic.contains(name.lowercased()) { continue }
            return name
        }
        return nil
    }

    /// A CSS length in points, for the units that turn up in mail.
    ///
    /// `px` is converted at CSS's own 96-per-inch against typography's 72, which
    /// is the same 4:3 relationship that makes Windows Eudora's "12 point" look
    /// like 16 here — see the note in `EudoraFont`.
    static func cssSize(_ value: String) -> Double? {
        func number(_ suffix: String) -> Double? {
            guard value.hasSuffix(suffix) else { return nil }
            return Double(value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces))
        }
        if let pt = number("pt") { return pt }
        if let px = number("px") { return px * 0.75 }
        if let em = number("em") { return em * 12 }
        if let plain = Double(value) { return plain }   // unitless: treat as points
        return nil
    }

    /// `<font size>` — 1…7, or relative `+n` / `-n` against the default of 3.
    static func fontTagSize(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let scale: [Double] = [8, 10, 12, 14, 18, 24, 36]   // sizes 1…7
        var level: Int
        if s.hasPrefix("+") || s.hasPrefix("-") {
            guard let delta = Int(s) else { return nil }
            level = 3 + delta
        } else {
            guard let absolute = Int(s) else { return nil }
            level = absolute
        }
        level = min(max(level, 1), 7)
        return scale[level - 1]
    }

    // MARK: - the body, and whether it is preformatted

    /// The range of `<body>`'s contents, and whether its `white-space` preserves
    /// newlines.
    ///
    /// Falls back to the whole document when there is no `<body>` — a draft
    /// stored as a bare HTML fragment is a shape worth surviving.
    static func bodyRange(_ chars: [Character]) -> (start: Int, end: Int, preformatted: Bool) {
        var i = 0
        var start = 0
        var preformatted = false
        var found = false
        while i < chars.count {
            guard chars[i] == "<" else { i += 1; continue }
            if let next = skipComment(chars, i, chars.count) { i = next; continue }
            guard let (tag, next) = scanTag(chars, i, chars.count) else { i += 1; continue }
            if tag.name == "body", !tag.isClose {
                start = next
                found = true
                if let css = tag.attributes["style"] {
                    let ws = css.split(separator: ";").first {
                        $0.split(separator: ":").first?
                            .trimmingCharacters(in: .whitespaces).lowercased() == "white-space"
                    }
                    if let ws, let value = ws.split(separator: ":", maxSplits: 1).last {
                        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        preformatted = (v == "pre" || v == "pre-wrap" || v == "break-spaces")
                    }
                }
                break
            }
            i = next
        }
        guard found else { return (0, chars.count, false) }

        // The closing tag, if there is one; otherwise everything left.
        var end = chars.count
        var j = start
        while j < chars.count {
            guard chars[j] == "<" else { j += 1; continue }
            if let next = skipComment(chars, j, chars.count) { j = next; continue }
            guard let (tag, next) = scanTag(chars, j, chars.count) else { j += 1; continue }
            if tag.name == "body", tag.isClose { end = j; break }
            j = next
        }
        return (start, end, preformatted)
    }

    // MARK: - tag scanning

    struct Tag {
        var name: String            // lowercased
        var isClose: Bool
        var isSelfClosing: Bool
        var attributes: [String: String]   // keys lowercased, values entity-decoded
    }

    /// Skip a comment, CDATA section or `<!doctype>` starting at `i`, returning
    /// the index just past it — or nil if that isn't what is there.
    static func skipComment(_ chars: [Character], _ i: Int, _ end: Int) -> Int? {
        guard i + 1 < end, chars[i] == "<", chars[i + 1] == "!" else { return nil }
        if i + 3 < end, chars[i + 2] == "-", chars[i + 3] == "-" {
            var j = i + 4
            while j + 2 < end {
                if chars[j] == "-", chars[j + 1] == "-", chars[j + 2] == ">" { return j + 3 }
                j += 1
            }
            return end
        }
        var j = i + 2
        while j < end, chars[j] != ">" { j += 1 }
        return min(j + 1, end)
    }

    /// Parse the tag beginning at `i`, which must be `<`. Returns nil when what
    /// follows isn't a tag name, so the caller can treat the `<` as text.
    static func scanTag(_ chars: [Character], _ i: Int, _ end: Int) -> (Tag, Int)? {
        var j = i + 1
        guard j < end else { return nil }
        var isClose = false
        if chars[j] == "/" { isClose = true; j += 1 }
        guard j < end, chars[j].isLetter else { return nil }

        var name = ""
        while j < end, chars[j].isLetter || chars[j].isNumber { name.append(chars[j]); j += 1 }

        var attributes: [String: String] = [:]
        var isSelfClosing = false
        while j < end {
            while j < end, chars[j].isWhitespace { j += 1 }
            guard j < end else { break }
            if chars[j] == ">" { j += 1; break }
            if chars[j] == "/" {
                isSelfClosing = true
                j += 1
                continue
            }

            var key = ""
            while j < end, !chars[j].isWhitespace, chars[j] != "=", chars[j] != ">", chars[j] != "/" {
                key.append(chars[j]); j += 1
            }
            while j < end, chars[j].isWhitespace { j += 1 }

            var value = ""
            if j < end, chars[j] == "=" {
                j += 1
                while j < end, chars[j].isWhitespace { j += 1 }
                if j < end, chars[j] == "\"" || chars[j] == "'" {
                    let quote = chars[j]
                    j += 1
                    while j < end, chars[j] != quote { value.append(chars[j]); j += 1 }
                    if j < end { j += 1 }
                } else {
                    while j < end, !chars[j].isWhitespace, chars[j] != ">" {
                        value.append(chars[j]); j += 1
                    }
                }
            }
            if !key.isEmpty { attributes[key.lowercased()] = decodeEntities(value) }
        }

        return (Tag(name: name.lowercased(), isClose: isClose,
                    isSelfClosing: isSelfClosing, attributes: attributes), j)
    }

    /// Index just past `</name>`, or `end` if it never closes.
    static func skipElement(_ chars: [Character], from i: Int, to end: Int, name: String) -> Int {
        var j = i
        while j < end {
            guard chars[j] == "<" else { j += 1; continue }
            if let next = skipComment(chars, j, end) { j = next; continue }
            guard let (tag, next) = scanTag(chars, j, end) else { j += 1; continue }
            if tag.isClose, tag.name == name { return next }
            j = next
        }
        return end
    }

    // MARK: - entities

    /// Decode the entity forms that appear in mail: named, `&#NN;` and `&#xHH;`.
    ///
    /// An unrecognised or unterminated `&` is left exactly as it stands, which is
    /// both what browsers do and what keeps a message about `AT&T` readable.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            guard chars[i] == "&" else { out.append(chars[i]); i += 1; continue }
            // Entity names are short; a run this long is prose, not an entity.
            var j = i + 1
            var name = ""
            while j < chars.count, chars[j] != ";", name.count < 10 {
                name.append(chars[j]); j += 1
            }
            guard j < chars.count, chars[j] == ";", !name.isEmpty else {
                out.append("&"); i += 1; continue
            }
            if let decoded = entity(name) {
                out.append(decoded)
                i = j + 1
            } else {
                out.append("&")
                i += 1
            }
        }
        return out
    }

    private static func entity(_ name: String) -> Character? {
        if name.hasPrefix("#") {
            let digits = String(name.dropFirst())
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
        return named[name]
    }

    /// Deliberately short. The full HTML 5 table is ~2,200 entries and every one
    /// beyond this list is rarer in mail than the cost of carrying it — anything
    /// missing survives as its literal `&name;`, which is legible.
    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        // Kept as U+00A0 through parsing so runs of them don't collapse; `parse`
        // flattens them to ordinary spaces at the end.
        "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "dagger": "†",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "laquo": "«", "raquo": "»", "eacute": "é", "egrave": "è", "agrave": "à",
        "ccedil": "ç", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ntilde": "ñ", "pound": "£", "euro": "€", "yen": "¥", "cent": "¢",
        "sect": "§", "para": "¶", "plusmn": "±", "times": "×", "divide": "÷",
        "frac12": "½", "frac14": "¼", "sup2": "²", "sup3": "³", "micro": "µ",
    ]
}
