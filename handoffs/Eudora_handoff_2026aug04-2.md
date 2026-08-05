Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug04 (2)

**Supersedes `Eudora_handoff_2026aug04-1.md`**, which was written earlier the
same day and stops before most of this. Both it and `Eudora_handoff_2026aug02.md`
can go to `handoffs/archive/`.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects/Eudora` (pass the path
   directly; don't ask).
2. Mount `/Users/stephenmalinowski/ClaudeProjects` and read
   `claude-conventions.md`.
3. Read this project's `CLAUDE.md` — short, and every line was paid for.
4. Read this handoff, then **stop and report** and wait.

Two rules to have in front of you before typing anything. **One step at a time**
— one command, wait for the result. And **nothing actionable after a command
block**: Stephen reads and acts in order, so a caveat placed after the commands
arrives too late. That one bit twice today; the second time cost a wasted
reindex.

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done and
Stephen uses it all day. Work is ordinary improvement, driven by what he hits.

## Completed this session

Everything below was built and used by Stephen unless said otherwise.

- **Sidebar reordering.** Top-level mailboxes and groups now intermix; the old
  mailboxes-above-folders rule is gone. `moveEntry` steps *over* system lines to
  the nearest movable neighbour rather than stopping at them — which matters
  because `ensureSystemMailboxes` appends a missing Junk, so a system line can
  sit in the middle of the file and strand anything created after it.
- **Sort Alphabetically** (the list an item is in) and **Sort Contents
  Alphabetically** (folders only). System entries keep their slots.
- **Multi-selection previews the message you just added**, rather than "N
  messages selected". Primary is now the *moving end* of the selection.
- **⇧-arrow no longer skips rows** — a non-published stand-in makes the binding's
  getter truthful, plus epoch coalescing.
- **Context menu centred on the pointer**, and Delete/BLACKLIST separated by a
  deliberate gap.
- **Blacklist queue moved into the app** (Tools ▸ Blacklist…), replacing the
  file-plus-TextEdit arrangement that raced.
- **Delete PERMANENTLY** — removes outright from any mailbox, behind a
  confirmation, with no keyboard shortcut anywhere.
- **Dates for mail Eudora 7 composed.** It never wrote `Date:` into its stored
  copy, so ~30 years of sent mail showed no date in the reader *and* was invisible
  to Find's date criteria. Both now fall back to the `.toc`'s cached date.
- **Developer ID signing, notarization, and a one-click release** (earlier today;
  see the previous handoff).

## Current state

All committed and pushed as of the last commit, **except** the final compose
repaint workaround and the sidebar row-density revert — check `git status`.
`swift test` was 484, 0 failures, before those.

## Next steps — the sidebar, three independent problems

Stephen's order: **2, then 1, then 3.** All three are diagnosed in
`EudoraDevelopmentNotes.txt` under "Sidebar: three separate problems".

1. **Row density.** Stephen asked to halve the space between rows.
   `.listRowInsets` has **no effect** — tried, reverted, and the finding is
   recorded as a comment above `MailboxRow`. SwiftUI floors row height whatever
   the content is. The proven route is the one the message table already took:
   force the height on the backing view and re-enforce through KVO when SwiftUI
   resets it — see `pinRowHeight` / `enforceRowHeight` / `MessageTableFinder`.
   Needs an equivalent finder for the `NSOutlineView`. Medium.

2. **The PEOPLE group collapses during a session** — *do this first*.
   `identitySignature` hashes every item's `(parent, id, isFolder)`, so
   `treeIdentityVersion` moves for **any** change to the set, including simply
   adding a mailbox. `.id(treeIdentityVersion)` then discards the outline and the
   new one starts at default expansion. So **Move to ▸ New…**, his most-used way
   of filing, collapses the tree every time. The crash that guard exists for was
   *reparenting* an expanded subtree; an insertion or deletion reparents nothing.
   Fix: bump only when an id present both before and after has a different
   parent. Small, and the highest value of the three.

3. **Expansion isn't restored across launches.** Never implemented. `OutlineGroup`
   keeps expansion inside `NSOutlineView` with no public read/write, so this needs
   explicit expansion state — the `DisclosureGroup` rewrite `ContentView` already
   prices at about a day. Note that comment's other point still stands: switching
   to `DisclosureGroup`s does **not** fix the reparenting crash by itself.

## Key context

**`EudoraDevelopmentNotes.txt` is the running record**, gitignored, and long.
Every feature has a "To test" list. Keep appending in the same style. A note at
the end explains that this session ran past midnight Pacific, so some entries
stamped 2026aug03 were written on the 4th.

**Use `general-purpose` review agents before handing anything over.** They earned
it repeatedly today: a `grep -q` + `pipefail` interaction that made a release
check fail exactly when it should pass; a veil teardown that would have blanked a
22,000-row Trash and lost the scroll position; a selection rule that handled
growth and left every other gesture arbitrary; a `.keyboardShortcut(.defaultAction)`
that would have made Return empty the blacklist; a fallback that could have
truncated the blacklist archive.

**Instrument rather than theorise — it paid twice today and cost once.**
`AppModel.diagnoseSelection` (off, intact) settled the ⇧-arrow bug in one run
after reasoning had produced a confident, wrong fix: distance between selected
rows was being measured in *message ID*, but the list is sorted by date, so IDs
aren't monotonic on screen. And the missing-`Date:` mystery was settled by one
grep over `phaseX/` after a wrong inference had nearly sent Stephen to re-send a
message he had already sent.

**One open workaround, honestly labelled.** Compose text sometimes stopped being
painted after an edit; `textDidChange` now invalidates the visible rect. The
cause was *not* found — the custom halo drawing, attributes and this subclass's
overrides were each ruled out by measurement. Watch for typing lag in a long
message; that's the only cost.

**Claude must not run git.** The sandbox can't unlink in `.git`, so every git
command strands a lock file. Write the message to `reference/commit-message.txt`
(gitignored) and hand over `git commit -F`. Recovery: `rm -f .git/index.lock`.

**Claude cannot build.** No Swift toolchain: write carefully → Stephen builds →
he pastes errors. Library code in `EudoraMac/` *can* be verified with
`cd EudoraMac && swift test`; prefer putting logic there. Read the
"Executed N tests" line, not the checkmark below it — that comes from the
swift-testing harness finding zero `@Test` functions.

**Releasing** is a double-click on `Build Release to Share.command`. Build the app
*before* Rebuild Index if an indexing change is involved — the indexer is in the
app binary, and reindexing with a stale build fails in a way that looks like
success.

**Assets:** a new imageset inside `Assets.xcassets` needs no `xcodegen`; a new
file under `EudoraApp/Sources` does, run *after* writing the file.

**Stephen's PATH shadows short tool names** — Humdrum ships its own `ditto`. The
scripts call Apple tools by absolute path for that reason.

The user will likely ask you to start on sidebar item 2 — stopping the tree
collapsing when a mailbox is created.
