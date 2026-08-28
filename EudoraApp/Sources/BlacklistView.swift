import SwiftUI
import AppKit
import EudoraStore

/// Where the pending blacklist lives between sessions.
///
/// `UserDefaults`, like `ViewStateStore` — a few hundred bytes of text that has
/// to survive a quit, with no other reader. Deliberately **not** a file in the
/// home directory: a file is something another program can open, and this list
/// existing as a file that TextEdit could hold open is the entire bug this
/// replaces.
enum BlacklistStore {
    /// One defaults key per bucket.
    ///
    /// **The ISP bucket keeps the original key**, which is the whole migration:
    /// the list Stephen already has decodes into the ISP list exactly as before,
    /// with no conversion step to get wrong and nothing to lose if this change
    /// is ever backed out. The Gmail bucket is simply a key that didn't exist
    /// yet, and an absent key already means "empty list" here.
    private static func key(_ bucket: BlacklistBucket) -> String {
        switch bucket {
        case .isp:   return "blacklistQueue.v1"
        case .gmail: return "blacklistQueue.gmail.v1"
        }
    }

    static func load(_ bucket: BlacklistBucket) -> BlacklistQueue {
        guard let blob = UserDefaults.standard.data(forKey: key(bucket)),
              let q = try? JSONDecoder().decode(BlacklistQueue.self, from: blob) else {
            return BlacklistQueue()
        }
        return q
    }

    static func save(_ q: BlacklistQueue, _ bucket: BlacklistBucket) {
        guard let blob = try? JSONEncoder().encode(q) else { return }
        UserDefaults.standard.set(blob, forKey: key(bucket))
    }

    /// The permanent record, appended to when a queue is drained.
    ///
    /// Still `~/email_blacklist.txt` for the ISP list, so nothing already there
    /// is orphaned — but **write-only from the app's point of view**, and written
    /// only at the moment the user has finished with the window. Nothing reads it
    /// back and nothing opens it, so the two-editors problem cannot come back
    /// through it.
    ///
    /// **A separate file per bucket**, rather than one file with both. The record
    /// exists so a blocklist can be rebuilt if one is ever lost, and a rebuild is
    /// per-destination: a merged file would have to be sorted back out by hand,
    /// using information the file doesn't carry. The existing file keeps its
    /// existing name and contents either way.
    static func archiveName(_ bucket: BlacklistBucket) -> String {
        switch bucket {
        case .isp:   return "email_blacklist.txt"
        case .gmail: return "email_blacklist_gmail.txt"
        }
    }

    static func appendToArchive(_ entries: [String], _ bucket: BlacklistBucket) throws {
        guard !entries.isEmpty else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(archiveName(bucket))
        let block = Data((entries.joined(separator: "\n") + "\n").utf8)
        // Existence tested explicitly, not inferred from a failed open. `if let
        // handle = try? FileHandle(forWritingTo:)` treats *any* open failure as
        // "no such file", and the fallback writes rather than appends — so a
        // permissions hiccup or a transient lock would replace years of archive
        // with the half-dozen lines being drained.
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: block)
        } else {
            try block.write(to: url)
        }
    }
}

/// The blacklist window: the addresses waiting to go to a blocklist, editable,
/// with one button for the way they actually leave.
///
/// The workflow this is shaped around, in Stephen's words: blacklist senders as
/// they arrive; later open this, edit the entries that should be whole domains
/// rather than one sender, copy the lot, paste it into the blocklist, and empty
/// it. "Copy and Clear" is that last part in one press, because doing it as
/// two — copy, then clear — invites clearing something that didn't make it to the
/// clipboard.
///
/// **Two lists, one window, drained independently.** The two destinations take
/// their addresses in different places — TigerTech's blocklist form, and the
/// From field of a Gmail filter — so a single combined list would have to be
/// sorted by hand at exactly the moment it is being pasted. Each section
/// therefore has its own Copy and its own Copy and Clear, and clearing one
/// leaves the other alone.
///
/// Which list an address lands on is decided when it is blacklisted, not here;
/// see `BlacklistRouting`. Moving a line from one to the other is a cut and a
/// paste, which is the right amount of ceremony for something that should be
/// rare.
struct BlacklistView: View {
    @EnvironmentObject private var model: AppModel

    // Hoisted out of `body` rather than written inline. A long `+` chain of
    // string literals inside a multi-argument initializer inside a `ViewBuilder`
    // is the classic shape for "the compiler is unable to type-check this
    // expression in reasonable time", and finding that out costs a build.
    private static let ispBlurb =
        "Paste into your ISP's blocklist. “Copy and Clear” also appends to ~/"
        + BlacklistStore.archiveName(.isp) + " as a permanent record."

