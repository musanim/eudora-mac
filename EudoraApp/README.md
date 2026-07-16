# EudoraApp — Phase 3 GUI (read-only three-pane)

A native **SwiftUI** macOS app in the classic Eudora 7 layout: mailbox/folder
tree on the left, and on the right the message list on **top** with the preview
pane **below** it (a draggable `VSplitView`). Reads through the existing
`EudoraStore` interop layer. It can also **compose and send** mail (SMTP), and
writes sent messages back into Eudora's `Out.mbx` — the one place it writes to
the tree, behind backup/atomic-write rails (see "Compose & send" below).

The message list carries the classic Eudora column set: **status** glyph,
**priority** (up/down chevrons), **attachment** (paperclip), **label**
(placeholder — see below), **Who**, **Date**, **Size (K)**, **Subject**.
"Who" is the sender for incoming mail and the recipient for the Out box, reduced
to a display name. Because the fixture's `.toc` caches the recipient for *every*
message, Who and the attachment glyph are filled in by parsing the message
rather than trusting the cache.

> **Not compiled here.** Like the rest of the project, this was authored with
> no Swift toolchain in the loop, so it has **not been built**. The code is
> written against the verified `EudoraStore` / `EudoraSearch` public API and
> reviewed for type-correctness, but expect the possibility of a small fixup on
> first build. Build it, paste any errors, and I'll fix.

## Build & run

The app is a proper `.app` target defined by an **XcodeGen** spec, so it stays
a real Xcode project (Info.plist, app bundle) rather than a bare SwiftPM
executable. From `~/ClaudeProjects/Eudora`:

```sh
brew install xcodegen        # one-time, if you don't have it
xcodegen generate            # reads project.yml, writes EudoraApp.xcodeproj
open EudoraApp.xcodeproj      # ⌘R to build & run
```

The generated project links the local `EudoraMac` package and its
`EudoraStore` + `EudoraSearch` products. Regenerate only when the file layout
or settings in `project.yml` change; editing Swift source doesn't require it.

> Prefer not to install XcodeGen? Say so and I'll hand-author the
> `.xcodeproj` instead. XcodeGen is just the robust route given I can't open
> Xcode to validate a hand-rolled `project.pbxproj`.

## Trying it against the fixture

There's no bundled default tree. Two ways to point it at one:

- **File ▸ Open Eudora Folder…** (⌘O) — choose a directory containing a
  `descmap.pce` (e.g. `phase0/sample-tree`).
- Set `EUDORA_ROOT` in the scheme's environment (Product ▸ Scheme ▸ Edit
  Scheme ▸ Run ▸ Arguments) to auto-open on launch, e.g.
  `~/ClaudeProjects/Eudora/phase0/sample-tree`.

You should see In / Out / Junk E-Mail / Trash and a **Projects** folder
containing Baidarka and Music; selecting a mailbox lists its messages (TOC
cache columns: status glyph, who, date, size, subject), and selecting a
message renders it — HTML mail in a locked-down `WKWebView`, plain text
otherwise.

## What it binds to (no new format knowledge in the UI)

All Eudora-format logic stays in `EudoraStore`. The app added only two
convenience overloads there so the UI can address a mailbox by the `base` URL
it already holds instead of round-tripping a name:

- `MailStore.list(at: URL, name: String?) -> Listing?`
- `MailStore.message(at: URL, index: Int) -> (record:, part:)?`

Everything else — tree, listing rows, MIME parsing, tolerant charset decode,
RFC-2047 header decode — is the existing public API.

## Files

