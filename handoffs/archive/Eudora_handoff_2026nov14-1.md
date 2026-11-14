Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026nov14 (1)

**Supersedes `Eudora_handoff_2026nov13-1.md`** (moved to `handoffs/archive/`).
Everything from nov13 is carried forward below the line, unchanged, with
these exceptions: its git counts under "Current state" are stale (everything is
pushed as of nov14), and its "Next session" is replaced by the one here.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects` (covers the project; pass
   the path directly, don't ask) and read `claude-conventions.md`.
2. Read this project's `CLAUDE.md`.
3. Read this handoff. **Then start on the first item under "Next session"** —
   Stephen queued it explicitly, so there's no need to ask what to do first.
   Confirm the design with him before writing code.

Two rules to have in front of you before typing anything. **One step at a time**
— one command, then wait. And **nothing actionable after a command block**.

---

## Next session

### 1. FIRST: automate handling of the responses to the MAM4U announcement

Stephen asked for this to be the first thing. Design it with him; don't start
coding before he agrees the shape. Facts to start from:

- **What was sent.** An announcement of the web-based MAM (MAM4U,
  `https://www.musanim.com/MAM4U/` and `/MAM4U/app/`) to people who over the
  years asked about the 2006 MAM MIDI Player or other software of his. One
  email per person, as a reply to their earliest matching message, 20 per
  batch. Batch 1 (20 people) was put in Out on 2026nov14 and Stephen is
  reviewing and sending it.
- **How to recognise a response.** Every announcement has the subject
  `Music Animation Machine (freeware video production beta now online)`, so
  replies arrive as `Re: <that>`. Do **not** count on matching `In-Reply-To`
  against the drafts' Message-IDs: `SMTPClient.send` mints a fresh Message-ID
  at send, so the sent copy in Out (status 8) carries an ID different from the
  draft's. The sent copies' IDs are what replies will reference.
- **Expect many bounces.** Lots of the addresses date from 1997–2010 (AOL,
  earthlink, old university and employer addresses). Bounces come from
  mailer-daemon/postmaster with the original attached or quoted, not as
  `Re:`. A good design probably separates bounces (mark the address dead in
  the list) from real replies (which Stephen wants to read and answer).
- **The campaign's files**, all in
  `~/ClaudeProjects/MAMforTheMasses/PeopleToEmail/` (gitignored there — it is
  private contact data; MAMforTheMasses has a GitHub remote):
  - `PeopleToEmail_2026nov14.txt` — the list. Tab-separated name, email,
    first-year, notes. Section A (270, the MIDI player/MAM software),
    B (54, Tapper/Tantrum/WAVAlign/LPMAM/Harmonizer/VoiceTracker, program in
    the notes column), C (41, maybe). Built by scanning ~/Eudora skipping
    SCAMS, Amazon, _GOVERNMENT, ____ORGANIZATIONS and PEOPLE mailboxes with
    more than 100 messages.
  - `MAM4U_bulkEmail.txt` — Stephen's template; `Dear _________,` is replaced
    by the guessed first name (or `Hello,` when there's no name).
  - `batchNN.json` — the input to `eudora-drafts` (below). batch01 = section A
    rows 1–20.
  - `progress.txt` — which rows each batch covered. **Next batch starts at
    Boyd Loughrige** (section A row 21).
  - `Out_backup_before_resubject/` — a copy of Out from before the subject
    change; delete once Stephen confirms batch 1 went out fine.
- Stephen wanted, and the next batches should keep: **one message per
  person**; if a person has two addresses use the **most recent** in To:;
  reply to their **earliest matching** message; quote it below the text the
  way Eudora's Reply does ("On <date>, <from> wrote:" then `> ` lines,
  attachment debris stripped); threading headers from that message.

### 2. Later batches of the announcement

Same procedure as batch 1, 20 at a time, when Stephen asks. The scripts that
picked messages and built the JSON lived in session scratch and are gone;
rebuild them from the description above (match rule: subject+unquoted body,
PLAYER phrase = 2, platform word within 250 chars of a software word = 2, an
asking word = 1, score ≥ 3; messages in the dedicated __MAM.fol folders
MAMPlayer/Software/Support/Source Code Requests/Tapper/Tantrum/Harmonic
Coloring/DYAD/Voice Tracker always count). Worth saving the scripts into
`MAMforTheMasses/tools/` this time.

### 3. Standing items from nov13 (unchanged)

