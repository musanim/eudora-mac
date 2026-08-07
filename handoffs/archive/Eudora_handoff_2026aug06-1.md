Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug06 (1)

**Supersedes `Eudora_handoff_2026aug05-2.md`.** Everything in its "Open threads"
and "Next session" lists is closed — Stephen went through them and declared the
slate clean, so nothing there applies any more. The standing project facts are
repeated below; don't go back to it for them.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects/Eudora` (pass the path
   directly; don't ask).
2. Mount `/Users/stephenmalinowski/ClaudeProjects` and read
   `claude-conventions.md`.
3. Read this project's `CLAUDE.md` — short, and every line was paid for.
4. Read this handoff, then **start on the Recents feature below.** Stephen
   supplied it with the handoff request, so it does not need confirming — but
   ask about the open questions listed under it before writing code.

Two rules to have in front of you before typing anything. **One step at a time**
— one command, wait for the result. And **nothing actionable after a command
block**: Stephen reads and acts in order, so a caveat placed after the commands
arrives too late.

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done and
Stephen uses it all day. Work is ordinary improvement, driven by what he hits.

## Current state

**One thing is in flight and it is the first thing to deal with: image paste is
written but not compiled.** Everything else is committed and confirmed.

## Completed and committed this session

Reply address handling and the compose caret. Built, confirmed by Stephen,
committed and pushed.

- **A comma inside a quoted display name tore a recipient in two.**
  `AppModel.splitAddresses` split on every comma, so replying to
  `"Andrews, Cody Kathy" <a@b.com>` asked the server to accept `"Andrews`. It
  now delegates to `EmailAddress.splitList`. Stephen reported this as "the
  quotes are rejected" — the quotes were the visible part of the error, the
  comma was the cause, and stripping quotes alone would not have fixed it.
- Two deeper faults on the same path, both found by review: `encodeAddress`
  stripped the quotes and never put them back (so the `To:` header went out
  malformed, invisible until the Out copy was reopened), and quoting without
  unquoting first doubled the escapes on every pass. New `quotedIfNeeded` /
  `unquotedDisplayName` / `quotingDisplayName` on `OutgoingMessage`.
- **Reopen and Send Again decoded the whole `To:` header before splitting it**,
  which turned the comma hidden inside an RFC 2047 encoded-word back into a
  separator. New `AppModel.recipientFieldText` splits raw, decodes per entry,
  re-quotes. `reply(all:)` uses it too — which is what delivers what Stephen
  actually asked for: quotes are dropped when a name doesn't need them and kept
  when they are load-bearing.
- **A reply opens with the caret at the top of the body.**
  `RichTextEditorController.focusBody`, plus a handshake that clears the
  composer's `@FocusState` — without it `RecipientField` re-grabs focus on the
  next republish and the caret jumps back to To after one keystroke.

Stephen dropped the second half of his original request — rendering
`"Last, First"` as `First Last` — after seeing the measurement: of 1,360 distinct
quoted display names in his In and Trash, 49 have a comma and most are not
personal names (`Charles Schwab & Co., Inc.`, `David Remnick, The New Yorker`,
`Alice Hansen, CMO`). He fixes those by hand and does not want a rule.

## In flight — image paste, WRITTEN NOT COMPILED

Pasting an image from the clipboard into a draft body, embedded on the receiving
end as `multipart/related` with `cid:` references. Stephen's scope: paste only,
no drag-and-drop, no size handling — he pastes small images and attaches large
ones. If a server refuses one it reports at send time and the draft survives.

**First actions of the next session, in this order:**

1. `cd ~/ClaudeProjects/Eudora/EudoraMac && swift test` — the store half is
   covered, including a four-pass save/reopen stability test.
2. Stephen builds the app and tries it. No `xcodegen` needed: both new files are
   in `EudoraMac`, which is picked up automatically.
3. Work the "To test" list in `EudoraDevelopmentNotes.txt` under today's image
   entry. The one not to skip is save-a-draft-with-an-image, reopen from Out,
   twice more — that is where both of today's other bugs lived.

Files touched: `RichText.swift`, `RichTextHTML.swift`, `MessageBuilder.swift`
(all `EudoraStore`), `RichTextAttributed.swift` (`EudoraRichText`),
`RichTextEditor.swift` and `AppModel.swift` and `ComposeView.swift` (`EudoraApp`),
plus a new `EudoraMac/Tests/EudoraStoreTests/RichTextImageTests.swift`.

Two design points that are load-bearing and will look like mistakes otherwise:

- **The inline image part carries no `name=` and no `filename=`.**
  `MIMEPart.isAttachment` answers true for *any* part with a filename whatever
  its disposition, so naming it would make the app treat its own embedded image
  as an attached file — reopening a draft would move the picture to the paperclip
  row, and the next save would send it both ways.
- **`RichTextImage`'s `==` ignores `data`.** `ComposeView.isDirty` compares the
  whole `RichText` inside `body`, on every keystroke. The id is a content hash,
  so comparing it *is* comparing the bytes, at fixed cost.

Three behaviours Stephen has not seen yet and might want changed: text wins when
the clipboard holds both text and a picture (Excel, Word, Keynote, Preview and
Safari all put a TIFF beside the text); TIFF is transcoded to PNG, losslessly,
because Gmail and Outlook won't render `image/tiff` inline; images go out at
whatever size they were pasted.

## Distribution audit — done, no action pending

