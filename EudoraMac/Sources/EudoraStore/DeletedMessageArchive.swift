import Foundation

/// A rescue copy, in the Finder's Trash, of a message Eudora is about to destroy.
///
/// **Why this exists.** Four paths in Eudora destroy mail outright rather than
/// filing it in the Trash *mailbox*: Delete PERMANENTLY, blacklisting a sender,
/// and plain Delete when the message is already in the Trash mailbox or when
/// there is no Trash mailbox at all. The first two are confirmed, and for a long
/// time that was judged enough — the reasoning being that a message you have
/// decided twice to destroy is one you will not want back. On 2026sep19 Stephen
/// wanted one back.
///
/// The other two are not confirmed and never have been, and that is deliberate:
/// deleting from the Trash mailbox is triage, and a dialog per batch would make
/// it unusable. They are also, for exactly that reason, the likeliest way to
/// lose something by accident, which is why they rescue too.
///
/// So each destroyed message is now written out as a plain text file and moved
/// to the Finder's Trash on its way out. Nothing about Eudora changes: the
/// message still leaves the mailbox, still leaves the search index, still
/// stops counting. It simply stops being unrecoverable until the Trash is
/// emptied, which is the promise every other delete in the app already makes.
///
/// **The bytes are the record exactly as it sat in the `.mbx`**, Eudora's
/// `From ???@???` separator line and all, so the file is a valid one-message
/// mbox and not merely a readable transcript. Recovering one is a matter of
/// appending it to a mailbox rather than retyping it. The extension is `.txt`
/// so that Quick Look shows it and a double-click opens it in TextEdit; `.eml`
/// would hand it to Mail.app, which is not a thing Stephen wants to happen.
public enum DeletedMessageArchive {

    /// Which command destroyed the message. It is in the file name because the
    /// two are worth telling apart when looking back: one was a decision about a
    /// message, the other a decision about a correspondent.
    public enum Reason: String {
        case deleted
        case blacklisted
    }

    /// Where a rescue copy ended up.
    public enum Destination: Equatable {
        /// In the Finder's Trash. No URL: `trashItem` does not always say where
        /// it put the file, and a guessed path is worse than none.
        case trash
        /// The Trash could not be used, and this is where the copy went instead.
        case fallback(URL)
    }

    // MARK: - naming

    /// The file name for one rescued message.
    ///
    /// Shaped for finding it again in a Trash that holds other things:
    ///
    ///     Eudora deleted 2026-09-19 14.22.05 — Fred Smith — Cheap watches.txt
    ///
    /// The constant first word is what makes a Trash search for "Eudora" find
    /// every one of them; the timestamp sorts them and matches "the ones I threw
    /// away just now"; the sender and subject are what identify the message
    /// without opening it. The timestamp is *when it was destroyed*, not the
    /// message's own date — the question being answered is "what did I just
    /// delete", and the message's own date is inside the file anyway.
    ///
    /// Periods in the time, never colons: a colon typed into a POSIX path
    /// component is shown by the Finder as a slash, which would read as a folder
    /// that isn't there.
    public static func fileName(reason: Reason, when: Date,
                                from: String, subject: String,
                                timeZone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"

        let who = clean(from, limit: 40, ifEmpty: "unknown sender")
        let what = clean(subject, limit: 70, ifEmpty: "no subject")
        let name = "Eudora \(reason.rawValue) \(stamp.string(from: when)) — \(who) — \(what)"
        return capped(name, bytes: 200) + ".txt"
    }

