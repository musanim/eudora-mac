Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug07 (1)

**Supersedes `Eudora_handoff_2026aug06-2.md`.** Three of its five queue items are
done, built, tested and committed (R/F glyph, key repeat, and — arriving out of
nowhere — a first test of image paste that failed immediately). Don't work from
its queue; the live one is below. What survives from it: **the dead-list bug is
still instrumented and still waiting to recur**, and two of its loose ends are
still open.

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

---

## Goal

Eudora 8: a native macOS replacement for Eudora 7. Cutover is long done and
Stephen uses it all day. Work is ordinary improvement, driven by what he hits.

## Current state

Everything is **committed and running**. Nothing is half-written. One diagnostic
is deliberately **on** (`RemovalVeilDiagnostics` + `MessageColumnResizeController.diagnose`,
for the dead-list bug); `BodyTextView.diagnosePaste` was switched **off** today
with its finding recorded.

## Done this session

All built, confirmed by Stephen, and committed.

- **The R mark.** Replying to a message now marks it `MS_REPLIED`, so the list
  shows R. The three-option design question in the last handoff *dissolved*: what
  Stephen wants is R for "I have responded", winning over F and over the unread
  dot. One flag, so one byte suffices — no side-car, no private status value, no
  new art, and no display change at all, since `MailStore.statusGlyphs` already
  mapped 2 to R. Only the write was missing.
- **View Response.** A message showing R gets a context-menu item that jumps to
  the most recent reply. Stephen's framing: the answer to "where did we leave
  this issue?"
- **Image paste, fixed.** Its first-ever test failed outright — see below.
- **Slow Delete/Backspace, fixed.** It was the format strip, not `readBack`.
- **`enlarge-mode-feasibility.md`** — a study, no code. See the queue.

## The three things worth knowing that aren't obvious from the code

**1. Two of today's four bugs were found by instrumenting after inspection had
cleared the code — twice each.** This is the CLAUDE.md rule earning its keep, and
it is worth being fast to reach for it.

- *Image paste did nothing.* Every step of `pasteImage` checks out, and I read it
  twice. The diagnostic showed pasting text logging six pasteboard types and its
  branch, and pasting an image logging **nothing at all**. The method was never
  called: AppKit validates ⌘V against `NSTextView.readablePasteboardTypes`, and a
  text view with `importsGraphics` off lists no image type, so the menu item was
  *disabled*. A method that isn't called and a method that declines look
  identical on screen and identical in the source.
- *Slow Delete.* The previous handoff recorded a well-reasoned theory —
  `readBack()` and its whole-storage `RichText` conversion. `sample` measured
  `readBack` at **10 of 13,686 main-thread samples**. The real cost was
  `FormatStrip` being `@ObservedObject`, so every keystroke rebuilt a picker item
  per installed font family.

**2. Short method names in this codebase collide with natural local-variable
names, and Swift's unqualified lookup stops at the innermost declaration.** This
cost two builds in one day: a parameter named `messageID` shadowed
`messageID(inHeaderBytes:)`, and a local named `item` shadowed `item(ofType:)`.
Watch for `item`, `messageID`, `status`, `content`.

**3. Deriving beat remembering again.** View Response needs no stored link
because every reply carries the original's id in `In-Reply-To`. Stephen's "I wish
I had thought of this earlier" is exactly right — that link has been in every
reply he has ever sent. The feature needed the R mark only to decide *when to
show the menu item*, not for its data.

---

## The queue — ask Stephen which first

### 1. Dead message list after a move — still instrumented, still waiting

Unchanged from the last handoff and **not reproduced today**. Both diagnostics
are still **on**. Read `RemovalVeilDiagnostics`' doc comment (`AppModel.swift`,
above `PerfLog`) for the healthy trace and the two failures to look for. The log
tells the two candidates apart: `VEIL DOWN` present and clicks still dead ⇒ the
veil is innocent, read the `[resize]` lines. **Turn both off once settled.**

A hole is already visible by inspection: three of the four arms of
`loadListing`'s scroll-restore chain set `pendingScrollTopRow` to nil, and
`clearPendingScroll` lifts the veil *only* when it finds one pending. What
doesn't fit is that Stephen's lasted minutes, not fifteen seconds.

### 2. Two loose ends from View Response, both raised and both deferred

- **`sendBlacklistNotice` sets `inReplyTo` and files its copy in Trash.** So a
  message replied to and *later* blacklisted has a Trash record that confirms as
  a reply and carries a fresh `Date:` — it would win "most recent" and View
  Response would land on it. Excluding Trash candidates is one line.
