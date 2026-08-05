import Foundation

/// Addresses waiting to be pasted into Stephen's ISP-side blocklist.
///
/// **Why this is a value in the app and not a file on disk.** It used to be
/// `~/email_blacklist.txt`: blacklisting a sender appended a line and opened the
/// file in TextEdit. That put two editors on one file. Blacklist a second sender
/// while TextEdit still has the first open with unsaved edits — which is exactly
/// what happens, because the drain is edit-then-cut-then-save — and the app
/// writes behind TextEdit's back. TextEdit then sees a document that is both
/// modified and stale, and refuses to save rather than pick a winner. There is no
/// version of "app appends to a file a person is editing" that doesn't have that
/// race; the fix is to stop having two editors.
///
/// Deliberately **free text**, not a list of parsed addresses. The whole point of
/// the drain is that Stephen edits it — most often generalising
/// `someone@spam.example` to the whole of `spam.example` — and a structured
/// editor would fight that. Lines are only interpreted for counting and for the
/// duplicate check.
public struct BlacklistQueue: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String = "") { self.text = text }

    /// Non-empty lines, trimmed. What `count` counts and `add` checks against.
    public var entries: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Append an address unless it's already listed.
    ///
    /// Case-insensitive, because a duplicate differing only in case is still a
    /// duplicate to every mail system that will read this. Returns whether it was
    /// added, so a caller can say "already on your list" rather than silently
    /// doing nothing — blacklisting the same sender twice is a thing that happens
    /// when the same spammer writes twice.
    ///
    /// Does **not** match a bare domain against an address inside it: if Stephen
    /// has generalised a line to `spam.example`, adding `new@spam.example` still
    /// appends. Guessing that the domain line covers it would need this to know
    /// what his ISP does with each line, which it doesn't.
    @discardableResult
    public mutating func add(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard !entries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += trimmed + "\n"
        return true
    }

    /// The text to hand to the pasteboard: entries only, one per line, no blank
    /// lines or stray indentation, and a trailing newline so a paste into a
    /// web form's textarea doesn't join the last address to whatever follows.
    public var pasteboardText: String {
        entries.isEmpty ? "" : entries.joined(separator: "\n") + "\n"
    }

    public mutating func clear() { text = "" }
}
