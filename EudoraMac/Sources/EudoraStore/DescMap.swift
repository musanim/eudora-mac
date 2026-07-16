import Foundation

/// Eudora mailbox kinds, as marked by the TypeChar in `descmap.pce`.
///
/// NOTE: these letters are our fixture convention approximating Eudora
/// (I=In, O=Out, T=Trash, J=Junk, F=Folder, M=regular mailbox). The real
/// letters must be re-verified against a genuine `descmap.pce` before we rely
/// on them for anything destructive.
public enum MailboxType: String {
    case inbox = "I"
    case outbox = "O"
    case trash = "T"
    case junk = "J"
    case folder = "F"
    case mailbox = "M"

    public init(char: String) {
        self = MailboxType(rawValue: char.uppercased()) ?? .mailbox
    }

    public var isFolder: Bool { self == .folder }

    public var label: String {
        switch self {
        case .inbox:   return "In"
        case .outbox:  return "Out"
        case .trash:   return "Trash"
        case .junk:    return "Junk"
        case .folder:  return "folder"
        case .mailbox: return "mailbox"
        }
    }
}

/// One line of a `descmap.pce`: `DisplayName,Filename,TypeChar,UnreadStatus`.
public struct DescMapEntry {
    public let display: String
    public let filename: String
    public let type: MailboxType
    public let unread: String

    public var hasUnread: Bool { unread.uppercased().hasPrefix("N") }
}

public enum DescMap {
    /// Parse the `descmap.pce` in a directory (empty array if absent).
    public static func read(directory: URL) -> [DescMapEntry] {
        let url = directory.appendingPathComponent("descmap.pce")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return [] }

        // NOTE: split on Character.isNewline, NOT `$0 == "\r" || $0 == "\n"`.
        // In a Swift String a CRLF is a single grapheme-cluster Character that
        // equals neither "\r" nor "\n", so the naive comparison never splits.
        var rows: [DescMapEntry] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            let parts = line.components(separatedBy: ",")
            if parts.count < 3 { continue }
            let unread = parts.count > 3 ? parts[3] : ""
            rows.append(DescMapEntry(display: parts[0],
                                     filename: parts[1],
                                     type: MailboxType(char: parts[2]),
                                     unread: unread))
        }
        return rows
    }
}
