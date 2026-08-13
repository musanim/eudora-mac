Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug12 (1)

**Supersedes `Eudora_handoff_2026aug11-1.md`.** Three of its items are closed:
the commit is done, the iPad question is answered (section 8 of
`design-decisions.md`, rewritten), and the `sendBlacklistNotice` Trash-copy loose
end is fixed at the source. Everything else from it is repeated below rather than
left behind.

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

**One Swift change is written, reviewed, and not built.** Blacklisting now
destroys the message outright instead of moving it to Trash, and keeps no copy of
the notice reply. Files: `AppModel.swift`, `MessageContextMenu.swift`. A review
agent checked it for compile-level problems and found one, which is fixed
(`selectionIsInTrash` was left dead and its doc comment was false; the property
is gone). **Build it before committing.**

**Nothing is committed.** The message is waiting at
`reference/commit-message.txt`. It covers the Swift change, the new
`scripts/night-mode.lua`, the deletion of `scripts/eudora-park.lua`, and the
rewritten section 8. **`scripts/eudora-park.lua` still needs deleting** — the
sandbox can't unlink, so `git rm` is in the command block Claude handed over.

`swift test` was passing at 564 tests before this change, and nothing in
`EudoraMac/` was touched. No test covers the blacklist notice: the only blacklist
test is `BlacklistQueueTests`, which exercises the queue.

Diagnostics: `RemovalVeilDiagnostics` and `MessageColumnResizeController.diagnose`
are still **on** for the dead-list bug. `MessageIDIndex.diagnose`,
`BodyTextView.diagnoseSpelling` and `BodyTextView.diagnoseMenuOrder` are **off**,
each with its finding in its doc comment.

## Done this session

- **Committed the previous session's work** (filing-triggered reindex,
  capitalized spelling guesses, `MessageIDIndex.diagnose` off).
- **The iPad problem is solved, outside Eudora.** `scripts/night-mode.lua` plus
  `m1ddc`. Read section 8 of `design-decisions.md` — it is long because four
  separate things had to be learned the hard way, and every one of them will
  otherwise be re-derived.
- **Blacklisting destroys rather than files.** Written, not built.

## The one thing to know that isn't in the docs

**The night-mode work cost most of a day, and most of that was avoidable.**
Three separate "it doesn't work" rounds were spent on: a script that had been
copied to `~/.hammerspoon/` but not reloaded; an event tap macOS had silently
disabled because the callback read `hs.settings`; and a hotkey that could not
fire because `hs.execute` was blocking the main thread. In all three, one probe
would have settled in a minute what an evening of reasoning did not. The
project's own rule — instrument rather than theorise — applies to Hammerspoon
exactly as it applies to Swift, and the probe that finally worked
(`hs.eventtap.new` printing `pid` and `state` per keystroke) is three lines.

---

## The queue — ask Stephen which first

### 1. Build, test, and commit

See Current state. The blacklist change is the only unbuilt thing.

### 2. Tonight's night-mode run is the real test

Everything so far was tested at the desk in daylight. What has never happened:
night mode on, an evening's mail read and answered from the iPad, and the desk
woken in the morning by touching the mouse. Things to watch:

- **A compose window opened from bed.** `sweepStrays` should pull it onto the
  built-in within five seconds. This is the failure that made the first night
  unusable, and it is the one thing that has not been exercised end to end.
- **Whether the morning restore returns Eudora to where it was.** The frame is
  saved as a screen UUID plus an offset from that screen's origin.
- **Whether the two DDC displays come back to their previous brightness.** If one
  doesn't, the script keeps its record and says so rather than clearing it.

`nightMode.status()` in the Hammerspoon console reports everything relevant.
There is also an automatic restore at 07:00 whatever else fails.

### 3. The filing-triggered reindex is still untested

Written two sessions ago, built, never exercised. Filing to a mailbox the
correspondent has never gone to should start a rebuild — **"Indexing…" should
appear about a second *after* the message list settles, not during it.** If it
appears while the list is still veiled, the deferral isn't working, and that
matters: the rebuild reads the whole 12 GB tree, and starting it against the
veil-lifting read is exactly how the dead-list bug would be made worse.

Two known costs, both deliberate, both to reconsider only if Stephen feels them:

- **The predicate is broad.** It fires whenever the index has no record of this
  correspondence in the destination, which includes filing a *known*
  correspondent into a topic mailbox. Narrowing it to "new correspondent or
  brand-new mailbox" is a one-line change to `filingIsUnfamiliar`.
- **The move path now costs 50–300 ms** before the veil goes up, and on the
  menu-driven route that work is done twice. Caching `filingCounts()` against the
  selection would make the second free.

