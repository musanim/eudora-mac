import Foundation

/// A parsed MIME entity: headers plus either a leaf body or child parts.
public final class MIMEPart {
    public var headers: [(name: String, value: String)] = []
    public var body: [UInt8] = []          // leaf content (undecoded)
    public var children: [MIMEPart] = []    // for multipart/*

    /// Set when the body was stored in Eudora's flattened form (`<x-html>` /
    /// `<x-flowed>`); overrides the now-inaccurate MIME Content-Type so the part
    /// displays and indexes as the correct text leaf.
    public var eudoraContentType: String? = nil

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
            return part
        }

        if part.isMultipart, let boundary = part.boundary {
            let segs = splitMultipart(bodyBytes, boundary: boundary)
            if segs.isEmpty {
                // Claimed multipart but no boundary delimiters present — keep the
                // raw body rather than losing it.
                part.body = bodyBytes
            } else {
                for seg in segs { part.children.append(parse(seg)) }
            }
        } else {
            part.body = bodyBytes
        }
        return part
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
    static func detect(_ body: [UInt8]) -> (contentType: String, body: [UInt8])? {
        if let inner = between(body, "<x-html>", "</x-html>") {
            return ("text/html", inner)
        }
        if let inner = between(body, "<x-flowed>", "</x-flowed>") {
            return ("text/plain", inner)
        }
        return nil
    }

    private static func between(_ body: [UInt8], _ open: String, _ close: String) -> [UInt8]? {
        let openB = Array(open.utf8), closeB = Array(close.utf8)
        guard let o = Bytes.find(openB, in: body) else { return nil }
        let start = o + openB.count
        let end = Bytes.find(closeB, in: body, from: start) ?? body.count
        return start <= end ? Array(body[start..<end]) : nil
    }
}
