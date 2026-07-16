import Foundation

/// Minimal RFC 2047 decoder for `=?charset?B/Q?text?=` encoded words in header
/// values (Subject, From display names, etc.). Plain headers pass through.
public enum HeaderDecoder {
    public static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }

        var result = ""
        var remaining = Substring(value)

        while let start = remaining.range(of: "=?") {
            result += remaining[remaining.startIndex..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]

            guard let end = afterStart.range(of: "?=") else {
                result += remaining[start.lowerBound...]
                remaining = Substring("")
                break
            }

            let token = afterStart[afterStart.startIndex..<end.lowerBound]
            let comps = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if comps.count >= 3,
               let decoded = decodeWord(charset: String(comps[0]),
                                        enc: String(comps[1]).uppercased(),
                                        text: String(comps[2])) {
                result += decoded
            } else {
                result += "=?\(token)?="
            }
            remaining = afterStart[end.upperBound...]
        }
        result += remaining
        return result
    }

    static func decodeWord(charset: String, enc: String, text: String) -> String? {
        let data: Data?
        switch enc {
        case "B": data = Data(base64Encoded: text)
        case "Q": data = QuotedPrintable.decodeQ(text)
        default:  return nil
        }
        guard let d = data, let e = CharsetDecoder.encoding(for: charset) else { return nil }
        return String(data: d, encoding: e)
    }
}
