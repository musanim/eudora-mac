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

    /// Delete an *empty* folder that `directory`'s descmap lists under `filename`
    /// (e.g. "Projects.fol"): remove the line, then the `.fol` directory.
    ///
    /// Empty means its own `descmap.pce` lists nothing **and** no `.mbx`/`.fol`
    /// sit inside it — a folder holding an orphaned mailbox (mail the index
    /// forgot) or a subfolder is refused, never destroyed. Same ordering as
    /// `deleteEmptyMailbox`: index first, files after.
    public static func deleteEmptyFolder(directory: URL, filename: String) throws {
        let fm = FileManager.default
        let descURL = directory.appendingPathComponent("descmap.pce")
        guard let descData = try? Data(contentsOf: descURL) else { throw DeleteError.notFound }
        guard let line = lineRange(of: filename, in: descData) else { throw DeleteError.notFound }

        let lineText = String(data: descData.subdata(in: line.range), encoding: .isoLatin1) ?? ""
        let parts = lineText.trimmingCharacters(in: .newlines).components(separatedBy: ",")
        guard parts.count >= 3,
              DescMap.resolveType(char: parts[2], display: parts[0]) == .folder else {
            throw DeleteError.notAMailbox
        }

        let folderDir = directory.appendingPathComponent(filename, isDirectory: true)
        guard DescMap.read(directory: folderDir).isEmpty else { throw DeleteError.notEmpty }
        if let names = try? fm.contentsOfDirectory(atPath: folderDir.path) {
            for n in names where ["mbx", "fol"].contains((n as NSString).pathExtension.lowercased()) {
                throw DeleteError.notEmpty
            }
        }

        var newDesc = descData
        newDesc.removeSubrange(line.range)
        do {
            try MailboxIO.backupOnce(descURL)
            try MailboxIO.atomicWrite(newDesc, to: descURL)
        } catch { throw DeleteError.ioError(error.localizedDescription) }

        try? fm.removeItem(at: folderDir)
    }

    // MARK: reordering

    public enum MoveDirection { case up, down }

    public enum MoveError: LocalizedError, Equatable {
        /// No descmap.pce, or no line in it names this file.
        case notFound
        /// A system mailbox (In/Out/Junk/Trash) — pinned, never reordered.
        case notMovable
        /// No movable neighbour on that side — either the end of the list, or a
        /// pinned system mailbox.
        case atBoundary
        case ioError(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:       return "that item isn't in the folder's index"
            case .notMovable:     return "the standard mailboxes stay put"
            case .atBoundary:     return "there's nothing it can swap with on that side"
            case .ioError(let m): return m
            }
        }
    }

    /// One descmap line's spans and role, for reordering.
    struct Line { let full: Range<Data.Index>; let text: Range<Data.Index>; let group: Group }

    /// The reorder group a line belongs to.
    ///
    /// Only `.system` is special now: In/Out/Junk/Trash are pinned and never
    /// swap, which is what keeps them as a block at the top of the sidebar.
    /// Everything below them reorders freely — a mailbox may swap with a folder
    /// and vice versa.
    ///
    /// **This used to also keep mailboxes above folders**, on the reasoning that
    /// it preserved the grouping Eudora 7 wrote without anyone enforcing it. It
    /// was a restriction nobody asked for, and it had a sharp edge: `create`
    /// appends to `descmap.pce`, so a newly made top-level mailbox lands after
    /// every folder and then could not be moved up past them — Move Up was
    /// greyed out with no way to reach anything. Ordinary use hit that within a
    /// day of anyone creating a mailbox at the top level.
    ///
    /// Nothing else depended on the grouping: `MailStore.build` walks
    /// `descmap.pce` in file order and does not sort, so the sidebar has always
    /// simply shown whatever order the file holds.
    enum Group: Equatable { case system, mailbox, folder }

    /// Move a mailbox or folder one place up or down by swapping its
    /// `descmap.pce` line with its neighbour. Mailboxes and folders intermix
    /// freely; only the system mailboxes are pinned. The swapped lines keep their
    /// exact text bytes (display name, filename, type, unread flag); only line
    /// terminators are normalised to the file's dialect, as `create` already
    /// does. Everything else in the file is untouched.
    ///
    /// - Throws: `.atBoundary` when there is no neighbour on that side, or the
    ///   neighbour is a system mailbox — which is exactly when the menu greys the
    ///   item out.
    public static func moveEntry(directory: URL, filename: String,
                                 direction: MoveDirection) throws {
        let descURL = directory.appendingPathComponent("descmap.pce")
        guard let data = try? Data(contentsOf: descURL) else { throw MoveError.notFound }
        let lines = descLines(in: data)
        guard let i = lines.firstIndex(where: { lineFilename($0, in: data) == filename }) else {
            throw MoveError.notFound
        }
        guard lines[i].group != .system else { throw MoveError.notMovable }

        // The lower of the two positions to swap. Up swaps (i-1, i); down (i, i+1).
        // The nearest MOVABLE neighbour in that direction, stepping over any
        // system lines in between rather than stopping at them.
        //
        // Skipping matters because system lines are not reliably at the top of
        // the file. `ensureSystemMailboxes` appends a missing role — Junk, most
        // often, since it postdates most Eudora trees — so a tree can easily
        // read In, Out, …user's mailboxes…, Junk. Anything created after that
        // lands below Junk, and a rule that stopped at the adjacent line would
        // leave it with a system line above and nothing below: both move
        // commands dead, permanently, and the blocking entry *invisible*,
        // because the sidebar hides Junk by default.
        //
        // Nothing is lost by skipping. The sidebar hoists system rows into their
        // own block above the divider (`MailboxTree.systemMailboxes`) whatever
        // order the file is in, so file-adjacency was never what kept them
        // together — and the splice below copies the bytes *between* the two
        // swapped lines verbatim, so an intervening system line stays exactly
        // where it was. What the user sees is the entry moving one place among
        // the entries they can actually see.
        let step = (direction == .up) ? -1 : 1
        var j = i + step
        while j >= 0, j < lines.count, lines[j].group == .system { j += step }
        guard j >= 0, j < lines.count else { throw MoveError.atBoundary }

        // Ordered by position, so the splice below always writes earlier-first.
        let (a, b) = i < j ? (lines[i], lines[j]) : (lines[j], lines[i])
        let term = lineTerminator(of: data)
        var out = Data()
        out.append(data.subdata(in: data.startIndex..<a.full.lowerBound))
        out.append(data.subdata(in: b.text))      // b's text, then…
        out.append(contentsOf: term)
        // Any bytes between the two entries — blank lines `descLines` skipped —
        // are preserved in place rather than dropped with the replaced span, so
        // the file stays byte-for-byte but for the swap. (Real Eudora writes no
        // interior blanks, but the promise everywhere else is to keep them.)
        out.append(data.subdata(in: a.full.upperBound..<b.full.lowerBound))
        out.append(data.subdata(in: a.text))      // …a's text — the swap
        out.append(contentsOf: term)
        out.append(data.subdata(in: b.full.upperBound..<data.endIndex))

        do {
            try MailboxIO.backupOnce(descURL)
            try MailboxIO.atomicWrite(out, to: descURL)
        } catch { throw MoveError.ioError(error.localizedDescription) }
    }

    /// Every descmap line, in file order, with its byte spans and group.
    static func descLines(in data: Data) -> [Line] {
        var out: [Line] = []
        var start = data.startIndex
        while start < data.endIndex {
            var lf = start
            while lf < data.endIndex, data[lf] != 0x0A { lf = data.index(after: lf) }
            let rangeEnd = lf < data.endIndex ? data.index(after: lf) : lf
            var textEnd = lf
            if textEnd > start, data[data.index(before: textEnd)] == 0x0D {
                textEnd = data.index(before: textEnd)
            }
            // Skip blank lines — they carry no entry. `moveEntry` preserves the
            // bytes between the two lines it swaps, so a skipped blank between
            // them survives rather than being dropped with the replaced span.
            if textEnd > start,
               let text = String(data: data.subdata(in: start..<textEnd), encoding: .isoLatin1) {
                let parts = text.components(separatedBy: ",")
                if parts.count >= 3 {
                    let type = DescMap.resolveType(char: parts[2], display: parts[0])
                    let group: Group = type == .folder ? .folder
                        : type == .mailbox ? .mailbox : .system
                    out.append(Line(full: start..<rangeEnd, text: start..<textEnd, group: group))
                }
            }
            start = rangeEnd
        }
        return out
    }

    private static func lineFilename(_ line: Line, in data: Data) -> String? {
        guard let text = String(data: data.subdata(in: line.text), encoding: .isoLatin1) else { return nil }
        let parts = text.components(separatedBy: ",")
        return parts.count >= 2 ? parts[1] : nil
    }

    // MARK: moving into a group

    public enum MoveIntoError: LocalizedError, Equatable {
        /// No source descmap.pce, or no line names this file.
        case notFound
        /// A system mailbox (In/Out/Junk/Trash) — pinned, never moved.
        case notMovable
        /// A `.lck` file sits next to the mailbox: Eudora may have it open.
        case locked
        /// A folder can't be moved into itself or one of its own descendants.
        case intoDescendant
        /// The destination already holds an item of this name (display or
        /// filename, case-insensitive). Carries the clashing name.
        case duplicate(String)
        case ioError(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:         return "that item isn't in the folder's index"
            case .notMovable:       return "the standard mailboxes stay put"
            case .locked:           return "the mailbox is locked (a .lck file is next to it)"
            case .intoDescendant:   return "a folder can't be moved inside itself"
            case .duplicate(let d): return "\u{201C}\(d)\u{201D} already exists there"
            case .ioError(let m):   return m
            }
        }
    }

    /// Move the mailbox or folder `sourceDir`'s descmap lists under `filename`
    /// into `destDir` — another folder's directory, or the tree root. Moves the
    /// files (a `.mbx` with its `.toc`/`.mbx.bak`; a folder's whole `.fol`
    /// directory) and edits both `descmap.pce` files, keeping the moved line's
    /// bytes exactly (display name, filename, type, unread flag).
    ///
    /// **Ordering: never a dangling index line.** The source line is removed
    /// *before* the files move, and the destination line is added only *after*
    /// they arrive — so at no instant does a descmap line point at a file that
    /// isn't there. The one transient state a crash could leave is orphaned
    /// files no line references (invisible, recoverable), the failure mode this
    /// codebase prefers everywhere. A file-move or destination-write failure is
    /// rolled back so nothing is lost visibly.
    /// - Returns: `true` if it moved, `false` if the item was already in `destDir`
    ///   (a no-op, so the caller can skip a "Moved" banner).
    @discardableResult
    public static func moveInto(filename: String, from sourceDir: URL, to destDir: URL) throws -> Bool {
        // Already there: a no-op, not an error.
        if sourceDir.standardizedFileURL == destDir.standardizedFileURL { return false }

        let srcDescURL = sourceDir.appendingPathComponent("descmap.pce")
        guard let srcData = try? Data(contentsOf: srcDescURL) else { throw MoveIntoError.notFound }
        let srcLines = descLines(in: srcData)
        guard let line = srcLines.first(where: { lineFilename($0, in: srcData) == filename }) else {
            throw MoveIntoError.notFound
        }
        guard line.group != .system else { throw MoveIntoError.notMovable }
        let isFolder = line.group == .folder

        // The exact line bytes, re-inserted verbatim at the destination.
        let lineTextBytes = srcData.subdata(in: line.text)
        let lineText = String(data: lineTextBytes, encoding: .isoLatin1) ?? ""
        let display = lineText.components(separatedBy: ",").first ?? ""
        let stem = (filename as NSString).deletingPathExtension

        let fm = FileManager.default

        // A locked mailbox stays put (folders have no lock file).
        if !isFolder,
           fm.fileExists(atPath: sourceDir.appendingPathComponent("\(stem).lck").path) {
            throw MoveIntoError.locked
        }

        // A folder can't land inside its own subtree.
        if isFolder {
            let folderDir = sourceDir.appendingPathComponent(filename, isDirectory: true)
                .standardizedFileURL
            let dest = destDir.standardizedFileURL
            if dest == folderDir || dest.path.hasPrefix(folderDir.path + "/") {
                throw MoveIntoError.intoDescendant
            }
        }

        // Name clash at the destination — on the display name (visual) or the
        // filename stem (physical: two same-named files in one directory would
        // collide), plus the filesystem for an orphan the index forgot.
        let displayLower = display.trimmingCharacters(in: .whitespaces).lowercased()
        let stemLower = stem.lowercased()
        for e in DescMap.read(directory: destDir) {
            let eStem = (e.filename as NSString).deletingPathExtension.lowercased()
            if e.display.lowercased() == displayLower || eStem == stemLower {
                throw MoveIntoError.duplicate(e.display)
            }
        }
        for ext in ["mbx", "toc", "fol", "mbx.bak", "lck"] {
            if fm.fileExists(atPath: destDir.appendingPathComponent("\(stem).\(ext)").path) {
                throw MoveIntoError.duplicate(display.isEmpty ? stem : display)
            }
        }

        // 1) Remove the source line (backup + atomic).
        var newSrc = srcData
        newSrc.removeSubrange(line.full)
        do {
            try MailboxIO.backupOnce(srcDescURL)
            try MailboxIO.atomicWrite(newSrc, to: srcDescURL)
        } catch { throw MoveIntoError.ioError(error.localizedDescription) }

        // 2) Move the files. On failure, restore the source line.
        let moves: [(from: URL, to: URL)]
        if isFolder {
            moves = [(sourceDir.appendingPathComponent(filename, isDirectory: true),
                      destDir.appendingPathComponent(filename, isDirectory: true))]
        } else {
            moves = ["mbx", "toc", "mbx.bak"].map {
                (sourceDir.appendingPathComponent("\(stem).\($0)"),
                 destDir.appendingPathComponent("\(stem).\($0)"))
            }
        }
        var done: [(from: URL, to: URL)] = []
        do {
            for m in moves where fm.fileExists(atPath: m.from.path) {
                try fm.moveItem(at: m.from, to: m.to)
                done.append(m)
            }
        } catch {
            for m in done { try? fm.moveItem(at: m.to, to: m.from) }   // undo partial move
            try? MailboxIO.atomicWrite(srcData, to: srcDescURL)        // restore the line
            throw MoveIntoError.ioError(error.localizedDescription)
        }

        // 3) Append the line to the destination descmap (backup + atomic). On
        //    failure, move the files home and restore the source line.
        let destDescURL = destDir.appendingPathComponent("descmap.pce")
        let destExisting = (try? Data(contentsOf: destDescURL)) ?? Data()
        let term = lineTerminator(of: destExisting)
        var newDest = destExisting
        if let last = destExisting.last, last != 0x0A { newDest.append(contentsOf: term) }
        newDest.append(lineTextBytes)
        newDest.append(contentsOf: term)
        do {
            try MailboxIO.backupOnce(destDescURL)
            try MailboxIO.atomicWrite(newDest, to: destDescURL)
        } catch {
            for m in done { try? fm.moveItem(at: m.to, to: m.from) }
            try? MailboxIO.atomicWrite(srcData, to: srcDescURL)
            throw MoveIntoError.ioError(error.localizedDescription)
        }
        return true
    }

    // MARK: renaming

    public enum RenameError: LocalizedError, Equatable {
        /// No descmap.pce, or no line in it names this file.
        case notFound
        case emptyName
        /// Same rule as create: a comma (descmap is unquoted CSV), a character
        /// no filename can hold, or one outside Latin-1.
        case invalidName
        /// Another entry at this level already uses this name (case-insensitive,
        /// by display or filename stem). Carries the existing name, in its case.
        case duplicate(String)
        case ioError(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:         return "that item isn't in the folder's index"
            case .emptyName:        return "the name can't be empty"
            case .invalidName:      return "the name can't contain , / \\ : * ? \" < > | or characters outside Latin-1"
            case .duplicate(let d): return "\u{201C}\(d)\u{201D} already exists here"
            case .ioError(let m):   return m
            }
        }
    }

    /// Rename the *display name* of the descmap line `directory`'s descmap lists
    /// under `filename` — the first, comma-delimited field — leaving the
    /// physical `.mbx`/`.fol` filename (and therefore the item's id and every
    /// descendant's) untouched. Real Eudora reads the display name from this
    /// same field, so both apps show the new name; the file keeping its old name
    /// is invisible in either UI, and stability of the id is worth far more than
    /// cosmetic filename agreement (an id change would break selection, saved
    /// column/scroll state, and — for a folder — every descendant id at once).
    ///
    /// The edit is byte-level: only field 1's bytes are replaced, so the
    /// filename, type, unread flag, terminator, and every other line survive
    /// exactly. Validation and the case-insensitive duplicate check mirror
    /// `create`, the renamed entry itself excepted.
    public static func rename(directory: URL, filename: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }
        guard trimmed.rangeOfCharacter(from: bannedNameCharacters) == nil,
              let newDisplay = trimmed.data(using: .isoLatin1) else {
            throw RenameError.invalidName
        }

        // Duplicates at this level, excluding the entry being renamed — so a
        // no-op rename (or a case-only change of its own name) is allowed.
        let lower = trimmed.lowercased()
        for e in DescMap.read(directory: directory) where e.filename != filename {
            let stem = (e.filename as NSString).deletingPathExtension
            if e.display.lowercased() == lower || stem.lowercased() == lower {
                throw RenameError.duplicate(e.display)
            }
        }

        let descURL = directory.appendingPathComponent("descmap.pce")
        guard let data = try? Data(contentsOf: descURL),
              let line = lineRange(of: filename, in: data) else { throw RenameError.notFound }

        // Field 1 (display) runs from the line's start to its first comma; the
        // display name can't hold a comma (banned above and at create), so the
        // first comma in the line is unambiguously the field separator.
        var comma = line.range.lowerBound
        while comma < line.range.upperBound, data[comma] != 0x2C {
            comma = data.index(after: comma)
        }
        guard comma < line.range.upperBound else { throw RenameError.notFound }

        var out = data
        out.replaceSubrange(line.range.lowerBound..<comma, with: newDisplay)
        do {
            try MailboxIO.backupOnce(descURL)
            try MailboxIO.atomicWrite(out, to: descURL)
        } catch { throw RenameError.ioError(error.localizedDescription) }
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
