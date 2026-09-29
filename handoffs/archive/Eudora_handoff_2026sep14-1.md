Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026sep14 (1)

**Supersedes `Eudora_handoff_2026sep07-1.md`** (now in `handoffs/archive/`). Two
items of its queue are closed and should not be carried further: the sort-menu
duplication is resolved (see below), and **queue 4's dead-list diagnostics are
no longer the only thing switched on** — several more are now on and are listed
here. Everything else from its queue is repeated below rather than left behind.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects/Eudora` (pass the path
   directly; don't ask).
2. Mount `/Users/stephenmalinowski/ClaudeProjects` and read
   `claude-conventions.md`.
3. Read this project's `CLAUDE.md`.
4. Read this handoff, then **ask Stephen which of the queue below to take
   first**.

Two rules to have in front of you before typing anything. **One step at a time**
— one command, then wait. And **nothing actionable after a command block**: he
reads and acts in order, so anything placed after the commands arrives too late.

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done and
Stephen uses it all day. Work is ordinary improvement, driven by what he hits.

## Current state — READ THIS FIRST

**One commit landed. Everything after it is uncommitted and BUILT BUT PARTLY
UNTESTED.** `swift test` unchanged at **639, 0 failures** — nothing touched
`EudoraMac/`.

Committed and pushed earlier in the session:

- `Remove Sort Alphabetically, keeping only Sort Contents Alphabetically`
  — plus a line in `CLAUDE.md` recording that `EudoraDevelopmentNotes.txt` is
  gitignored.

**Uncommitted, with a ready message in `reference/commit-message.txt`:**

- `project.yml` — a scheme build **post-action** that installs every build to
  `/Applications/Eudora.app`. Working and verified.
- `EudoraApp.swift` — the mailto forwarding for a duplicate instance
  (**never once executed**), `eudoraDiag()`, trace points, a window census.
- `ContentView.swift`, `AppModel.swift` — trace points.
- `SplashWindow.swift` — new `disarm()`, and a comment recording the splash was
  ruled out as a cause of the second window.
- `ComposeWindow.swift` — corrected a doc comment that blamed state restoration.

`EudoraApp.xcodeproj` is gitignored; `xcodegen generate` has already been run
against the current `project.yml`.

### Diagnostics currently ON — more than usual

- `RemovalVeilDiagnostics` and `MessageColumnResizeController.diagnose` — the
  long-standing dead-list pair (queue 4), unchanged.
- `AppDelegate.diagnoseMailtoForward` — the `[trace]` points and the mailto
  forwarding lines.
- `AppDelegate.diagnoseReopen` — `[reopen]` plus the `[windows]` census.

Off: `MessageIDIndex.diagnose`, `BodyTextView.diagnoseSpelling`,
`BodyTextView.diagnoseMenuOrder`, `MessageContextMenuController.diagnosePlacement`,
`PinnedSetHeightReader.diagnose`.

## Done this session

**The mailto: mystery, and what was underneath it.** Clicking a `mailto:` with
Eudora running "opened a second Eudora". Three separate things turned out to be
tangled together, and two are fixed.

1. **The registered handler was a stale path.** Settings ▸ Default email app
   said "another copy of Eudora", pointing at
   `dist/DerivedData/Build/Products/Release/Eudora.app` — release.sh's *build
   product*, registered at some point by pressing the button while running the
   release build out of its build folder. Meanwhile the Dock tile pointed at an
   Xcode DerivedData build and `/Applications/Eudora.app` was from aug04. Every
   click launched a third copy, which the single-instance guard killed, taking
   the URL with it.

2. **`/Applications` is now kept current by the build.** A scheme build
   post-action in `project.yml`. It refuses to install a bundle that fails
   `codesign --verify`, refuses to overwrite a running copy (checked twice),
   stages the copy and swaps by rename, recovers the previous bundle if an
   earlier run died mid-swap, locks against an overlapping `release.sh` build,
   re-registers with `lsregister`, and can never fail a build. It logs to
   `~/Library/Logs/Eudora-install.log`. Stephen has dragged `/Applications`
   onto the Dock; the registration followed by itself.

3. **The mailto forwarding for a duplicate instance** — written, compiles,
   **never run**. See queue 0.

**The second main window is diagnosed at last.** The 2026sep03 sighting, unsolved
for eight handoffs. SwiftUI opens a new window from a `WindowGroup` to satisfy an
*external event*, and a `mailto:` arriving at a running app is one. The log is the
whole argument — two `ContentView.onAppear` at 12.823 and 12.950, then
`application(open:)` at 12.965. **The window exists before the URL reaches any
Eudora code**, which is why reading our own handling never explained it.

**Not fixed.** Both `handlesExternalEvents` settings were tried and both failed in
opposite directions; both reverted. Full account, including the two dead ends, in
`EudoraDevelopmentNotes.txt` under "The Dock tile, and the mailto: that went
nowhere". A comment beside `.commands` in `EudoraApp.swift` says the absence is
deliberate.

**Sort Alphabetically is gone from the mailbox context menu.** It sorted the list
the clicked item sat in, which on a folder was byte-for-byte the same operation
as its parent's Sort Contents Alphabetically. Only the contents sort remains;
mailboxes have no sort item. The top level is no longer sortable from the UI —
deliberate, and Stephen declined a Mailbox-menu replacement: the upper levels are
sparse and ordering them by hand is easy. Settled, not pending.

---

## The queue — ask Stephen which first

### 0. Finish what's on the bench (the likely first)

Three things, all cheap, none done:

- **The mailto forwarding has never run.** Launch from Xcode, click a `mailto:`
  in Chrome. A second Dock icon should appear for up to 3 s and go, and the
  Xcode-launched Eudora should come forward with a composer.
  `~/Library/Logs/Eudora-diagnostics.log` should carry
  `[mailto] captured 1 URL(s) in NNN ms; forwarding` and
  `[mailto] survivor received 1 forwarded URL(s)`. If instead it says
  `no launch URL after 3002 ms`, the run-loop pump is the problem and the
  fallback design is written out in the doc comment on `forwardLaunchURLs`.
- **Find and Blacklist still open from their menus** — not re-checked since the
  scene modifiers went in and came out.
- **Then commit.** `reference/commit-message.txt` is current and describes
  everything above. Decide the diagnostic flags first (see queue 1).

### 1. Close the second main window on sight

The fix the 2026sep03 entry prescribed, and now the one that looks right.
`MainWindowAccessor` already watches every window appearing and already decides
which is the real main one, so it is the place. `window.close()` bypasses
`windowShouldClose`, so it will not trigger the quit. Care needed not to close
the legitimate window and not to upset `SplashWindow.knownMainWindow`. Read the
sep14 notes entry first — it says what has already been eliminated, so the same
ground isn't covered twice. Once this works, `diagnoseMailtoForward` and
`diagnoseReopen` can go off and the trace points can come out or stay dark.

### 2. Dialogs open too far away to proofread

Stephen keeps the main window on a secondary display that's fine for menus and
too far to read typing on — he's slightly dyslexic and wants to see his own
typos. Three `PointerAlert` callers are text entry and are the ones that matter:
New Mailbox, Rename (both `MoveToMenu.swift`) and "Correct 'x' to…"
(`RichTextEditor.promptAddCorrection`). The other two — Delete PERMANENTLY and
Blacklist sender — are confirmations with nothing to read and should stay at the
pointer.

Three candidate targets were put to him and he hasn't chosen: centre in the
Eudora main window (safe, doesn't solve the reading problem); centre on the
primary display (solves it, but at night the primary is a blacked-out external
and the dialog is modal); or primary-unless-Eudora-is-on-the-built-in, which
infers night mode from where night-mode.lua has put the window. **Re-open that
question before writing anything.** `New Mailbox` lands at the top edge because
`PointerAlert` clamps a tall panel to the pointer's screen; `PointerAlert.traceEnabled`
would confirm that in one run.

### 3. `MailboxMutator` rebuilds the `.toc` instead of patching it

`TocWriter.data(entries:)` writes the seven fields `Toc` models and zeroes the
other 210 bytes of each 218-byte entry plus the 104-byte folder header. Measured
over `phaseX`: **97% of entries carry non-zero bytes outside those fields** and
116 of 120 folder headers are non-empty. `setStatus` and `replace` both rebuild
the whole index, so every status change blanks them. Eudora 8 doesn't read them,
so nothing visible breaks — but it is silent, ongoing loss of Eudora 7's only
record of some things. `RecordedAttachmentRelink.patchedToc` is the shape of the
fix — read offset/length, write offset/length, copy everything else — but
`setStatus` also changes a status byte and `replace` needs the cached
date/to/subject columns, so it is "patch these fields in place" rather than a
straight lift. Testable in `EudoraMac/` with the byte-poking fixture
(`testTocBytesOutsideTheModelledFieldsSurvive`). **This was the sep07 handoff's
pick for the real work and never got started.**

### 4. Seven mailboxes with a `.toc` that doesn't describe the `.mbx`

`eudora-relink` skipped these, leaving 11 messages unrelinked:
`PEOPLE.fol/C.FOL/CarlLumm`, `PEOPLE.fol/E.FOL/Etienne Abelin`,
`PEOPLE.fol/J.FOL/JA.fol/James Carmichael`, `PEOPLE.fol/A.FOL/Anna Detrick`,
`PEOPLE.fol/G.FOL/Grace Cho`, `PEOPLE.fol/A.FOL/Andreya von Waldenfels-Marks`,
`__MAM.fol/MISCINQ`. Large mailboxes (16,918 / 6,420 / 7,173 / 5,128 messages).
The skip rule is strict — *every* `.toc` entry must name a record — while
`MailStore` trusts a `.toc` at a simple majority. Two questions first: how stale
is each, and is there a safe way to rebuild an index without losing the status
flags it is the only copy of. Follows naturally from queue 3. Re-running the
tool is easy (idempotent; refuses when a `.prerelink` backup exists, so move it
aside first).

### 5. Confirm the letter-group auto-sort

Built on sep07, **still never exercised**. Create a mailbox inside a PEOPLE or
ORGANIZATIONS letter group, and move an existing one into another; each should
land in alphabetical position with no banner beyond the usual create/move one.
Then decide whether **rename** inside a letter group should re-sort too (it
doesn't). Small either way. Note the rule is "display name is one character", so
ORGANIZATIONS' A–Z groups get it as well as PEOPLE's.

### 6. `MIMEParser.parseHeaders` decodes CP1252 headers as UTF-8

`String(decoding: bytes, as: UTF8.self)` at `MIME.swift:359`. Every non-ASCII
header byte becomes U+FFFD (`CarterCaténaires.png` → `CarterCat<?>naires.png`).
`CP1252.decode` exists and is what `Toc.cString` uses. Small change, every
header in the app goes through it — wants its own session and a look at what
depends on the lossy behaviour.

### 7. Dead message list after a move — still instrumented, still waiting

Unchanged for nine handoffs, **not reproduced**. Both diagnostics still on.
Read `RemovalVeilDiagnostics`' doc comment (`AppModel.swift`, above `PerfLog`).
`VEIL DOWN` present with clicks still dead ⇒ the veil is innocent, read the
`[resize]` lines. **Turn both off once settled.** The inspection-found hole:
three of the four arms of `loadListing`'s scroll-restore chain nil
`pendingScrollTopRow`, and `clearPendingScroll` lifts the veil only when it
finds one pending. Doesn't fit that Stephen's lasted minutes.

### 8. The only known open bug that can duplicate mail

`shiftDraftOffsets` is called only from the draft-save paths, never from
`deleteSelected` or `moveSelected`. Deleting or moving a record in **Out** while
other drafts are open strands their offsets; each later save appends a copy.
`MenuBarView`'s Delete is gated on `canActOnSelection` alone and can reach it.

### 9. Remaining View Response loose end

The jump reads the destination mailbox in full on the main thread:
`MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a whole-file
scan. (Stephen didn't recognise this one on aug31 — re-explain before doing.)

### 10. Gmail-side blacklisting, if he wants Eudora to do it

`users.settings.filters.create`, `from:` → `addLabelIds: ["TRASH"]`, one filter
per address, 1,000-filter ceiling. The price is **OAuth2**. Two sharp edges: the
consent screen must be published "In Production" or refresh tokens expire after
7 days; published-but-unverified means a sign-in warning and a 100-user cap,
which is fine for him alone and not for the notarized Eudora he shares. The
argument for: the same subsystem closes the POP/SMTP OAuth2 gap. Don't start it
without him choosing it deliberately.

### 11. Older doc loose ends, still open

- `SidebarExpansion`'s doc comment claims a rename changes a `MailboxItem.ID`.
  Wrong, and load-bearing for Recents.
- `AppModel.swift`'s doc on `removalNotice` describes "Moved to Trash." as a
  delete's completion message; no delete path passes a notice.
- `EudoraDevelopmentNotes.txt:2219` names `MailboxItem.hasUnread`, which no
  longer exists.
- `SidebarOutlineFinder` is **ambiguous** since the pinning — two single-column
  headerless `NSTableView`s. Only switched-off probes use it;
  `SidebarRowSizeStyleTrial` *mutates* what it finds. The outline is the taller.

### 12. Test list — still outstanding

- A sent message with both a real MIME attachment and an `X-Attachments` header
  (187 in `phaseX`) — the file must appear once, as a working chip.
- Most of Recents: rename and delete of a listed mailbox, the empty menu,
  clicking the blank right-hand part of the row.
- Several compose windows at once: save a middle one then another; no duplicate
  in Out (queue 8's bug — a failure is expected).
- A plain unstyled message must still be a single `text/plain` part.
- View Response with a second reply left as an unsent draft, and with two sent.
- Open sender's mailbox on a sender with mail in several places, and on one
  with none ("None found", not an empty submenu).
- Blacklist routing on a message with no `Delivered-To` — both lists.

### 13. Housekeeping left behind by the relink

- **156 `.mbx.prerelink` / `.toc.prerelink` files** in `~/Eudora`. Their presence
  blocks a re-run on that mailbox by design. Worth confirming they never show in
  the sidebar (the walk looks for `.mbx`; nobody has looked).
- **The Laetrile PDF**: one curated location dropped — a non-breaking space in
  the on-disk name, and no longer at the recorded path by the time the tool ran.
- **`reference/missing-attachment-names.md` is built from `phaseX`** (2026apr03).
  `python3 reference/list-recorded-attachments.py ~/Eudora` regenerates it
  against the live tree; Stephen runs it.

---

## Key context

**Claude cannot build or test.** Write carefully → Stephen builds and runs
`swift test` → he pastes the errors. Prefer `EudoraMac/` over `EudoraApp/`.

**`print()` IS INVISIBLE FOR AN APP LAUNCHED BY LAUNCHSERVICES, and launching
the binary directly to see stdout CHANGES THE BEHAVIOUR.** A direct launch
bypasses LaunchServices and gave three windows at launch where
`open /Applications/Eudora.app` gave one. Most of sep14 went into measuring that
artefact. Use the new **`eudoraDiag()`** (top of `EudoraApp.swift`) for anything
about launch or URL behaviour; it appends to
`~/Library/Logs/Eudora-diagnostics.log` as well as stdout.

**`ContentView.onAppear` is not a window counter.** It fired twice on a cold
launch whose census showed exactly one main window. Only the `[windows]` census
is trustworthy.

**Anything that touches the built product must run AFTER signing**, which means a
scheme post-action, not a `postBuildScripts` phase — Xcode signs after every
build phase. A build phase installed an unsigned bundle and the kernel killed it
with `Killed: 9`. Incremental builds hid it, because a copy taken when nothing
relinked picks up a still-signed binary. **`codesign` has no `--quiet`**; passing
one exits 2, which reads as "invalid".

**Use `general-purpose` review agents before handing anything over, and two when
the change writes to real data.** Both sep14 reviews caught real defects,
including a destructive one: the install script's staged swap was safe for its
own run but the *next* run's leading `rm -rf` would have deleted the only
surviving copy.

**A kept old build is a cheap bisect.** `dist/DerivedData/Build/Products/Release/`
still holds the aug04 release, and running it is what ruled out every change made
that day.

**Find's engine is `LIKE` over stored columns, not FTS `MATCH`.** Case-insensitive
substring, `ESCAPE '\'`. `TextTarget.columns` says which columns each Where
searches; Anywhere is all six including raw `headers`. The snippet comes from
`body` only — a match in any other column is invisible in the results row.

**`ContentExtractor` (EudoraSearch/Content.swift) is what the index holds.**
Add a column's contents there; the schema check `hasCurrentSchema` only tests
for the `headers`/`epoch` columns, so a content change without a column change
needs a manual Rebuild Search Index.

**Main window close = Quit**, by design (`CloseToQuitProxy`, `SplashWindow.swift`).
Compose and Find windows close normally.

**The tree is in file order on purpose.** `sortEntries` is the one-off action;
the only automatic sort is the single-letter-group rule (queue 5).

**A literal tab inside a Swift raw string won't compile.** Use `"\t"`.

**`phaseX` is a copy** (2026apr03). Anything generated from it is private and
belongs in `reference/` (gitignored); the repo is public.

**`eudora-relink`**: `swift run -c release eudora-relink <root> <locations.tsv>`
is a dry run; `--apply` writes; `--mailbox <path>` restricts; idempotent; refuses
a mailbox whose backup exists; Eudora must be quit.

**For performance, `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary is
`Eudora`.

**Claude must not run git**, and cannot delete files. Write the message to
`reference/commit-message.txt` (gitignored) and hand over `git commit -F`,
naming the changed files explicitly. **Never name `EudoraDevelopmentNotes.txt` in
a pathspec — it is gitignored, and the whole commit aborts.** A new file needs
`git add` first. Recovery from a stranded lock: `rm -f .git/index.lock`.

**Assets and files:** a new file under `EudoraApp/Sources` needs `xcodegen
generate`, run *after* writing it — and so does any `project.yml` change. Files
in `EudoraMac/` and new imagesets in `Assets.xcassets` don't. Icon generators
live in `assets/` and write straight into the catalog.

**Releasing** is a double-click on `Build Release to Share.command`. Note the
post-action now installs the Release build to `/Applications` *before*
release.sh staples it, so **Gatekeeper must be tested against `dist/`, never
against `/Applications`.**

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. See queue 10.

**musanim.com and gmail.com are independent mailboxes**, collected separately.

**Hammerspoon** carries `night-mode.lua` (Stephen's, moves Eudora's windows to
the built-in display at night; the externals go black). Repo copy
`scripts/night-mode.lua`, live copy `~/.hammerspoon/night-mode.lua`. It is the
reason queue 2 can't simply centre dialogs on the primary display.

---

## Next session

Ask him rather than choosing. The natural order is **queue 0** — finish the
bench, then commit, so nothing is carried further uncommitted — and then either
**queue 1** (close the second window on sight, while the diagnosis is fresh and
the diagnostics are still on) or **queue 2**, which is his own request and has an
open question waiting on him. **Queue 3 remains the largest real work** and has
now been deferred twice.

The user will likely ask you to take queue 0 first.
