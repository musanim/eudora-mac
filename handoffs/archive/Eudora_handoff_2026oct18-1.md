Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026oct18 (1)

**Supersedes `Eudora_handoff_2026oct16-1.md`** (moved to `handoffs/archive/`).
Nothing in it was done or dropped except as listed under "Done this session";
queue 4–15 and Key context carry forward unchanged, with additions to Key
context at the end.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects/Eudora` (pass the path
   directly; don't ask).
2. Mount `/Users/stephenmalinowski/ClaudeProjects` and read
   `claude-conventions.md`.
3. Read this project's `CLAUDE.md`.
4. Read this handoff, then **ask Stephen what he wants to do**. This session,
   like the last, was features he brought himself; queue 4–15 is for "later".

Two rules to have in front of you before typing anything. **One step at a time**
— one command, then wait. And **nothing actionable after a command block**: he
reads and acts in order, so anything placed after the commands arrives too late.

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done
(first Eudora 8 send: 2026-07-31) and Stephen uses it all day. Work is ordinary
improvement, driven by what he hits.

## Current state

**Everything is committed; Stephen was pushing as this was written** (three
feature commits plus this handoff's). Only `EudoraNotes_2026jul27.txt` is
untracked, deliberately.

### Done this session (2026oct16 – oct18), all built, `swift test` passed, confirmed by Stephen

- **`5033322` — paragraph alignment in the composer, and selected images show.**
  - Format strip: standard 4-segment control (left/centre/right/justify) right
    of Bold/Italic. `RichTextEditorController.setAlignment` calls NSTextView's
    `alignLeft/Center/Right/Justified` (whole paragraphs, undo for free).
  - Model: `RichTextStyle.alignment` (`RichTextAlignment`, raw values = HTML
    `align`). `RichText.normalize` → `uniformParagraphAlignment`: a paragraph
    takes its **first run's** alignment (AppKit's rule). All-left bodies are
    byte-identical to before. Image runs carry alignment
    (`RichTextRun(image:alignment:)`); a paste takes the caret paragraph's.
  - Wire: `<div align="…">…<br></div>` with the paragraph's `<br>` *inside* —
    exactly what Eudora 7 writes (found in `phaseX`). Parser reads `align` on
    div/p/h1–6, `<center>`, and CSS `text-align` only on those (not td/span).
    One narrow parser exception: the closing tag of an *aligned* block at the
    very end of the body adds no trailing newline (`alignedBlockBreak`), so a
    centred last line round-trips; plain `<div>a</div>` still ends in `\n`.
  - Forward now carries a received message's centring.
  - `BodyTextView.drawSelectedAttachments` tints a selected embedded image
    (AppKit's highlight is hidden behind an opaque attachment).
  - Known, not fixed: no per-segment tooltip (segmented Picker drops them);
    with a mixed selection whose first paragraph is centred, clicking Centre
    is a no-op (value unchanged) — click another segment first.
- **`9213510` — Reply to All / Reply to All as To.** In the message-list context
  menu and both Message menus. `ReplyRecipients.compute` (EudoraStore, tested):
  drops your own addresses (`AppModel.me`), dedupes by bare address, drops
  address-less entries, and on your own sent mail answers the people you wrote
  to (note-to-self falls back to From). `AppModel.reply(_ mode:)` replaces
  `reply(all:)`. Fixed the old Reply to All, which copied everything into Cc.
- **`cca192a` — To/Cc/Bcc wrap between recipients and grow.** See Key context
  ("Recipient fields") for how; `RecipientLineBreaks` (EudoraStore, tested)
  holds the rule.

### Diagnostics currently ON — three

    RemovalVeilDiagnostics.enabled                    AppModel.swift (queue 6)
    MessageColumnResizeController.diagnose            ContentView.swift (queue 6)
    AppModel.diagnoseDraftLookup                      AppModel.swift (item 15)

`[resize] DOWN` lines fire on every click in the message list; the log was
182 KB on oct16. Not urgent, but it's the first to silence if the log grows.

---

## The queue — for later

### 15. A sent reply left its draft behind in Out (2026oct16) — instrumented

One reply window; last saved 12:12:19 (subject "Re: influence, deliberately,
intentional, expression"), subject then edited, sent 12:12:54 ("presentation,
discovery"). Out ended with **both** records: the draft (status 9, Message-ID
`<B2D3B51C…>`) and the sent copy appended after it (status 8, `<0A1B2467…>`).
Bodies byte-identical. The differing Message-IDs mean nothing — `SMTPClient.send`
always mints a fresh one. So `recordSent` → `locateDraft` returned nil and took
the append fallback. Stephen remembers nothing done to Out meanwhile.

Code reading found no way for both the offset check and the Message-ID scan to
miss a draft the same window had just saved. The one hole found (scan used
listing rows, which skip records the `.toc` doesn't name) is closed in
`7fa2554`, but there's no evidence it was the cause. **If it happens again,
read the `[draft]` lines in `~/Library/Logs/Eudora-diagnostics.log` before
theorising** — they give the draft's offset/ID, what sat at the offset, the
scan result, all open drafts, and every Out record with its ID. Turn
`diagnoseDraftLookup` off once explained. The `~/Library/Logs` and `~/Eudora`
folders are both grantable; Out was read this way on oct16.

### 4. Blacklisting's rescue copy is still untested

Everything else in `DeletedMessageArchive` is confirmed working. The blacklist
path waits for a message actually worth blacklisting. When one arrives, check
that `Eudora blacklisted …` appears in the Finder's Trash alongside the notice
reply going out.

### 5. Seven mailboxes with a `.toc` that doesn't describe the `.mbx`

`eudora-relink` skipped these, leaving 11 messages unrelinked:
`PEOPLE.fol/C.FOL/CarlLumm`, `PEOPLE.fol/E.FOL/Etienne Abelin`,
`PEOPLE.fol/J.FOL/JA.fol/James Carmichael`, `PEOPLE.fol/A.FOL/Anna Detrick`,
`PEOPLE.fol/G.FOL/Grace Cho`, `PEOPLE.fol/A.FOL/Andreya von Waldenfels-Marks`,
`__MAM.fol/MISCINQ`. Large mailboxes (16,918 / 6,420 / 7,173 / 5,128 messages).
The skip rule is strict — *every* `.toc` entry must name a record — while
`MailStore` trusts a `.toc` at a simple majority. Two questions first: how stale
is each, and is there a safe way to rebuild an index without losing the status
flags it is the only copy of. Follows naturally from queue 2. Re-running the tool
is easy (idempotent; refuses when a `.prerelink` backup exists, so move it aside
first).

### 6. Dead message list after a move — still instrumented, still waiting

**Not reproduced in over a month.** Both diagnostics still on. Read
`RemovalVeilDiagnostics`' doc comment (`AppModel.swift`, above `PerfLog`).
`VEIL DOWN` present with clicks still dead ⇒ the veil is innocent, read the
`[resize]` lines. **Turn both off once settled.** The inspection-found hole:
three of the four arms of `loadListing`'s scroll-restore chain nil
`pendingScrollTopRow`, and `clearPendingScroll` lifts the veil only when it finds
one pending. Doesn't fit that Stephen's lasted minutes.

### 7. Stale draft offsets after a delete/move in Out

`shiftDraftOffsets` is called only from the draft-save paths, never from
`deleteSelected` or `moveSelected`, so deleting or moving a record in **Out**
while drafts are open strands their offsets. `locateDraft` then falls back to
`findDraft` (Message-ID scan), which since `7fa2554` scans every `.mbx` record
rather than the listing's rows — so this should now recover rather than
duplicate. Not tested. See also the new item 15.

### 8. Confirm the letter-group auto-sort

Built on sep07, **still never exercised**. Create a mailbox inside a PEOPLE or
ORGANIZATIONS letter group, and move an existing one into another; each should
land in alphabetical position with no banner beyond the usual create/move one.
Then decide whether **rename** inside a letter group should re-sort too (it
doesn't). Note the rule is "display name is one character", so ORGANIZATIONS'
A–Z groups get it as well as PEOPLE's.

### 9. `MIMEParser.parseHeaders` decodes CP1252 headers as UTF-8

`String(decoding: bytes, as: UTF8.self)` at `MIME.swift:359`. Every non-ASCII
header byte becomes U+FFFD (`CarterCaténaires.png` → `CarterCat<?>naires.png`).
`CP1252.decode` exists and is what `Toc.cString` uses. **Now slightly more
pressing**: `DeletedMessageArchive.descriptor` and `MessageBody.descriptor` both
read headers through this path, so a rescue copy's file name and a stitched
body's parts inherit the mangling. Small change, every header in the app goes
through it — wants its own session and a look at what depends on the lossy
behaviour.

### 10. Remaining View Response loose end

The jump reads the destination mailbox in full on the main thread:
`MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a whole-file
scan. (Stephen didn't recognise this one on aug31 — re-explain before doing.)

### 11. Gmail-side blacklisting, if he wants Eudora to do it

`users.settings.filters.create`, `from:` → `addLabelIds: ["TRASH"]`, one filter
per address, 1,000-filter ceiling. The price is **OAuth2**. Two sharp edges: the
consent screen must be published "In Production" or refresh tokens expire after
7 days; published-but-unverified means a sign-in warning and a 100-user cap,
which is fine for him alone and not for the notarized Eudora he shares. The
argument for: the same subsystem closes the POP/SMTP OAuth2 gap. Don't start it
without him choosing it deliberately.

### 12. Older doc loose ends, still open

- `SidebarExpansion`'s doc comment claims a rename changes a `MailboxItem.ID`.
  Wrong, and load-bearing for Recents.
- `AppModel.swift`'s doc on `removalNotice` describes "Moved to Trash." as a
  delete's completion message; no delete path passes a notice.
- `EudoraDevelopmentNotes.txt:2219` names `MailboxItem.hasUnread`, which no
  longer exists.
- `SidebarOutlineFinder` is **ambiguous** since the pinning — two single-column
  headerless `NSTableView`s. Only switched-off probes use it;
  `SidebarRowSizeStyleTrial` *mutates* what it finds. The outline is the taller.

### 13. Test list — still outstanding

- A sent message with both a real MIME attachment and an `X-Attachments` header
  (187 in `phaseX`) — the file must appear once, as a working chip.
- Most of Recents: rename and delete of a listed mailbox, the empty menu,
  clicking the blank right-hand part of the row.
- Several compose windows at once: save a middle one then another; no duplicate
  in Out (queue 7's bug — a failure is expected).
- A plain unstyled message must still be a single `text/plain` part.
- View Response with a second reply left as an unsent draft, and with two sent.
- Open sender's mailbox on a sender with mail in several places, and on one with
  none ("None found", not an empty submenu).
- Blacklist routing on a message with no `Delivered-To` — both lists.
- A dozen mailto: clicks, then quit and relaunch: the main window should come
  back where it was, not walked across the screen by the shared frame autosave.

### 14. Housekeeping left behind by the relink

- **156 `.mbx.prerelink` / `.toc.prerelink` files** in `~/Eudora`. Their presence
  blocks a re-run on that mailbox by design. Worth confirming they never show in
  the sidebar (the walk looks for `.mbx`; nobody has looked). **Now checkable
  directly** — see Key context on `~/Eudora`.
- **The Laetrile PDF**: one curated location dropped — a non-breaking space in
  the on-disk name, and no longer at the recorded path by the time the tool ran.
- **`reference/missing-attachment-names.md` is built from `phaseX`** (2026apr03).
  `python3 reference/list-recorded-attachments.py ~/Eudora` regenerates it
  against the live tree; Stephen runs it.

---

## Key context

**Claude cannot build or test.** Write carefully → Stephen builds and runs
`swift test` → he pastes the errors. Prefer `EudoraMac/` over `EudoraApp/`.

**CLAUDE RUNS GIT NOW, AND STEPHEN PUSHES.** Reversed 2026sep20 at his request;
`CLAUDE.md` has the full rule. Commit when a unit of work is finished *and* he
has built and tested it, then say there is something to push. **Check delete
permission with a scratch file before every git session** — it lapses silently
when the connection to the Mac drops, and git then runs, succeeds, and strands
`HEAD.lock`, `index.lock` and `tmp_obj_*` files that block his own git. That
happened on sep22. Recovery: `rm -f .git/*.lock`, `find .git/objects -name
'tmp_obj_*' -delete`, then `git fsck --no-dangling`.

**`~/Eudora`, the LIVE tree, can now be read** — request folder access for
`/Users/stephenmalinowski/Eudora` with a specific reason. This is new; the old
rule said only `phaseX` was reachable. It is real mail and read-only by
discipline: copy what you need to scratch **outside** the mounted folders, work
on the copy, delete it. `phaseX` is still the right tool for design questions
(free to grep, no risk) but it is a snapshot taken **2026apr03** and says nothing
about the months since — which is exactly how it misleads. Anything generated
from either is private and belongs in `reference/` (gitignored); the repo is
public.

**Use `general-purpose` review agents before handing anything over, and two when
the change writes to real data.** They have earned it repeatedly. In September
alone they caught: `appropriateFor:` handed a URL that doesn't exist, which would
have made every Trash rescue fail silently while two dialogs promised otherwise;
a "placed" latch set before the guard that needed the main window, stranding
compose windows on the wrong display; `NSScreen` compared by `===`; four
regressions in the body-parts fix (invites quoting raw iCalendar, bounces showing
returned headers, Forward collapsing line breaks, image-only newsletters
dropped); and a stale function that wouldn't have compiled.

**`print()` IS INVISIBLE FOR AN APP LAUNCHED BY LAUNCHSERVICES, and launching
the binary directly to see stdout CHANGES THE BEHAVIOUR.** A direct launch
bypasses LaunchServices and gave three windows at launch where
`open /Applications/Eudora.app` gave one. Use `eudoraDiag()` (top of
`EudoraApp.swift`) for anything about launch or URL behaviour; it appends to
`~/Library/Logs/Eudora-diagnostics.log` as well as stdout.

**`ContentView.onAppear` is not a window counter.** It fired twice on a cold
launch whose census showed exactly one main window. Only the `[windows]` census
is trustworthy.

**SwiftUI derives a window's frame autosave key from the view's TYPE NAME.**
Adding or removing a scene modifier orphans the remembered frame and the window
forgets where it was. The preferences domain still holds an orphan from the
`handlesExternalEvents` experiment. Know this before touching that scene.

**`NSScreen` instance identity is not stable** across display reconfiguration or
sleep/wake. Compare displays by `CGDirectDisplayID` out of
`deviceDescription["NSScreenNumber"]`, which is what `night-mode.lua` has always
done with `id()` and `getUUID()`. "Built-in" is `CGDisplayIsBuiltin`, not the
display's localized name.

**A nested type inherits its enclosing type's `@MainActor`.** Building one inside
`Task.detached` is an isolation *error*, not a `Sendable` warning. The payload
types that already cross into detached tasks (`BuiltListing`, `RenderedMessage`,
`MessagePreview`) are file-scope on purpose.

**`MessageBody` (EudoraStore) is now the one place that decides what "the body"
is** — the message view, reply quoting and Forward all go through it. Anything
that needs a message's readable text should too, rather than walking the part
tree again.

**Anything that touches the built product must run AFTER signing**, which means a
scheme post-action, not a `postBuildScripts` phase — Xcode signs after every
build phase. A build phase installed an unsigned bundle and the kernel killed it
with `Killed: 9`. Incremental builds hid it. **`codesign` has no `--quiet`**;
passing one exits 2, which reads as "invalid".

**A kept old build is a cheap bisect.** `dist/DerivedData/Build/Products/Release/`
still holds the aug04 release.

**Find's engine is `LIKE` over stored columns, not FTS `MATCH`.** Case-insensitive
substring, `ESCAPE '\'`. `TextTarget.columns` says which columns each Where
searches; Anywhere is all six including raw `headers`. The snippet comes from
`body` only — a match in any other column is invisible in the results row.

**`ContentExtractor` (EudoraSearch/Content.swift) is what the index holds.** Add
a column's contents there; the schema check `hasCurrentSchema` only tests for the
`headers`/`epoch` columns, so a content change without a column change needs a
manual Rebuild Search Index. It already indexes *every* text part, which is why
the text-after-an-attachment bug was findable but not readable.

**Main window close = Quit**, by design (`CloseToQuitProxy`, `SplashWindow.swift`).
Compose and Find windows close normally.

**The tree is in file order on purpose.** `sortEntries` is the one-off action;
the only automatic sort is the single-letter-group rule (queue 8).

**A literal tab inside a Swift raw string won't compile.** Use `"\t"`.

**`eudora-relink`**: `swift run -c release eudora-relink <root> <locations.tsv>`
is a dry run; `--apply` writes; `--mailbox <path>` restricts; idempotent; refuses
a mailbox whose backup exists; Eudora must be quit.

**For performance, `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary is
`Eudora`.

**Assets and files:** a new file under `EudoraApp/Sources` needs `xcodegen
generate`, run *after* writing it — and so does any `project.yml` change. Files
in `EudoraMac/` and new imagesets in `Assets.xcassets` don't. Icon generators
live in `assets/` and write straight into the catalog.

**Releasing** is a double-click on `Build Release to Share.command`. The
post-action installs the Release build to `/Applications` *before* release.sh
staples it, so **Gatekeeper must be tested against `dist/`, never against
`/Applications`.**

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. See queue 11.

**musanim.com and gmail.com are independent mailboxes**, collected separately.

**Hammerspoon** carries `night-mode.lua` (Stephen's, moves Eudora's windows to
the built-in display at night; the externals go black). Repo copy
`scripts/night-mode.lua`, live copy `~/.hammerspoon/night-mode.lua`. It is why
queue 1 can't simply centre dialogs on the primary display, and its compose-window
sweep is what taught the autosave the wrong display in the first place.

### Added this session

**Recipient fields wrap through two paths that must agree.** At rest the cell
draws `RecipientLineBreaks.displayString` (no-break spaces + U+2060 between
every two characters of a recipient) through a separate plain
`NSTextFieldCell`; while editing, each field has its **own** TextKit-1 field
editor (`RecipientFieldCell.fieldEditor(for:)`) whose layout-manager delegate
allows breaks only at `entryStarts`. Not the window's shared field editor —
that would steer Subject too. Height: `RecipientField.sizeThatFits` →
`RecipientTextField.fittingHeight`, from the editor's own layout while editing.
The rounded bezel was checked at multi-line heights and is fine.

**An `NSCell` subclass must not hold Swift object references.** `NSCell` copies
with a bitwise copy that doesn't retain them — one copy away from a double
release. Keep storage on the control (see `RecipientTextField`).

**`NSMutableAttributedString(attachment:)` is not reliable** — `init(attachment:)`
comes from a class factory returning `NSAttributedString`. Use
`NSMutableAttributedString(attributedString: NSAttributedString(attachment:))`.

**`NSTextView()` is TextKit 2 on macOS 12+.** Anything needing a
`layoutManager` delegate should use `NSTextView(usingTextLayoutManager: false)`.

---

## Next session

Ask Stephen. He brought his own requests all session and deferred 4–15. If he
wants queue work, the natural candidates are still **13** (the test list —
several items cheap now; "several compose windows at once" also exercises item
15) and **9** (CP1252 headers, its own session). If he mentions a leftover
draft in Out, go straight to the `[draft]` log lines.