```
project.yml                 XcodeGen spec (app target + local package deps)
EudoraApp/
  Info.plist                bundle metadata
  Sources/
    EudoraApp.swift         @main App + File ▸ Open command
    AppModel.swift          ObservableObject; tree/list/message state + UI wrappers
                            (MailboxItem, MessageRow, MessagePreview) + body rendering
    ContentView.swift       classic layout (sidebar + VSplitView list/preview),
                            Eudora column set, toolbar, compose sheet, sent banner
    MenuBarView.swift       in-window Windows-Eudora-style menu bar (9 menus)
    WebView.swift           NSViewRepresentable WKWebView, CSP-locked, JS off
    AccountStore.swift      SMTP account (UserDefaults) + password (Keychain)
    SettingsView.swift      ⌘, settings form for identity + SMTP server
    ComposeView.swift       compose sheet; assembles + sends, then writes to Out

Store/net layer (in the EudoraMac package):
    EudoraStore/MessageBuilder.swift   OutgoingMessage → RFC-822 bytes
    EudoraStore/TocWriter.swift        writes the binary .toc (mirrors Toc reader)
    EudoraStore/Outbox.swift           Out.mbx write-back (backup + atomic + .toc)
    EudoraStore/MailboxIO.swift        shared backup / atomic-write / toc-align
    EudoraStore/MailboxMutator.swift   mark read/unread, remove, move messages
    EudoraStore/Delivery.swift         deliver incoming mail into In (unread)
    EudoraNet/SMTPAccount.swift        outgoing account model
    EudoraNet/POP3Account.swift        incoming account model
    EudoraNet/Keychain.swift           password storage
    EudoraNet/SMTPClient.swift         SMTP over NWConnection, implicit TLS (465)
    EudoraNet/POP3Client.swift         POP3 over NWConnection, implicit TLS (995)
```

## In-window menu bar (Windows-Eudora style)

The menus live **inside the window** — a horizontal bar across the top of the
content (`MenuBarView`) with the full Eudora layout: **File, Edit, Mailbox,
Message, Transfer, Special, Tools, Window, Help**. This suits a large display,
where the system menu bar at the top of the screen is far from the window.

- Items for features that exist are wired; unbuilt ones (Mailbox ops, Special,
  parts of File/Tools) are present but **greyed-out placeholders** so the
  structure is faithful and fills in as we build.
- **Edit** routes Cut/Copy/Paste/Select All/Undo/Redo to the focused field via
  the responder chain, exactly like a real menu.
- **Transfer** lists the other mailboxes (move destinations); **Tools ▸
  Settings…** opens the account settings.
- The **system menu bar is stripped** to essentially the app menu — the
  relocated command groups (New, pasteboard, undo/redo) are removed so their
  shortcuts don't double-register.

**Needs a test pass:** SwiftUI keyboard-shortcut registration for items inside
in-window menus (as opposed to the system menu bar) is less standard. The
shortcuts are attached to the in-window items; if any (⌘N, ⌘R, ⌘⌫, …) don't
fire, tell me which and I'll add a hidden shortcut layer to guarantee them.
`⌘,` (Settings) and `⌘M` (Minimize) are intentionally left to the system so
they don't conflict.

## Receiving mail (POP3)

**Check Mail** (toolbar, or File ▸ Check Mail / ⇧⌘M) downloads new messages over
POP3 into the In box — the "keep a local archive, don't leave it on the ISP"
model, same as classic Eudora and the intended musanim.com setup.

Set it up in **Settings ▸ Incoming mail (POP3)**: server, port (995),
username, password (Keychain), and a **"Delete mail from server after
downloading"** toggle.

Testing against Gmail: enable POP in Gmail (Settings ▸ Forwarding and POP/IMAP),
then use `pop.gmail.com`, port `995`, your full address as username, and the
same app password as SMTP. Gmail keeps spam in its own Spam folder, so a normal
POP fetch won't pull junk.

How it works, and the safety stance:

- **Implicit TLS only (port 995)**, the same NWConnection transport as SMTP-465.
- New messages are found by **UIDL** and tracked in a per-account seen-list
  (persisted after each delivery), so Check Mail only ever pulls what's new —
  no duplicates.
- Each message is written into `In.mbx` as **unread**, via the same
  backup + atomic + `.toc` write-back used everywhere else.
- **Delete is a separate second pass** that runs only after every message is
  safely written locally, and only if you enable the toggle. It defaults **off**
  (leave-on-server) so a first fetch can't lose anything; flip it on once you've
  seen a clean download.

Current limitations: `UIDL` is required (Gmail supports it); the seen-UID list
isn't pruned; a transient connection hiccup surfaces as a hard error rather than
retrying. All fine for now, noted for later.

## Compose & send

The app can now write and send mail. Set it up once in **Settings (⌘,)**: your
name/email, and the SMTP server, port, security, username, and password (the
password goes to the **Keychain**, everything else to `UserDefaults`).

