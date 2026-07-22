# Handoff: Eudora (macOS successor) — 2026jul20

Continues `handoffs/Eudora_handoff_2026jul19_evening.md`. That session's next-steps
list is done or superseded. This session was **column sorting, the mouse wheel,
keyboard shortcuts, Gmail setup, and the big one — Eudora 7-style outgoing mail**.

**Read `CLAUDE.md` first** (added this session). It records how to work here, and
one rule above all: **ask Stephen questions in plain prose, never the
multiple-choice widget** — it doesn't render reliably for him.

## Goal
Native macOS email client to replace Windows Eudora 7: reads the existing Eudora
tree in place, mirrors the mailbox layout, matches/beats its search. Security
stance: a **"dumb" client** — no active behaviour a message can trigger.
`EudoraMac/` is a SwiftPM package (EudoraStore / EudoraSearch / EudoraNet);
`EudoraApp/` is the SwiftUI app built via XcodeGen.

## Completed this session
Five commits. **`6b44831`, `5d6158a`, `ae87e5d` are unpushed** (`git push`).

- **`e45eef9` Column sorting.** Click a header to sort, click again to reverse;
  the glyph column sorts by status (left half) or attachment (right half). Sort
  is per mailbox and persisted in `ViewState`. `rows` is sorted *in place* so it
  stays display order — that's what keeps the right-click menu's row→id mapping
  and the scroll restore correct without touching them. `MessageRow.sortDate`
  gives Date a real key. There is **no single TOC date format**: modelling the
  parser in Python over all 245,671 TOC entries found sixty-odd shapes; the ten
  in `EudoraDateFormat.tocFormats` leave 0.03% unparsed.
- **`7188b41` Mouse wheel.** It read the top row from `rows(in: visibleRect)`
  (which includes the 28 pt band under the header) but wrote the new position
  with that inset subtracted — so every notch targeted a row at or behind where
  the list already was. `Scrolling.topVisibleRow` / `originY` are now inverses of
  each other and the wheel, the recorder and the restore all go through them.
- **`c9b81f5` Keyboard shortcuts + readable errors.** See gotchas.
- **`6b44831` + `5d6158a` + `ae87e5d` Outgoing mail.** The big one, below.

### Outgoing mail (the Eudora 7 model)
A new message is a record in **Out** as **unsent** the moment it's opened, before
you type. Send turns that same record into a sent one. Closing prompts Save /
Don't Save / Cancel. Each message gets **its own window**; several can be open.
Double-clicking an unsent or send-error message in Out reopens it.

- `MailboxMutator.replace` rewrites a record in place and reports `delta`, since
  every later offset shifts. `AppModel.openDrafts` owns the drafts (not the
  windows) so `shiftDraftOffsets` can correct them all — a window holding its own
  offset goes stale the moment an earlier draft is saved.
- **Identity is the Message-ID, not the offset.** Delete a message the same
  length as an open draft and the stale offset lands on a *different real
  message*, which Save would overwrite. `locateDraft` checks the ID, fails
  closed, and falls back to finding the record by ID when the offset is stale.
- States: unsent (9), sent (8), **send-error (5)** on a failed send, with
  Stephen's art (`assets/make-row-icons.py` adds the alpha channel; rerun it if
  art is replaced). Send-error reverts to unsent on the next save. `isDraft`
  (`isUnsent || isSendError`) is what every behaviour keys off.
- Closing goes through `windowShouldClose` via a proxy `NSWindowDelegate`
  (`ComposeWindow.WindowCloseGuard`), because `dismiss()` doesn't consult it.

### Three silent pre-existing bugs found on the way
- **`rfc822` appends nothing after the body**, so a message not ending in a
  newline produced a record not ending at a line boundary — the next record's
  separator was then not at a line start, `findRecords` stopped seeing it, and
  two messages **merged into one**. All record writing now goes through
  `Mbox.record`; `Outbox.append` also pads when the existing file ends mid-line.
- **`Outbox.append` deleted the `.toc`** whenever it didn't match record-for-
  record — i.e. any mailbox with deleted-but-uncompacted ghosts. Tolerable when
  appending only happened on send; fatal once it happens on every ⌘N.
- **`Outbox` wrote the TOC date as "Mon Jul 20 2026"**, which nothing can parse.

