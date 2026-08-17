Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug11 (1)

**Supersedes `Eudora_handoff_2026aug07-1.md`.** Two of its five queue items are
resolved: enlarge mode is **closed, not deferred**, and the dead-list bug is
unchanged and still waiting. Its items 2, 4 and 5 are untouched and still live —
they are repeated below rather than left behind.

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

**Nothing is committed.** The commit message is written and waiting at
`reference/commit-message.txt`; the command is

```
cd /Users/stephenmalinowski/ClaudeProjects/Eudora
git commit -a -F reference/commit-message.txt
```

**The working tree is one Bool ahead of what Stephen built and tested.** He
confirmed the spell-check menu with `BodyTextView.diagnoseMenuOrder = true`;
it was set to `false` afterwards and that build has not been made. Rebuild
before committing, or at least know that's the delta.

`swift test` passes — 564 tests, 0 failures.

Diagnostics: `RemovalVeilDiagnostics` and `MessageColumnResizeController.diagnose`
are still **on** for the dead-list bug. `MessageIDIndex.diagnose`,
`BodyTextView.diagnoseSpelling` and `BodyTextView.diagnoseMenuOrder` are all
**off**, each with its finding recorded in its doc comment.

## Done this session

- **Enlarge mode closed.** Committed. Stephen does the enlarging at the other
  end of a remote-desktop viewer. `enlarge-mode-feasibility.md` is kept, with a
  CLOSED note at the top and its open-questions section marked moot.
- **Capitalized spellings as spell-check guesses.** Built and confirmed working.
  Right-clicking a misspelled word offers the capitalized and all-caps forms the
  dictionary accepts, bold-first, above AppKit's own suggestions. Replaces the
  one occurrence, records nothing.
- **Filing to an unfamiliar mailbox triggers a reindex.** Written and built, but
  **not exercised** — see the queue.
- **`MessageIDIndex.diagnose` off**, the cut-over being long over.

## The four things worth knowing that aren't obvious from the code

**1. A one-word document is not a valid way to test spelling, and this ate most
of the session.** The composer appeared to have no spell check at all: nothing
underlined, no guesses in the context menu, while the same words underlined fine
in every other app and "Check Spelling While Typing" read as ticked. Inspection
cleared everything. The probe (`BodyTextView.diagnoseSpelling`, still in the
tree) printed `teh: viewTag=false tag0=false lang=en automatic=true` — the
checker itself declared the typo correct. Cause: **automatic language
identification with nothing to identify from.** Three characters in an empty
compose window makes it guess, it lands on a language with no installed
dictionary, and such a language accepts every word. Typing the same typo inside
an ordinary English sentence underlined it immediately. Two consequences — test
spelling only inside real prose, and `isMisspelled` now names its language
explicitly instead of passing nil.

**2. `NSTextView` fills its spelling guesses in lazily, when the menu is about to
open rather than when it is built.** Items inserted at index 0 in `menu(for:)`
are pushed *below* them by the time the menu is on screen; that is why "Ritalin"
first appeared under half a dozen of AppKit's suggestions. Insertion moved to
`willOpenMenu`, after `super`. Apple's own note introducing that method says it
"should not be used to make modifications to the passed in menu object", so the
ordering is not contractual — `diagnoseMenuOrder` exists for the day it changes.

**3. AppleSpell does *not* wave through arbitrary all-caps as acronyms.**
`RITALIN` was rejected while `Ritalin` was accepted. That settles the risk that
an ordinary typo would spuriously offer "TEH", and makes the all-caps candidate
safe to keep.

**4. Review agents earned their keep three more times.** They found: the
`startIndexing` re-entry guard testing `isIndexing`, which is set *inside* its
own Task while `indexingPath` is set synchronously, so two calls in one turn
could both open a SQLite writer on the same scratch file; a filing made during a
rebuild being refused and then forgotten; and `BodyTextView` doubling as the
read-only reader, where a case guess would have rewritten displayed message text.
All three are fixed.

---

## The queue — ask Stephen which first

### 1. Commit, and rebuild first

See Current state. Nothing else should start before this is settled.

### 2. The filing-triggered reindex is untested

Written this session, built, never exercised. Filing to a mailbox the
correspondent has never gone to should start a rebuild — **"Indexing…" should
appear about a second *after* the message list settles, not during it.** If it
shows up while the list is still veiled, the deferral isn't working and that
matters: the rebuild reads the whole 12 GB tree, and starting it against the
veil-lifting read is exactly how the dead-list bug would be made worse.

Two known costs, both deliberate, both to reconsider only if Stephen feels them:

- **The predicate is broad.** It fires whenever the index has no record of this
  correspondence in the destination — which includes filing a *known*
  correspondent into a topic mailbox (TAXES/2026, a project box). That is what
  Stephen asked for, and he said the churn doesn't bother him, but during a
  filing session it can mean near-continuous rebuilding. Narrowing it to "new
  correspondent or brand-new mailbox" is a one-line change to
  `filingIsUnfamiliar`.
