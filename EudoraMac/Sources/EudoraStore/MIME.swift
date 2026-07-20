import Foundation

/// A parsed MIME entity: headers plus either a leaf body or child parts.
public final class MIMEPart {
    public var headers: [(name: String, value: String)] = []
    public var body: [UInt8] = []          // leaf content (undecoded)
    public var children: [MIMEPart] = []    // for multipart/*

    /// Set when the declared Content-Type is known to be wrong — either the body
    /// was stored in Eudora's flattened form (`<x-html>` / `<x-flowed>`), or the
    /// part claims multipart but has no boundary delimiters (see
    /// `MIMEParser.parse`). Overrides the header so the part displays and indexes
    /// as the text leaf it actually is.
    public var eudoraContentType: String? = nil

    /// Bytes that followed Eudora's flattened-body wrapper.
    ///
    /// Not displayable content — it is Eudora's record of what it *removed* when
    /// it flattened the message: "Attachment Converted:" notes, and sometimes
    /// orphaned headers from the stripped parts. Kept separate from `body` so it
    /// never renders, but kept, because it is the only surviving evidence that a
    /// received message had an attachment. See `DetachedAttachment`.
    public var eudoraTrailer: [UInt8] = []

    public init() {}

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for h in headers where h.name.lowercased() == lower { return h.value }
        return nil
    }

    public var contentTypeRaw: String { header("Content-Type") ?? "text/plain" }

    public var contentType: String {
        if let e = eudoraContentType { return e }
        return contentTypeRaw
            .split(separator: ";")
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
    }

    public var mainType: String { contentType.split(separator: "/").first.map { String($0) } ?? "text" }
    public var subType: String { contentType.split(separator: "/").last.map { String($0) } ?? "plain" }
    public var isMultipart: Bool { mainType == "multipart" }

    public var charset: String? { Self.param("charset", in: contentTypeRaw) }
    public var boundary: String? { Self.param("boundary", in: contentTypeRaw) }
    public var contentDisposition: String? { header("Content-Disposition") }

    public var transferEncoding: String? {
        header("Content-Transfer-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public var filename: String? {
        if let d = contentDisposition, let f = Self.paramValue("filename", in: d) { return f }
        if let f = Self.paramValue("name", in: contentTypeRaw) { return f }
        return nil
    }

    public var isAttachment: Bool {
        if filename != nil { return true }
        if let d = contentDisposition, d.lowercased().contains("attachment") { return true }
        return false
    }

    /// Content bytes with the Content-Transfer-Encoding applied.
    public func decodedPayload() -> Data {
        switch transferEncoding {
        case "base64":
            let s = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: s) ?? Data(body)
        case "quoted-printable":
            return QuotedPrintable.decode(body)
        default:
            return Data(body)
        }
    }

    /// Self plus all descendants, depth-first.
    public func walk() -> [MIMEPart] {
        var out: [MIMEPart] = [self]
        for c in children { out.append(contentsOf: c.walk()) }
        return out
    }

    /// Parse `; key=value` / `key="value"` parameters out of a header value.
    static func param(_ key: String, in header: String) -> String? {
        let lowerKey = key.lowercased()
        for comp in header.components(separatedBy: ";").dropFirst() {
            let kv = comp.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if kv.count == 2, kv[0].lowercased() == lowerKey {
                var v = kv[1]
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                return v
            }
        }
        return nil
    }

    // MARK: - RFC 2231 parameter values (non-ASCII / long filenames)

    /// Resolve a parameter that may use RFC 2231 encoding, needed for real-world
    /// attachment names:
    ///   - `name*=charset'lang'%XX%XX…`            (extended, percent-encoded)
    ///   - `name*0=…; name*1=…`                    (continuation, plain)
    ///   - `name*0*=charset'lang'%XX…; name*1*=%XX…` (continuation + extended)
    /// Falls back to the plain `name="…"` form. Prefers the extended/continued
    /// value when both are present (per the RFC).
    static func paramValue(_ base: String, in header: String) -> String? {
        let lowerBase = base.lowercased()
        let params = parseParams(header)

        var plain: String?
        var simpleExtended: String?
        var segments: [(index: Int, extended: Bool, value: String)] = []

        for (key, value) in params {
            if key == lowerBase {
                plain = value
            } else if key == lowerBase + "*" {
                simpleExtended = value
            } else if key.hasPrefix(lowerBase + "*") {
                let rest = String(key.dropFirst(lowerBase.count + 1))   // after "name*"
                let extended = rest.hasSuffix("*")
                let idxStr = extended ? String(rest.dropLast()) : rest
                if let idx = Int(idxStr) {
                    segments.append((idx, extended, value))
                }
            }
        }

        // Continuation form wins when present.
        if !segments.isEmpty {
            segments.sort { $0.index < $1.index }
            var charset: String?
            // The charset'lang' prefix, if any, rides on segment 0 (extended).
            if segments[0].index == 0, segments[0].extended,
               let (cs, rest) = splitExtendedValue(segments[0].value) {
                charset = cs
                segments[0].value = rest
            }
            var out = ""
            for seg in segments {
                out += seg.extended ? percentDecode(seg.value, charset: charset) : seg.value
            }
            if !out.isEmpty { return out }
            // Malformed/empty continuation → fall through to simple/plain forms.
        }

        if let ext = simpleExtended {
            if let (cs, rest) = splitExtendedValue(ext) {
                return percentDecode(rest, charset: cs)
            }
            return percentDecode(ext, charset: nil)
        }
        return plain
    }

    /// Split a header value into its parameters, quote-aware, returning
    /// `(lowercased-key, unquoted-value)` pairs (the leading type token dropped).
    static func parseParams(_ header: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for comp in splitSemicolons(header).dropFirst() {
            guard let eq = comp.firstIndex(of: "=") else { continue }
            let key = String(comp[comp.startIndex..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(comp[comp.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { out.append((key, val)) }
        }
        return out
    }

    /// Split on `;` but not inside a quoted string.
    static func splitSemicolons(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch) }
            else if ch == ";" && !inQuote { parts.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        parts.append(cur)
        return parts
    }

    /// Split an RFC 2231 extended value `charset'lang'value` → (charset, value).
    static func splitExtendedValue(_ s: String) -> (String, String)? {
        let parts = s.components(separatedBy: "'")
        guard parts.count >= 3 else { return nil }
        let charset = parts[0].isEmpty ? "us-ascii" : parts[0]
        let value = parts[2...].joined(separator: "'")   // lang = parts[1], ignored
        return (charset, value)
    }

    /// Percent-decode `%XX` sequences into bytes, then decode with `charset`
    /// (falling back to UTF-8, then Latin-1 — never fails).
    static func percentDecode(_ s: String, charset: String?) -> String {
        let src = Array(s.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < src.count {
            if src[i] == 0x25, i + 2 < src.count,               // '%'
               let hi = hexNibble(src[i + 1]), let lo = hexNibble(src[i + 2]) {
                bytes.append(UInt8(hi << 4 | lo))
                i += 3
            } else {
                bytes.append(src[i])
                i += 1
            }
        }
        let data = Data(bytes)
        if let cs = charset, let enc = CharsetDecoder.encoding(for: cs),
           let str = String(data: data, encoding: enc) {
            return str
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func hexNibble(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default:          return nil
        }
    }
}

public enum MIMEParser {
    public static func parse(_ bytes: [UInt8]) -> MIMEPart {
        let (headerBytes, bodyBytes) = splitHeaderBody(bytes)
        let part = MIMEPart()
        part.headers = parseHeaders(headerBytes)

        // Eudora rewrites received mail into its own flattened form: HTML wrapped
        // in <x-html>…</x-html> (and, for format=flowed, plain text in
        // <x-flowed>…), with the MIME parts removed even though the Content-Type
        // header still claims multipart. Recover it as the correct text leaf.
        if let eudora = EudoraBody.detect(bodyBytes) {
            part.eudoraContentType = eudora.contentType
            part.body = eudora.body
            part.eudoraTrailer = eudora.trailer
            return part
        }

        if part.isMultipart {
            let segs = part.boundary.map { splitMultipart(bodyBytes, boundary: $0) } ?? []
            if segs.isEmpty {
                // Claimed multipart, but there are no boundary delimiters in the
                // body (or no boundary parameter at all). This is common in a
                // real Eudora tree — it strips the MIME structure and keeps one
                // alternative, leaving the Content-Type header describing a
                // structure that is no longer there. About 6% of the messages in
                // `phaseX` are this shape.
                //
                // Keep the body, and *also* correct the type: leaving the part
                // claiming multipart made it invisible to every consumer that
                // walks parts looking for text, because they all skip multipart
                // nodes and this node has no children. That is what produced
                // "(no text body)" in the reader, and silently dropped the same
                // messages' bodies from the search index.
                // Split off any trailing "Attachment Converted:" notes, exactly
                // as the <x-html> path does, so they don't render as body text.
                let (visible, trailer) = Self.splitTrailingAttachmentNotes(bodyBytes)
                part.body = visible
                part.eudoraTrailer = trailer
                part.eudoraContentType = Self.sniffedTextType(visible)
            } else {
                for seg in segs { part.children.append(parse(seg)) }
            }
        } else {
            part.body = bodyBytes
        }
        return part
    }

    /// Split a salvaged body into what should be displayed and the trailing run
    /// of Eudora's "Attachment Converted:" notes.
    ///
    /// Deliberately conservative: it cuts at the first marker line **only if**
    /// everything from there to the end is marker lines and blank lines. A
    /// message that merely mentions the phrase partway through real prose is left
    /// whole, because truncating a body is far worse than showing one stray line.
    /// Returns the body unchanged when there is nothing to split.
    static func splitTrailingAttachmentNotes(_ body: [UInt8]) -> (visible: [UInt8],
                                                                 trailer: [UInt8]) {
        let marker = Array(DetachedAttachment.marker.utf8)
        guard let first = firstLineStart(of: marker, in: body) else { return (body, []) }

        // Walk the remainder: every line must be blank or another marker.
        var i = first
        while i < body.count {
            var end = i
            while end < body.count, body[end] != 0x0a { end += 1 }
            var lineEnd = end
            if lineEnd > i, body[lineEnd - 1] == 0x0d { lineEnd -= 1 }
            let isBlank = (lineEnd == i)
            let isMarker = lineEnd - i >= marker.count
                && Array(body[i..<(i + marker.count)]) == marker
            if !isBlank && !isMarker { return (body, []) }
            i = end + 1
        }

        // Drop the blank line(s) that separated the body from the notes.
        var cut = first
        while cut > 0, body[cut - 1] == 0x0a || body[cut - 1] == 0x0d { cut -= 1 }
        return (Array(body[0..<cut]), Array(body[first...]))
    }

    /// Index of `needle` where it begins a line, or nil.
    private static func firstLineStart(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        var from = 0
        while let hit = Bytes.find(needle, in: hay, from: from) {
            if hit == 0 || hay[hit - 1] == 0x0a { return hit }
            from = hit + 1
        }
        return nil
    }

    /// Guess whether a salvaged body is HTML or plain text.
    ///
    /// Only reached for a part whose declared type is known to be wrong, so
    /// there is nothing better to go on than the bytes. Sniffs a prefix rather
    /// than the whole body: a plain-text mail quoting `<html>` far down is far
    /// likelier than an HTML document that doesn't announce itself early.
    static func sniffedTextType(_ body: [UInt8]) -> String {
        let head = String(decoding: body.prefix(1024), as: UTF8.self).lowercased()
        for marker in ["<html", "<!doctype html", "<body", "<table", "<div"] {
            if head.contains(marker) { return "text/html" }
        }
        return "text/plain"
    }

    static func splitHeaderBody(_ bytes: [UInt8]) -> ([UInt8], [UInt8]) {
        if let idx = Bytes.find([0x0d, 0x0a, 0x0d, 0x0a], in: bytes) {
            return (Array(bytes[0..<idx]), Array(bytes[(idx + 4)...]))
        }
        if let idx = Bytes.find([0x0a, 0x0a], in: bytes) {
            return (Array(bytes[0..<idx]), Array(bytes[(idx + 2)...]))
        }
        return (bytes, [])
    }

    static func parseHeaders(_ bytes: [UInt8]) -> [(name: String, value: String)] {
        let text = String(decoding: bytes, as: UTF8.self)
        var headers: [(name: String, value: String)] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            // Folded continuation line.
            if let first = line.first, (first == " " || first == "\t"), !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colon])
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name: name, value: value))
            }
        }
        return headers
    }

    /// Split a multipart body into raw part byte-arrays (preamble/epilogue dropped).
    static func splitMultipart(_ bytes: [UInt8], boundary: String) -> [[UInt8]] {
        let delim = Array(("--" + boundary).utf8)
        var positions: [Int] = []
        var i = 0
        while let idx = Bytes.find(delim, in: bytes, from: i) {
            let atLineStart = (idx == 0) || bytes[idx - 1] == 0x0a
            if atLineStart { positions.append(idx) }
            i = idx + 1
        }

        var parts: [[UInt8]] = []
        for k in 0..<positions.count {
            let start = positions[k]
            let afterDelim = start + delim.count
            // Closing boundary "--boundary--" -> stop.
            if afterDelim + 1 < bytes.count, bytes[afterDelim] == 0x2D, bytes[afterDelim + 1] == 0x2D {
                break
            }
            // Content begins after the delimiter line.
            guard let nl = Bytes.find([0x0a], in: bytes, from: start) else { continue }
            let contentStart = nl + 1
            var contentEnd = (k + 1 < positions.count) ? positions[k + 1] : bytes.count
            // Trim the CRLF/LF that precedes the next boundary.
            if contentEnd - 2 >= contentStart, bytes[contentEnd - 2] == 0x0d, bytes[contentEnd - 1] == 0x0a {
                contentEnd -= 2
            } else if contentEnd - 1 >= contentStart, bytes[contentEnd - 1] == 0x0a {
                contentEnd -= 1
            }
            if contentStart <= contentEnd {
                parts.append(Array(bytes[contentStart..<contentEnd]))
            }
        }
        return parts
    }
}

