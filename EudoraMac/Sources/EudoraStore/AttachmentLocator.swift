import Foundation

/// A detached attachment, as far as we can tell where it went.
public struct LocatedAttachment: Hashable, Sendable {
    /// Bare filename, as recorded in the message.
    public let filename: String
    /// The full Windows path Eudora recorded, kept for display when the file
    /// can't be found — it is the only clue the user has left.
    public let recordedPath: String
    /// Where the bytes actually are on this machine, if we found them.
    public let url: URL?

    public var isFound: Bool { url != nil }

    public init(filename: String, recordedPath: String, url: URL?) {
        self.filename = filename
        self.recordedPath = recordedPath
        self.url = url
    }
}

/// Finds the files Eudora detached from received mail.
///
/// The path in an "Attachment Converted:" marker is a Windows path from the
/// machine Eudora ran on (`Y:\Documents\Active\Eudora\Attachments\invoice.pdf`),
/// so only the *filename* transfers. The bytes, if they came across with the
/// tree, are in the `Attachments` folder beside the mailboxes.
///
/// Lookup is by filename, and deliberately conservative: it never guesses. Two
/// things in a real tree make guessing tempting and wrong —
///
/// - **Eudora truncates.** The recorded name can be shorter than the original
///   MIME `filename=` (one message in `phaseX` records
///   `Christine & Stephen 5876 Park Ave.doc` for a file whose header called it
///   `Christine & Stephen 5876 Park Ave Richmond Report 7-2-26.doc`).
/// - **Eudora de-duplicates** by appending a digit, so `report.pdf`,
///   `report.pdf1` and `report.pdf2` can all exist and mean different files.
///
/// A prefix or fuzzy match would therefore attach the *wrong file* to a message
/// sooner or later, which is worse than showing the name without a link. So an
/// exact filename match is the only thing accepted, and `url` is nil otherwise.
public struct AttachmentLocator: Sendable {
    /// The folder Eudora detached into — `Attachments` beside the mailboxes.
    public let directory: URL

    public init(mailRoot: URL, folderName: String = "Attachments") {
        self.directory = mailRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Resolve one recorded path.
    ///
    /// Surrounding quotes are stripped from the stored path as well as from the
    /// filename, so the tooltip doesn't show stray quotes when this is called
    /// directly rather than through `locateAll(in:)`.
    public func locate(recordedPath: String) -> LocatedAttachment {
        var stored = recordedPath.trimmingCharacters(in: .whitespaces)
        if stored.hasPrefix("\"") && stored.hasSuffix("\"") && stored.count >= 2 {
            stored = String(stored.dropFirst().dropLast())
        }
        let name = DetachedAttachment.filename(fromRecordedPath: recordedPath)
        return LocatedAttachment(filename: name,
                                 recordedPath: stored,
                                 url: url(forFilename: name))
    }

    /// Every detached attachment of a message, in the order Eudora recorded them.
    public func locateAll(in message: MIMEPart) -> [LocatedAttachment] {
        DetachedAttachment.recordedPaths(in: message).map { locate(recordedPath: $0) }
    }

    /// The file for a bare filename, if it is present and really is a file.
    ///
    /// The name comes from message content, so it is treated as untrusted: a
    /// name containing a path separator, or any form of `..`, is rejected rather
    /// than allowed to escape the Attachments folder. `lastPathComponent` alone
    /// would not be enough on its own, so the check is explicit.
    func url(forFilename name: String) -> URL? {
        guard !name.isEmpty,
              !name.contains("/"), !name.contains("\\"),
              name != ".", name != ".." else { return nil }

        let candidate = directory.appendingPathComponent(name, isDirectory: false)

        // Belt and braces: confirm the resolved path really is inside the
        // Attachments folder after the filesystem has had its say (symlinks,
        // case folding, Unicode normalisation).
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path,
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }
}