- **The move path now costs 50–300 ms** before the veil goes up — up to twenty
  32 KB reads, a MIME parse each, and one FTS query — and on the menu-driven
  route that work is done twice, once to build the menu and once on the pick.
  Caching `filingCounts()` against the selection would make the second free.
  Deliberately not done on a guess; wait for him to feel it.

### 3. Dead message list after a move — still instrumented, still waiting

Unchanged from the last two handoffs and **not reproduced**. Both diagnostics
still on. Read `RemovalVeilDiagnostics`' doc comment (`AppModel.swift`, above
`PerfLog`) for the healthy trace and the two failures to look for. `VEIL DOWN`
present with clicks still dead ⇒ the veil is innocent, read the `[resize]` lines.
**Turn both off once settled.**

The inspection-found hole still stands: three of the four arms of `loadListing`'s
scroll-restore chain set `pendingScrollTopRow` to nil, and `clearPendingScroll`
lifts the veil *only* when it finds one pending. What doesn't fit is that
Stephen's lasted minutes, not fifteen seconds.

### 4. One behaviour change he may want reversed

`menu(for:)`/`willOpenMenu` now bail unless the view is editable, so
**"Correct 'word' to…" no longer appears when right-clicking a word in a message
you are reading.** It was dead there anyway (no controller to save through), but
it was visible. Say the word and it comes back for the reader without the case
guesses, which are the part that would have rewritten displayed mail.

### 5. iPad client — parked, deliberately

Stephen reads in bed and wants to check and *reply to* mail from the iPad. The
blocker isn't the Mac being asleep (it isn't) — it's that turning the external
displays off reflows their windows onto the built-in display, making an Edovia
Screens session a mess.

**He is trying BetterDisplay first**, to make a virtual display that Eudora lives
on permanently; Screens can already connect to one specific display and remember
the choice. If that works, the whole project is unnecessary. He also noted the
morning scramble only happens if he moves windows on the built-in display at
night, so he may be entirely home free.

If it doesn't work, the shape agreed was: **a small HTTP server inside the
running Mac app, and a web client in Safari first, a native iPad app later on the
same foundation.** One correction to record, because it makes the idea much
better than it first looked — an in-process server means there is **no second
writer** to the mail files: the iPad asks the running app to do the work and it
goes through the same `AppModel` and the same mutators, serialized on the main
actor. Replying from the iPad is then no riskier than replying at the desk.
`MessageBuilder` and `SMTPClient` already exist and are tested. `EudoraStore` is
deliberately UI-framework-free and `BodyRenderer` already produces the HTML the
reading pane shows.

### 6. Two loose ends from View Response, both still open

- **`sendBlacklistNotice` sets `inReplyTo` and files its copy in Trash**, so a
  message replied to and later blacklisted has a Trash record that confirms as a
  reply and carries a fresh `Date:` — it would win "most recent". Excluding Trash
  candidates is one line.
- **The jump reads the destination mailbox in full on the main thread.**
  `MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a whole-file
  record scan, unbounded.

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

### 8. Test list, unchanged from the last handoff

- **A plain unstyled message must still be a single `text/plain` part** — the
  regression guard for the whole image change.
- View Response with a second reply left open as an unsent draft, and with two
  sent replies.
- Most of Recents: rename and delete of a listed mailbox, the empty menu, and
  clicking the blank right-hand part of the row.
- Several compose windows at once: three or four open, save a middle one then
  another, and confirm neither produces a duplicate in Out.

---

## Key context

**Claude cannot build**, and cannot run `swift test` either — Stephen runs both.
Write carefully → he builds → he pastes errors. Prefer `EudoraMac/` over
`EudoraApp/`, where it can be tested.

**Use `general-purpose` review agents before handing anything over.** See point 4
above.

**Instrument rather than theorise.** Proved again today, twice: two plausible,
well-argued theories about the spell checker were both wrong, and one printed
line settled it. Follow the existing pattern — leave the probe in the tree,
switched off, with its finding in the doc comment.

**For performance, use `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary
is `Eudora`, not `EudoraApp`.

**Claude must not run git.** Write the message to `reference/commit-message.txt`
(gitignored) and hand over `git commit -F`. Recovery: `rm -f .git/index.lock`.
Claude *can* read `.git/logs/HEAD` to see what has been committed — that strands
no lock file, and it was used today to confirm the enlarge-mode commit landed.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't.
Nothing added there today.

**Releasing** is a double-click on `Build Release to Share.command`.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap.

---

The user will likely ask you to rebuild and commit first — see queue item 1 —
and then to pick from the queue. Ask him rather than choosing, and don't start
work off this list without his say-so.