    /// One line of a file name: no path separators, no control characters, no
    /// runs of space, not empty.
    ///
    /// `/` and `:` both become `-`. In a POSIX path component `/` is impossible
    /// and `:` is a lie (the Finder draws it as `/`), and a subject line
    /// containing either is not unusual — "Re: 50/50" would otherwise produce a
    /// name no one could read.
    static func clean(_ raw: String, limit: Int, ifEmpty: String) -> String {
        var s = raw
        s = String(s.map { ch -> Character in
            if ch == "/" || ch == ":" { return "-" }
            // All-control, not any-control: "\r\n" is a single Character whose
            // two scalars are both Cc and must collapse to one space, while an
            // emoji joined by a zero-width joiner must survive intact.
            if ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                return " "
            }
            return ch
        })
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // A name starting with a dot is hidden, which would defeat the purpose.
        while s.first == "." { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return ifEmpty }
        if s.count > limit { s = String(s.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }

    /// Trims to a byte budget without splitting a character. macOS allows 255
    /// UTF-8 bytes in a path component; 200 leaves room for the extension and
    /// for the " 2" the Trash appends when a name is already taken.
    static func capped(_ s: String, bytes: Int) -> String {
        var out = s
        while out.utf8.count > bytes, !out.isEmpty { out.removeLast() }
        return out
    }

    // MARK: - reading the message

    /// The sender and subject to put in the file name.
    ///
    /// Read from the record's own headers rather than from the `.toc`, whose
    /// cached columns hold what Eudora chose to *display* — the Who column is
    /// the recipient in a sent mailbox and the sender in a received one — and
    /// which is a cache that can disagree with the message.
    ///
    /// Headers only, not `MIMEParser.parse`: a full parse copies the body and
    /// splits every multipart, and this wants two lines. On a select-all delete
    /// of a few thousand messages that difference is the difference between a
    /// pause and a freeze.
    ///
    /// The envelope line is stripped first. Leaving it on happens to work —
    /// `From ???@??? Fri Sep 19 14` parses as a junk header that never collides
    /// with the real `From` — but working by luck is not a thing to leave in.
    ///
    /// Decoded, because an encoded-word subject in the Trash
    /// (`=?UTF-8?B?…?=`) defeats the one job the file name has, and spam is
    /// exactly what gets blacklisted.
    public static func descriptor(for record: [UInt8]) -> (from: String, subject: String) {
        let (headerBytes, _) = MIMEParser.splitHeaderBody(Mbox.messageBytes(fromRecord: record))
        let headers = MIMEParser.parseHeaders(headerBytes)
        func first(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let rawFrom = HeaderDecoder.decode(first("From"))
        let (name, address) = OutgoingMessage.splitFrom(rawFrom)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let who = !trimmedName.isEmpty ? trimmedName
                : !trimmedAddress.isEmpty ? trimmedAddress
                : rawFrom
        return (who, HeaderDecoder.decode(first("Subject")))
    }

    // MARK: - writing them out

    /// Writes a batch of records to the Finder's Trash, one file each, and says
    /// per record what became of it.
    ///
    /// A batch rather than one call per message because the staging directory is
    /// made once, and because a partial batch needs one answer per record rather
    /// than one answer overall. `deletePermanentlySelected` can be pointed at a
    /// few thousand rows.
    ///
    /// **Nothing here throws out of the loop.** A failure on message three must
    /// not cost messages four to ten their copies — the mail has already left
    /// the mailbox by the time this is called, so every record gets its own
    /// attempt and its own answer.
    public static func rescue(records: [[UInt8]], reason: Reason, near: URL,
                              now: Date = Date()) -> [Result<Destination, Error>] {
        guard !records.isEmpty else { return [] }
        let fm = FileManager.default
        // `try?`: no staging directory is not fatal, it only means every record
        // takes the fallback path.
        let staging = try? stagingDirectory(near: near)
        defer { if let staging { try? fm.removeItem(at: staging) } }
        return records.map { record in
            Result { try rescueOne(record, reason: reason, staging: staging, now: now) }
        }
    }

    /// A temporary directory on the same volume as the mail.
    ///
    /// `trashItem` across volumes is a copy-and-delete at best and a failure at
    /// worst, and the mail tree and the home folder are not guaranteed to be the
    /// same disk.
    ///
    /// **`appropriateFor:` needs a URL that exists**, and a mailbox *base* does
    /// not: it is a name with no extension, and the files beside it are
    /// `base.mbx` and `base.toc`. Handing it the base makes the volume lookup
    /// fail and takes every rescue down with it — which would have been silent,
    /// and would have made both confirmation dialogs liars.
    static func stagingDirectory(near: URL) throws -> URL {
        let fm = FileManager.default
        let mbx = near.appendingPathExtension("mbx")
        let anchor = fm.fileExists(atPath: mbx.path) ? mbx : near.deletingLastPathComponent()
        return try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                          appropriateFor: anchor, create: true)
    }

    /// One record: into the Trash if that can be managed, into the fallback
    /// folder if not, and a thrown error only when neither worked.
    ///
    /// Every step is inside the `do`, deliberately. An earlier version had the
    /// staging write outside it, so a full disk or a read-only volume threw past
    /// the fallback entirely — the one path that could still have saved the
    /// message.
    static func rescueOne(_ record: [UInt8], reason: Reason,
                          staging: URL?, now: Date) throws -> Destination {
        let d = descriptor(for: record)
        let name = fileName(reason: reason, when: now, from: d.from, subject: d.subject)
        let data = Data(record)

        if let staging {
            do {
                let staged = staging.appendingPathComponent(name)
                try data.write(to: staged, options: .atomic)
                var landed: NSURL?
                try FileManager.default.trashItem(at: staged, resultingItemURL: &landed)
                _ = landed      // see `Destination.trash`
                return .trash
            } catch {
                // Fall through. The message is already out of the mailbox, so
                // anywhere on disk beats an error.
            }
        }
        let there = try uniqueURL(in: try fallbackDirectory(), name: name)
        try data.write(to: there, options: .atomic)
        return .fallback(there)
    }

    /// `~/Library/Application Support/Eudora/Rescued`, created on demand.
    static func fallbackDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Eudora/Rescued", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `name`, or `name 2`, `name 3`… if it is taken. The Trash does this for
    /// itself; the fallback folder has to.
    ///
    /// **Throws rather than returning a name it knows is taken.** Same sender,
    /// same subject, same second, a thousand times over is absurd — and writing
    /// atomically over an earlier rescue copy would destroy the very thing this
    /// file exists to preserve.
    static func uniqueURL(in directory: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let url = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for n in 2...999 {
            let candidate = directory.appendingPathComponent("\(stem) \(n)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
