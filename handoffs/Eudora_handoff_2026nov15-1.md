Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026nov15 (1)

**Supersedes `Eudora_handoff_2026nov14-3.md`.** What no longer applies from it:
its "Next session" item 1 (MAM4U section A is finished) and the second limit
under item 2 (the stale-`.toc` refusal is gone — fixed at the root). **The
"Carried forward" section of `handoffs/archive/Eudora_handoff_2026nov14-1.md`
is still current**, with nov14-3's corrections (HOLDING confirmed,
`diagnoseHolding` off, three diagnostics on), plus the queue-item-5 note below.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects` (pass the path directly)
   and read `claude-conventions.md`. Ask for `~/Eudora` too if MAM4U work or
   live-tree reading is likely — request both together.
2. Read this project's `CLAUDE.md`.
2a. Read `ClaudeProjects/ClaudeManagement/CLAIMS.md` and `LOG.md` (the shared
   board; rules in the "Coordination between instances" section of
   `claude-conventions.md`, effective 2026nov15). **Before editing anything
   outside `Eudora/`** — including `MAMforTheMasses/tools/mam4u_batch.py` and
   the `PeopleToEmail/` files — add a claim line; when done, commit, remove it,
   and append one line to `LOG.md`.
3. Read this handoff, then the "Carried forward" section of
   `handoffs/archive/Eudora_handoff_2026nov14-1.md`.
4. Wait for Stephen.

**One step at a time** — one command, then wait. **Nothing actionable after a
command block.** No multiple-choice widget; ask in prose. For MAM4U batches,
fix greetings yourself and go straight to `--apply` (he quits Eudora first, no
dry run). The device shell has **no Swift**: `eudora-drafts` and `swift test`
run on his Mac.

---

## Next session

### 1. MAM4U section B — needs its own email text first

Section A (MAM MIDI Player, 270 rows) is **done**: batches 1–14 written to Out.
Section B of `PeopleToEmail_2026nov14.txt` is 54 people who asked about other
software (Tapper, Tantrum, WAVAlign, LPMAM, Harmonizer, VoiceTracker — program
in the notes column). `MAM4U_bulkEmail.txt` talks about the MAM MIDI Player,
so B needs different wording, and `mam4u_batch.py`'s `read_list` reads only
section A (`== A.` … next `== `). Nothing started; Stephen hasn't said whether
he wants B mailed at all. Ask.

### 2. Replies coming in → Make Person Mailbox…

Stephen files repliers with right-click → **Make Person Mailbox…**, one per
person. It now moves out of mailboxes with dead index entries (MISCINQ), and
he confirmed it "works like a charm". The one remaining known limit: it
**matches the From address only**, so a replier writing from a new address
leaves older mail behind (possible fix in nov14-3: follow `In-Reply-To` and
offer its recipients in the sheet). Record, don't build unless asked.

### 3. Bounces — watch, note in progress.txt

New this session: Matthew Bick (row 158, `smartcity.net`, "550 Route does not
accept incoming messages" — dead), Jacob Downer (row 266, old FCPS student
address; a quick web search found no current address, and Stephen is content
to drop it).

### 4. Index follow-ups from the review agents — none asked for

- **Shift repair.** If a `.toc` write ever fails after its `.mbx` write
  (crash between the two), the index is left shifted; it's still trusted, so
  records after the edit stay hidden. Writes are now atomic, so only a crash in
  that instant does it. A reviewer sketched a repair: find one constant `d`
  moving the dead entries onto the unnamed records. Build only if seen.
- **`appendRecord` duplicate entry** (`MailboxMutator.swift`, the streamed
  append): it never checks for an existing entry at the new offset. Low.
- **Length-mismatch census.** An entry at a real record start whose `length`
  differs from the record's may describe a different message. One-off count
  over the live tree would say whether that ever happens (allow for the ~26
  false-separator splits in In). Not run.
- Old, not touched: `setStatus(base:index:)`'s comment says it never parses
  the whole mailbox; it does (`findRecords`).

### 5. Standing queue — see the archived nov14-1 handoff

**Queue item 5 (seven mailboxes whose `.toc` doesn't describe the `.mbx`)
changed meaning:** a trusted-but-stale index (MISCINQ: 4 dead of 2,092) is now
kept, minus its dead entries, by the first Move/Delete/append/replace into or
out of it — so MISCINQ is probably clean already. `eudora-relink`'s own skip
rule is separate and unchanged.

---

## Done this session (2026nov14 evening – nov15)

All committed and pushed except this handoff's commit. `swift test` passes
(all; 842 + the 2 new); the app was built and Make Person Mailbox confirmed on a MISCINQ sender.

- **`6c087a6` — Move/Delete keep a trusted `.toc`.** New
  `MailboxMutator.trustedEntries(_:recs:) -> [Int]?` is the one rule (empty
  index, or a strict majority of entries naming a record); `MailStore.list`
  reads through it and `removeMany` writes back its live entries minus the
  removed ones. Only an untrusted index is deleted. `PersonMailbox.Scan.indexIsStale`
  removed; `personMoveBlocked` now only blocks Out read without an index
  (sheet label says so).
- **`260d64d` — Out writers too, and atomic index writes.** `Outbox.append`,
  `replace`, `setStatus(base:index:)` go by `trustedEntries`; dead entries are
  dropped on rewrite (none can sit where a new record lands). `tocConsistent`
  deleted, its history folded into `trustedEntries`' doc. Every `.toc` rewrite
  in these paths uses `MailboxIO.atomicWrite`.
- Two review agents on each; they found no bugs, one rare regression
  (shifted index after a failed write) answered by the atomic writes.
- **MAM4U batches 6–14** (rows 103–270). `progress.txt` is current.
- **`mam4u_batch.py` fixes** — committed in the **MAMforTheMasses** repo
  (`8eec160`, logged in `ClaudeManagement/LOG.md`), not this one. That repo
  belongs to the MAMforTheMasses instance; touch it only under a claim. It
  needs `git -c user.name=… -c user.email=…` (no identity configured there).
  `unflip()` turns "Last, First" into "First Last" — **a comma in a To display
  name fails on send** — and a name with several commas goes to the bare
  address with "Hello,"; a leading initial is skipped for the greeting;
  nameless rows are no longer merged as one person (they were, at rows
  261–267). Backup `tools/mam4u_batch.py.pre-comma`.

## Key context added this session

- **Greeting judgment calls made in batches** (for consistency next time):
  handles and business names → "Hello,"; all-caps → capitalised; surname-first
  East Asian / Romanian names → given name ("Dear Ryosuke," "Dear Dimitrie,"),
  or "Hello," when the order is unclear (Yeh Kun); families → "Hello,".
  Same person under two names (Oecxwen / Oecxwen MMM) → keep the newer address
  only. Same name on consecutive rows is merged by the script automatically.
- `reference/` holds disposable copies from this session: `*.pre-toc`,
  `*.pre-toc2`, `toc-keep*.diff`, `commit-msg.txt`.
- Delete permission had lapsed again at the first git call this session;
  the scratch-file test caught it.
