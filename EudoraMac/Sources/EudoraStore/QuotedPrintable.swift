import Foundation

/// Minimal quoted-printable decoder for message bodies and RFC 2047 words.
public enum QuotedPrintable {
    public static func decode(_ bytes: [UInt8]) -> Data {
        var out: [UInt8] = []
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == 0x3D { // '='
                // Soft line break: =CRLF or =LF
                if i + 2 < n, bytes[i + 1] == 0x0d, bytes[i + 2] == 0x0a { i += 3; continue }
                if i + 1 < n, bytes[i + 1] == 0x0a { i += 2; continue }
                // =HH hex escape
                if i + 2 < n, let hi = hexVal(bytes[i + 1]), let lo = hexVal(bytes[i + 2]) {
                    out.append((hi << 4) | lo); i += 3; continue
                }
                out.append(b); i += 1
            } else {
                out.append(b); i += 1
            }
        }
        return Data(out)
    }

    /// RFC 2047 "Q" encoding: like quoted-printable but `_` means space.
    public static func decodeQ(_ text: String) -> Data {
        var bytes = Array(text.utf8)
        for k in 0..<bytes.count where bytes[k] == 0x5F { bytes[k] = 0x20 } // '_' -> ' '
        return decode(bytes)
    }

    static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30          // 0-9
        case 0x41...0x46: return b - 0x41 + 10      // A-F
        case 0x61...0x66: return b - 0x61 + 10      // a-f
        default: return nil
        }
    }

    // MARK: encode

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Encode UTF-8 text as quoted-printable for a message body: escapes
    /// non-printable / 8-bit bytes and `=`, preserves CRLF line breaks, and
    /// soft-wraps lines to ≤76 chars per RFC 2045.
    public static func encodeBody(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var lineLen = 0

        func emit(_ b: UInt8) { out.append(b); lineLen += 1 }
        func softWrapIfNeeded(next: Int) {
            if lineLen + next > 75 {          // leave room; 76 incl. trailing '='
                out.append(0x3D); out.append(0x0d); out.append(0x0a) // "=\r\n"
                lineLen = 0
            }
        }

        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            // Preserve hard CRLF and LF line breaks verbatim.
            if b == 0x0d, i + 1 < n, bytes[i + 1] == 0x0a {
                out.append(0x0d); out.append(0x0a); lineLen = 0; i += 2; continue
            }
            if b == 0x0a {
                out.append(0x0d); out.append(0x0a); lineLen = 0; i += 1; continue
            }

            let printable = (b >= 0x20 && b <= 0x7E && b != 0x3D)
            if printable {
                softWrapIfNeeded(next: 1)
                emit(b)
            } else {
                softWrapIfNeeded(next: 3)
                emit(0x3D)                      // '='
                emit(hexDigits[Int(b >> 4)])
                emit(hexDigits[Int(b & 0x0F)])
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
