import Foundation

/// One image whose bytes are physically present in the message (an embedded
/// `cid:` part, a `data:` URI, or an image attachment). The render step stashes
/// these so the view can open them in a native window with **zero network** —
/// the box in the body is just a link that resolves to one of these by `id`.
public struct EmbeddedImage: Equatable, Sendable {
    public let id: String            // stable within one rendered message (e.g. "eu-img-1")
    public let data: Data            // decoded image bytes
    public let mimeType: String      // best-known MIME type ("image/png", …)
    public let suggestedName: String // filename to pre-fill in a Save panel

    public init(id: String, data: Data, mimeType: String, suggestedName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.suggestedName = suggestedName
    }
}

/// The result of rewriting a message's HTML for safe display: the transformed
/// HTML (every `<img>` turned into a box) plus the registry the view uses to
/// resolve `eudora-image:<id>` clicks back to bytes.
public struct RenderedBody {
    public let html: String
    public let images: [String: EmbeddedImage]

    public init(html: String, images: [String: EmbeddedImage]) {
        self.html = html
        self.images = images
    }
}

/// Turns attacker-controlled HTML mail into a "dumb"-client-safe form.
///
/// Policy (see `design-decisions.md` §2/§3): **nothing is ever fetched.** Every
/// `<img>` is replaced with a text box:
///
/// - `http(s):` source  → an unviewable **blocked remote image** box (skull).
///   Its bytes are not in the message, so it can't be viewed; the only
///   affordance is copying the URL (handled by the view, since the box is an
///   `<a href>` to the real remote URL).
/// - `cid:` / `data:` / image attachment (bytes present) → an **`IMAGE [view]`**
///   box: an `<a href="eudora-image:<id>">` the navigation delegate intercepts
///   to open a native viewer. No JavaScript involved.
/// - anything else (relative, unknown scheme, missing `src`) → a neutral
///   "image unavailable" span — never fetched.
///
/// Text `<a href>` links are deliberately left untouched here: they render
/// normally and the *view* enforces the no-navigate / copy-the-true-URL policy.
public enum BodyRenderer {

    public static func rewrite(html: String, in message: MIMEPart) -> RenderedBody {
        var counter = 0
        var resources: [String: EmbeddedImage] = [:]

        // Pre-index every image part that carries bytes, keyed by normalized
        // Content-ID, so `cid:` references in the HTML resolve locally.
        var cidToID: [String: String] = [:]
        for part in message.walk() where isImagePart(part) {
            counter += 1
            let id = "eu-img-\(counter)"
            let res = resource(from: part, id: id)
            resources[id] = res
            if let cid = normalizedCID(part.header("Content-ID")) {
                cidToID[cid] = id
            }
        }

        let ns = html as NSString
        // Match a whole <img …> tag, skipping over quoted attribute values so a
        // '>' inside an attribute (e.g. alt="a>b") doesn't truncate the tag.
        let re = try! NSRegularExpression(pattern: "<img\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>",
                                          options: [.caseInsensitive, .dotMatchesLineSeparators])
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let tag = ns.substring(with: m.range)
            out += box(forImgTag: tag,
                       cidToID: cidToID,
                       resources: &resources,
                       counter: &counter)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)

