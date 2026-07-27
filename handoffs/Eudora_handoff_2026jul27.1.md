# Handoff: Eudora — 2026jul27.1

**Read `CLAUDE.md` first.** The one rule above all: **ask Stephen questions in plain
prose, never the multiple-choice widget** — it doesn't render for him.

## Goal
A native macOS Eudora 7 replacement ("Eudora 8"), Swift/SwiftUI+AppKit, macOS 13 /
Swift 5.7. Two SwiftPM-ish targets: **EudoraMac** (library — *testable*, `cd
EudoraMac && swift test`) and **EudoraApp** (the app — *not* testable in the
sandbox). Reads the real Eudora tree in place; format shared with Windows Eudora 7.

## Milestone
As of this session, **Stephen says 8 is "almost as good as" Eudora 7** (which he's
used for 30 years). The last thing we did — matching 7's font rendering — he called
"perfect." Morale is high; we're polishing, not firefighting.

## Completed this session (all built + confirmed by Stephen)
- **To/Cc/Bcc auto-fill.** `RecentRecipients` store (EudoraStore, tested) + custom
  `RecipientField` (EudoraApp) with a non-modal dropdown; MRU seeded only from To on
  send; **forward-Delete (⌦) removes** the highlighted entry; accepting inserts the
  name with **no trailing comma**.
- **Spell check** on the compose body (continuous red underline, no autocorrect;
  Learn/Unlearn via the built-in right-click menu — nothing to build there).
- **Text corrections** (the user's *own* autocorrect list, case-sensitive):
  `TextCorrections` store (tested), applied on word completion in the editor,
  right-click "Correct 'word' to…" quick-add, and a Settings section.
- **Add to BLACKLIST** (right-click a received message; "BLACKLIST" is bold):
  critical confirm → auto-sends a reply (your line + 2 CRLFs + original body),
  appends the address to `~/email_blacklist.txt`, opens it in TextEdit, and files a
  copy of the notice in **Trash**.
- **Hide Junk** mailbox by default + a "Show Junk mailbox" Settings toggle
  (`AppModel.showJunkMailbox` / `visibleTree`; display-only, disk untouched).
- **Sidebar divider** below the pinned system mailboxes (In/Out/Junk/Trash).
- **Quiet Xcode console**: `OS_ACTIVITY_MODE=disable` added to the Run scheme in
  `project.yml` (re-run `xcodegen generate` to pick it up).
- **Outgoing attachments.** `OutgoingMessage.Attachment` + multipart/mixed assembly
  (MessageBuilder, tested), `ComposeDraft.attachments`, an **"Attach" row** in the
  composer (drag-drop + paperclip, removable chips), bytes embedded in the draft so
  they survive save/reopen, extracted back on reopen / Send Again.
- **Move to group.** `MailboxTreeMutator.moveInto` (EudoraStore, tested —
  `MailboxMoveIntoTests`) + `AppModel.moveIntoGroup`; a **hierarchical** right-click
  "Move to group ▸ …" submenu with **Top Level** at the head; each group is directly
  clickable (SwiftUI `Menu` + `primaryAction`), no "Move here" item.
- **New Mailbox / New Group** wired into the Mailbox menu (`AppModel.createTopLevel`,
  creates at top level; "New Group…" = folder).
- **From field** made click-only (out of the Tab order via `canBecomeKeyView=false`);
  fixed reverse Shift-Tab (re-added `.focused` on the recipient fields); fixed compose
  window sizing (content overflow → `minHeight: 540`, editor no longer greedy).
- **Eudora-style anti-aliasing.** New `BodyAntialiasing` enum (off/system/eudora) +
  a halo-lightness slider. `.eudora` caches a crisp (AA-off) bitmap and grays the
  background pixels *orthogonally* touching ink — reproducing Eudora 7's simple,
  gradient-free smoothing, which keeps a distinct solid core. Stephen tuned it to
  **perfect at font size 13**. (Why it matters: we measured that macOS `.system`
  smoothing *bolds* the type ~27–40% heavier than 7; `.off` is lighter than 7;
  `.eudora` sits where 7 does.)

## Current state
**Clean stopping point — nothing half-done.** Everything above is built and Stephen
confirmed each piece by building + testing as we went (he builds; the sandbox can't
compile Swift). Last exchange: he dialed in the Eudora-style halo and said "we're
home."

## Next steps (Stephen will choose; nothing is queued as urgent)
1. **Update `EudoraDevelopmentNotes.txt`** — its "to do" is just `move mailbox into
   group`, which is now **done** (design note beneath it can be cleared/archived).
2. **Deferred, on the table:** multi-select for "Move to group." Estimate given: the
   *move* logic is a few hours (loop `moveInto`, filter selected-descendants,
   aggregate partial failures, exclude the whole set from destinations); the *cost*
   is sidebar multi-selection (single `Binding<ID?>` today → primary-vs-set model +
   right-click-on-selection semantics, likely needing the AppKit right-click pattern
   `MessageContextMenu` uses). ~a day, ~80% selection plumbing.
3. **Deferred:** Finder-style drag for reorganizing the tree (needs the same set
   handling; would also justify moving the sidebar context menu to an **AppKit lazy
   menu**, which is the upgrade if the folder tree ever gets large/deep — the current
   "Move to group" submenu builds eagerly on right-click, fine for modest trees).

## Verify-at-build (Eudora-style AA — Stephen already confirmed it renders + is
tuned, so these are effectively cleared, but note them)
- Orientation of the cached-bitmap blit (flipped view) — confirmed not mirrored.
- Scroll smoothness of `.eudora` on a long message — re-renders + 2 pixel passes per
  draw; if it ever drags, `sample $(pgrep -x Eudora) 10 -file out.txt` and add a
  cache. `.off`/`.system` are unaffected. Tuned for non-Retina (halo = 1 device px
  on Retina, subtler by design).

