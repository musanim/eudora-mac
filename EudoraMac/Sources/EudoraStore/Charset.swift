import Foundation

public struct DecodedText {
    public let text: String
    public let charsetUsed: String
    public let note: String
}

/// Tolerant text decoding. Eudora-for-Windows routinely mislabeled UTF-8 as
/// iso-8859-1 (or us-ascii). When the declared charset is single-byte but the
/// bytes are valid multibyte UTF-8, we prefer UTF-8 and report the repair.
public enum CharsetDecoder {
    private static let singleByte: Set<String> = [
        "us-ascii", "ascii", "iso-8859-1", "latin-1", "latin1",
        "windows-1252", "cp1252",
    ]

    public static func smartDecode(_ raw: Data, declared: String?) -> DecodedText {
        let dec = (declared ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let effective = dec.isEmpty ? "us-ascii" : dec
        let westernOrUndeclared = dec.isEmpty || singleByte.contains(effective)

        // 1. Mislabel repair: declared single-byte / undeclared, but the bytes
        //    are valid multibyte UTF-8. Eudora-for-Windows did this constantly.
        if westernOrUndeclared,
           let u = String(data: raw, encoding: .utf8),
           u.unicodeScalars.contains(where: { $0.value > 127 }) {
            return DecodedText(text: u, charsetUsed: "utf-8",
                               note: "declared \(effective), decoded as utf-8 (mislabel repaired)")
        }

        // 2. Western single-byte / undeclared: prefer Windows-1252 over Latin-1
        //    (it renders the smart quotes / em-dashes / ellipses real Western
        //    mail puts in 0x80–0x9F), with Latin-1 as the never-fail backstop.
        if westernOrUndeclared {
            let hasHigh = raw.contains { $0 > 0x7F }
            if !hasHigh {
                let s = String(data: raw, encoding: .ascii)
                    ?? String(decoding: raw, as: UTF8.self)
                return DecodedText(text: s, charsetUsed: effective, note: "")
            }
            if let s = String(data: raw, encoding: .windowsCP1252) {
                let alreadyCP = (effective == "windows-1252" || effective == "cp1252")
                return DecodedText(text: s, charsetUsed: "windows-1252",
                                   note: alreadyCP ? "" : "declared \(effective); rendered as windows-1252")
            }
            let fallback = String(data: raw, encoding: .isoLatin1) ?? ""
            return DecodedText(text: fallback, charsetUsed: "latin-1",
                               note: "declared \(effective); windows-1252 failed, used latin-1")
        }

        // 3. Any other declared charset: honor it via the full IANA lookup.
        if let enc = encoding(for: effective), let s = String(data: raw, encoding: enc) {
            return DecodedText(text: s, charsetUsed: effective, note: "")
        }

        // 4. Never fail: Latin-1 maps every byte to *something* readable.
        let fallback = String(data: raw, encoding: .isoLatin1) ?? ""
        return DecodedText(text: fallback, charsetUsed: "latin-1(replace)",
                           note: "declared \(effective) failed; used latin-1")
    }

    /// Map an IANA charset name to a `String.Encoding`. Common names take a
    /// fast path (and pin our preferred mappings); everything else the OS knows
    /// resolves through CoreFoundation — the full ISO-8859-*, Windows-125x,
    /// Shift-JIS / EUC-JP / ISO-2022-JP, GB2312 / GBK / GB18030, Big5, KOI8-R,
    /// Mac Roman families, etc.
    public static func encoding(for charset: String) -> String.Encoding? {
        let key = charset.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "utf-8", "utf8":                    return .utf8
        case "us-ascii", "ascii":                return .ascii
        case "iso-8859-1", "latin-1", "latin1":  return .isoLatin1
        case "windows-1252", "cp1252":           return .windowsCP1252
        case "utf-16", "utf16":                  return .utf16
        default:                                 break
        }
        // General IANA → CFStringEncoding → NSStringEncoding → String.Encoding.
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return String.Encoding(rawValue: ns)
    }
}
