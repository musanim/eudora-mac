Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug06 (2)

**Supersedes `Eudora_handoff_2026aug06-1.md`.** Its "Next session" list (the
Recents feature) is done, built, confirmed and committed. Its "In flight — image
paste" section is still live but has moved on: that work is now **committed and
running**, and only its test list is outstanding. Don't go back to it.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects/Eudora` (pass the path
   directly; don't ask).
2. Mount `/Users/stephenmalinowski/ClaudeProjects` and read
   `claude-conventions.md`.
3. Read this project's `CLAUDE.md`.
4. Read this handoff, then **ask Stephen which of the queue below to take
   first** — they are independent and he may have a preference.

Two rules to have in front of you before typing anything. **One step at a time**
— one command, then wait. And **nothing actionable after a command block**: he
reads and acts in order, so anything placed after the commands arrives too late.
That was violated once today (a script was named in a message that also said
"run it later", and he ran it immediately). It costs him time; take it seriously.

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done and
Stephen uses it all day. Work is ordinary improvement, driven by what he hits.

## Current state

Everything is **committed and running**. Nothing is half-written. Two
diagnostics are deliberately switched **on** and are the first thing the next
session will be reading (see the queue).

## Done this session

All built, confirmed by Stephen, and committed in one commit.

- **Recents.** A sidebar row in a set of its own between the system mailboxes
  and the user's own, listing the mailboxes mail has been filed into lately;
  clicking drops an AppKit menu, picking an entry opens that mailbox with its
  newest message selected. Age-based expiry (100 days, `RecentMailboxes.maxAgeDays`),
  no count cap, only moves out of In and Out recorded, bare display names.
- **Reply caret.** `focusBody` abandoned a refused `makeFirstResponder`; a
  refusal is now retried and a *success* re-checked a turn later.
- **⌘R with a compose window open** did nothing, because the real menu bar gated
  Reply on `openDrafts.isEmpty` while the in-window menu didn't. Split into three
  gates; several replies can be open at once now.
- **Slow key repeat in the composer.** `refreshSelection` published all five
  format-strip properties unconditionally on every caret move.

`EudoraDevelopmentNotes.txt` (now ~3,200 lines) has the full account of each
with its own "To test" list. **Three of those lists are unworked** — see the
queue.

## Facts learned today that aren't obvious from the code

- **`~/Eudora` is the live mail tree. `phaseX` is a copy for reading.** CLAUDE.md
  points at `phaseX` for format questions without saying this, and the omission
  cost a whole seed list built from three-week-old data. **Worth fixing in
  CLAUDE.md.**
- **A rename does not change a `MailboxItem.ID`.** `renameTreeItem` rewrites only
  the descmap display field; the id is the path of *filenames*. This is now
  load-bearing for Recents. `SidebarExpansion`'s doc comment still says the
  opposite and **should be corrected**.
- **`defaultMinListRowHeight` is read once per `List`, not per row.** Writing it
  again on a single row, nested inside the one `MailboxTree` applies to its
  content, changed nothing — measured. Another entry for `SidebarRowMetrics`'s
  list of things that look like they should work on the sidebar and don't.
- **A `Divider()` in a `List` is a row**, so the list draws its own separator
  above *and* below it. That is why the sidebar's set breaks are now drawn as
  overlays on the Recents row's edges rather than as rows.
- **`@FocusState` is bidirectional**, and writing nil to it reads as "unfocus
  everything" — measured, it clears first responder a runloop turn later. That is
  what the reply caret's re-assert exists to recover from.
- Claude **can** diff the working tree against HEAD without running git, by
  reading `.git`'s object store from Python. That settled "is this a regression
  from the image work" in one pass. Worth remembering; it strands no lock files.

---

## The queue — ask Stephen which first

### 1. Dead message list after a move — INSTRUMENTED, waiting for it to recur

Stephen clicked a message in In, sorted by Who, went to a browser, came back,
moved the message by right-click. After that **no row in the list could be
selected by clicking, while the column headers still sorted**. Switching apps and
back cured it. The move itself succeeded.

Two candidates, both instrumented and **both switched on**:

- `RemovalVeilDiagnostics` (`AppModel.swift`, above `PerfLog`) — the removal
  veil's overlay swallows clicks over the list and nothing else, which is exactly
  the symptom. Its doc comment says how to read the log and what a healthy move
  looks like. **A real hole is already visible in that code by inspection**: three
  of the four arms of `loadListing`'s scroll-restore chain set
  `pendingScrollTopRow` to nil, and `clearPendingScroll` lifts the veil *only*
  when it finds one pending — so on those paths only the 15-second backstop can
  lift it. What doesn't fit is that Stephen's lasted minutes.
- `MessageColumnResizeController.diagnose` (`ContentView.swift`) — he clicked a
  header to sort, then switched apps. A `leftMouseUp` delivered to another
  application never reaches this monitor, so `dragColumn` can be left set, and an
  open drag treats later events as continuation.