## Key context / gotchas (still current)
- **Build loop:** Claude cannot compile — write carefully → Stephen builds → he
  pastes errors. **Use `general-purpose` review agents for anything non-trivial
  before handing over.** They caught real bugs every feature this session (e.g. the
  little-endian ARGB alpha-byte bug in the halo routine, the blacklist-on-sent-mail
  footgun, the styled-draft-with-attachments formatting loss).
- **`swift test` works** for EudoraMac. New this session: `RecentRecipientsTests`,
  `TextCorrectionsTests`, `MessageBuilderTests` (attachments), `MailboxMoveIntoTests`.
- **`xcodegen generate`** only after adding a **new source file to
  `EudoraApp/Sources/`**. Files in `EudoraMac/` and imagesets are picked up
  automatically. (No new EudoraApp source file is pending — `RecipientField.swift`
  was the only one and it's already generated. But the `project.yml` scheme change
  (`OS_ACTIVITY_MODE`) needs a regenerate.)
- **`phaseX/` is real mail (12 GB), gitignored; repo is public.** Claude may read it
  to diagnose format bugs; never commit addresses.
- **Instrument, don't theorise** — guessing has cost build round-trips (the compose
  layout bug this session took 3 wrong guesses before a screenshot settled it; the
  fix was window `minHeight`, not the things I guessed).
- **descmap.pce is byte-preserved** on every tree mutation (backup-once + atomic
  write; lines that stay are never re-encoded). `MailboxTreeMutator.moveInto` follows
  this and never leaves a descmap line pointing at a missing file.
- **The compose focus model** is subtle: forward Tab uses AppKit's key-view loop;
  reverse uses `BackTabCatcher` + `@FocusState`. Recipient fields (`RecipientField`)
  self-manage first responder AND carry `.focused` so SwiftUI doesn't wipe the focus
  value; From is click-only (`canBecomeKeyView=false`) and out of the `Field` enum.
- macOS 13 / Swift 5.7. Read `design-decisions.md` and `eudora-mac-architecture.md`;
  don't re-debate settled decisions.

The user will likely ask you to tidy `EudoraDevelopmentNotes.txt` (move-to-group is
done), or to pick up one of the deferred items (multi-select move, or Finder drag) —
or to start something new. Confirm the goal in plain prose before building, and lean
on review agents.
