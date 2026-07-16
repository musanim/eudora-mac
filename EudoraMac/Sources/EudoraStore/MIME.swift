import Foundation

/// A parsed MIME entity: headers plus either a leaf body or child parts.
public final class MIMEPart {
    public var headers: [(name: String, value: String)] = []
    public var body: [UInt8] = []          // leaf content (undecoded)
    public var children: [MIMEPart] = []    // for multipart/*

    public init() {}

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for h in headers where h.name.lowercased() == lower { return h.value }
        return nil
    }

    public var contentTypeRaw: String { header("Content-Type") ?? "text/plain" }

    public var contentType: String {
        contentTypeRaw
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
        if let d = contentDisposition, let f = Self.param("filename", in: d) { return f }
        if let f = Self.param("name", in: contentTypeRaw) { return f }
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
}

public enum MIMEParser {
    public static func parse(_ bytes: [UInt8]) -> MIMEPart {
        let (headerBytes, bodyBytes) = splitHeaderBody(bytes)
        let part = MIMEPart()
        part.headers = parseHeaders(headerBytes)

        if part.isMultipart, let boundary = part.boundary {
            for seg in splitMultipart(bodyBytes, boundary: boundary) {
                part.children.append(parse(seg))
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