- The next libero.it message → read the `[holding]` log line and confirm.
- A new kind of fraud → measure a recognizer against the live tree first.
- The queue (cheapest: 13, the test list), and the oct25 watch-items.

---

## Done this session (2026nov14)

- **`6044726` — `eudora-drafts`** (`EudoraMac/Sources/eudora-drafts/main.swift`,
  new executable in `Package.swift`). Appends a JSON batch of prepared replies
  to Out as unsent drafts via the composer's own calls
  (`OutgoingMessage.rfc822(includeBcc: true)` + `Outbox.append(status:
  statusUnsent)`), so they open, edit and send like app-saved drafts. Dry run
  by default; `--apply` refuses while Eudora is running
  (`NSRunningApplication`, bundle `com.stephen.eudora.app`) and skips any
  draft whose `inReplyTo` is already an `In-Reply-To:` in Out or earlier in
  the same run. Built and used by Stephen.

      cd ~/ClaudeProjects/Eudora/EudoraMac && swift run -c release eudora-drafts ~/Eudora <batch.json> [--apply]

  Known limit: the originals don't get the "replied" mark when these are
  sent (that mark lives only in memory, `AppModel.swift` ReplyOrigin), same as
  any reopened draft.
- **Resetting Out by hand** was needed once (subject change after writing):
  with Eudora quit and Out holding only the batch, `Out.mbx` was truncated to
  0 bytes and `Out.toc` restored to 104 zero bytes — exactly Out's prior
  empty state. Only valid when Out held nothing else; check first.
- **`~/Eudora` was written** (Out only), at Stephen's request, the one
  deliberate exception to read-only. It is now 20 drafts with the new subject.

---

# Carried forward from Eudora_handoff_2026nov13-1.md

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done
(first Eudora 8 send: 2026-07-31) and Stephen uses it all day. Work is ordinary
improvement, driven by what he hits.

## Current state

**Everything is committed.** Stephen pushes; at handoff time `main` was ahead
of origin by 2 (`4506262`, `7946766`) plus this handoff's commit. Only
`EudoraNotes_2026jul27.txt` is untracked, deliberately.

**One thing is waiting on real mail:** the HOLDING rule (`7946766`) is built
and `swift test` passes, but no libero.it message has arrived since. Stephen
will say when one does. Then: `grep holding ~/Library/Logs/Eudora-diagnostics.log`
(the `~/Library/Logs` folder is grantable) and confirm the decision matches
where the message landed. Turn `AppModel.diagnoseHolding` off once he trusts it.

### Done this session (2026oct25 – nov13), all built and confirmed by Stephen

- **`0747351` — sidebar folder clicks redraw again.** `4517c7d` had wrapped the
  outline in a `ScrollViewReader`, moving the read of the expansion set into the
  reader's closure; SwiftUI charges a `@State` read to the view whose body is
  running, so `MailboxTree` stopped depending on it and only the first
  disclosure click showed. `MailboxTree.body` now reads `renderExpandedIDs` and
  passes it to `treeList(expanded:)`. **Never read `@State` only inside a child
  closure** — same family as the `setExpanded` comment.
- **`5b04699` — Report Fraud ▸** (right-click, single received message, below
  Forward as Attachment). `EudoraStore/FraudReport.swift` + `FraudReportTests`.
  `FraudKind` cases so far: `usptoImpersonation` (to `TMScams@uspto.gov` + the
  scammer's From and Reply-To as **bare addresses**, subject "PTO scam (original
  email attached)", body "The original message is attached.") and `phishing`
  (to `reportphishing@apwg.org`, sender not copied — phishing forges innocent
  From lines). Picking one opens a **composer**, not an auto-send. Recognized
  kinds float to the top, marked "(looks like this)".
  - USPTO recognizer: claims USPTO (display name, domain containing "uspto",
    or subject patterns) **and** is not uspto.gov with `dkim=pass
    header.d=(*.)uspto.gov` in the **topmost** Authentication-Results (an old
    uspto.gov message with no AR counts as genuine). Measured on the live tree:
    15/15 scams, 0 false positives over 185 candidate mailboxes.
  - Kinds are added **case by case** as Stephen brings examples; check a new
    recognizer against the live tree (catches the examples, flags nothing else)
    before adding it.
