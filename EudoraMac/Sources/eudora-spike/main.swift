import Foundation
import EudoraStore
import EudoraSearch

// Phase 0/2 spike, ported to the target language. Reads a Eudora tree in place.
//
//   eudora-spike <root> tree
//   eudora-spike <root> list <mailbox>
//   eudora-spike <root> dump <mailbox> <index> [--save <dir>]
//   eudora-spike <root> search <query...>

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let usage = """
usage:
  eudora-spike <root> tree
  eudora-spike <root> list <mailbox>            e.g. In  or  Projects/Music
  eudora-spike <root> dump <mailbox> <index>    (1-based) [--save <dir>]
  eudora-spike <root> search <query...>         FTS5 full-text search
"""

let args = CommandLine.arguments
guard args.count >= 3 else { print(usage); exit(1) }

let root = URL(fileURLWithPath: args[1], isDirectory: true)
let store = MailStore(root: root)
let command = args[2]

switch command {
case "tree":
    printTree()
case "list" where args.count >= 4:
    printList(args[3])
case "dump" where args.count >= 5:
    guard let idx = Int(args[4]) else { fail("index must be a number") }
    var saveDir: String?
    if let s = args.firstIndex(of: "--save"), s + 1 < args.count { saveDir = args[s + 1] }
    printDump(args[3], idx, saveDir)
case "search" where args.count >= 4:
    printSearch(args[3...].joined(separator: " "))
default:
    print(usage); exit(1)
}

// MARK: - tree

func printTree() {
    print(root.path)
    func recurse(_ nodes: [MailboxNode]) {
        for n in nodes {
            let indent = String(repeating: "  ", count: n.depth + 1)
            if n.isFolder {
                print("\(indent)\(n.entry.display)/    [folder]")
                recurse(n.children)
            } else {
                let flag = n.entry.hasUnread ? "  *unread*" : ""
                print("\(indent)\(n.entry.display)  (\(n.messageCount) msg) [\(n.entry.type.label)]\(flag)")
            }
        }
    }
    recurse(store.tree())
}

// MARK: - list

func printList(_ name: String) {
    guard let listing = store.list(name) else { fail("mailbox not found: \(name)") }
    print("# \(listing.name)   \(listing.rows.count) messages   [index source: \(listing.source.rawValue)]")
    print("\("#".padded(3))  S  Pri  \("Date".padded(16)) \("Size".padded(7))  \("From/To".padded(28)) Subject")
    for r in listing.rows {
        let idx = String(r.index).padded(3)
        print("\(idx)  \(r.statusGlyph)  \(r.priority.padded(3))  \(r.date.padded(16)) \(String(r.size).padded(7))  \(r.who.padded(28)) \(r.subject)")
    }
}

// MARK: - search

func printSearch(_ query: String) {
    do {
        // Build a fresh in-memory index over the whole tree, then query it.
        // (A real app persists the index as an app-owned sidecar and updates
        // it incrementally; rebuilding each run keeps the spike self-contained.)
        let index = try SearchIndex(path: ":memory:")
        try index.rebuild(from: store)
        let hits = try index.search(query)
        print("# search \(query.debugDescription)   \(hits.count) hit(s)   (\(try index.count()) messages indexed)")
        for h in hits {
            print("  \(h.mailbox) @\(h.offset)  \(h.subject.padded(32))  \(h.snippet)")
        }
    } catch {
        fail("search failed: \(error)")
    }
}

// MARK: - dump

func printDump(_ name: String, _ index: Int, _ saveDir: String?) {
    guard let (rec, part) = store.message(name, index: index) else {
        fail("mailbox not found or index out of range: \(name) #\(index)")
    }
    print("===== \(name) #\(index)  (offset \(rec.offset), \(rec.length) bytes) =====")
    for h in ["Date", "From", "To", "Subject"] {
        if let v = part.header(h) { print("\(h): \(HeaderDecoder.decode(v))") }
    }
    print(String(repeating: "-", count: 60))

    var attachments: [(name: String, ctype: String, data: Data)] = []
    for p in part.walk() {
        if p.isMultipart { continue }
        let payload = p.decodedPayload()
        if p.isAttachment {
            attachments.append((name: p.filename ?? "(unnamed)", ctype: p.contentType, data: payload))
            continue
        }
        if p.mainType == "text" {
            let d = CharsetDecoder.smartDecode(payload, declared: p.charset)
            let note = d.note.isEmpty ? "" : "; \(d.note)"
            print("[\(p.contentType); \(d.charsetUsed)\(note)]")
            print(d.text.trimmingCharacters(in: .whitespacesAndNewlines))
            print("")
        }
    }

    if !attachments.isEmpty {
        print(String(repeating: "-", count: 60))
        print("Attachments: \(attachments.count)")
        for a in attachments {
            print("  - \(a.name)  (\(a.ctype), \(a.data.count) bytes)")
            if let dir = saveDir {
                let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
                try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                let safe = a.name == "(unnamed)" ? "unnamed.bin" : (a.name as NSString).lastPathComponent
                let dest = dirURL.appendingPathComponent(safe)
                try? a.data.write(to: dest)
                print("      saved -> \(dest.path)")
            }
        }
    }
}
