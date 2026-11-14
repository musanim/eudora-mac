import AppKit
import Foundation
import EudoraStore

// Writes a batch of prepared replies into Out as unsent drafts, so they can be
// opened, reviewed and sent one at a time from Eudora.
//
//   eudora-drafts <root> <drafts.json>             dry run: report only
//   eudora-drafts <root> <drafts.json> --apply     append the drafts to Out
//
// The bytes come from `OutgoingMessage.rfc822(includeBcc: true)` and land via
// `Outbox.append(status: statusUnsent)` — the same two calls the app makes when
// it saves a new draft (`AppModel.draftBytes` / `appendDraftRecord`) — so a
// record written here is indistinguishable from one the composer saved.
//
// Quit Eudora first. The app keeps Out's listing and open drafts' offsets in
// memory; appending behind its back would leave both stale. A running Eudora is
// refused rather than warned about.
//
// Re-running a batch is refused per draft: one whose `inReplyTo` already names
// an `In-Reply-To:` in Out is skipped, so an accidental second --apply doesn't
// double the batch.
//
// drafts.json:
//   { "from": "Stephen Malinowski <stephen@musanim.com>",
//     "drafts": [ { "to": "...", "subject": "...", "body": "...",
//                   "inReplyTo": "<id>", "references": ["<id>", ...] } ] }

struct Batch: Decodable {
    struct Draft: Decodable {
        let to: String
        let subject: String
        let body: String
        let inReplyTo: String?
        let references: [String]?
    }
    let from: String
    let drafts: [Draft]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage:
  eudora-drafts <root> <drafts.json> [--apply]

  <root>         the Eudora tree, e.g. ~/Eudora
  <drafts.json>  the prepared replies (see the comment at the top of main.swift)
  --apply        append them to Out. Without it, nothing is written.
"""

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 || args.count == 3 else { print(usage); exit(1) }
let apply = args.count == 3
if apply, args[2] != "--apply" { fail("unknown argument: \(args[2])\n\n\(usage)") }

let root = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath, isDirectory: true)
    .standardizedFileURL.resolvingSymlinksInPath()
let batchURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)

let batch: Batch
do {
    batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: batchURL))
} catch {
    fail("can't read \(batchURL.path): \(error)")
}

let outBase = root.appendingPathComponent("Out")
let outMbx = outBase.appendingPathExtension("mbx")
guard FileManager.default.fileExists(atPath: outMbx.path) else {
    fail("no Out mailbox at \(outMbx.path)")
}

if apply {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.stephen.eudora.app")
    if !running.isEmpty { fail("Eudora is running. Quit it first, then run this again.") }
}

let (fromName, fromAddress) = OutgoingMessage.splitFrom(batch.from)
guard !fromAddress.isEmpty else { fail("\"from\" has no address: \(batch.from)") }

// What Out already answers, so a re-run skips rather than duplicates.
let existing = String(decoding: (try? Data(contentsOf: outMbx)) ?? Data(), as: UTF8.self)
func alreadyDrafted(_ id: String) -> Bool {
    existing.range(of: "In-Reply-To: \(id)", options: .caseInsensitive) != nil
}

var written = 0, skipped = 0
var seenThisRun = Set<String>()
for (n, d) in batch.drafts.enumerated() {
    let to = EmailAddress.splitList(d.to)
    guard !to.isEmpty else { fail("draft \(n + 1): empty To") }
    // Blank means "not a reply": an empty header would parse back as "" and
    // match every reply in Out on the next run.
    let replyID = d.inReplyTo.map { $0.trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
    if let id = replyID, !(id.hasPrefix("<") && id.hasSuffix(">")) {
        fail("draft \(n + 1): inReplyTo must be a <message-id>, got \(id)")
    }
    if let id = replyID, alreadyDrafted(id) || seenThisRun.contains(id) {
        print("skip  \(n + 1): \(d.to) — Out already has a reply to \(id)")
        skipped += 1
        continue
    }
    let message = OutgoingMessage(fromName: fromName, fromAddress: fromAddress,
                                  to: to, subject: d.subject, body: d.body,
                                  inReplyTo: replyID, references: d.references ?? [])
    let data = message.rfc822(includeBcc: true).data
    print("\(apply ? "write" : "would write") \(n + 1): \(d.to) | \(d.subject) | \(data.count) bytes")
    guard apply else { continue }
    do {
        _ = try Outbox.append(messageData: data, to: outBase,
                              status: MailboxMutator.statusUnsent,
                              who: d.to, subject: d.subject)
        written += 1
        if let id = replyID { seenThisRun.insert(id) }
    } catch {
        fail("draft \(n + 1) failed after \(written) written: \(error)")
    }
}
print(apply ? "\(written) drafts written to Out, \(skipped) skipped."
            : "Dry run: nothing written. \(batch.drafts.count - skipped) would be written, \(skipped) skipped.")