        return RenderedBody(html: out, images: resources)
    }

    // MARK: - per-<img> transformation

    private static func box(forImgTag tag: String,
                            cidToID: [String: String],
                            resources: inout [String: EmbeddedImage],
                            counter: inout Int) -> String {
        guard let src = attribute("src", in: tag) else {
            return unavailableBox
        }
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            return remoteBox(url: trimmed)
        }
        if lower.hasPrefix("cid:") {
            let cid = normalizedCID(String(trimmed.dropFirst(4))) ?? ""
            if let id = cidToID[cid] {
                return imageBox(id: id)
            }
            return unavailableBox   // referenced part not found
        }
        if lower.hasPrefix("data:") {
            if let res = dataURIResource(trimmed, counter: &counter) {
                resources[res.id] = res
                return imageBox(id: res.id)
            }
            return unavailableBox
        }
        // Relative URLs / unknown schemes: nothing can (or should) be loaded.
        return unavailableBox
    }

    private static func remoteBox(url: String) -> String {
        // The box is a link to the *real* remote URL. The view refuses to
        // navigate and instead copies it — matching the link affordance (§1).
        "<a href=\"\(attrEscape(url))\" class=\"eu-remote\" " +
        "title=\"Remote image blocked — click to copy its URL\">" +
        "\u{2620}\u{FE0E} blocked remote image</a>"
    }

    private static func imageBox(id: String) -> String {
        "<a href=\"eudora-image:\(attrEscape(id))\" class=\"eu-image\" " +
        "title=\"Click to view this embedded image\">IMAGE&nbsp;[view]</a>"
    }

    private static let unavailableBox =
        "<span class=\"eu-broken\" title=\"Image not available\">image unavailable</span>"

    // MARK: - MIME helpers

    private static func isImagePart(_ p: MIMEPart) -> Bool {
        if p.isMultipart { return false }
        if p.mainType == "image" { return true }
        if let f = p.filename, imageExtension(of: f) != nil { return true }
        return false
    }

    private static func resource(from part: MIMEPart, id: String) -> EmbeddedImage {
        let ext = part.filename.flatMap(imageExtension) ?? extForMIME(part.contentType)
        let mime = part.mainType == "image" ? part.contentType : (mimeForExt(ext) ?? "application/octet-stream")
        let name = safeName(part.filename) ?? "\(id).\(ext)"
        return EmbeddedImage(id: id, data: part.decodedPayload(), mimeType: mime, suggestedName: name)
    }

    /// Parse `data:[<mediatype>][;base64],<data>` into an EmbeddedImage.
    private static func dataURIResource(_ uri: String, counter: inout Int) -> EmbeddedImage? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let meta = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]) // after "data:"
        let payload = String(uri[uri.index(after: comma)...])

        let tokens = meta.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let isBase64 = tokens.contains { $0.lowercased() == "base64" }
        let mime = tokens.first { $0.contains("/") }?.lowercased() ?? "image/png"

        let data: Data?
        if isBase64 {
            let cleaned = payload.filter { !$0.isWhitespace }
            data = Data(base64Encoded: cleaned)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8) ?? payload.data(using: .utf8)
        }
        guard let bytes = data, !bytes.isEmpty else { return nil }

        counter += 1
        let id = "eu-img-\(counter)"
        let ext = extForMIME(mime)
        return EmbeddedImage(id: id, data: bytes, mimeType: mime, suggestedName: "\(id).\(ext)")
    }

    /// A tidy default filename for the Save panel: drop path separators and
    /// control characters from the (attacker-controlled) MIME filename.
    private static func safeName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw.map { ch -> Character in
            if ch == "/" || ch == "\\" || ch == ":" { return "_" }
            if let s = ch.unicodeScalars.first, s.value < 0x20 { return "_" }
            return ch
        }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func normalizedCID(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("<") && s.hasSuffix(">") && s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        return s.lowercased()
    }

    private static func imageExtension(of filename: String) -> String? {
        let known: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff",
                                  "webp", "heic", "heif", "ico", "svg"]
        guard let dot = filename.lastIndex(of: ".") else { return nil }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return known.contains(ext) ? ext : nil
    }

    private static func extForMIME(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
        case "image/svg+xml": return "svg"
        default: return "img"
        }
    }

    private static func mimeForExt(_ ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "ico": return "image/x-icon"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }

    // MARK: - tiny string utilities

    /// Extract an attribute's value from a single tag (quoted or bare).
    static func attribute(_ name: String, in tag: String) -> String? {
        // `(?<![\w-])` so we match `src=` but not the `src=` inside `data-src=`.
        let pattern = "(?<![\\w-])\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s'\"<>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return nil
    }

    static func attrEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }
}
