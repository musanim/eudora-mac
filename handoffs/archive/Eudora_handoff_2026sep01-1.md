Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026sep01 (1)

**Supersedes `Eudora_handoff_2026aug31-1.md`.** Four of its items are closed and
should not be carried further: **queue 1** (night mode over Screens — "fine for
now"), **queue 2** (night mode's two unproven paths — both work), **queue 7**
(the attachment-name list, which turned into this session's whole body of work),
and one line of **queue 9** (the pinned sidebar with Junk shown — passes).
Everything else from it is repeated below rather than left behind.

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

**Everything is built, tested, committed and pushed. Nothing is pending.**
`swift test` reports **637 tests, 0 failures** (576 before this session). Three
commits landed, each built and confirmed by Stephen first:

- `Point the recorded attachments I could find at where they actually are`
- `Stop a right-click in the preview pane selecting a message off screen`
- `Reveal a sent attachment whose file I still have`

All three `reference/commit-message*.txt` are spent.

Diagnostics unchanged from aug31: `RemovalVeilDiagnostics` and
`MessageColumnResizeController.diagnose` still **on** for the dead-list bug;
`MessageIDIndex.diagnose`, `BodyTextView.diagnoseSpelling`,
`BodyTextView.diagnoseMenuOrder`, `MessageContextMenuController.diagnosePlacement`
and `PinnedSetHeightReader.diagnose` **off**.

## Done this session

**The missing sent attachments are found and recorded in the mail.** Eudora 7
recorded a Parallels staging path for any file dragged in from the Mac, so 696
sends named a `$TMPDIR` folder macOS purged years ago. A whole-disk scan matched
370 filenames to real files; Stephen curated the matches by hand; `eudora-relink`
wrote the verified locations into **320 messages across 156 mailboxes** in the
live tree. Verified afterwards: `Shanker Krishnan.mbx` holds 15 `X-Attachments`
lines naming `/Users/stephenmalinowski/…` and its `.prerelink` backup holds none.

**Those rows now act.** A recorded path that names a file which is actually there
gets a `url`, the row shows just the paperclip and the filename, and right-click
offers Reveal in Finder plus Copy Path / Copy Name.

**A right-click bug that had shipped**: right-clicking anywhere in the preview
pane could select an unrelated message. See below.

New in `reference/` (all gitignored, all private — they hold paths from real
mail): `scan-for-missing-attachments.py`, `build-ambiguous-list.py`,
`found-attachment-candidates.{md,tsv}`, `attachmentToKeep*.md`,
`attachment-locations.tsv`. The last is the input `eudora-relink` reads.

## The four things to know that aren't in the docs

**1. `TocWriter` blanks most of a real `.toc`, and the app has been doing it all
along.** It writes the seven fields `Toc` models and zeroes the other 210 bytes
of each 218-byte entry plus the 104-byte folder header. Measured over `phaseX`
(120 files, 2,875 entries): **97% of entries carry non-zero bytes outside those
fields** — a timestamp at 8-11, flags at 14-15, more at 178-212 — a second
timestamp sits in the dead tail of the date field at 46-49, and **116 of 120
folder headers are non-empty** (they hold the mailbox name and window/sort/column
state). `RecordedAttachmentRelink.patchedToc` therefore patches four bytes of
offset and four of length in place and copies the rest. **`MailboxMutator.setStatus`
and `replace` still rebuild the whole index**, so marking a message read blanks
those bytes. Eudora 8 doesn't read them so nothing visible is broken — but it is
data loss on every status change. Queue item 1.

**2. A scrolled `NSTableView`'s `bounds` is not what you see.** The table is the
scroll view's document view, so `bounds` covers every row above and below the
fold. `table.bounds.contains(point)` therefore accepts clicks in the *preview
pane*, and `row(at:)` answers with a real row below the fold. That is the whole
right-click bug, and `visibleRect` is the fix — it is by definition a subset, so
it can only reject clicks that were never over the list. **The tell was free and
worth the minute it cost: the misbehaviour vanishes when the list is scrolled to
the bottom.** Confirming that before touching code is the pattern; see
`CLAUDE.md`'s "instrument rather than theorise".

**3. `.textSelection(.enabled)` steals the context menu.** A selectable `Text`
installs its own editing menu, and it wins over the enclosing row's, so
right-clicking the path offered spelling suggestions while only the paperclip
offered the attachment's options. Copy items in the row's menu replace what
selection was for.

**4. Two review passes were worth more than one.** The first `general-purpose`
review of the relink code found eight defects that would have lost data — no
backup at all, a failed `.toc` write reported as success, a mismatched `.toc`
deleted rather than skipped, two things that wouldn't compile, a CRLF list
putting a bare CR into every header, duplicate filenames silently picking a
winner, and the `TocWriter` finding above. The **second** pass, over the rewrite,
found three more, including that the test named "longer header" actually
shortened the record — so nothing was exercising the direction where a stale
offset lands *inside* the next message. Budget for the second pass.

---

## The queue — ask Stephen which first

### 1. `MailboxMutator` rebuilds the `.toc` instead of patching it

The finding above, applied to `setStatus` and `replace`. Both call
`TocWriter.data(entries:)` over the whole index, so every status change blanks
97% of entries' unmodelled bytes and the folder header. `patchedToc` in
`RecordedAttachmentRelink` is the shape of the fix — read offset/length, write
offset/length, copy everything else — but `setStatus` also needs to change a
status byte, and `replace` needs the cached date/to/subject columns, so it is
"patch these fields in place" rather than a straight lift. Testable in
`EudoraMac/` with the same byte-poking fixture
(`testTocBytesOutsideTheModelledFieldsSurvive`).

Worth doing even though nothing visibly breaks: it is silent, ongoing loss, and
the bytes are Eudora 7's only record of some things.

### 2. Seven mailboxes with a `.toc` that doesn't describe the `.mbx`

`eudora-relink` skipped these rather than damage them, leaving 11 messages
unrelinked: `PEOPLE.fol/C.FOL/CarlLumm`, `PEOPLE.fol/E.FOL/Etienne Abelin`,
`PEOPLE.fol/J.FOL/JA.fol/James Carmichael`, `PEOPLE.fol/A.FOL/Anna Detrick`,
`PEOPLE.fol/G.FOL/Grace Cho`, `PEOPLE.fol/A.FOL/Andreya von
Waldenfels-Marks`, `__MAM.fol/MISCINQ`. They are large mailboxes (16,918 /
6,420 / 7,173 / 5,128 messages) — the ones most likely to have accumulated
ghosts.

The skip rule is strict: *every* `.toc` entry must name a record. `MailStore`
tolerates far worse (it trusts a `.toc` at a simple majority, and the worst in
the real tree matches ~71%). So these are readable but genuinely stale. Two
questions before doing anything: how stale is each one, and is there a safe way
to rebuild an index without losing the status flags it is the only copy of.

Re-running the tool over them later is easy — it is idempotent, and it refuses
rather than overwrites when a `.prerelink` backup exists, so any retry needs the
old backup moved aside first.

### 3. `MIMEParser.parseHeaders` decodes CP1252 headers as UTF-8

`String(decoding: bytes, as: UTF8.self)` at `MIME.swift:359`. Eudora wrote
headers in CP1252, so every non-ASCII byte in a header becomes U+FFFD:
`CarterCaténaires.png` displays as `CarterCat<?>naires.png`. This is why the
attachment-name list generated from the mail had two mangled entries, and why
`RecordedAttachmentRelink.Locations.lookup` carries a wildcard matcher at all.
`CP1252.decode` already exists and is what `Toc.cString` uses. Small change,
wide blast radius — every header in the app goes through this — so it wants its
own session and a careful look at what currently depends on the lossy behaviour.

### 4. Dead message list after a move — still instrumented, still waiting

Unchanged for seven handoffs and **not reproduced**. Both diagnostics still on.
Read `RemovalVeilDiagnostics`' doc comment (`AppModel.swift`, above `PerfLog`)
for the healthy trace and the two failures to look for. `VEIL DOWN` present with
clicks still dead ⇒ the veil is innocent, read the `[resize]` lines. **Turn both
off once settled.**

The inspection-found hole still stands: three of the four arms of `loadListing`'s
scroll-restore chain set `pendingScrollTopRow` to nil, and `clearPendingScroll`
lifts the veil *only* when it finds one pending. What doesn't fit is that
Stephen's lasted minutes, not fifteen seconds.

### 5. The only known open bug that can duplicate mail

`shiftDraftOffsets` is called only from the draft-save paths, never from
`deleteSelected` or `moveSelected`. Deleting or moving a record in **Out** while
other drafts are open strands their offsets, and each later save then appends a
copy instead of updating. `MenuBarView`'s Delete is gated on `canActOnSelection`
alone and can still reach it.

### 6. Remaining View Response loose end

**The jump reads the destination mailbox in full on the main thread.**
`MailStore.indexOfRecord` is a non-mapped `Data(contentsOf:)` plus a whole-file
record scan, unbounded. (Stephen didn't recognise this one when it came up on
aug31 — it may want re-explaining before it is worth doing.)

### 7. Gmail-side blacklisting, if he wants Eudora to do it

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

### 9. Test list — mostly still outstanding

Only the pinned-sidebar-with-Junk item was done. Remaining, in the order they
were judged worth doing:

- **A sent message with both a real MIME attachment and an `X-Attachments`
  header** (187 of these in `phaseX`) — the file must appear once, as a working
  chip, not also as a greyed row.
- **Most of Recents**: rename and delete of a listed mailbox, the empty menu, and
  clicking the blank right-hand part of the row.
- **Several compose windows at once**: three or four open, save a middle one then
  another, and confirm neither produces a duplicate in Out. (This is queue 5's
  bug, so a failure here is expected rather than surprising.)
- **A plain unstyled message must still be a single `text/plain` part** — the
  regression guard for the whole image change.
- View Response with a second reply left open as an unsent draft, and with two
  sent replies.
- **Open sender's mailbox** on a sender with mail in several places, and on one
  with none (should read "None found" rather than an empty submenu).
- **Blacklist routing** on a message that carries no `Delivered-To` at all —
  should land on both lists.

### 10. Housekeeping left behind by the relink

- **156 `.mbx.prerelink` and `.toc.prerelink` files** now sit in `~/Eudora` beside
  the mailboxes they back up. They are small (these are per-person mailboxes),
  and their presence *blocks* a re-run of `eudora-relink` on that mailbox by
  design. Worth confirming they don't show up anywhere in the sidebar — the tree
  walk looks for `.mbx`, and `x.mbx.prerelink` has extension `prerelink`, so it
  shouldn't, but nobody has looked.
- **The Laetrile PDF** is the one curated location that was dropped: its filename
  on disk carries a non-breaking space where the mail header has a plain one, and
  by the time the tool ran it was no longer at the recorded path. One message.
- **`reference/missing-attachment-names.md` is still built from `phaseX`**, the
  2026apr03 copy. `python3 reference/list-recorded-attachments.py ~/Eudora`
  regenerates it against the live tree; Stephen runs it, Claude can't see
  `~/Eudora`. It would now also pick up the 320 relinked paths as "recorded at a
  real path", which is the point.
- The search index's `attachments` column holds only *MIME* filenames, so
  `Attachments contains foo.pdf` won't match a recorded one (it is findable via
  the `headers` column). Pre-existing; the relink doesn't change it, but it does
  make it more noticeable now that the recorded ones are real files.

---

## Key context

**Claude cannot build or test.** Write carefully → Stephen builds and runs
`swift test` → he pastes the errors. Prefer `EudoraMac/` over `EudoraApp/`.

**Use `general-purpose` review agents before handing anything over, and use two
when the change writes to real data.** See "the four things to know" above:
eleven real defects across two passes this session.

**A literal tab inside a Swift raw string won't compile** — "unprintable ASCII
character found in source file". Cost one build round-trip. Use `"\t"` and escape
the backslash rather than reaching for `#"…"#`.

**`phaseX` is a copy.** See `CLAUDE.md`'s section on the two mail trees. Anything
generated from it is private and belongs in `reference/`, which is gitignored —
the repo is public. Everything this session generated is there.

**`eudora-relink` is re-runnable.** `swift run -c release eudora-relink <root>
<locations.tsv>` is a dry run; `--apply` writes; `--mailbox <path>` restricts to
one; `--verbose` lists every header. It is idempotent (a relinked entry holds a
POSIX path, and every staging segment `pathRecordsOrigin` looks for is
backslash-delimited), it refuses a mailbox whose backup already exists, and it
asks for typed confirmation before a tree-wide `--apply`. Eudora must be quit.

**For performance, use `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary
is `Eudora`, not `EudoraApp`.

**Claude must not run git**, and cannot delete files either — the sandbox can't
unlink. Write the message to `reference/commit-message*.txt` (gitignored) and
hand over `git commit -F`, naming the changed files explicitly rather than `-A`.
**A new file needs `git add` first.** Recovery from a stranded lock:
`rm -f .git/index.lock`. Claude *can* read `.git/logs/HEAD`.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't —
this session's new sources all went there, so nothing needed regenerating.

**Releasing** is a double-click on `Build Release to Share.command`.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap, and see
queue 7.

**musanim.com and gmail.com are independent mailboxes**, collected separately;
neither forwards to the other. Confirmed 2026aug30.

**Hammerspoon** carries `night-mode.lua`, which is Stephen's, not Eudora's, but
the two touch: it moves Eudora's windows. Repo copy at `scripts/night-mode.lua`,
live copy at `~/.hammerspoon/night-mode.lua`. Editing the repo copy does nothing
until it is copied across and Hammerspoon is reloaded.

---

## Next session

Ask him rather than choosing, and don't start work off this list without his
say-so. The likely first is **queue 1** — the `TocWriter` finding is this
session's loose end, it is ongoing silent data loss, and the fix has a proven
shape and a ready test fixture. **Queue 2** follows naturally from it, since a
safe index rebuild is what those seven mailboxes need.