### 4. Dead message list after a move — still instrumented, still waiting

Unchanged for four handoffs and **not reproduced**. Both diagnostics still on.
Read `RemovalVeilDiagnostics`' doc comment (`AppModel.swift`, above `PerfLog`)
for the healthy trace and the two failures to look for. `VEIL DOWN` present with
clicks still dead ⇒ the veil is innocent, read the `[resize]` lines. **Turn both
off once settled.**

The inspection-found hole still stands: three of the four arms of `loadListing`'s
scroll-restore chain set `pendingScrollTopRow` to nil, and `clearPendingScroll`
lifts the veil *only* when it finds one pending. What doesn't fit is that
Stephen's lasted minutes, not fifteen seconds.

### 5. One behaviour change he may want reversed

`menu(for:)`/`willOpenMenu` bail unless the view is editable, so **"Correct
'word' to…" no longer appears when right-clicking a word in a message you are
reading.** It was dead there anyway (no controller to save through), but it was
visible. Say the word and it comes back for the reader without the case guesses,
which are the part that would have rewritten displayed mail.

### 6. Remaining View Response loose end

The first of the two is now fixed — the blacklist notice no longer exists to be
found. Still open: **the jump reads the destination mailbox in full on the main
thread.** `MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a
whole-file record scan, unbounded.

### 7. Older loose ends, still open

- `SidebarExpansion`'s doc comment claims a rename changes a `MailboxItem.ID`.
  Wrong, and now load-bearing for Recents.
- `shiftDraftOffsets` is called only from the draft-save paths, never from
  `deleteSelected` or `moveSelected`. Deleting or moving a record in **Out** while
  other drafts are open strands their offsets, and each later save then appends a
  copy instead of updating. `MenuBarView`'s Delete is gated on
  `canActOnSelection` alone and can still reach it. **This is the only known open
  bug that can duplicate mail.**
- **CLAUDE.md should say that `~/Eudora` is the live mail tree and `phaseX` is a
  copy for reading.** The omission already cost a seed list built from
  three-week-old data.
- `AppModel.swift`'s doc on `removalNotice` describes "Moved to Trash." as a
  delete's completion message. No delete path passes a notice; the only "Moved
  to…" comes from `moveSelected`. Cosmetic, but wrong.

### 8. Test list, unchanged

- **A plain unstyled message must still be a single `text/plain` part** — the
  regression guard for the whole image change.
- View Response with a second reply left open as an unsent draft, and with two
  sent replies.
- Most of Recents: rename and delete of a listed mailbox, the empty menu, and
  clicking the blank right-hand part of the row.
- Several compose windows at once: three or four open, save a middle one then
  another, and confirm neither produces a duplicate in Out.
- **Add to BLACKLIST**, new this session: confirm the message vanishes rather
  than appearing in Trash, that no copy of the notice appears in Trash or Out,
  and that the notice still arrives.

---

## Key context

**Claude cannot build**, and cannot run `swift test` either — Stephen runs both.
Write carefully → he builds → he pastes errors. Prefer `EudoraMac/` over
`EudoraApp/`, where it can be tested.

**Use `general-purpose` review agents before handing anything over.** They earned
their keep four more times today, on Lua rather than Swift: a restore that
recorded the window's position *after* macOS had already moved it, absolute
screen coordinates that shift when the primary display changes, a parked flag
that could silently disagree with reality, and — the one that mattered most —
several paths that would have left the desk dark with no record of how to undo
it.

**Instrument rather than theorise.** See "the one thing to know" above.

**For performance, use `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary
is `Eudora`, not `EudoraApp`.

**Claude must not run git**, and cannot delete files either — the sandbox can't
unlink. Write the message to `reference/commit-message.txt` (gitignored) and hand
over `git commit -F`. Recovery: `rm -f .git/index.lock`. Claude *can* read
`.git/logs/HEAD` to see what has been committed.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't.
Nothing was added to either today.

**Releasing** is a double-click on `Build Release to Share.command`.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap.

**Hammerspoon** now carries `night-mode.lua`, which is Stephen's, not Eudora's,
but the two touch: it moves Eudora's windows. The repo copy is at
`scripts/night-mode.lua` and the live copy at `~/.hammerspoon/night-mode.lua`.
**Editing the repo copy does nothing until it is copied over and Hammerspoon is
reloaded** — that alone cost a full test round.

---

The likely first request is to build and commit — see queue item 1 — and then to
hear how the night went. Ask him rather than choosing, and don't start work off
this list without his say-so.
