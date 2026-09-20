Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026aug30 (1)

**Supersedes `Eudora_handoff_2026aug12-1.md`.** Four of its items are closed and
should not be carried further: queue item 1 (build/test/commit — done on aug12
and aug13), item 4 (the filing-triggered reindex is tested and works), item 6
(the spell-correct change is accepted as it stands, no reversal wanted), and the
aug12 night-mode note about the 07:00 automatic restore, which was removed and
committed on aug17. Everything else from it is repeated below rather than left
behind.

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

**Everything is built, tested, committed and pushed. Nothing is pending.** Three
commits landed this session, each built and confirmed by Stephen before the
commit:

- `Open sender's mailbox, from the message context menu`
- `A second blacklist bucket, for mail that arrives via Gmail`
- `Sidebar bold: derive it, rather than trust a flag nobody writes`

`swift test` is at **576** and passing (565 before this session, plus 11 new
routing tests). `reference/commit-message.txt` holds the last message used and
is spent.

Diagnostics: `RemovalVeilDiagnostics` and `MessageColumnResizeController.diagnose`
are still **on** for the dead-list bug. `MessageIDIndex.diagnose`,
`BodyTextView.diagnoseSpelling`, `BodyTextView.diagnoseMenuOrder` and
`MessageContextMenuController.diagnosePlacement` are **off**, each with its
finding in its doc comment.

## Done this session

- **"Open sender's mailbox"** in the message context menu, under Move to. Lists
  the mailboxes this sender's mail has been filed into, ranked, Trash and Junk
  excluded; picking one opens it. A single received message only, gated on the
  new `AppModel.isOutgoingMessage` — review caught that the obvious gate,
  `isSentMessage`, means "successfully sent" and would have offered it on every
  draft in Out.
- **Two blacklist buckets**, TigerTech (musanim.com) and Gmail (gmail.com), with
  `BlacklistRouting` deciding from the message's own headers. The Blacklist
  window has two sections, each drained separately.
- **Sidebar bold is derived**, and `MailboxItem.hasUnread` is deleted. See below.
- **Gmail blacklisting researched**, with the manual procedure settled — see
  "Gmail, for reference" below.

## The two things to know that aren't in the docs

**1. Reading the real mail settled two designs that reasoning would have got
wrong.** `phaseX` is right there and `grep` over it answers questions in seconds:

- Routing a blacklisted address by recipient looked like a `To:` question.
  Counting `To:` across In and Trash found 561 @aol.com and 323 @googlegroups.com
  — mail that arrived at one of his two addresses while naming neither, because
  it was Bcc'd or went through a list. `Delivered-To:` carries 19,794
  @musanim.com and 3,619 @gmail.com, and `X-Original-To:` another 19,801. That
  measurement *is* the design, and it is recorded in `BlacklistRouting`'s doc.
- Roughly a fifth of recent messages carry neither delivery header, which is why
  the `To`/`Cc` fallback and the both-lists last resort exist.

**2. A remembered badge with no writer at all.** Stephen asked for Out's sidebar
label to be bold like In's and Trash's. The cause turned out to be that
`MailboxItem.hasUnread` was the fourth field of `descmap.pce` — Eudora 7's unread
flag — which **Eudora 8 reads and never writes**; every `MailboxTreeMutator`
operation carries it across byte-for-byte on purpose. So every bold name in the
sidebar reported what Eudora 7 believed on cutover day. His emptied Trash was
permanently bold because the live line still reads `Trash,Trash.mbx,S,Y`.

This is the In new-mail flag's lesson from the other side: that one was
remembered state with an unreliable clearer, this was remembered state with *no*
writer. Bold is now derived and means one thing — In when its newest message is
unread, Out when it holds unsent mail, nothing else ever.

**The probe that settled it was `grep -i trash ~/Eudora/descmap.pce`**, run by
Stephen. Claude could not: `~/Eudora` is the live tree and is **not mounted**;
only the project folder is. `phaseX` is a copy and its Trash line reads `N`, so
believing the copy would have produced a confident wrong diagnosis. When a
question is about live state, ask him to run one line rather than infer from
`phaseX`.

---

## The queue — ask Stephen which first

### 1. Fix the `CLAUDE.md` omission (two minutes, and it has now cost twice)

`CLAUDE.md` should say that **`~/Eudora` is the live mail tree, `phaseX` is a
copy for reading, and only the latter is mounted.** This has been on the loose-
ends list for four handoffs. It cost a seed list built from three-week-old data
once, and this session it nearly cost a wrong diagnosis of the bold-Trash bug.

### 2. Night mode over Screens: the menu-scrolling problem

**Stephen was going to test the free option on the night of aug30 — ask him how
it went before doing anything here.**

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

### 3. Night mode: two things still unproven

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

### 4. Dead message list after a move — still instrumented, still waiting

Unchanged for five handoffs and **not reproduced**. Both diagnostics still on.
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
record scan, unbounded.

### 7. Gmail-side blacklisting, if he wants Eudora to do it