Stephen supplied `AUDIT-works-on-my-machine.md` after Cochleagram 0.2/0.3 shipped
and crashed for every user (SwiftPM's generated `Bundle.module`, whose fallback
is an absolute path into the author's `.build`). He had sent Eudora 0.3.3 to one
person who never reported back.

**Verdict: that fault is structurally impossible in Eudora, and a crash is the
least likely explanation.** Audited the exact shipped artifact,
`dist/Eudora-0.3.3.zip`, unpacked fresh. No `Bundle.module` anywhere, no SwiftPM
resources, no nested `.bundle`. Zero absolute paths in the binary's *runtime*
string sections — `strings` reports 298 hits but every one is in the symbol
table and debug map. Universal x86_64 + arm64. Only system libraries. Notarized
and stapled (`Contents/CodeResources` begins `s8ch`). `UserDefaults` reads all
handle absence deliberately. Full account in `EudoraDevelopmentNotes.txt`.

The likely explanations are design, not defect, and Stephen has decided not to
act until he hears more:

1. Eudora 8 reads **Windows** Eudora 7 trees (it needs `descmap.pce`); Mac Eudora
   stopped at 6.2.4 with a different format. First launch with no saved folder
   does nothing at all — no prompt, no onboarding.
2. `AppModel.open` calls `ensureSystemMailboxes` *before* reading the tree
   (`AppModel.swift:1233`, tree at `:1244`) and the open panel sets no
   `directoryURL`, so picking the wrong folder creates In/Out/Junk/Trash in it
   and shows a working-looking client with no mail.

If the friend reports back, the two are distinguishable: "it wouldn't open
anything" is (1), "it opened but there was no mail" is (2).

---

## Next session — the Recents feature

Stephen's words, supplied with the handoff request:

> The feature is a Recents item. It will be a new item in the sidebar, below
> Trash, above everything else. Clicking it will bring up the list of mailboxes
> I've most recently moved received/sent (In/Out mailbox) items to. Selecting the
> item opens that mailbox (in the sidebar) with the last item (by date) selected.

**Ask these before writing code** — in plain prose, not the question widget:

- How many entries, and do they ever expire?
- "Clicking it will bring up the list" — a menu at the pointer (there is
  `PointerAlert` and an AppKit `NSMenu` precedent in `MoveToMenu`), a panel, or
  does Recents expand in the sidebar like a folder?
- Moves *from* In and Out only, or from anywhere? His wording says In/Out; worth
  confirming, since filing from a project mailbox to another is also a move.
- Does the list survive a quit? (Almost certainly yes — see the precedents.)
- Should a mailbox that no longer exists disappear silently or show greyed?

**Where the pieces already are:**

- `AppModel.moveSelected(to:)` at `AppModel.swift:4758` is where a move happens —
  the one place to record from.
- **`RecentRecipients` is the exact same shape already solved**: a persisted MRU
  list, `record()` bumping to front, `UserDefaults`-backed, with tests. Read it
  before inventing anything (`AppModel.recentRecipients`, and
  `EudoraMac/Sources/.../RecentRecipients.swift` with `RecentRecipientsTests`).
- `SidebarExpansion` in `EudoraStore`, stored per Eudora folder in `ViewState`,
  is the precedent if this should be per-folder rather than global.
- `AppModel.filingSuggestions()` at `:3705` is **not** this — it answers "where
  has this correspondent's mail been filed before", from the search index, and is
  not a recency list. Don't try to reuse it.
- The sidebar tree is built by `AppModel.buildItems`; the view is `MailboxTree`
  in `ContentView.swift`. Note `.id(treeIdentityVersion)` discards the outline on
  any identity change, and `SidebarRowMetrics` documents why row height answers
  to exactly two things.
- "Opens that mailbox with the last item by date selected" — `MailStore.newestStatus`
  already reads the newest record cheaply; selection restore lives near
  `restoreSelection`.

Put whatever logic can be tested in `EudoraMac`. The sidebar item itself can't be.

---

## Key context

**`EudoraDevelopmentNotes.txt` is the running record**, gitignored, now 2,889
lines. Every feature has a "To test" list. Keep appending in the same style.

**Claude cannot build.** No Swift toolchain in the sandbox — and cannot run
`swift test` either; Stephen runs that too. The loop is write carefully →
Stephen builds → he pastes errors. Prefer `EudoraMac/` over `EudoraApp/`.

**Use `general-purpose` review agents before handing anything over.** They have
earned it three times in one day: the malformed `To:` header, the escape
accumulation, and — on the image work — a parse pass that silently dropped every
image, two helpers that were internal but called across a module boundary, and a
SHA-256 running on the typing path.

**Model the round trip, don't reason about it.** Both of today's worst bugs were
things that came out different on the second pass. Simulating the pipeline in
Python across four consecutive save/reopen cycles found what reading the code had
not, twice. Do that for anything that reads back what it writes.

**Claude must not run git.** The sandbox can't unlink in `.git`, so every git
command strands a lock file. Write the message to `reference/commit-message.txt`
(gitignored) and hand over `git commit -F`. Recovery: `rm -f .git/index.lock`.

**Releasing** is a double-click on `Build Release to Share.command`.

**Assets:** a new imageset inside `Assets.xcassets` needs no `xcodegen`; a new
file under `EudoraApp/Sources` does, run *after* writing the file.

**`phaseX/` is real mail (12 GB), gitignored, and the repo is public.** Reading it
has settled several questions outright — including today's 1,360-display-name
measurement and the 106 backslash-bearing senders that exposed the escape bug.

**Stephen's PATH shadows short tool names** — Humdrum ships its own `ditto`, so
the scripts call Apple tools by absolute path.

**SMTP/POP are implicit TLS only** — no STARTTLS (port 587), no OAuth2. Known
gap, not currently biting.