- **The jump reads the destination mailbox in full on the main thread.**
  `MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a whole-file
  record scan, unbounded — so landing on a reply filed in a 600 MB archive is a
  several-hundred-megabyte main-thread read. Pre-existing on the Find path, but
  View Response reaches it from the message list where the destination can be
  anything.

### 3. Enlarge mode — studied, not started

`enlarge-mode-feasibility.md` (top level, committed). Verdict: feasible, ~135
numbers, three phases, and the two obvious shortcuts both fail —
`.scaleEffect` breaks the message list's window-coordinate hit-testing, and
`importsGraphics`-style whole-app tricks don't exist here.

**Before any code, Stephen was asked to try a scaled display resolution** to
settle whether he wants 120, 130 or 140%. That number gets baked into a retune of
the column widths, so picking it twice is expensive. He hasn't reported back.
Three other open questions are in the study's last section.

Phase 1 is ~15 numbers and is a genuine stopping point.

### 4. Older loose ends, still open

- `SidebarExpansion`'s doc comment claims a rename changes a `MailboxItem.ID`.
  Wrong, and now load-bearing for Recents.
- `shiftDraftOffsets` is called only from the draft-save paths, never from
  `deleteSelected` or `moveSelected`. Deleting or moving a record in **Out**
  while other drafts are open strands their offsets, and each later save then
  appends a copy instead of updating. The real menu bar's `deleteCommandEnabled`
  blocks it; `MenuBarView`'s Delete is gated on `canActOnSelection` alone and can
  still reach it. **This is the only known open bug that can duplicate mail.**
- **CLAUDE.md should say that `~/Eudora` is the live mail tree and `phaseX` is a
  copy for reading.** It points at `phaseX` for format questions without saying
  this, and the omission already cost a seed list built from three-week-old data.

### 5. Test lists — mostly worked now

Stephen worked the six highest-risk items today and all six passed, including the
two that could have lost data (⌘R on a message in Out; a draft with an image
saved and reopened three times). What he skipped, to return to in normal use:

- **A plain unstyled message must still be a single `text/plain` part.** This is
  the regression guard for the whole image change and is the first thing to run
  if plain mail ever looks wrong.
- View Response with a second reply left open as an unsent draft (should land on
  the sent one), and with two sent replies (should land on the second).
- Most of Recents: rename and delete of a listed mailbox, the empty menu, and
  clicking the blank right-hand part of the row — inspection could not settle
  that an untagged `Button` inside an `NSTableView`-backed `List` takes the click.
- Several compose windows at once: three or four open, save a middle one then
  another, and confirm neither produces a duplicate in Out.
- Re-sample the composer to confirm the Picker/Toggle/Button leaves are gone.
  Speed is confirmed by feel, not by a second profile.

---

## Key context

**Claude cannot build**, and cannot run `swift test` either — Stephen runs both.
Write carefully → he builds → he pastes errors. Prefer `EudoraMac/` over
`EudoraApp/`, where it can be tested.

**Use `general-purpose` review agents before handing anything over.** They earned
it three times today: a certain compile error from the `messageID` shadowing, an
unguarded write that would have destroyed a draft on ⌘R in Out, and four separate
ways View Response could jump to the wrong message — including `max(by:)`
returning the *first* of equal elements, which mattered because Eudora 7 wrote no
`Date:` into the copy it kept, so every reply it sent scores zero and they all
tie.

**Instrument rather than theorise.** See section 1 above. This is the single
highest-value habit in this project and it was proved twice today.

**For performance, use `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary
is `Eudora`, not `EudoraApp`. Note the sample will be of a **Debug** build unless
Stephen is running the released app — type-metadata costs are inflated there, but
SwiftUI's own body-evaluation costs are not.

**Claude must not run git.** Write the message to `reference/commit-message.txt`
(gitignored) and hand over `git commit -F`. Recovery: `rm -f .git/index.lock`.
Claude *can* diff the working tree against HEAD by reading `.git`'s object store
from Python, and can read `.git/logs/HEAD` and `.git/COMMIT_EDITMSG` to see what
has been committed — both strand no lock files.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't.
Nothing added there today.

**Releasing** is a double-click on `Build Release to Share.command`.

**Stephen's PATH shadows short tool names** — scripts call Apple tools by
absolute path.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap.

---

The user will likely ask you which queue item to take first — ask him rather
than choosing, and don't start work off this list without his say-so.
