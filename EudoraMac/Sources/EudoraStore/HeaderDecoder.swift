import Foundation

/// Minimal RFC 2047 decoder for `=?charset?B/Q?text?=` encoded words in header
/// values (Subject, From display names, etc.). Plain headers pass through.
public enum HeaderDecoder {
    public static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }

        var result = ""
        var remaining = Substring(value)
        // RFC 2047 §6.2: whitespace *separating two adjacent encoded-words* is
        // an artefact of header folding and must be discarded when displaying.
        // A long subject gets split mid-word — `...respo?= =?UTF-8?Q?nse...` —
        // and keeping the space renders it "developer respo nse".
        var previousWasEncodedWord = false

        while let start = remaining.range(of: "=?") {
            let gap = remaining[remaining.startIndex..<start.lowerBound]
            let isFoldArtefact = previousWasEncodedWord
                && !gap.isEmpty
                // Scalars, not Characters: "\r\n" is a *single* Character in
                // Swift, so a Character-wise comparison against "\r" and "\n"
                // silently fails on exactly the CRLF fold this exists to handle.
                && gap.unicodeScalars.allSatisfy {
                    $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
                }
            if !isFoldArtefact { result += gap }
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
                previousWasEncodedWord = true
            } else {
                // Left verbatim, so it is ordinary text and the whitespace after
                // it is real.
                result += "=?\(token)?="
                previousWasEncodedWord = false
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
