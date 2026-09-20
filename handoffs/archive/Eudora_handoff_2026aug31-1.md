Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug31 (1)

**Supersedes `Eudora_handoff_2026aug30-1.md`.** Two of its items are closed and
should not be carried further: **queue item 1** (the `CLAUDE.md` omission — done,
along with two more corrections, see below) and **queue item 8** (sidebar bold:
Stephen was never asked, and the question is now moot — nothing has come up about
missing the pre-cutover-unread marker in the month since). Everything else from it
is repeated below rather than left behind.

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

**Everything is built, tested, committed and pushed. Nothing is pending.** Two
commits landed this session, both built and confirmed by Stephen first:

- `Show the attachments Eudora 7 recorded on the messages I sent`
- `Pin In, Out, Trash and Recents at the top of the sidebar`

`swift test` passed (Stephen ran it; the count wasn't captured — it was 576
before this session plus the new `RecordedAttachmentTests` and four new
`MessageDigest` cases). Both `reference/commit-message.txt` and
`reference/commit-message-sidebar.txt` are spent.

Diagnostics: `RemovalVeilDiagnostics` and `MessageColumnResizeController.diagnose`
are still **on** for the dead-list bug. `MessageIDIndex.diagnose`,
`BodyTextView.diagnoseSpelling`, `BodyTextView.diagnoseMenuOrder`,
`MessageContextMenuController.diagnosePlacement` and the new
`PinnedSetHeightReader.diagnose` are **off**, each with its finding in its doc
comment.

## Done this session

- **Legacy sent attachments are visible.** Eudora 7 kept no copy of a file it
  sent — the bytes went on the wire and the filed copy got only an
  `X-Attachments:` header naming a path. Eudora 8 ignored the header entirely.
  New `RecordedAttachment` (in `EudoraMac/`) reads it, `MessageDigest` counts it
  toward the paperclip, and the preview lists the name in the header block with
  From/To/Date.
- **`CLAUDE.md` corrected in three places** — see "The corrections" below.
- **`reference/missing-attachment-names.md`**, a list of the 633 distinct
  filenames whose location was never recorded, plus
  `reference/list-recorded-attachments.py` to regenerate it.
- **The sidebar's first set is pinned** and no longer scrolls away from the In
  box's green new-mail ball.

## The three things to know that aren't in the docs

**1. A `List`'s "row height" constants are a floor, and nothing rests on it.**
This is now in `CLAUDE.md`, but the cost is worth recording once: three builds
were spent computing the pinned set's height from `rowHeight` (21) and
`recentsRowPadding` (2). Measured, the rows are **25**, and Recents **27**. Every
failure looked like an arithmetic slip — first the Recents row was clipped in
half, then a band of background appeared under it — and each time the plausible
next guess was another number rather than a measurement. `PinnedSetHeightReader`
now measures, and one run of its `diagnose` flag settled in seconds what three
rounds of inference had not.

**The general lesson, which `CLAUDE.md` already states and this session ignored
for three builds: when a screenshot shows a geometry wrong, print the geometry.**
The tell is a second failed guess about the same number.

**2. The path in `X-Attachments` is often not a location.** Dragging a file from
the Mac into Windows Eudora never handed Eudora the file's path: Parallels copied
it into a per-drag folder under the Mac's `$TMPDIR` and gave Eudora *that*.
Measured over `phaseX`'s 8,320 recorded paths: **all 653 `\\Mac\AllFiles` paths
are of this shape and not one names a real place**, plus 43 more under Windows
`Temp` folders; the other 7,624 are real. The UI says which is which, because
"was at …" on a staging path sends you after a directory that never held the
file — and away from the Desktop where, in the case that started this, it was
still sitting.

**3. Reading the real mail settled two designs again.** Continuing the aug30
note: the 79,813 / 6,102 / 187 / 10 breakdown behind `RecordedAttachment`'s doc
came from a Python pass over `phaseX`, not from reasoning, and a first estimate
made by a subagent that skipped binary-matching files was low by an order of
magnitude. **Check a corpus claim before putting it in a doc comment.**

---

## The queue — ask Stephen which first

### 1. Night mode over Screens: the menu-scrolling problem

**Stephen was going to test the free option on the night of aug30 — this was
never asked, and is still the likely first thing to raise.**

The problem: right-click a message, Move to, navigate into a folder with more
items than fit on screen. Locally the list auto-scrolls as the pointer nears the
bottom edge and stops when it moves back up. Through Screens it does neither, and
clicking files the message to the *wrong* mailbox.

The diagnosis, which fits all three symptoms: an `NSMenu` picks the currently
**highlighted** item, not the item under the click, and both the highlight and
the edge auto-scroll are driven by mouse-moved events. Screens warps the remote
cursor rather than posting events — the same finding that made the night-mode
wake trigger keypress-only. So the highlight is frozen wherever it last was, and
a scroll started by clicking the arrow never learns that the pointer left it.

