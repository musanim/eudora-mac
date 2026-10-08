Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026sep29 (1)

**Supersedes `Eudora_handoff_2026sep14-1.md`.** Four of its queue items are
closed and must not be carried further: queue 0 (the bench) and queue 1 (the
second main window) are done, committed and pushed. Two of its **Key context**
entries are now WRONG and are replaced below — *Claude must not run git* (it
now does) and *Claude cannot see `~/Eudora`* (it can, on request). Everything
else from its queue is repeated here rather than left behind.

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

## Current state

**Everything is committed. Nothing is uncommitted.** `swift test` passes and the
app builds; every change below was built and confirmed by Stephen before being
committed.

**FIVE COMMITS ARE UNPUSHED** — Claude commits, Stephen pushes:

    9a4db08  Check delete permission before each git session, not once
    499d416  Show every body part, not just the first
    1c7c7e2  Claude runs git in this project now; Stephen still pushes
    7ca6204  Archive the older handoffs
    3be5f7b  Ignore the notarization password

One untracked file left alone deliberately: `EudoraNotes_2026jul27.txt`. Unlike
`EudoraDevelopmentNotes.txt` it is not obviously a scratchpad, and whether it
belongs in a public repo is Stephen's call.

### Diagnostics currently ON — six of them, which is too many

    RemovalVeilDiagnostics.enabled                    AppModel.swift:454
    MessageColumnResizeController.diagnose            ContentView.swift:2762
    AppDelegate.diagnoseMailtoForward                 EudoraApp.swift:438
    AppDelegate.diagnoseReopen                        EudoraApp.swift:445
    MainWindowAccessor.diagnoseExtraWindow            SplashWindow.swift:293
    ComposeWindowPlacer.diagnoseComposePlacement      ComposeWindow.swift:253

The first two are the long-standing dead-list pair (queue 6). The other four
have all served their purpose; see queue 0.

## Done since 2026sep14

**The mailto: path, end to end.** `/Applications` is kept current by a scheme
build post-action; a duplicate instance forwards its URL to the survivor instead
of taking it to the grave (confirmed working — the pump does dispatch the GURL
event, so the fallback on `forwardLaunchURLs` is not needed); and the second
main window, open since 2026sep03, is closed on sight in `MainWindowAccessor`.

**Compose windows open where they should.** A setting — **off by default** —
called "Stephen's special night-mode behavior" (Settings ▸ Windows,
`AppModel.nightModeComposePlacement`). On: a new compose window opens on the
built-in display when the main window is there (night mode), and centred on the
**primary** display otherwise, whichever display the main window is on. Every
new window, every time; a window already open is never moved.

**Destroyed mail leaves a rescue copy in the Finder's Trash.** All four paths
that destroy rather than file — Delete PERMANENTLY, blacklist, and plain Delete
both from the Trash mailbox and with no Trash mailbox — write the message out as
`Eudora deleted 2026-09-19 14.22.05 — Sender — Subject.txt` and trash it. See
`DeletedMessageArchive`.

**Text after an attachment is shown at last.** Three readers of "the body" kept
only the first text part; `MessageBody` (EudoraStore, 20 tests) now decides for
all three, per RFC 2046 per container.