    private static let gmailBlurb =
        "Paste into the From field of a Gmail filter, inside braces: "
        + "{a@x.com b@y.com}. Gmail has no wildcards — a bare domain already "
        + "matches every address at it. “Copy and Clear” also appends to ~/"
        + BlacklistStore.archiveName(.gmail) + "."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BlacklistBucketView(title: "Waiting for TigerTech (musanim.com)",
                                blurb: Self.ispBlurb,
                                queue: $model.blacklistQueue,
                                bucket: .isp)

            Divider()

            BlacklistBucketView(title: "Waiting for Gmail (gmail.com)",
                                blurb: Self.gmailBlurb,
                                queue: $model.gmailBlacklistQueue,
                                bucket: .gmail)
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 560)
    }
}

/// One list: its own editor, its own count, its own two buttons.
///
/// Split out of `BlacklistView` when the second list arrived, rather than
/// duplicated. The `@State` here is the reason it has to be its own view — the
/// note and the text it applies to are per-list, and two copies in one view
/// would have to be two pairs of variables threaded through every call.
private struct BlacklistBucketView: View {
    let title: String
    let blurb: String
    @Binding var queue: BlacklistQueue
    let bucket: BlacklistBucket

    @State private var note: String = ""
    /// The queue text the note describes. Compared on change so an edit clears
    /// the note but the clear performed *by* "Copy and Clear" does not — that
    /// change is one this view just made, and wiping the confirmation it was
    /// about to show would leave the button looking as though it did nothing.
    @State private var noteAppliesTo: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text("Edit freely — shorten an address to its domain to block the whole "
                 + "domain. " + blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Free text, deliberately: see `BlacklistQueue`. The monospaced face
            // is so a mistyped domain stands out, which is the one kind of error
            // that would silently block the wrong mail.
            TextEditor(text: $queue.text)
                // Any edit invalidates the last outcome — "Copied and cleared."
                // left standing while new addresses arrive reads as though they
                // had been copied too.
                .onChange(of: queue.text) { new in
                    if new != noteAppliesTo { note = "" }
                }
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(Color(nsColor: .separatorColor))

            HStack {
                Text(queue.count == 1 ? "1 address" : "\(queue.count) addresses")
                    .foregroundStyle(.secondary)
                if !note.isEmpty {
                    Text(note).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { copy() }
                    .disabled(queue.isEmpty)
                // ⌘Return, deliberately NOT `.keyboardShortcut(.defaultAction)`.
                // That would make Return the window's default action, and the
                // main control here is a multi-line editor where Return means
                // "new line" — so adding or splitting an entry would empty the
                // list instead. Settings hit exactly this and recorded it; see
                // the note on Save in `SettingsView`.
                //
                // **Only the ISP list takes ⌘Return.** Two views can't both claim
                // one shortcut — AppKit picks one and it isn't stated which — and
                // this is the list Stephen drains far more often. The Gmail list
                // is a click.
                //
                // The optional-`KeyboardShortcut` overload, not the
                // `(key:modifiers:)` one — that takes a non-optional
                // `KeyEquivalent`, so "no shortcut here" cannot be expressed
                // through it.
                Button("Copy and Clear") { copyAndClear() }
                    .keyboardShortcut(bucket == .isp
                                      ? KeyboardShortcut(.return, modifiers: .command)
                                      : nil)
                    .disabled(queue.isEmpty)
            }
        }
    }

    /// Returns whether the pasteboard actually took it — which `copyAndClear`
    /// depends on, so this cannot discard it.
    @discardableResult
    private func copy() -> Bool {
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(queue.pasteboardText, forType: .string)
        say(ok ? "Copied." : "Couldn't copy to the clipboard.")
        return ok
    }

    /// Archive first, then clear. If the append fails the list is left alone and
    /// says why — losing the addresses because a write failed would be the worst
    /// outcome available here, and it is silent.
    private func copyAndClear() {
        // The clipboard first, and only proceed if it took. Clearing a list that
        // never reached the clipboard is the one outcome this window exists to
        // prevent.
        guard copy() else { return }
        do {
            try BlacklistStore.appendToArchive(queue.entries, bucket)
        } catch {
            say("Copied, but couldn't append to ~/\(BlacklistStore.archiveName(bucket))"
                + " — list kept.")
            return
        }
        queue.clear()
        say("Copied and cleared.")
    }

    /// Show an outcome, and record which text it is about.
    private func say(_ message: String) {
        note = message
        noteAppliesTo = queue.text
    }
}