Four ways out, in increasing cost:

1. **The keyboard, no code at all.** `NSMenu` navigates with arrows and does
   type-select; keystrokes get through Screens intact. This is what he was
   testing. If it works, it may be the whole answer.
2. **A filter-box mailbox picker** — "Move to ▸ Find…", type, list narrows,
   Return files. Keyboard-driven, so identical local and remote, and probably
   the better answer for 2,657 mailboxes regardless of Screens. The one to build
   if he wants a durable fix.
3. **Synthesize the missing events**: poll `NSEvent.mouseLocation` on a timer
   while a menu is open and post a synthetic mouse-moved when it changes. The
   cursor position is correct; only the notification is missing. Targeted, and
   fighting AppKit's private tracking loop.
4. **Chunk long levels** so nothing ever scrolls. Removes the failure mode rather
   than fixing it, and adds a step locally where nothing was wrong.

Recommendation given: 1, then 2 if he wants more; never 3 or 4.

### 2. Night mode: two things still unproven

Unchanged from aug12 and still not exercised end to end:

- **A compose window opened from bed.** `sweepStrays` should pull it onto the
  built-in within five seconds. This is the failure that made the very first
  night unusable.
- **Whether the morning restore returns Eudora to where it was**, now that the
  automatic 07:00 path is gone and the only ways out are a keypress at the desk,
  ctrl-alt-cmd-D, and the menu-bar item.

`nightMode.status()` in the Hammerspoon console reports everything relevant.
**Editing `scripts/night-mode.lua` does nothing until it is copied to
`~/.hammerspoon/` and Hammerspoon is reloaded** — that alone cost a full test
round once.

### 3. Dead message list after a move — still instrumented, still waiting

Unchanged for six handoffs and **not reproduced**. Both diagnostics still on.
Read `RemovalVeilDiagnostics`' doc comment (`AppModel.swift`, above `PerfLog`)
for the healthy trace and the two failures to look for. `VEIL DOWN` present with
clicks still dead ⇒ the veil is innocent, read the `[resize]` lines. **Turn both
off once settled.**

The inspection-found hole still stands: three of the four arms of `loadListing`'s
scroll-restore chain set `pendingScrollTopRow` to nil, and `clearPendingScroll`
lifts the veil *only* when it finds one pending. What doesn't fit is that
Stephen's lasted minutes, not fifteen seconds.

### 4. The only known open bug that can duplicate mail

`shiftDraftOffsets` is called only from the draft-save paths, never from
`deleteSelected` or `moveSelected`. Deleting or moving a record in **Out** while
other drafts are open strands their offsets, and each later save then appends a
copy instead of updating. `MenuBarView`'s Delete is gated on `canActOnSelection`
alone and can still reach it.

### 5. Remaining View Response loose end