**Git changed hands** (2026sep20, at Stephen's request) — see `CLAUDE.md`.

Full accounts of all of these, including the dead ends, are in
`EudoraDevelopmentNotes.txt` under their dated headings.

---

## The queue — ask Stephen which first

### 0. Turn the diagnostics off (cheap, and overdue)

Four of the six above have done their job. `diagnoseMailtoForward` and
`diagnoseReopen` were to be turned off once the second window was fixed, and it
is. `diagnoseExtraWindow` and `diagnoseComposePlacement` were each to be watched
"for a few days"; it has been more than a week for the first.

**One thing must be read before `diagnoseMailtoForward` goes off**: the measured
`[mailto] captured 1 URL(s) in NNN ms` in
`~/Library/Logs/Eudora-diagnostics.log`. `AppDelegate.launchURLWait` is 3.0 s
rather than 0.5 only until that number is known, and dropping it is the point.

### 1. Dialogs open too far away to proofread

**Stephen's own request, and the open question is still waiting on him.** He
keeps the main window on a secondary display that's fine for menus and too far
to read typing on; he's slightly dyslexic and wants to see his own typos. Three
`PointerAlert` callers are text entry and are the ones that matter: New Mailbox,
Rename (both `MoveToMenu.swift`) and "Correct 'x' to…"
(`RichTextEditor.promptAddCorrection`). The other two — Delete PERMANENTLY and
Blacklist sender — are confirmations with nothing to read and should stay at the
pointer.

Three candidate targets were put to him in September and he hasn't chosen:
centre in the Eudora main window; centre on the primary display; or
primary-unless-Eudora-is-on-the-built-in. **Re-open that question before writing
anything** — and note it is now much easier to answer, because
`ComposeWindowPlacer` has already settled the same argument for compose windows
and its rule ("built-in when the main window is there, primary otherwise") is
almost certainly the one he wants here too. The Settings label was deliberately
written broad enough to cover this as a second member.

`New Mailbox` lands at the top edge because `PointerAlert` clamps a tall panel to
the pointer's screen; `PointerAlert.traceEnabled` would confirm that in one run.

### 2. `MailboxMutator` rebuilds the `.toc` instead of patching it

**The largest real work, now deferred four times.** `TocWriter.data(entries:)`
writes the seven fields `Toc` models and zeroes the other 210 bytes of each
218-byte entry plus the 104-byte folder header. Measured over `phaseX`: **97% of
entries carry non-zero bytes outside those fields** and 116 of 120 folder headers
are non-empty. `setStatus` and `replace` both rebuild the whole index, so every
status change blanks them. Eudora 8 doesn't read them, so nothing visible breaks
— but it is silent, ongoing loss of Eudora 7's only record of some things.
`RecordedAttachmentRelink.patchedToc` is the shape of the fix — read
offset/length, write offset/length, copy everything else — but `setStatus` also
changes a status byte and `replace` needs the cached date/to/subject columns, so
it is "patch these fields in place" rather than a straight lift. Testable in
`EudoraMac/` with the byte-poking fixture
(`testTocBytesOutsideTheModelledFieldsSurvive`).

### 3. Is his outgoing mail being filtered? — INCONCLUSIVE, and the next step is his

Stephen's report (2026sep29): since the cutover, far more of his sent mail gets
no reply, including from people who had answered same-day for years.

Checked, and none of it supports a blocklist:

- `musanim.com` publishes `v=spf1 include:tigertech.net ~all` and a DMARC record
  (`p=none`). Neither is misconfigured.
- Both TigerTech outbound relays that carry his mail — 208.80.4.151 and .152 —
  are **unlisted** on Spamhaus Zen (query answered, not refused).
- Four delivery failures in four months, all mundane: a mailbox that doesn't
  exist, an unsubscribe address, a `.gov.uk` notifications address. No spam
  rejection.
- What Eudora 8 writes on the wire is standards-clean, and `Bcc` is kept to the
  local archive copy only.
- 54% of messages Eudora 8 has sent got a reply that threads back.

**The before/after could not be measured, and that attempt should not be
repeated as it was.** Reply-rate-by-Message-ID gives 0–5% for *every* Eudora 7
year from 2015 to 2025, including years known to be normal — the threading
doesn't survive into that era. There is no baseline in the archive.

**Next step is Stephen's, not Claude's**: send a message from Eudora 8 to the
address `mail-tester.com` gives, and read the score. It reports what a receiving
filter sees, including whether **DKIM** passes and aligns — the one thing that
could not be checked from here, because it needs a message of his as a third
party received it. If that is clean, the mundane explanation (several reliable
correspondents changing jobs or addresses at once) is the likelier one.

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

### 7. The only known open bug that can duplicate mail

`shiftDraftOffsets` is called only from the draft-save paths, never from
`deleteSelected` or `moveSelected`. Deleting or moving a record in **Out** while
other drafts are open strands their offsets; each later save appends a copy.
`MenuBarView`'s Delete is gated on `canActOnSelection` alone and can reach it.

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

---

## Next session

Ask him rather than choosing. The natural order is **queue 0** — four
diagnostics have done their job and the log has the number that lets
`launchURLWait` come down — and then either **queue 1**, which is his own request
and has an open question that `ComposeWindowPlacer` has since made much easier to
answer, or **queue 2**, the `.toc` patching, which remains the largest real work
and has now been deferred four times.

**Queue 3 is waiting on him, not on Claude**: one message to mail-tester.com
settles whether the missing replies are a delivery problem at all, and nothing
further should be built on that question until it does.

Five commits are unpushed.
