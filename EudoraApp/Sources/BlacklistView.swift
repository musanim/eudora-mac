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
    private static let key = "blacklistQueue.v1"

    static func load() -> BlacklistQueue {
        guard let blob = UserDefaults.standard.data(forKey: key),
              let q = try? JSONDecoder().decode(BlacklistQueue.self, from: blob) else {
            return BlacklistQueue()
        }
        return q
    }

    static func save(_ q: BlacklistQueue) {
        guard let blob = try? JSONEncoder().encode(q) else { return }
        UserDefaults.standard.set(blob, forKey: key)
    }

    /// The permanent record, appended to when the queue is drained.
    ///
    /// Still `~/email_blacklist.txt`, so nothing already there is orphaned — but
    /// now **write-only from the app's point of view**, and written only at the
    /// moment the user has finished with the window. Nothing reads it back and
    /// nothing opens it, so the two-editors problem cannot come back through it.
    static func appendToArchive(_ entries: [String]) throws {
        guard !entries.isEmpty else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("email_blacklist.txt")
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

/// The blacklist window: the addresses waiting to go to the ISP, editable, with
/// one button for the way they actually leave.
///
/// The workflow this is shaped around, in Stephen's words: blacklist senders as
/// they arrive; later open this, edit the entries that should be whole domains
/// rather than one sender, copy the lot, paste it into the ISP's blocklist, and
/// empty it. "Copy and Clear" is that last part in one press, because doing it as
/// two — copy, then clear — invites clearing something that didn't make it to the
/// clipboard.
struct BlacklistView: View {
    @EnvironmentObject private var model: AppModel
    @State private var note: String = ""
    /// The queue text the note describes. Compared on change so an edit clears
    /// the note but the clear performed *by* "Copy and Clear" does not — that
    /// change is one this view just made, and wiping the confirmation it was
    /// about to show would leave the button looking as though it did nothing.
    @State private var noteAppliesTo: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Addresses waiting for your ISP's blocklist.")
                .font(.headline)
            Text("Edit freely — shorten an address to its domain to block the whole "
                 + "domain. “Copy and Clear” also appends the list to "
                 + "~/email_blacklist.txt as a permanent record.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Free text, deliberately: see `BlacklistQueue`. The monospaced face
            // is so a mistyped domain stands out, which is the one kind of error
            // that would silently block the wrong mail.
            TextEditor(text: $model.blacklistQueue.text)
                // Any edit invalidates the last outcome — "Copied and cleared."
                // left standing while new addresses arrive reads as though they
                // had been copied too.
                .onChange(of: model.blacklistQueue.text) { new in
                    if new != noteAppliesTo { note = "" }
                }
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .border(Color(nsColor: .separatorColor))

            HStack {
                Text(model.blacklistQueue.count == 1
                     ? "1 address"
                     : "\(model.blacklistQueue.count) addresses")
                    .foregroundStyle(.secondary)
                if !note.isEmpty {
                    Text(note).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { copy() }
                    .disabled(model.blacklistQueue.isEmpty)
                // ⌘Return, deliberately NOT `.keyboardShortcut(.defaultAction)`.
                // That would make Return the window's default action, and the
                // main control here is a multi-line editor where Return means
                // "new line" — so adding or splitting an entry would empty the
                // list instead. Settings hit exactly this and recorded it; see
                // the note on Save in `SettingsView`.
                Button("Copy and Clear") { copyAndClear() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.blacklistQueue.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
    }

    /// Returns whether the pasteboard actually took it — which `copyAndClear`
    /// depends on, so this cannot discard it.
    @discardableResult
    private func copy() -> Bool {
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(model.blacklistQueue.pasteboardText,
                                                forType: .string)
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
            try BlacklistStore.appendToArchive(model.blacklistQueue.entries)
        } catch {
            say("Copied, but couldn't append to ~/email_blacklist.txt — list kept.")
            return
        }
        model.blacklistQueue.clear()
        say("Copied and cleared.")
    }

    /// Show an outcome, and record which text it is about.
    private func say(_ message: String) {
        note = message
        noteAppliesTo = model.blacklistQueue.text
    }
}