- **`4506262` — sending a report files it.** `recordSent` → `fileSentReport`
  (Out → SCAMS, by the exact offset just written, shifting open drafts'
  offsets) and `fileFraudOriginal` (original → SCAMS, confirmed by Message-ID).
  Moved directly, **not** via `moveSelected` (that would add SCAMS to Recents
  and trigger a full index rebuild for an unfamiliar sender).
  `refreshAfterFraudFiling` re-lists the original's mailbox if on screen (even
  under a veil) or refreshes SCAMS in place. `recordSent` now **returns the
  banner text**, because ComposeView's "Message sent." overwrote anything shown
  from inside it. Also: **Subject in the message pane is selectable.**
- **`7946766` — HOLDING for unknown senders at watched domains.** See the
  waiting item above and Key context below.

### Diagnostics currently ON — four

    RemovalVeilDiagnostics.enabled                    AppModel.swift (queue 6)
    MessageColumnResizeController.diagnose            ContentView.swift (queue 6)
    AppModel.diagnoseDraftLookup                      AppModel.swift (item 15)
    AppModel.diagnoseHolding                          AppModel.swift (new; HOLDING)

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

### Added 2026oct16–18

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

### Added 2026oct18–23

**Two folders named `Eudora` collide in the mount.** With both the project and
`~/Eudora` connected, they mount as `$HOME/mnt/ClaudeProjects--Eudora` and
`$HOME/mnt/stephenmalinowski--Eudora`, not `mnt/Eudora`. `ls $HOME/mnt/` first;
a path that "doesn't exist" in the live tree is usually the wrong mount.

**An empty `.toc` (header, zero entries) means "empty mailbox", even over
ghosts.** Fixed in `7780eab`: `MailboxMutator.tocConsistent` is vacuously true
for it, and `MailStore.list` returns no rows rather than scanning. A review
agent checked `phaseX`: 17 mailboxes are header-only over a non-empty `.mbx`,
all genuine Eudora 7 ghost mailboxes that Eudora 7 itself showed as empty.
Header byte 44 (u16) = 1 marks "has uncompacted deletions"; byte 72 (u16) is
Eudora 7's total record count; byte 96 (u32) is mbx size+1 but goes stale once
this app patches. None of that is used yet — a possible guard if a header-only
index over *real* mail ever turns up.

**Consequence worth knowing:** a ghost-holding mailbox now lists and counts 0
but `deleteEmptyMailbox` still refuses it (`notEmpty`), and there is no Compact
command. Safe, but puzzling if it comes up — the natural fix is Compact.

**`appendRecord` now starts a `.toc` when appending into an empty mailbox
with none**, so a mailbox that lost its index heals once emptied. Before, only
`Outbox.append` (delivery/drafts) did; a move into it stayed "?" forever.

**Opening links: `BrowserOpener`** (`2035694`). When Chrome is the default
browser, Open in Browser runs an AppleScript that makes a new Chrome window and
centres it in the primary display's visible area; anything else falls back to
`NSWorkspace.open` with a `[browser]` diagnostics line. Needs the
`com.apple.security.automation.apple-events` entitlement
(`EudoraApp/Eudora.entitlements`, wired via `CODE_SIGN_ENTITLEMENTS` in
`project.yml`) and `NSAppleEventsUsageDescription` — without the entitlement
the script fails -1743 and never prompts. **Not yet seen by notarization**: the
next `Build Release to Share` is the first test of it.

**Find window focus: `FirstFieldFocuser`** (`91000ce`, `FindView.swift`). Every
command that opens Find goes through `FindView.open(openWindow)`, which also
posts `FindView.openRequested`; the focuser puts first responder in the topmost
editable `NSTextField` and selects all. AppKit, not `@FocusState`, for the
reasons in its doc comment.


### Added 2026oct23–25

**Adding `~/Eudora` to the session can unmount ClaudeProjects** (seen
2026oct25: after granting `~/Eudora`, `ls $HOME/mnt/` showed only `Eudora`, the
live tree). Re-request ClaudeProjects, and `ls $HOME/mnt/` before trusting a
path. After a reconnection *both* grants may be gone. Re-granting also resets
delete permission — test with a scratch file before git.

**What the unlabelled-bytes census found** (`phaseX`, header lines only):
5,639 non-ASCII lines are valid UTF-8, 3,433 are not (CP1252), 141 mix the two
(mostly spam, already garbage). Under the per-sequence decoder 173 of the
3,433 decode differently from pure CP1252, all of them improvements (emoji,
`€` beside NBSP). `MailStore.rawHeaderBlock` (the All Headers panel) still
decodes as Latin-1 by design; it was not touched.

