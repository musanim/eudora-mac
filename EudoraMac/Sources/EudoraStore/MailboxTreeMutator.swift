import Foundation

/// Mutations to the mailbox *tree* — as against `MailboxMutator`, which edits
/// messages inside one mailbox: deleting an empty mailbox, and creating a
/// mailbox or folder. Each is a `descmap.pce` edit plus file work.
///
/// Safety stance, same as everywhere else that writes into the tree:
///   • `descmap.pce` is backed up once (`descmap.pce.bak`) before its first
///     mutation and rewritten atomically;
///   • the lines that stay are preserved **byte-for-byte** — the file is edited
///     as raw bytes, never re-serialized from parsed entries, so encoding
///     (Latin-1 display names), line endings, and even lines our parser skips
///     all survive untouched;
///   • the `.mbx` is the source of truth for emptiness: a stale `.toc` can
///     claim messages a compacted mailbox no longer holds, and refusing on its
///     say-so would block deleting a mailbox the list itself shows as empty.
public enum MailboxTreeMutator {

    public enum DeleteError: LocalizedError, Equatable {
        /// No descmap.pce, or no line in it names this file.
        case notFound
        /// The mailbox still holds messages.
        case notEmpty
        /// The descmap line is a folder or a system mailbox (In/Out/Junk/Trash)
        /// — neither is deletable.
        case notAMailbox
        /// A `.lck` file sits next to the mailbox: Eudora itself may have it open.
        case locked
        case ioError(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:       return "that mailbox isn't in the folder's index"
            case .notEmpty:       return "the mailbox isn't empty"
            case .notAMailbox:    return "only regular, empty mailboxes can be deleted"
            case .locked:         return "the mailbox is locked (a .lck file is next to it)"
            case .ioError(let m): return m
            }
        }
    }

    /// Delete the empty mailbox that `directory`'s `descmap.pce` lists under
    /// `filename` (the second field of its line, extension included — e.g.
    /// "Old stuff.mbx"). Removes the line and the mailbox's `.mbx`/`.toc`.
    ///
    /// Ordering: the descmap is rewritten *first*, the files removed after. A
    /// failure in between leaves orphaned files no index references — invisible
    /// and harmless — where the other order could leave an index line pointing
    /// at nothing that a crash then makes permanent. (An unlisted mailbox is
    /// recoverable by re-adding the line; Eudora treats descmap as the truth.)
    ///
    /// Any `.mbx.bak` next to the mailbox is deliberately **left on disk**: it
    /// is the backup of the mailbox's former contents, possibly the only copy,
    /// and deleting an *empty* mailbox is no reason to destroy it.
    public static func deleteEmptyMailbox(directory: URL, filename: String) throws {
        let fm = FileManager.default
        let descURL = directory.appendingPathComponent("descmap.pce")
        guard let descData = try? Data(contentsOf: descURL) else { throw DeleteError.notFound }
        guard let line = lineRange(of: filename, in: descData) else { throw DeleteError.notFound }

        // Only a regular mailbox ("M"). System mailboxes and folders keep their
        // lines no matter what the caller resolved them to.
        let lineText = String(data: descData.subdata(in: line.range), encoding: .isoLatin1) ?? ""
        let parts = lineText
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: ",")
        guard parts.count >= 3,
              DescMap.resolveType(char: parts[2], display: parts[0]) == .mailbox else {
            throw DeleteError.notAMailbox
        }

        // Same base derivation as MailStore.build: the descmap filename carries
        // the extension; the .mbx/.toc hang off the name without it.
        let base = directory.appendingPathComponent(filename).deletingPathExtension()
        if fm.fileExists(atPath: base.appendingPathExtension("lck").path) {
            throw DeleteError.locked
        }

        // Empty means: no records in the .mbx (or no .mbx at all — a dead
        // descmap line with no file behind it is deletable, not stuck). The
        // .toc is deliberately not consulted; see the type comment.
        let mbx = base.appendingPathExtension("mbx")
        if let data = try? Data(contentsOf: mbx),
           !Mbox.findRecords([UInt8](data)).isEmpty {
            throw DeleteError.notEmpty
        }

        // Cut the line out of the raw bytes and write back atomically. Every
        // other byte of the file is untouched.
        var newDesc = descData
        newDesc.removeSubrange(line.range)
        do {
            // A failed backup aborts, same as MailboxMutator's writes: mutating
            // the index with no .bak behind it is the trade this codebase
            // refuses everywhere else.
            try MailboxIO.backupOnce(descURL)
            try MailboxIO.atomicWrite(newDesc, to: descURL)
        } catch { throw DeleteError.ioError(error.localizedDescription) }

        // The files last (see the ordering note above). Failures are swallowed:
        // the mailbox may never have had a .toc, or a .mbx at all.
        try? fm.removeItem(at: mbx)
        try? fm.removeItem(at: base.appendingPathExtension("toc"))
    }

    // MARK: creating

    public enum CreateError: LocalizedError, Equatable {
        case emptyName
        /// The name contains a character that can't survive the round trip:
        /// a comma (descmap.pce is unquoted comma-separated), a character no
        /// filename can hold (the tree is shared with real Eudora on Windows),
        /// or one outside Latin-1 (descmap's encoding).
        case invalidName
        /// A mailbox, folder, or orphaned file of this name (compared
        /// case-insensitively) already exists at this level. Carries the
        /// existing name, in its own case.
        case duplicate(String)
        case ioError(String)

        public var errorDescription: String? {
            switch self {
            case .emptyName:          return "the mailbox needs a name"
            case .invalidName:        return "the name can't contain , / \\ : * ? \" < > | or characters outside Latin-1"
            case .duplicate(let d):   return "\u{201C}\(d)\u{201D} already exists here"
            case .ioError(let m):     return m
            }
        }
    }

    /// Characters no created name may contain: the comma breaks descmap.pce's
    /// unquoted format; the rest can't be filenames on Windows (where real
    /// Eudora may share this tree) or POSIX.
    static let bannedNameCharacters = CharacterSet(charactersIn: ",/\\:*?\"<>|")
        .union(.controlCharacters).union(.newlines)

    /// Create an empty mailbox at this level: a descmap.pce line plus a
    /// zero-byte `.mbx` and a header-only `.toc` — the same state
    /// `deleteEmptyMailbox` calls "empty-but-real". Returns the descmap
    /// filename ("Name.mbx"), from which callers derive ids and bases.
    ///
    /// The typed case is preserved exactly, in the display name and the
    /// filename both; only the *duplicate check* is case-insensitive.
    @discardableResult
    public static func createMailbox(directory: URL, name: String) throws -> String {
        try create(directory: directory, name: name, isFolder: false)
    }

    /// Create an empty folder: a descmap.pce line, a `Name.fol` directory, and
    /// an empty `descmap.pce` inside it, so the folder reads as a real (empty)
    /// Eudora folder immediately. Returns "Name.fol".
    @discardableResult
    public static func createFolder(directory: URL, name: String) throws -> String {
        try create(directory: directory, name: name, isFolder: true)
    }

    private static func create(directory: URL, name: String, isFolder: Bool) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CreateError.emptyName }
        guard trimmed.rangeOfCharacter(from: bannedNameCharacters) == nil else {
            throw CreateError.invalidName
        }
        let filename = trimmed + (isFolder ? ".fol" : ".mbx")
        // Latin-1 encodability is part of *validation*, checked before any
        // file exists — descmap.pce can't hold what Latin-1 can't spell, and
        // discovering that at the append would strand freshly created files.
        guard let lineBytes = "\(trimmed),\(filename),\(isFolder ? "F" : "M"),N"
            .data(using: .isoLatin1) else { throw CreateError.invalidName }

        // Duplicates, case-insensitively, against everything already at this
        // level: display names, filename stems, and — because an orphaned file
        // the index forgot must not be silently adopted or clobbered — the
        // filesystem itself.
        let lower = trimmed.lowercased()
        for e in DescMap.read(directory: directory) {
            let stem = (e.filename as NSString).deletingPathExtension
            if e.display.lowercased() == lower || stem.lowercased() == lower {
                throw CreateError.duplicate(e.display)
            }
        }
        let fm = FileManager.default
        for ext in ["mbx", "toc", "fol"] {
            if fm.fileExists(atPath: directory.appendingPathComponent("\(trimmed).\(ext)").path) {
                throw CreateError.duplicate(trimmed)
            }
        }

        // The files first, the index line after — the mirror of delete's
        // ordering, for the mirror reason: a failure in between leaves
        // orphaned files no index references (invisible, harmless), never an
        // index line pointing at files that don't exist.
        do {
            if isFolder {
                let dir = directory.appendingPathComponent(filename, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                try Data().write(to: dir.appendingPathComponent("descmap.pce"))
            } else {
                let base = directory.appendingPathComponent(trimmed)
                try Data().write(to: base.appendingPathExtension("mbx"))
                try TocWriter.data(entries: []).write(to: base.appendingPathExtension("toc"))
            }
        } catch { throw CreateError.ioError(error.localizedDescription) }

        // Append the line in the file's own dialect: its line terminator is
        // detected, not assumed, and a final line missing its terminator gets
        // one first so the append can't merge into it. Everything already in
        // the file is preserved byte-for-byte.
        let descURL = directory.appendingPathComponent("descmap.pce")
        let existing = (try? Data(contentsOf: descURL)) ?? Data()
        let terminator = lineTerminator(of: existing)

        var newDesc = existing
        if let last = existing.last, last != 0x0A { newDesc.append(contentsOf: terminator) }
        newDesc.append(lineBytes)
        newDesc.append(contentsOf: terminator)
        do {
            try MailboxIO.backupOnce(descURL)
            try MailboxIO.atomicWrite(newDesc, to: descURL)
        } catch { throw CreateError.ioError(error.localizedDescription) }
        return filename
    }

    // MARK: system mailboxes

    /// The four mailboxes every Eudora tree must hold, in Eudora's order.
    /// They can't be deleted (`deleteEmptyMailbox` refuses their "S" lines),
    /// and `ensureSystemMailboxes` recreates any that are missing.
    public static let systemRoles: [(type: MailboxType, name: String)] = [
        (.inbox, "In"), (.outbox, "Out"), (.junk, "Junk"), (.trash, "Trash"),
    ]

    /// Make sure In/Out/Junk/Trash all exist at the tree's root, creating any
    /// that don't — including, on a genuinely fresh directory, the tree's
    /// first `descmap.pce`. Returns the display names created, in Eudora's
    /// order; empty means the tree was already complete **and nothing was
    /// touched at all** (the common case, on every open).
    ///
    /// No existing *mailbox* is ever overwritten (the one exception: a stray
    /// `.toc` with no `.mbx` behind it names nothing real and gets replaced).
    /// An orphaned `In.mbx` full of real mail whose index line went missing
    /// is *adopted* — its line comes back, its bytes stay — and a role whose
    /// canonical name is already
    /// taken by an ordinary mailbox (an "M" line named "In") is skipped
    /// rather than doubled: a second line with the same filename would be
    /// worse than a missing role.
    @discardableResult
    public static func ensureSystemMailboxes(root: URL) throws -> [String] {
        let entries = DescMap.read(directory: root)
        let presentTypes = Set(entries.map(\.type))
        let takenNames = Set(entries.flatMap {
            [$0.display.lowercased(), ($0.filename as NSString).deletingPathExtension.lowercased()]
        })

        var missing: [String] = []
        for role in systemRoles where !presentTypes.contains(role.type) {
            guard !takenNames.contains(role.name.lowercased()) else { continue }
            missing.append(role.name)
        }
        guard !missing.isEmpty else { return [] }

        // Files first, index after — same ordering and reasoning as `create`.
        // A role whose .mbx already exists on disk gets no new files (that is
        // the adoption case); its .toc, present or not, is left for the
        // reader to reconcile.
        let fm = FileManager.default
        do {
            for name in missing {
                let base = root.appendingPathComponent(name)
                let mbx = base.appendingPathExtension("mbx")
                guard !fm.fileExists(atPath: mbx.path) else { continue }
                try Data().write(to: mbx)
                try TocWriter.data(entries: []).write(to: base.appendingPathExtension("toc"))
            }
        } catch { throw CreateError.ioError(error.localizedDescription) }

        let descURL = root.appendingPathComponent("descmap.pce")
        let existing = (try? Data(contentsOf: descURL)) ?? Data()
        let terminator = lineTerminator(of: existing)
        var newDesc = existing
        if let last = existing.last, last != 0x0A { newDesc.append(contentsOf: terminator) }
        for name in missing {
            newDesc.append(Data("\(name),\(name).mbx,S,N".utf8))   // pure ASCII: Latin-1 safe
            newDesc.append(contentsOf: terminator)
        }
        do {
            try MailboxIO.backupOnce(descURL)
            try MailboxIO.atomicWrite(newDesc, to: descURL)
        } catch { throw CreateError.ioError(error.localizedDescription) }
        return missing
    }

    /// The file's own line-ending convention: CRLF if its first LF follows a
    /// CR, bare LF if not, and Eudora's native CRLF for a file with no lines
    /// yet to disagree.
    static func lineTerminator(of data: Data) -> [UInt8] {
        guard let lf = data.firstIndex(of: 0x0A) else { return [0x0D, 0x0A] }
        if lf > data.startIndex, data[data.index(before: lf)] == 0x0D { return [0x0D, 0x0A] }
        return [0x0A]
    }

    /// Where the descmap line whose second field equals `filename` sits in the
    /// raw bytes — terminator included, so removing the range removes the whole
    /// line. Lines end in LF or CRLF; a final line without a terminator is
    /// still matched.
    struct DescLine { let range: Range<Data.Index> }

    static func lineRange(of filename: String, in data: Data) -> DescLine? {
        var start = data.startIndex
        while start < data.endIndex {
            // Find the LF (or end of file); the line's bytes run to just before
            // it, its *range* to just after.
            var lf = start
            while lf < data.endIndex, data[lf] != 0x0A { lf = data.index(after: lf) }
            let rangeEnd = lf < data.endIndex ? data.index(after: lf) : lf

            // Trim a trailing CR from the text, not from the range.
            var textEnd = lf
            if textEnd > start, data[data.index(before: textEnd)] == 0x0D {
                textEnd = data.index(before: textEnd)
            }
            if let text = String(data: data.subdata(in: start..<textEnd), encoding: .isoLatin1) {
                let parts = text.components(separatedBy: ",")
                if parts.count >= 3, parts[1] == filename {
                    return DescLine(range: start..<rangeEnd)
                }
            }
            start = rangeEnd
        }
        return nil
    }
}
