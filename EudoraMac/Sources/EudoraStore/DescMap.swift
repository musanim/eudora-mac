import Foundation

/// Eudora mailbox kinds. Verified against a genuine Windows Eudora 7
/// `descmap.pce`: the TypeChar is **S** (system mailbox: In/Out/Junk/Trash,
/// distinguished by name), **M** (regular mailbox), or **F** (folder — a `.fol`
/// subdirectory with its own `descmap.pce`). The single-letter cases below are
/// the internal roles we resolve those to (plus legacy fixture chars I/O/T/J).
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

    public var hasUnread: Bool { unread.uppercased().hasPrefix("Y") }
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
                                     type: resolveType(char: parts[2], display: parts[0]),
                                     unread: unread))
        }
        return rows
    }

    /// Map a `descmap.pce` TypeChar to a role. Real Eudora uses "S" for the four
    /// system mailboxes (resolved to In/Out/Junk/Trash by their display name),
    /// "M" for a regular mailbox, and "F" for a folder. Legacy fixture chars
    /// (I/O/T/J) are still honoured.
    static func resolveType(char: String, display: String) -> MailboxType {
        switch char.uppercased() {
        case "F": return .folder
        case "I": return .inbox
        case "O": return .outbox
        case "T": return .trash
        case "J": return .junk
        case "S":
            switch display.lowercased() {
            case "in":    return .inbox
            case "out":   return .outbox
            case "junk":  return .junk
            case "trash": return .trash
            default:      return .mailbox
            }
        default: return .mailbox   // "M" and anything unknown
        }
    }
}
