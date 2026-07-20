import Foundation

/// Attachments Eudora *detached* on receipt, rather than leaving in the message.
///
/// Windows Eudora does not keep received attachments inside the mailbox. It
/// writes the bytes out to its Attachments folder and replaces the MIME part
/// with a marker line at the end of the body:
///
///     Attachment Converted: "Y:\Documents\Active\Eudora\Attachments\invoice.pdf"
///
/// One line per attachment. This is why scanning `MIMEPart.walk()` for
/// `isAttachment` finds nothing on most received mail in a real Eudora tree:
/// there is genuinely no MIME attachment left to find, only this note that one
/// used to be there. Both forms occur in the same tree — mail Eudora never
/// processed (and everything in the outbox) still carries real MIME parts — so
/// callers that care about "does this message have an attachment" must ask about
/// both.
///
/// The path recorded is a Windows path from the machine Eudora ran on, so it is
/// meaningful only as a *filename* plus a hint about where the bytes went. It is
/// deliberately not resolved to anything here: locating the file on this machine
/// is a separate concern (the tree may be mounted anywhere, or not at all).
public enum DetachedAttachment {

    /// The literal marker Eudora writes. Matched at the start of a line only, so
    /// a message quoting the phrase mid-sentence doesn't count.
    public static let marker = "Attachment Converted:"

    /// Filenames of the attachments Eudora detached from this message, in the
    /// order the markers appear. Empty when there are none.
    public static func filenames(in message: MIMEPart) -> [String] {
        var out: [String] = []
        forEachMarkerLine(in: message) { path in
            out.append(filename(fromRecordedPath: path))
            return .continue
        }
        return out
    }

    /// The recorded Windows paths, unmodified, in marker order.
    ///
    /// Kept alongside `filenames(in:)` because the directory part is the only
    /// clue to where the bytes actually went, and Eudora sometimes truncates the
    /// recorded name relative to the original MIME `filename=` parameter.
    public static func recordedPaths(in message: MIMEPart) -> [String] {
        var out: [String] = []
        forEachMarkerLine(in: message) { path in
            var p = path
            if p.hasPrefix("\"") && p.hasSuffix("\"") && p.count >= 2 {
                p = String(p.dropFirst().dropLast())
            }
            out.append(p)
            return .continue
        }
        return out
    }

    /// Whether Eudora detached at least one attachment from this message.
    ///
    /// Stops at the first marker, so it stays cheap enough to call while building
    /// a message list; a message with no markers still costs one scan over its
    /// leaves, but that scan allocates nothing until a marker is actually found.
    public static func isPresent(in message: MIMEPart) -> Bool {
        var found = false
        forEachMarkerLine(in: message) { _ in
            found = true
            return .stop
        }
        return found
    }

    // MARK: - Internals

    enum Continuation { case `continue`, stop }

    private static let markerBytes = Array(marker.utf8)

    /// Main types whose leaves are raw bytes and can never hold a Eudora note.
    ///
    /// An exclusion list rather than a `mainType == "text"` inclusion, because
    /// Eudora flattens messages into leaves whose *declared* type is unreliable.
    /// (The parser now retypes the worst of those — a part claiming multipart
    /// with no boundary delimiters becomes a text leaf — but staying permissive
    /// costs nothing and doesn't depend on that salvage catching every shape.)
    /// Excluding binary types is still needed on its own account: a base64
    /// attachment can decode to bytes that happen to contain the marker.
    private static let binaryMainTypes: Set<String> =
        ["image", "audio", "video", "application", "model"]

    /// Calls `body` with the recorded path from each marker line.
    private static func forEachMarkerLine(in message: MIMEPart,
                                          _ body: (String) -> Continuation) {
        for part in message.walk() where part.children.isEmpty
                                     && !binaryMainTypes.contains(part.mainType) {
            // Eudora strips the transfer encoding when it flattens a message, so
            // the common case needs no decoding at all.
            let bytes: [UInt8]
            switch part.transferEncoding {
            case nil, "", "7bit", "8bit", "binary": bytes = part.body
            default: bytes = [UInt8](part.decodedPayload())
            }
            if scan(bytes, body) == .stop { return }
            // The markers usually live here rather than in the body proper: they
            // follow Eudora's `</x-html>` wrapper. See `MIMEPart.eudoraTrailer`.
            if !part.eudoraTrailer.isEmpty, scan(part.eudoraTrailer, body) == .stop { return }
        }
    }

    /// Marker lines in `bytes`, recognised only at the start of a line so that a
    /// message quoting the phrase mid-sentence doesn't count.
    ///
    /// Byte-level, and the path is read as UTF-8 with replacement rather than
    /// through `CharsetDecoder`: the marker and the path separators are ASCII in
    /// every encoding Eudora writes (Windows ANSI code pages, all ASCII
    /// supersets), so a non-ASCII filename can only garble the *name* reported,
    /// never cause a marker to be missed. Nothing is allocated until a marker is
    /// found, which is what makes this affordable per-message.
    private static func scan(_ bytes: [UInt8], _ body: (String) -> Continuation) -> Continuation {
        var i = 0
        while let hit = Bytes.find(markerBytes, in: bytes, from: i) {
            i = hit + markerBytes.count
            guard hit == 0 || bytes[hit - 1] == 0x0a else { continue }  // line start only
            var end = i
            while end < bytes.count, bytes[end] != 0x0a { end += 1 }
            let lineEnd = (end > i && bytes[end - 1] == 0x0d) ? end - 1 : end
            let path = String(decoding: bytes[i..<lineEnd], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, body(path) == .stop { return .stop }
        }
        return .continue
    }

    /// The bare filename from a recorded path.
    ///
    /// Quotes are optional in the wild (older Eudora omitted them), and the path
    /// is a Windows one, so `\` is the separator — but `/` is also accepted so a
    /// hand-edited or Mac-side path doesn't yield a filename with a directory
    /// still glued to the front.
    static func filename(fromRecordedPath path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if let cut = s.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            s = String(s[s.index(after: cut)...])
        }
        return s
    }
}
