import Foundation
import EudoraStore

// Repoints `X-Attachments:` headers at where the files actually are.
//
//   eudora-relink <root> <locations.tsv>              dry run: report only
//   eudora-relink <root> <locations.tsv> --apply      rewrite the mail
//
// See `RecordedAttachmentRelink` for what is and isn't rewritten. The default is
// a dry run because this edits finished mail: the report is the thing to read
// before the rewrite, not after it. Quit Eudora first — a mailbox with a `.lck`
// beside it is refused, but that check is a probe, not a lock.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage:
  eudora-relink <root> <locations.tsv> [--apply] [--mailbox <path>] [--verbose]

  <root>            the Eudora tree, e.g. ~/Eudora
  <locations.tsv>   name<TAB>real path, one per line

  --apply           rewrite the mail. Without it, nothing is written.
                    A tree-wide --apply asks for confirmation first.
  --mailbox <path>  restrict to one mailbox, relative to root, e.g.
                    "PEOPLE.fol/R.FOL/ralphlei.mbx"
  --verbose         print every header that would change, not just a count
  --skip-checks     don't verify that each listed file is still on disk
"""

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print(usage); exit(1) }

let root = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath,
               isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let mapURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
args.removeFirst(2)

var apply = false
var verbose = false
var checkFiles = true
var onlyMailbox: String?
var i = 0
while i < args.count {
    switch args[i] {
    case "--apply":       apply = true
    case "--verbose":     verbose = true
    case "--skip-checks": checkFiles = false
    case "--mailbox":
        i += 1
        guard i < args.count, !args[i].hasPrefix("--") else { fail("--mailbox needs a path") }
        onlyMailbox = args[i]
    default: fail("unknown argument: \(args[i])\n\n\(usage)")
    }
    i += 1
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
    fail("no such directory: \(root.path)")
}

// MARK: - the list

var locations: RecordedAttachmentRelink.Locations
do {
    locations = try RecordedAttachmentRelink.Locations.load(contentsOf: mapURL)
} catch {
    fail("cannot read \(mapURL.path): \(error.localizedDescription)")
}

if !locations.rejected.isEmpty {
    print("\(locations.rejected.count) line(s) in the list were rejected:")
    for r in locations.rejected { print("  \(r.name): \(r.why)") }
    print("")
}

// A location that no longer exists is worse than the staging path it would
// replace: the staging path at least says honestly that it was a copy.
if checkFiles {
    var missing: [(String, String)] = []
    for pair in locations.pairs where !FileManager.default.fileExists(atPath: pair.path) {
        missing.append((pair.name, pair.path))
    }
    for (name, _) in missing { locations.remove(name: name) }
    if !missing.isEmpty {
        print("\(missing.count) listed file(s) are no longer at the recorded path "
              + "and will be left alone:")
        for (_, path) in missing.prefix(20) { print("  \(path)") }
        if missing.count > 20 { print("  …and \(missing.count - 20) more") }
        print("")
    }
}

guard locations.count > 0 else { fail("no usable name/path pairs in \(mapURL.path)") }

// MARK: - the mailboxes

/// Every `.mbx` under the tree, as (path relative to root, base URL).
func mailboxes(under root: URL) -> [(name: String, base: URL)] {
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]) else { return [] }
    var found: [(name: String, base: URL)] = []
    for case let url as URL in walker {
        guard url.pathExtension.lowercased() == "mbx" else { continue }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        let full = url.standardizedFileURL.path
        let relative = full.hasPrefix(root.path)
            ? String(full.dropFirst(root.path.count).drop(while: { $0 == "/" }))
            : full
        found.append((name: relative, base: url.deletingPathExtension()))
    }
    return found.sorted { $0.name < $1.name }
}

var targets = mailboxes(under: root)
if let only = onlyMailbox {
    // Case-insensitively, and tolerating both `.mbx` and `.MBX` — the real tree
    // has 285 of the latter.
    let wanted = only.lowercased().hasSuffix(".mbx") ? only : only + ".mbx"
    targets = targets.filter { $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }
    if targets.isEmpty { fail("no mailbox in \(root.path) named \(wanted)") }
}

print("\(locations.count) known locations, \(targets.count) mailboxes"
      + (apply ? "" : "   [dry run — nothing will be written]"))
print("")

// MARK: - dry run first, always

var plans: [RecordedAttachmentRelink.Outcome] = []
var failures: [(String, String)] = []
var nameOf: [String: String] = [:]

for (name, base) in targets {
    do {
        let outcome = try RecordedAttachmentRelink.run(base: base, locations: locations,
                                                       apply: false)
        guard !outcome.isEmpty else { continue }
        plans.append(outcome)
        nameOf[base.path] = name
    } catch {
        failures.append((name, "\(error)"))
    }
}

for outcome in plans {
    let name = nameOf[outcome.base.path] ?? outcome.base.lastPathComponent
    print("\(name)  —  \(outcome.changes.count) of \(outcome.recordCount) messages, "
          + "\(outcome.delta >= 0 ? "+" : "")\(outcome.delta) bytes")
    switch outcome.disposition {
    case .skippedTocMismatch:
        print("    SKIPPED: its .toc does not describe this mailbox, so the offsets")
        print("             cannot be patched. Relinking it would cost every")
        print("             read/replied flag in the mailbox, so it is left alone.")
    case .skippedBackupExists(let backup):
        print("    SKIPPED: \(backup) is already there from an earlier run.")
        print("             Move it aside to relink this mailbox again.")
    default:
        break
    }
    if verbose {
        for change in outcome.changes {
            for entry in change.relinked {
                print("    #\(change.index)  \(entry.name)")
                print("            -> \(entry.path)")
            }
        }
    }
}

let actionable = plans.filter { $0.disposition == .wouldRewrite }
let messages = actionable.reduce(0) { $0 + $1.changes.count }
let skipped = plans.count - actionable.count

print("")
print("\(messages) message(s) in \(actionable.count) mailbox(es) would be rewritten."
      + (skipped > 0 ? "  \(skipped) mailbox(es) skipped." : ""))

if !failures.isEmpty {
    print("")
    print("\(failures.count) mailbox(es) could not be read:")
    for (name, why) in failures { print("  \(name): \(why)") }
}

guard apply else {
    if messages > 0 { print("\nRe-run with --apply to write these.") }
    exit(failures.isEmpty ? 0 : 2)
}
guard messages > 0 else { exit(failures.isEmpty ? 0 : 2) }

// One --apply over a whole tree is a lot of authority for a flag. Restricting to
// a single mailbox is its own confirmation; anything wider is typed out.
if onlyMailbox == nil {
    print("")
    print("About to rewrite \(messages) message(s) in \(actionable.count) mailbox(es) "
          + "under \(root.path).")
    print("Each mailbox is copied to <name>.mbx.\(RecordedAttachmentRelink.backupSuffix) first.")
    print("Type yes to proceed: ", terminator: "")
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
          answer == "yes" else {
        print("Nothing written.")
        exit(1)
    }
}

// MARK: - apply

print("")
var rewritten = 0
var rescans: [String] = []
for outcome in actionable {
    let name = nameOf[outcome.base.path] ?? outcome.base.lastPathComponent
    do {
        let done = try RecordedAttachmentRelink.run(base: outcome.base,
                                                    locations: locations, apply: true)
        switch done.disposition {
        case .rewritten:
            rewritten += done.changes.count
            if done.tocRemoved { rescans.append(name) }
        case .skippedBackupExists(let backup):
            failures.append((name, "\(backup) already exists — an earlier run's "
                                 + "backup. Move it aside first."))
        default:
            failures.append((name, "changed between the report and the write; "
                                 + "re-run to see the current state"))
        }
    } catch {
        failures.append((name, "\(error)"))
    }
}

print("\(rewritten) message(s) rewritten.")
if !rescans.isEmpty {
    print("\(rescans.count) mailbox(es) lost their .toc and will be rescanned on "
          + "first open: \(rescans.joined(separator: ", "))")
}
if !failures.isEmpty {
    print("")
    print("\(failures.count) problem(s):")
    for (name, why) in failures { print("  \(name): \(why)") }
    exit(2)
}