/// Recovers the displayable body from Eudora's flattened storage form. Eudora
/// stores received mail with the MIME structure removed: HTML mail as
/// `<x-html>…</x-html>` and format=flowed plain text as `<x-flowed>…</x-flowed>`.
/// The bytes between the markers are the real content.
enum EudoraBody {
    static func detect(_ body: [UInt8]) -> (contentType: String, body: [UInt8], trailer: [UInt8])? {
        if let r = between(body, "<x-html>", "</x-html>") {
            return ("text/html", r.inner, r.trailer)
        }
        if let r = between(body, "<x-flowed>", "</x-flowed>") {
            return ("text/plain", r.inner, r.trailer)
        }
        return nil
    }

    /// The bytes between the markers, plus everything after the closing one.
    ///
    /// The trailer is not displayable content, but it is where Eudora records
    /// what it removed — "Attachment Converted:" notes, and sometimes orphaned
    /// headers from the parts it stripped — so it must not be discarded. It used
    /// to be, which meant detached attachments were invisible to the app.
    private static func between(_ body: [UInt8], _ open: String, _ close: String)
        -> (inner: [UInt8], trailer: [UInt8])? {
        let openB = Array(open.utf8), closeB = Array(close.utf8)
        guard let o = Bytes.find(openB, in: body) else { return nil }
        let start = o + openB.count
        guard let c = Bytes.find(closeB, in: body, from: start) else {
            // Unterminated wrapper: everything left is content, nothing trails.
            return start <= body.count ? (Array(body[start...]), []) : nil
        }
        return (Array(body[start..<c]), Array(body[(c + closeB.count)...]))
    }
}
