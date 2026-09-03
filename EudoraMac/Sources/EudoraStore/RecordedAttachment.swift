import Foundation

/// Attachments Eudora recorded in *my own* copy of a message I sent.
///
/// Windows Eudora did not keep the bytes of a file it sent. It encoded them onto
/// the wire and, in the copy it filed in Out, wrote only a header naming where
/// the file had been on the sending machine:
///
///     X-Attachments: \\Mac\Home\Documents\photo.jpg; C:\DEV\TUNING.ZIP;
///
/// Semicolon-separated with a trailing semicolon, and usually present but empty.
/// The header does not travel — `phaseX/In.mbx` contains not one — so finding it
/// means "this is my sent copy, and these are the files I attached."
///
/// This is the outgoing counterpart to `DetachedAttachment`, and it is separate
/// from it because the two say different things about where the bytes are. A
/// detached attachment was written into the `Attachments` folder and may still
/// be sitting there; a recorded one was **never in the mail tree at all**. It was
/// an arbitrary file on the sending machine.
///
/// **The name is the reliable part, not the path.** Most of these paths do name
/// a real place, but the ones that don't are the ones you meet when a file goes
/// missing: a file dragged in from the Mac is recorded at the throwaway copy
/// Parallels made of it, so the path names a directory macOS has since purged
/// while the file itself sits untouched where it always was. See
/// `pathRecordsOrigin`. So the filename is what this exists to surface — it is
/// exact, it is what a search matches, and it is what actually found the file
/// the first time this was needed.
///
/// **Why this matters more than its obscurity suggests.** Measured over
/// `phaseX/*.mbx`: 79,813 messages carry the header, 6,102 of them non-empty,
/// naming 8,309 files. Only 187 of those also kept a MIME attachment part and 10
/// a detached-attachment marker — so **5,905 messages had an attachment and, until
/// this type existed, displayed as though they never did**. That silence is what
/// cost an afternoon reconstructing whether a PDF had actually been sent to a
/// correspondent in March 2026. It had; only the local record of it was mute.
public enum RecordedAttachment {

    /// Eudora's header. Not an RFC header, and not one anyone else writes.
    public static let headerName = "X-Attachments"

