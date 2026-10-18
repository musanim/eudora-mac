import Foundation

/// Where a To / Cc / Bcc field may wrap: between recipients, never inside one.
///
/// The field wraps when the compose window is too narrow for one line, and an
/// address broken across lines — `Bob Smith <bob@` / `example.com>` — is hard to
/// read and easy to misjudge. So the only allowed break is at the start of a
/// recipient, which is the first non-space character after a separator.
///
/// The separator rules match `EmailAddress.splitList` exactly: a comma or
/// semicolon inside a quoted name or inside `<…>` is not a separator, and a
/// backslash in a quoted name escapes the next character. If the two ever
/// disagreed, the field would break a line in the middle of what the sender
/// treats as one recipient.
///
/// Two forms, for the two ways the field draws text:
/// - `entryStarts` for the field editor while typing, whose layout manager
///   asks, position by position, whether it may break there;
/// - `displayString` for the field at rest, drawn by ordinary string drawing,
///   which can only be steered through the characters it is given.
public enum RecipientLineBreaks {

    /// UTF-16 offsets at which a recipient begins (offset 0 excluded): the
    /// only places the line may break.
    ///
    /// UTF-16 offsets because that is what `NSLayoutManager` indexes by; but
    /// the walk is by `Character`, as `splitList`'s is, so a combining mark on
    /// a quote or comma makes it not-a-quote here exactly as it does there.
    public static func entryStarts(in text: String) -> Set<Int> {
        var starts = Set<Int>()
        var scanner = Scanner()
        var offset = 0
        for ch in text {
            defer { offset += ch.utf16.count }
            if scanner.awaitingEntry {
                if ch == " " || ch == "\t" { continue }
                starts.insert(offset)
                scanner.awaitingEntry = false
            }
            scanner.consume(ch)
        }
        return starts
    }

    /// `text` with every break opportunity inside a recipient suppressed, for
    /// drawing only — never stored or sent.
    ///
    /// A space or tab inside a recipient becomes a no-break space (same width),
    /// and a word joiner (zero width) goes between every two characters of a
    /// recipient. Spaces, hyphens and slashes are not the only places line
    /// breaking will break — it breaks between CJK ideographs, and after `)` or
    /// `?` before a letter — and the field editor's delegate refuses *every*
    /// position but a recipient's start, so anything less here would let the
    /// field wrap differently at rest than while being edited. The spaces after
    /// a separator are left alone: they are the break opportunities.
    public static func displayString(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count * 2)
        var scanner = Scanner()
        // Whether the last character written belongs to a recipient (as
        // opposed to nothing yet, or the gap after a separator).
        var previousInEntry = false
        for ch in text {
            let isSpace = ch == " " || ch == "\t"
            if scanner.awaitingEntry {
                if isSpace {
                    out.append(" ")
                    previousInEntry = false
                    continue
                }
                scanner.awaitingEntry = false
            }
            if previousInEntry { out.append("\u{2060}") }
            out.append(isSpace ? "\u{00A0}" : ch)
            previousInEntry = true
            scanner.consume(ch)
        }
        return out
    }

    /// The separator state machine, shared so the two forms can't drift.
    private struct Scanner {
        var inQuote = false
        var escaped = false
        var angle = 0
        /// Set by a top-level separator; cleared at the next recipient's first
        /// character.
        var awaitingEntry = false

        mutating func consume(_ ch: Character) {
            if escaped { escaped = false; return }
            switch ch {
            case "\\" where inQuote: escaped = true
            case "\"": inQuote.toggle()
            case "<" where !inQuote: angle += 1
            case ">" where !inQuote: if angle > 0 { angle -= 1 }
            case ",", ";":
                if !inQuote && angle == 0 { awaitingEntry = true }
            default: break
            }
        }
    }
}
