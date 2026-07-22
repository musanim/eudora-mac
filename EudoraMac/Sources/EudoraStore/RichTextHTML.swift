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
/// ### Whitespace: `pre-wrap`, and no `<br>`
///
/// The generated document sets `white-space: pre-wrap` on `<body>` and emits the
/// author's newlines and spaces literally, rather than the more traditional
/// `<br>` plus `&nbsp;`. Three reasons, in order of weight:
///
/// 1. It round-trips exactly. `parse(html(x)) == x` for every string, including
///    tabs and runs of spaces. The `<br>`/`&nbsp;` encoding cannot manage that —
///    a tab has no faithful spelling in it — and a draft that came back subtly
///    different each time it was saved would be a genuinely nasty bug.
/// 2. Indentation and alignment survive, which in a mail composer is content.
/// 3. It is less to get wrong: no decisions about which spaces are significant.
///
/// The cost is a reader too old to honour `white-space`, which would show the
/// message as one paragraph. That reader is served the `text/plain` alternative
/// instead — which is exactly what `multipart/alternative` is for, and why this
/// trade is affordable here when it wouldn't be in a HTML-only message.
public enum RichTextHTML {

    /// What outgoing HTML declares as the body face, whatever the composer is
    /// *displaying* locally.
    ///
    /// Deliberately not the display font setting. Stephen's local face is a
    /// personal choice about how type looks on his own non-Retina screen (see
    /// `EudoraFont`); imposing it on recipients would be both rude and useless,
    /// since they almost certainly don't have it installed. Arial is what
    /// Eudora 7 declared and is present nearly everywhere, with the generic
    /// `sans-serif` behind it for when it isn't.
    public static let wireFontFamily = "Arial, sans-serif"

    // MARK: - generation

    /// The complete HTML document for a styled body.
    public static func html(from rich: RichText) -> String {
        var body = ""
        for run in rich.runs {
            let text = escape(run.text)
            if let css = declarations(for: run.style) {
                body += "<span style=\"" + css + "\">" + text + "</span>"
            } else {
                body += text
            }
        }
        return prologue + body + epilogue
    }

    /// Everything before the first character of the body.
    ///
    /// **Ends immediately after `<body …>` with no newline, and `epilogue`
    /// starts immediately with `</body>`.** Under `white-space: pre-wrap` a
    /// newline there would render as a blank first line, and a newline before
    /// `</body>` as a trailing one — which would then be read back in, so a
    /// draft would grow a line every time it was saved and reopened.
    static let prologue =
        "<html>\n"
        + "<head>\n"
        + "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">\n"
        + "</head>\n"
        + "<body style=\"font-family: " + wireFontFamily + "; white-space: pre-wrap\">"

    /// No trailing newline: this string is a MIME part's content, and the line
    /// ending before the closing boundary belongs to the boundary. Ending here
    /// would put an empty line between the two.
    static let epilogue = "</body>\n</html>"

    /// The CSS for one run's style, or nil when it has none.
    ///
    /// Only what the run overrides — the base face is on `<body>`, so a run that
    /// merely happens to be in the default font says nothing about fonts.
    static func declarations(for style: RichTextStyle) -> String? {
        var parts: [String] = []
        if let face = style.face { parts.append("font-family: " + cssFamily(face)) }
        if let size = style.size { parts.append("font-size: " + points(size) + "pt") }
        if style.bold { parts.append("font-weight: bold") }
        if style.italic { parts.append("font-style: italic") }
        if let color = style.color { parts.append("color: " + color.hex) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// A family name safe to drop into a `style="…"` attribute.
    ///
    /// Strips the characters that could end the attribute or the declaration
    /// rather than escaping them. A font family containing a quote or a
    /// semicolon does not exist; a *malicious* one might, and this string is
    /// about to become part of a document sent to someone else.
    static func cssFamily(_ name: String) -> String {
        let cleaned = String(name.filter { !"\"'<>&;\\{}".contains($0) })
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "sans-serif" }
        let bare = cleaned.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        return bare ? cleaned : "'" + cleaned + "'"
    }

    /// A point size without a pointless `.0`.
    static func points(_ size: Double) -> String {
        let rounded = (size * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// Escape text for HTML content. Newlines, tabs and spaces stay literal —
    /// see the note on `pre-wrap` above.
    ///
    /// CR is folded into LF first so the same body produces the same bytes
    /// whichever line ending the editor handed over.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 16)
        var previousWasCR = false
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "\n"
            case "\n": if !previousWasCR { out += "\n" }
            default: out.append(ch)
            }
            previousWasCR = (ch == "\r")
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
    public static func parse(_ source: String) -> RichText {
        // Newlines first, and this is load-bearing rather than tidiness.
        //
        // A part on the wire has CRLF endings — `OutgoingMessage` normalises
        // every body it writes — so the HTML read back out of a saved draft has
        // CRLF where the author typed a single newline. In `pre-wrap` those CRs
        // are preserved verbatim, and reopening a styled draft would put a
        // literal CR at the end of every line: the editor would show them, and
        // `ComposeView.isDirty` compares text, so the window would announce
        // unsaved changes the instant it opened.
        //
        // Doing it here rather than at the app boundary is also what HTML
        // itself specifies — CR and CRLF in the input stream are a single line
        // break — and it mirrors the same fold `escape` does on the way out.
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
        return RichText(runs: out.map {
            RichTextRun($0.text.replacingOccurrences(of: "\u{00A0}", with: " "), style: $0.style)
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