    /// The recorded paths, in the order Eudora wrote them. Empty for the common
    /// case of an absent or blank header.
    ///
    /// Splitting on `;` is Eudora's own format, and it provides no escape for a
    /// semicolon inside a filename. A name containing one would split into two
    /// wrong rows — accepted, because the alternative is guessing, and the cost
    /// is a garbled name rather than a wrong file: nothing here is resolved to
    /// anything on disk.
    public static func recordedPaths(inHeaderValue value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func recordedPaths(in message: MIMEPart) -> [String] {
        recordedPaths(inHeaderValue: message.header(headerName))
    }

    /// Whether the header names at least one file.
    ///
    /// Deliberately not `!recordedPaths(...).isEmpty`: this one is called once
    /// per message while the list is being built, and it answers from the header
    /// string without splitting or allocating. The two agree by construction —
    /// both treat a value of only semicolons and whitespace as empty.
    public static func isPresent(inHeaderValue value: String?) -> Bool {
        guard let value else { return false }
        return value.contains { $0 != ";" && !$0.isWhitespace }
    }

    /// The recorded attachments as display rows, sharing `LocatedAttachment` with
    /// the detached ones so the preview has a single list to draw.
    ///
    /// `url` is set only when the recorded path is already a POSIX path and a
    /// file is sitting at exactly it. Both halves of that are load-bearing, and
    /// the two things this still refuses to do are the reasons why:
    ///
    /// - **The `Attachments` folder is not searched, and neither is anywhere
    ///   else.** That folder holds what Eudora detached from *received* mail. A
    ///   name match there would be a coincidence between someone else's
    ///   attachment and mine — exactly the wrong-file failure
    ///   `AttachmentLocator`'s exact-match rule exists to prevent, and worse
    ///   here, because the row would look authoritative.
    /// - **A Windows path is not translated to a Mac path.** It reaches us
    ///   through whichever share mapping was in use at the time, and `phaseX`
    ///   holds at least four: `\\Mac\Home`, `\\Mac\AllFiles`, `\\psf\Host`, and
    ///   plain drive letters (`C:`, `Y:`) from the pre-Parallels years. Inferring
    ///   the mapping from the prefix would be a guess that sometimes lands on a
    ///   real, different file. So a path that isn't already POSIX is never
    ///   resolved — `hasPrefix("/")` is the whole test, and it also means a
    ///   Windows path never costs a filesystem call.
    ///
    /// What changed is that some of these paths are now POSIX. `eudora-relink`
    /// wrote verified locations into 320 messages whose recorded path had been a
    /// purged Parallels staging folder (see `RecordedAttachmentRelink`), so for
    /// those the file genuinely is where the header says. Resolving one is a
    /// statement of fact about an exact path, not a search — which is why it does
    /// not reopen either refusal above.
    public static func located(in message: MIMEPart) -> [LocatedAttachment] {
        recordedPaths(in: message).map {
            LocatedAttachment(filename: displayName(fromRecordedPath: $0),
                              recordedPath: $0,
                              url: fileIfPresent(at: $0),
                              origin: .recordedOnSend)
        }
    }

    /// The file at exactly this recorded path, or nil.
    ///
    /// No inference of any kind: a path that doesn't begin `/` is not a Mac path
    /// and is refused without touching the disk, and a POSIX path is checked
    /// where it points and nowhere else.
    public static func fileIfPresent(at path: String) -> URL? {
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Whether the recorded path says anything about where the file came from.
    ///
    /// It usually does, and sometimes it is a lie of omission. Dragging a file
    /// from the Mac into Windows Eudora never hands Eudora the file's path:
    /// Parallels copies the file into a fresh per-drag folder under the Mac's
    /// `$TMPDIR` and gives Windows a path to *that*, through the `\\Mac\AllFiles`
    /// share:
    ///
    ///     \\Mac\AllFiles\private\var\folders\r_\…\T\<UUID>\StephenChatGPT_morality.pdf
    ///
    /// So the path is the transport, not the origin. The real file can be sitting
    /// untouched on the Desktop while this names a copy macOS purged days later —
    /// which is exactly what happened to the message that prompted all of this.
    ///
    /// Measured over `phaseX`'s 8,320 recorded paths: **all 653 `\\Mac\AllFiles`
    /// paths are of this shape and not one names a real location**, and 43 more
    /// staging paths sit under Windows `Temp` folders. The other 7,624 do record
    /// where the file was.
    ///
    /// Worth telling apart because the two deserve opposite advice — "look here"
    /// against "the name is all you have". A false positive (a folder the user
    /// really did call `Temp`) costs a sentence of wording, never a lost path:
    /// the recorded text is shown either way.
    public static func pathRecordsOrigin(_ path: String) -> Bool {
        let lower = path.lowercased()
        return !stagingSegments.contains { lower.contains($0) }
    }

    /// Path fragments that mean "a copy made to hand the file over", not a place
    /// the user put anything. Matched with the separators attached so a file
    /// merely *named* `temp.doc`, or a folder called `Template`, doesn't match.
    private static let stagingSegments = [
        #"\private\var\folders\"#,      // macOS $TMPDIR, via Parallels
        #"\var\folders\"#,
        #"\appdata\local\temp\"#,       // Windows, modern
        #"\local settings\temp\"#,      // Windows, pre-Vista
        #"\temp\"#,
        #"\tmp\"#,
    ]

    /// The name to show for one recorded entry.
    ///
    /// `DetachedAttachment.filename(fromRecordedPath:)` does the path work, but a
    /// handful of the oldest entries are not paths at all. Mac Eudora, before the
    /// Windows years, wrote the attachment's *name and encoding* instead:
    ///
    ///     X-Attachments: "USA28XA1.ZIP" (type: uuencode-datafork)
    ///
    /// Eight of these in `phaseX` — 0.13% of the non-empty headers, so not worth
    /// a parser, but worth two lines: without them the row's name is the whole
    /// string, quotes and parenthetical included, and the icon is chosen from a
    /// "file extension" of `uuencode-datafork)`. The trailing parenthetical is
    /// dropped and the quotes stripped; `recordedPath` still carries the original
    /// text, so the tooltip loses nothing.
    ///
    /// Public for the search indexer, which wants the names without the
    /// filesystem probe `located(in:)` makes.
    public static func displayName(fromRecordedPath path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(")"), let open = s.range(of: " (type:", options: .backwards) {
            s = String(s[s.startIndex..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return DetachedAttachment.filename(fromRecordedPath: s)
    }
}