**The blob rule, measured on the live tree (2026oct25):** stripped runs are
overwhelmingly DKIM-Signature (203K), X-Google-DKIM-Signature (80K),
ARC-Message-Signature (47K), ARC-Seal (37K), X-YMail-OSG (35K). The digit-or-`+`
condition exists because long letter-only runs are sometimes words — a
58-letter Welsh place name in a Subject, `donaudampfschiff…` in a Return-Path.
Letter-only spam-filter encodings (`gggrugg…` in X-VR-*/X-ME-Proxy-Cause)
survive and could still produce a chance hit; accepted.

**Find's snippet matcher is case- and diacritic-insensitive; the `LIKE` that
finds the row is ASCII-case-insensitive only.** The snippet can therefore
always locate what `LIKE` found. Don't tighten one without the other.

**`ComposeWindowPlacer` now has two callers.** `cascades: false` keeps the Find
window out of the compose cascade; `request` re-opens the once-only latch each
time the owner asks (Find bumps it in `onAppear`). A window already open is
never moved — the same promise as for composers.

**Sidebar reveal path:** `AppModel.sidebarReveal` (with a `serial`, so a
repeat is a change) → `MailboxTree.reveal`, which is in `==` → `applyReveal`
inside a `ScrollViewReader` wrapping `treeList`. The `.safeAreaInset` for the
pinned set now attaches to the reader rather than the List; it behaves the
same. Any future "show this mailbox" feature (Recents, View in Mailbox) can
reuse `revealInSidebar` — note that Recents picks into a collapsed group
currently select a mailbox the sidebar doesn't show.

---


### Added 2026oct25–nov13

**HOLDING rule (`HoldingRule.swift`, `AppModel` "holding unknown senders at
watched domains").** `holdingWatchedDomains = ["libero.it"]` — a constant, added
to case by case when Stephen names a domain. A watched-domain sender goes to the
top-level **HOLDING** mailbox (Stephen created it) unless known: in
`recentRecipients`, named in From/To/Cc anywhere in In or Out
(`LocalCorrespondents`, read once per check, 256 KB header window), or found by
`SearchIndex.mailboxesFiledInto` in any mailbox but SCAMS and HOLDING.
**"Can't tell" → In**, always (In/Out unreadable, no index, `isSearching`).
Held mail is **silent by Stephen's explicit choice**: not in `received`, no
glyph, no notice; its duplicates go in `heldDuplicates`, never reported.
`report(held:)` uses it only for the "check failed" wording. A watched-domain
message bound for In is dropped if HOLDING's own `MessageIDIndex` already has it.
**Known, accepted gap:** a correspondent whose only message was deleted
unanswered (Trash, ~600 MB, not scanned) is unknown until the next index
rebuild.

**Why not block by name/content:** the libero.it spam passes SPF/DKIM/DMARC
(it is sent through libero's real webmail), scores negative at TigerTech, and
uses a new address every time ("sender address seen 1 times"); SCAMS holds two
other libero campaigns with different names. Real libero.it correspondents:
Anceschi, Paternoster, Cerullo, Maltagliati, Carbonara, Mythic Picnic and a few
more, all filed in PEOPLE.

**`ComposeView` shows its own "Message sent." banner straight after
`recordSent`** — anything that wants to report on a send must return its text
through `recordSent`, not call `showBanner` itself.

**`SMTPClient.send` mints a fresh Message-ID**, so after `recordSent` the Out
record no longer carries the draft's ID; address it by the offset `recordSent`
wrote (`fileSentReport` does).

**`.textSelection(.enabled)` and `.disabled` are different types** — a ternary
between them won't compile.

**Forward as Attachment / Report Fraud attach as `application/octet-stream`
`.eml`, deliberately** (see `forwardAsAttachment`). Some scammer servers reject
`.eml` attachments outright (`usptoboard.com`, 2026nov03); that bounces only for
that recipient. If it becomes common, the scammer copy could go without the
attachment. The `.eml` filename truncates the subject mid-word — cosmetic,
offered to Stephen, not asked for.

**Review agents earned it again:** they caught a `\b` that let
`uspto.gov-mail.example` pass as uspto.gov, decoded-before-split recipient
headers (phantom recipients), every filing banner being overwritten,
`moveSelected` triggering a 12 GB index rebuild, held-mail duplicates breaking
the silence, and a `continue` skipping the UID checkpoint. Use two when a change
writes real mail.

---