Now that a Gmail list exists to push from, the API route is real but not cheap.
`users.settings.filters.create` with `from:` → `addLabelIds: ["TRASH"]`, one
filter per address, 1,000-filter ceiling. The price is **OAuth2**, which the
project lists as a known gap. Two sharp edges to state before starting:

- The consent screen **must be published "In Production"**, or Google expires
  every refresh token after 7 days.
- Published-but-unverified means a warning at sign-in and a 100-user cap. Fine
  for him alone; not fine for the Eudora he notarizes and shares, which would
  need Google's verification review for a sensitive scope.

The argument in favour is that the same subsystem would close the POP/SMTP
OAuth2 gap. Don't start it without him choosing it deliberately.

### 8. Sidebar bold: one thing was lost on purpose

An ordinary mailbox holding pre-cutover unread mail used to be bold — frozen,
but not necessarily wrong — and now isn't. If Stephen misses that marker, say so
plainly: deriving it per mailbox means listing all 2,657 on every tree walk,
which is the cost this app has spent months removing. There is no cheap version.

### 9. Older doc loose ends, still open

- `SidebarExpansion`'s doc comment claims a rename changes a `MailboxItem.ID`.
  Wrong, and now load-bearing for Recents.
- `AppModel.swift`'s doc on `removalNotice` describes "Moved to Trash." as a
  delete's completion message. No delete path passes a notice; the only "Moved
  to…" comes from `moveSelected`. Cosmetic, but wrong.
- `EudoraDevelopmentNotes.txt:2219` still names `MailboxItem.hasUnread` as a live
  thing. It no longer exists.

### 10. Test list

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

---

## Gmail, for reference — the manual procedure, settled

Stephen asked how to blacklist Gmail addresses by hand. The answer, researched
and confirmed, so it doesn't need re-deriving:

- **Gmail's "Blocked addresses" list cannot be hand-edited.** You can only add to
  it from an actual message; Settings offers only *un*block. It is the wrong tool.
- **Use a filter instead.** Settings ▸ See all settings ▸ Filters and Blocked
  Addresses ▸ Create a new filter; put the addresses in the **From** field inside
  braces — `{a@x.com b@y.com}`, which means OR — then Create filter and tick
  **Delete it**. To add more later, edit the same filter.
- **The From field caps around 1,470 characters**, roughly 45 addresses. Past
  that, make a second filter; there is no limit on how many.
- **Gmail has no wildcard operator, and doesn't need one.** `from:` matches
  substrings, so `repdailyred.com` already catches every address at the domain
  and its subdomains, and `repdailyred` alone catches the whole `.net`/`.info`
  family. The flip side: it matches display names too, so a short or common token
  over-matches badly. `from:news` would be a disaster.
- **Test every entry in Gmail's search box before putting it in a filter.** Same
  matching engine, and the action is "Delete it".

## Key context

**Claude cannot build**, and cannot run `swift test` either — Stephen runs both.
Write carefully → he builds → he pastes errors. Prefer `EudoraMac/` over
`EudoraApp/`, where it can be tested. `BlacklistRouting` was put in `EudoraMac/`
for exactly that reason and it paid immediately.

**Use `general-purpose` review agents before handing anything over.** Three times
this session, three real findings: the `isSentMessage` gate that would have
offered "Open sender's mailbox" on every draft in Out; reading only the *first*
`Delivered-To`, which is the last hop since MTAs prepend; and four stale comments
left describing a world with one blacklist destination.

**Instrument rather than theorise.** See "the two things to know" above. `phaseX`
is real mail and `grep` over it is the cheapest design tool in the project — but
it is a *copy*, so for questions about live state, ask Stephen to run one line
against `~/Eudora`.

**For performance, use `sample $(pgrep -x Eudora) 10 -file out.txt`.** The binary
is `Eudora`, not `EudoraApp`.

**Claude must not run git**, and cannot delete files either — the sandbox can't
unlink. Write the message to `reference/commit-message.txt` (gitignored) and hand
over `git commit -F`, naming the changed files explicitly rather than `-A`.
Recovery: `rm -f .git/index.lock`. Claude *can* read `.git/logs/HEAD` to see what
has been committed, which is how this session discovered the aug12 handoff was
eight days stale.

**Assets and files:** a new file under `EudoraApp/Sources` needs
`xcodegen generate`, run *after* writing the file. Files in `EudoraMac/` don't —
both new files this session went there, so nothing needed regenerating.

**Releasing** is a double-click on `Build Release to Share.command`.

**SMTP/POP are implicit TLS only** — no STARTTLS, no OAuth2. Known gap, and see
queue item 7.

**musanim.com and gmail.com are independent mailboxes**, collected separately;
neither forwards to the other. Confirmed 2026aug30. The blacklist routing's
multi-hop handling is a guard against a shape his mail doesn't currently have.

**Hammerspoon** carries `night-mode.lua`, which is Stephen's, not Eudora's, but
the two touch: it moves Eudora's windows. Repo copy at `scripts/night-mode.lua`,
live copy at `~/.hammerspoon/night-mode.lua`.

---

The likely first request is to hear how the Screens keyboard test went — see
queue item 2 — and to pick up from there. Ask him rather than choosing, and don't
start work off this list without his say-so.
