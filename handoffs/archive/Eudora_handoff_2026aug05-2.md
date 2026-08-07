Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug05 (2)

**Supersedes `Eudora_handoff_2026aug05-1.md`**, written earlier the same day and
already in `handoffs/archive/`. Its "Next steps — the sidebar, three independent
problems" section is **entirely done** — all three, in its own suggested order — so
nothing in it applies any more except the standing project facts, which are
repeated below.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects/Eudora` (pass the path
   directly; don't ask).
2. Mount `/Users/stephenmalinowski/ClaudeProjects` and read
   `claude-conventions.md`.
3. Read this project's `CLAUDE.md` — short, and every line was paid for. It
   gained three bullets today.
4. Read this handoff, then **stop and report** and wait.

Two rules to have in front of you before typing anything. **One step at a time**
— one command, wait for the result. And **nothing actionable after a command
block**: Stephen reads and acts in order, so a caveat placed after the commands
arrives too late.

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done and
Stephen uses it all day. Work is ordinary improvement, driven by what he hits.

## Current state

**Committed and pushed** through the sidebar work. `swift test` is 508 tests, 0
failures (up from 484; the delta is larger than the 16 tests added here, so the
484 figure in the previous handoff evidently predated something — not chased).

**Everything in this handoff is built, confirmed by Stephen, and committed.**
Nothing is in flight.

Two items from the previous session may still be uncommitted — the compose
repaint workaround and a sidebar row-density revert. `git status` is the check;
today's commit staged explicit paths, not `-A`, so it didn't sweep them in.

## Completed this session

Six changes, every one built and confirmed by Stephen. The three sidebar items the
previous handoff listed as next steps, then three more that came out of use.

- **Sidebar expansion persists.** New `SidebarExpansion` in `EudoraStore` (a Set
  of open folder ids, `Codable` as a *sorted* array so identical state encodes
  identically), stored per Eudora folder in `ViewState`. The tree is now built
  from `DisclosureGroup`s bound to that set instead of an `OutlineGroup`, which
  keeps expansion inside `NSOutlineView` with no public accessor.
  - This also fixed what had been filed as a separate problem: `.id(treeIdentityVersion)`
    still discards the outline on any identity change, but expansion no longer
    lives inside the discarded view, so **Move to ▸ New… stops collapsing the
    tree**. The `.id()` guard stays — same coordinator, same diff, same crash.
- **Row density 32 → 21 pt.** Two conditions, and neither works alone:
  `.listStyle(.plain)`, and `defaultMinListRowHeight` applied **inside** the
  `List`. See below; this took five builds and the account is in
  `SidebarRowMetrics`.
- **The In new-mail badge is now derived, not remembered.** Rule is Stephen's: if
  In's most recent message is unread, the pass through In is unfinished.
  Recomputed on every tree walk (`AppModel.inboxNewestIsUnread`), which already
  runs at launch, on delivery, and at the end of `markSelected`. New
  `MailStore.newestStatus` / `newestIsUnread` read one 218-byte record rather
  than parsing the `.toc`.

## Pointer-positioned dialogs (the tail of the session)

`PointerAlert` (new file, `EudoraApp/Sources/PointerAlert.swift`) opens an
`NSAlert` at the pointer instead of centre-screen. Applied to the five dialogs
reached by right-clicking something: Delete PERMANENTLY and the blacklist
confirmation anchor their **action button** on the pointer; New Mailbox, Rename and
the composer's "Correct … to…" prompt anchor their **text field**, because those
are type-and-Return dialogs whose button is never clicked.

Three things in it cost a build each and are all recorded in the file's header
comment: setting the frame before `runModal` does nothing (`NSAlert` positions its
panel when shown); a queued main-queue block also runs too early; and the offset
must be *read* from the anchor view rather than computed, because the window frame
carries shadow margin on top of `NSAlert`'s unpublished padding. It is also
deliberately not `@MainActor` — annotating it makes both hooks errors on Swift 5.7.

Also in the same pass: **Delete PERMANENTLY and Add to BLACKLIST now have the same
gap between them** as the one above them. Different reasoning from the first gap,
which is distance from the most-used action — this is distance between two adjacent
shouting items that do entirely different things, one destroying the message and
the other replying to the sender on Stephen's behalf *and then* destroying it.
Built inside the conditional that adds the blacklist item, so the gap arrives with
the item it protects. See `MessageContextMenu`, and note that `addGap` interleaves
disabled spacer rows because consecutive separators coalesce into one line.

One process note worth carrying: adding a file under `EudoraApp/Sources` needs
`xcodegen generate` before it will build, and this session forgot it once.

## What was learned, so it isn't re-derived

Three bullets went into `CLAUDE.md`; the long form is in
`EudoraDevelopmentNotes.txt` under today's entries.

- **A `List`'s row height answers to exactly two things:** `.listStyle(.plain)`
  (the sidebar style pins a fixed 32 pt row) and `defaultMinListRowHeight`
  applied *inside* the `List`, since `List` overwrites that key in its content
  environment. Measured inert on this view: the AppKit `rowHeight` (forced to 20,
  `rect(ofRow:)` stayed 32 — SwiftUI answers `heightOfRowByItem` here, unlike the
  message table's `Table` where the same code works), `usesAutomaticRowHeights`,
  `intercellSpacing` (already 0), `rowSizeStyle` (set to `.small`, no movement),
  and `.listRowInsets`. KVO-pinning the height the way `TableScrollStateSyncer`
  does **stack-overflows** here.
- **Passing `self` into a child view is fine for `@ViewBuilder` methods and not
  fine for `@State`.** A write through a copy the child holds updates the value
  but invalidates nothing. Symptom: a disclosure whose visible response to a
  click was *arbitrary* while the stored state was correct every time — so
  persistence tests passed and the screen was wrong. See `MailboxTree.setExpanded`.
- **Prefer deriving a badge to remembering one.** The In flag as session state
  produced two bugs (cleared by a delivery's own selection echo; lost on quit).
  Deriving it deleted both plus seven other things.

Two of my diagnoses today were wrong and were corrected in place rather than
quietly rewritten — the notes keep the wrong prediction *and* its refutation,
because in both cases the refutation was the more useful fact.

## Diagnostics left switched off but intact

Per CLAUDE.md's convention. All in `ContentView.swift`:

- `SidebarDensityProbe` — five builds of density work were decided by its output.
- `SidebarRowSizeStyleTrial` — **must stay off**; it mutates the table mid-run.
- `SidebarExpansionProbe` — separates "state moved, outline ignored it" from
  "write isn't invalidating" from "click never reached the disclosure".
- `SidebarRowHeightPin` is now measurement-only and `updateNSView` returns
  immediately when both density diagnostics are off, so the shipped build never
  walks the view tree.

The one deliberate deletion is noted where it stood: the
`@Environment(\.defaultMinListRowHeight)` read in `MailboxRow` was the decisive
density measurement, and the comment where `reportEnvironment` used to be says
how to put it back in one line. It's out because `MailboxRow` is the hot view.

## Open threads

- **The compose repaint workaround** (carried from the previous handoff, still
  honest): `textDidChange` invalidates the visible rect; the cause was never
  found. Watch for typing lag in a long message.
- **Row density could go tighter than 21** only by bounding `TreeIcon.newMail`
  (the green In badge, a 20×20 PNG drawn at native size) to ~16. That visibly
  shrinks a glyph Stephen sized deliberately, so it needs asking.
- **An interrupted enrichment pass leaves a stale sort order.** Found while
  explaining a real puzzle: a mailbox sorted by Who showing two different
  correspondents interleaved. `compareText` is a total order, so distinct keys
  cannot interleave — the order was *stale*, not wrong. `applyEnrichment` rewrites
  `who`/`whoSort` in place and deliberately does not re-sort per batch; the single
  compensating re-sort is at the end of the pass (`dependsOnEnrichment`), and both
  loop guards `return` on a generation change. So an interrupted pass — or one
  still running — leaves new values in old positions. Worst on Trash, 22,000+ rows.
  Not fixed, and not obviously a bug rather than a cost; a re-sort by hand corrects
  it. Stephen reached the same conclusion independently.
- **`PointerAlert`: one redundant hook.** It repositions from both a queued
  main-queue block and `didBecomeKeyNotification`, and which one does the work was
  never captured — the build that added the trace also fixed the behaviour. They're
  idempotent, so it's harmless; one run with `traceEnabled = true` would settle
  which to delete.
- **SMTP/POP are implicit TLS only** — no STARTTLS (port 587), no OAuth2. Known
  gap, not currently biting.
- **A Windows port was discussed and deliberately not started.** A friend of
  Stephen's, a long-time Eudora for Windows user, asked. The finding: don't port.
  70% of our ~26,800 Swift lines are SwiftUI/AppKit with nothing transferable, and
  Eudora 7 for Windows already does everything the port was reproducing. The
  short delta over Eudora 7 — including its own `Date:` bug on composed mail —
  would be better added to the Qualcomm MFC source directly. Offered to write this
  up as a document for the friend; not yet done.

## Next session

Nothing is pending or half-finished. Work is driven by what Stephen hits, so the
likely candidates, in no particular order:

1. Whatever the tightened sidebar turns up in daily use.
2. The write-up for Stephen's friend on the Windows question, if he wants it.
3. Bounding the In badge art, if 21 pt still isn't tight enough.
4. `Mailbox ▸ New…` at the pointer too, if the menu-bar case turns out to want it.
5. STARTTLS, if a mail server ever forces it.

**Draft — confirm or replace before relying on it.** Stephen supplied no next
steps with the handoff request, so this list is inferred from the session tail.

## Key context

**`EudoraDevelopmentNotes.txt` is the running record**, gitignored, and now 2,400+
lines. Every feature has a "To test" list. Keep appending in the same style.

**Claude cannot build.** No Swift toolchain in the sandbox — not even for
`swift test`, despite what an earlier handoff implied; Stephen runs that too. The
loop is write carefully → Stephen builds → he pastes errors. Prefer putting logic
in `EudoraMac/` where `swift test` can reach it.

**Use `general-purpose` review agents before handing anything over.** One caught
three real problems in today's density code before the build: a probe that would
have latched having measured nothing, a six-element concatenation of
interpolations (the exact shape that has already cost an "unable to type-check in
reasonable time" in this file), and two view-tree walks per `updateNSView` on the
path an arrow-key press takes.

**Instrument rather than theorise.** Today's clearest lesson. Five builds went
into guessing at row density; one line of measurement (`delegateItemHeight true`)
ended it, and a second (`defaultMinListRowHeight as seen by a row 32.0`) found
the placement bug. Both times the guess was confident and wrong.

**Claude must not run git.** The sandbox can't unlink in `.git`, so every git
command strands a lock file. Write the message to `reference/commit-message.txt`
(gitignored) and hand over `git commit -F`. Recovery: `rm -f .git/index.lock`.

**Releasing** is a double-click on `Build Release to Share.command`. Build the app
*before* Rebuild Index if an indexing change is involved.

**Assets:** a new imageset inside `Assets.xcassets` needs no `xcodegen`; a new
file under `EudoraApp/Sources` does, run *after* writing the file.

**Stephen's PATH shadows short tool names** — Humdrum ships its own `ditto`, so
the scripts call Apple tools by absolute path.
