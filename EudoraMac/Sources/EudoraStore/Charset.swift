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
        let dec = (declared ?? "us-ascii").lowercased()

        var utf8Text: String?
        var looksUTF8 = false
        if let u = String(data: raw, encoding: .utf8) {
            utf8Text = u
            looksUTF8 = u.unicodeScalars.contains { $0.value > 127 }
        }

        if singleByte.contains(dec), looksUTF8, let u = utf8Text {
            return DecodedText(text: u, charsetUsed: "utf-8",
                               note: "declared \(dec), decoded as utf-8 (mislabel repaired)")
        }
        if let enc = encoding(for: dec), let s = String(data: raw, encoding: enc) {
            return DecodedText(text: s, charsetUsed: dec, note: "")
        }
        let fallback = String(data: raw, encoding: .isoLatin1) ?? ""
        return DecodedText(text: fallback, charsetUsed: "latin-1(replace)",
                           note: "declared \(dec) failed")
    }

    public static func encoding(for charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8":                    return .utf8
        case "us-ascii", "ascii":                return .ascii
        case "iso-8859-1", "latin-1", "latin1":  return .isoLatin1
        case "windows-1252", "cp1252":           return .windowsCP1252
        case "utf-16", "utf16":                  return .utf16
        default:                                 return nil
        }
    }
}