### Timing work
Deleting took ~6 s to put the list back. `sample` showed the app **idle** three
quarters of that; `PerfLog` showed a 4,017 ms gap between the read finishing and
the rows appearing. The read's *continuation* was blocked: publishing the tree
bumped `treeVersion`, which re-rendered the sidebar (6,699 nodes) and the Move
menu (2,657 items) on the main actor. Fixes: the tree refresh now runs **after**
the rows land (via `rebuildRows`'s completion), `reloadTree` is off the main
thread with a one-in-flight latch, `AppModel.base(ofType:)` answers from the
in-memory tree, and `treeStructureVersion` separates shape from counts.
**Delete → list on screen is now 239 ms.**

## Current state
Working tree clean, everything committed. Nothing half-done. Three commits need
pushing.

## Next steps
1. **Task 13 — make the toolbar and Transfer Move menus lazy AppKit menus.** They
   still materialise all 2,657 items on every delete (measured 1,137 samples in
   `NSToolbarItemViewer` layout). `.equatable()` stops the body re-running but not
   the platform item list rebuilding when the toolbar item is invalidated — which
   the Move button's `.disabled(!hasSelection)` guarantees. `MessageContextMenu`
   already solved this exact problem: `NSMenu` + `MailboxMenuBuilder` filling one
   level per `menuNeedsUpdate:`. Now *after* the list returns, so it's an
   optimisation, not a fix.
2. **`splitAddresses` ignores quoting.** `"Doe, Jane" <j@d.com>` splits on the
   comma into two bogus addresses. On the send path already; drafts make it
   repeatable, damaging the message a bit more on each round trip.
3. **Two copies of the app can open the same tree** and silently overwrite each
   other's writes (confirmed: `pgrep -x Eudora` returned two PIDs). Both read the
   whole `.mbx`, modify in memory, and atomically replace. Eudora's `.lck`
   convention is right there and we don't write one.
4. Deferred, none chosen: memory-mapping the `.mbx` reads (perf part 3 from the
   last handoff), address book (`nndbase.txt`), filters (`filters.pce`),
   incremental indexing, Text-Encoding override, compaction.
5. Small: splash art is 1x only; **File ▸ Open** on a running app still blocks;
   Message commands are disabled app-wide whenever *any* draft window is open
   (accepted trade — a command menu can't tell which window is key, and ⌘⌫
   reaching Delete while typing is unrecoverable).

## Key context / gotchas
- **Build loop**: Claude cannot compile. Write carefully → Stephen builds →
  pastes errors. **Use review agents for anything non-trivial.** This session
  they caught, among others: the model correcting draft offsets while the window
  went on reading its own stale copy; `dismiss()` bypassing the Save prompt so
  Escape would discard edits silently; an unbounded duplicate-append when
  reopening a draft real Eudora wrote; and Mark as Read destroying a draft's
  unsent state in one keystroke.
- **Verify library changes for real**: `cd EudoraMac && swift test`.
  `MailboxReplaceTests` deliberately asserts on the *neighbours* of a replaced
  record — a wrong offset shift throws nothing and parses fine.
- **`xcodegen generate`** after adding a file to `EudoraApp/Sources/` — *after*
  writing it. New imagesets in `Assets.xcassets` are picked up automatically.
- **`.keyboardShortcut` inside an in-window `Menu` does nothing.** Real shortcuts
  live in `EudoraApp.eudoraCommands`; the ones in `MenuBarView` are decorative
  glyphs that render the ⌘ symbols. This is why every shortcut silently didn't
  work for months.
- **SwiftUI state set on one line isn't visible to a closure captured on the
  next.** Cost two bugs this session (the Save-then-close, the send-then-close).
- **Instrument, don't theorise.** Claude guessed wrong three times on the wheel
  bug and twice on the timing. `Scrolling.diagnose`, `PerfLog`,
  `TableHeaderIconStyler.diagnoseGeometry` are all off but intact, each with a
  comment recording what it found. `sample $(pgrep -x Eudora) 5 -file out.txt`.
- **Claude can read `phaseX/` directly** (real mail, 12 GB, gitignored; the repo
  is public). Reading `Out.toc` settled a "the icon never changed" question in one
  step — the disk said status 9, and the file hadn't been touched since before
  the feature was built.
- **Gmail needs an app password** (`myaccount.google.com/apppasswords`), not the
  account password — and Google revokes them all whenever you change your Google
  password, which is why it "stopped working without changing anything".
- macOS 13 / Swift 5.7. Read `design-decisions.md` and
  `eudora-mac-architecture.md`; don't re-debate settled decisions.

The user will likely ask you to **push the three unpushed commits**, then take on
**task 13 — converting the toolbar and Transfer Move menus to lazy AppKit menus**.