- **New Message** (⌘N), **Reply** (⌘R), **Reply All** (⇧⌘R), **Forward** (⌘L),
  plus toolbar buttons. Reply/Forward pre-fill recipients, `Re:`/`Fwd:` subject,
  threading headers (`In-Reply-To`/`References`), and a quoted body.
- **Send** (⌘D in the compose window) assembles a proper RFC-822 message
  (UTF-8, quoted-printable body when needed, RFC-2047 headers), sends it over
  SMTP, and on success **writes it into Eudora's `Out.mbx`** in native format.

### SMTP transport caveat

The client does **implicit TLS only (SSL, port 465)**. Network.framework can't
upgrade a plaintext socket to STARTTLS mid-stream, so **port 587 / STARTTLS
isn't wired yet** — it's a clearly-scoped follow-up. Pick "SSL/TLS (465)" in
Settings. AUTH PLAIN and AUTH LOGIN are both supported. And since I can't reach
a real mail server from here, the SMTP path is **untested against a live
server** — expect to iterate once you point it at your provider.

### Write-back safety

Recording a sent message is the first thing that writes to the Eudora tree, so
it's guarded: the `Out.mbx` is **backed up once** to `Out.mbx.bak` before the
first write, the new mailbox is written to a temp file and **atomically
renamed**, and the `.toc` is updated by appending one entry to the existing
(validated) index so prior messages keep their cached status — or the `.toc` is
dropped so the reader rebuilds by scanning. Against the synthetic fixture this
is all safely regenerable; the same rails are what will make it trustworthy
against real mail later.

## Message management

Delete, move, and mark read/unread — all written back to the Eudora tree, from
the **toolbar**, the **Message menu**, or a **right-click** context menu on the
list.

- **Mark as Read / Unread** (⌘⇧U / ⌘U) flips the message's status byte in the
  `.toc` only; the `.mbx` is untouched. Selection and preview are preserved.
- **Delete** (⌘⌫) follows Eudora: it **moves the message to Trash**, not a hard
  delete. Deleting a message that's *already* in Trash removes it for good.
- **Move** (toolbar/context menu) relocates the message to any other mailbox.

Under the hood a move removes the record from the source `.mbx` (shifting the
following `.toc` offsets) and appends it to the destination, carrying its
status/priority/subject. Every `.mbx` change gets the same rails as sending:
one-time `.mbx.bak` backup + temp-write-and-atomic-rename. A mailbox's `.toc`
is only rewritten when it was a valid cache; if it wasn't (e.g. the toc-less
`Projects/Music` fixture), the file is dropped so the reader rescans rather than
inventing status flags for the other messages. (One edge: marking read/unread on
a *toc-less* mailbox has to create a `.toc`, so its other messages get a default
"read" status — moot for mailboxes that already have a `.toc`, which is all but
one in the fixture.)

## Security stance

- HTML mail renders with **JavaScript disabled** and a strict CSP
  (`default-src 'none'`, images only from `data:`), and the navigation
  delegate cancels any `http(s)` request — so **no remote content is ever
  fetched** (no tracking pixels, no remote fonts/scripts).
- The app is **non-sandboxed** (personal build reading a tree in place from an
  arbitrary home-dir path). Sandboxing later means adding the
  user-selected-file entitlement + security-scoped bookmarks.

## Known limitations / next

- **Label column is a placeholder.** Eudora's per-message color label isn't in
  our `.toc` parse yet (the reverse-engineered struct doesn't map that field), so
  the column renders blank. Wire it once the label byte is identified.
- Selecting a mailbox now parses its messages (for Who + attachment glyph) in
  addition to the `.toc` read — synchronous on the main thread, fine for the
  fixture; move to a background load for large real mailboxes.
- The Date column reformats the RFC-822 `Date` header to Eudora style
  ("12/17/02 9:04 AM"); if a header won't parse it falls back to the `.toc`
  cached date string.
- No search UI yet (the deliberate scope cut). Next pass: wire a search field
  to a persisted `SearchIndex` sidecar in Application Support with incremental
  updates, per the architecture doc §3.3.
- Loose-file attachments aren't resolved yet (only inline MIME parts are shown
  in the attachment line), same caveat as Phase 1/2.
- `updateNSView` reloads the web view on each SwiftUI update; if it flickers,
  gate the reload on an actual content change.
```