The log tells them apart: `VEIL DOWN` present and clicks still dead ⇒ the veil is
innocent, look at `[resize]`.

**Turn both off once this is settled.**

### 2. R/F status glyph — designed, not started

Replying to or forwarding a message does not mark the original: **nothing in the
app ever writes `MS_REPLIED` (2) or `MS_FORWARDED` (3)**. The only status writes
are read/unread, the draft states and send outcomes. The F Stephen saw was
Eudora 7's, surviving because the auto-mark-read path only fires on a message
whose status is genuinely unread.

He wants a combined glyph — R in the upper-left triangle, F in the lower-right,
divided by a diagonal — because he wants to know both. **The obstacle is that
Eudora's status is one byte**: replied and forwarded are two values of one field,
not two flags, so the format cannot say "both". Three options were put to him and
**he has not chosen yet**:

1. A private status value (say 13). One byte, travels with the record, but writes
   a non-standard value into a Eudora file and doesn't extend.
2. A side-car keyed by Message-ID in `ViewState`. No format change, survives
   moves, holds any combination — but it's remembered state (which CLAUDE.md
   warns against) and knows nothing of Eudora 7's history, so today's F vanishes.
3. **Both** (recommended to him): keep writing the standard byte so the file stays
   honest and the Eudora 7 history keeps showing, plus a side-car for the pair;
   the glyph draws the union.

Either way `ComposeDraft` has to start remembering where it came from — mailbox
id plus the original's byte offset — and tolerate that record being refiled or
deleted before the reply is sent, which given how Stephen files *will* happen.
`MessageIDIndex` in EudoraStore already exists and is probably the right handle.

### 3. Key repeat is still slow for Delete and Backspace

Reported at the very end of the session, not investigated at all. Arrow keys are
now fast (that fix is in), but the destructive keys are not. Note that these
*change the text*, so they go through `textDidChange` → `readBack()` → a full
`RichTextAttributed.richText` conversion of the whole storage on every repeat,
where an arrow key did not. `readBack` also assigns `content` unconditionally.
That is the obvious place to look; measure before changing anything.

### 4. Three unworked test lists in `EudoraDevelopmentNotes.txt`

- **Inline image paste.** Built and committed but never tested. Its list is the
  one with "save a draft with an image, reopen from Out, twice more", which is
  where two bugs already lived.
- **Recents**, most of it: rename and delete of a listed mailbox, the empty menu,
  picking from a mailbox sorted by Who, and clicking the blank right-hand part of
  the row (an untagged `Button` inside an `NSTableView`-backed `List` has no
  precedent in this app — inspection could not settle that it takes the click).
- **Several compose windows at once**: three or four open, save a middle one then
  another, and confirm neither produces a duplicate in Out.

### 5. Two loose ends worth closing

- `SidebarExpansion`'s doc comment claims a rename changes an id. Wrong, and now
  load-bearing.
- `shiftDraftOffsets` is called only from the draft-save paths, never from
  `deleteSelected` or `moveSelected`. Deleting or moving a record in **Out** while
  other drafts are open strands their offsets, and per that function's own comment
  each later save then appends a copy instead of updating. The real menu bar's
  `deleteCommandEnabled` blocks it; `MenuBarView`'s Delete is gated on
  `canActOnSelection` alone and can still reach it.

---

## Key context

**Claude cannot build**, and cannot run `swift test` either — Stephen runs both.
Write carefully → he builds → he pastes errors. Prefer `EudoraMac/` over
`EudoraApp/`.

**Use `general-purpose` review agents before handing anything over.** They earned
it again today: the "newest by date" tie-break going by `rows.last` (wrong under
any sort but mailbox order), a stranded `pendingMessageID` that would have eaten a
Recents pick, and the whole diff-against-HEAD that cleared the image work of the
caret bug.

**Instrument rather than theorise.** Twice today the log said something different
from the best available theory — the caret was undone by a *success*, not a
refusal — and the second time the theory had already produced a fix.

**Claude must not run git.** Write the message to `reference/commit-message.txt`
(gitignored) and hand over `git commit -F`. Recovery: `rm -f .git/index.lock`.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't.

**Seeding UserDefaults** is `reference/seed-recents.py`, and the pattern is worth
knowing: `defaults export … | python3 … | defaults import …`, never editing the
plist file, because cfprefsd caches. `ViewStateStore` encodes with a plain
`JSONEncoder`, so a `Date` is a bare Double of seconds since 2001 — an ISO string
there decodes as a missing field and `ViewStateStore.load`'s `try?` would swallow
the error and wipe the whole blob.

**Releasing** is a double-click on `Build Release to Share.command`.

**Stephen's PATH shadows short tool names** — the scripts call Apple tools by
absolute path.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap.