**The jump reads the destination mailbox in full on the main thread.**
`MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a whole-file
record scan, unbounded.

### 6. Gmail-side blacklisting, if he wants Eudora to do it

The API route is real but not cheap. `users.settings.filters.create` with
`from:` → `addLabelIds: ["TRASH"]`, one filter per address, 1,000-filter ceiling.
The price is **OAuth2**, which the project lists as a known gap. Two sharp edges
to state before starting:

- The consent screen **must be published "In Production"**, or Google expires
  every refresh token after 7 days.
- Published-but-unverified means a warning at sign-in and a 100-user cap. Fine
  for him alone; not fine for the Eudora he notarizes and shares, which would
  need Google's verification review for a sensitive scope.

The argument in favour is that the same subsystem would close the POP/SMTP
OAuth2 gap. Don't start it without him choosing it deliberately.

### 7. Attachment-name list: regenerate against the live tree, if wanted

`reference/missing-attachment-names.md` was built from `phaseX`, a 2026apr03
copy. `python3 reference/list-recorded-attachments.py ~/Eudora` regenerates it
against the live tree — Stephen runs it; Claude can't see `~/Eudora`. Little is
expected to have changed, since Eudora 8 keeps the bytes.

Two known follow-ons, neither asked for:

- The search index's `attachments` column holds only *MIME* filenames, so
  `Attachments contains foo.pdf` won't match a recorded one (it is findable via
  the `headers` column). The same pre-existing gap applies to detached
  attachments.
- The Windows-`Temp` half of the staging-path rule is inferred, not measured —
  43 paths. The `\\Mac\AllFiles` half is measured and total. If Stephen ever
  deliberately sent files from a folder he called `Temp`, narrow the rule to the
  Parallels shape only. **Two places to change together:**
  `RecordedAttachment.stagingSegments` and `STAGING` in
  `reference/list-recorded-attachments.py`.

### 8. Older doc loose ends, still open

- `SidebarExpansion`'s doc comment claims a rename changes a `MailboxItem.ID`.
  Wrong, and now load-bearing for Recents.
- `AppModel.swift`'s doc on `removalNotice` describes "Moved to Trash." as a
  delete's completion message. No delete path passes a notice; the only "Moved
  to…" comes from `moveSelected`. Cosmetic, but wrong.
- `EudoraDevelopmentNotes.txt:2219` still names `MailboxItem.hasUnread` as a live
  thing. It no longer exists.
- `SidebarOutlineFinder` is now **ambiguous** — it looks for *the* single-column
  headerless `NSTableView` and the sidebar has two since the pinning. Only the
  switched-off probes use it, and `SidebarRowSizeStyleTrial` carries a warning
  because it *mutates* what it finds. Disambiguate before enabling either: the
  outline is the taller of the two.

### 9. Test list

- **A plain unstyled message must still be a single `text/plain` part** — the
  regression guard for the whole image change.
- View Response with a second reply left open as an unsent draft, and with two
  sent replies.
- Most of Recents: rename and delete of a listed mailbox, the empty menu, and
  clicking the blank right-hand part of the row.
- Several compose windows at once: three or four open, save a middle one then
  another, and confirm neither produces a duplicate in Out.
- **Open sender's mailbox** on a sender with mail in several places, and on one
  with none (should read "None found" rather than an empty submenu).
- **Blacklist routing** on a message that carries no `Delivered-To` at all —
  should land on both lists.
- **The pinned sidebar set with Junk shown**, which changes the row count from 4
  to 5: the height should re-measure within a second. It falls back to a
  deliberately generous estimate during the gap, so the failure to look for is a
  strip of empty list that doesn't go away.
- **A sent message with both a real MIME attachment and an `X-Attachments`
  header** (187 of these in `phaseX`) — the file must appear once, as a working
  chip, not also as a greyed row.

---

## The corrections made to `CLAUDE.md` this session

Recorded because they were on the loose-ends list for five handoffs before being
done, and because two of them are new:

1. **"The two mail trees"**, a new section: `~/Eudora` is live, `phaseX` is a
   mounted copy, and questions about live state go to Stephen. This was the
   original queue item 1.
2. **Claude cannot run `swift test` either.** The file said library changes could
   be verified for real. There is no Swift toolchain in the sandbox at all —
   `which swift` finds nothing. `EudoraMac/` is still the better place for logic,
   but because *Stephen* can test it, not Claude.
3. **The row-height floor**, added to "Things that will bite" — see "the three
   things to know" above.

## Key context

**Claude cannot build or test.** Write carefully → Stephen builds and runs
`swift test` → he pastes the errors. Prefer `EudoraMac/` over `EudoraApp/`.

**Use `general-purpose` review agents before handing anything over.** Four times
this session, four real findings: a de-duplication comparing a sanitized filename
against an unsanitized one; a set rule whose 40 pt overhang was safe only because
a `List` row clipped it, and which would have painted a grey bar across the
message list; a latch that would have frozen a too-small measurement for the
session; and a table search that could have measured the wrong table.

**Instrument rather than theorise** — and see "the three things to know" for the
session where that rule was available from the first screenshot and ignored for
three builds.

**`phaseX` is a copy.** See `CLAUDE.md`'s new section. Anything generated from it
is private and belongs in `reference/`, which is gitignored — the repo is public.

**For performance, use `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary
is `Eudora`, not `EudoraApp`.

**Claude must not run git**, and cannot delete files either — the sandbox can't
unlink. Write the message to `reference/commit-message*.txt` (gitignored) and
hand over `git commit -F`, naming the changed files explicitly rather than `-A`.
**A new file needs `git add` first** — `git commit <paths>` only accepts tracked
ones, and this bit once this session. Recovery from a stranded lock:
`rm -f .git/index.lock`. Claude *can* read `.git/logs/HEAD` to see what has been
committed.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't —
the one new source file this session went there, so nothing needed regenerating.

**Releasing** is a double-click on `Build Release to Share.command`.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap, and see
queue item 6.

**musanim.com and gmail.com are independent mailboxes**, collected separately;
neither forwards to the other. Confirmed 2026aug30.

**Hammerspoon** carries `night-mode.lua`, which is Stephen's, not Eudora's, but
the two touch: it moves Eudora's windows. Repo copy at `scripts/night-mode.lua`,
live copy at `~/.hammerspoon/night-mode.lua`.

---

## Next session

The likely first request is still the one the aug30 handoff predicted and this
session never got to: **how the Screens keyboard test went** — queue item 1
above. Ask him rather than choosing, and don't start work off this list without
his say-so.
