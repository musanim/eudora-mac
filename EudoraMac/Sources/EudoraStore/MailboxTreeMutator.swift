import Foundation

/// Mutations to the mailbox *tree* — as against `MailboxMutator`, which edits
/// messages inside one mailbox. The first (and so far only) operation is
/// deleting an empty mailbox, which is a `descmap.pce` edit plus file removal.
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
