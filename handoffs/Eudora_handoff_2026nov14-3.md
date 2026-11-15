Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026nov14 (3)

**Supersedes `Eudora_handoff_2026nov14-2.md`.** What no longer applies from it:
its "Next session" item 1 (Make Person Mailbox… is built and committed) and
item 2's starting row (batches 3–5 are done; next is row 103). **Everything
under the heading "Carried forward from Eudora_handoff_2026nov13-1.md" in
`handoffs/archive/Eudora_handoff_2026nov14-1.md` is still current**, except:
the HOLDING "waiting on real mail" item is **done** (first libero.it arrival
held correctly, Stephen confirmed) and `diagnoseHolding` is now **off**, so
three diagnostics remain on, not four.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects` (pass the path directly)
   and read `claude-conventions.md`.
2. Read this project's `CLAUDE.md`.
3. Read this handoff, then the "Carried forward" section of
   `handoffs/archive/Eudora_handoff_2026nov14-1.md`.
4. Wait for Stephen; he will most likely ask for the next MAM4U batch.

**One step at a time** — one command, then wait. **Nothing actionable after a
command block.** No multiple-choice widget; ask in prose. Stephen reviews every
draft before sending, so **don't ask him about greetings** — fix obvious
handles yourself ("Hello,") and go straight to `--apply`. He quits Eudora
first; no dry run needed. The device shell has **no Swift**: `eudora-drafts`
runs on his Mac, always.

---

## Next session

### 1. MAM4U batch 6, from row 103

    cd ~/ClaudeProjects/MAMforTheMasses/PeopleToEmail && python3 ../tools/mam4u_batch.py $HOME/mnt/Eudora PeopleToEmail_2026nov14.txt 103 20 batch06.json

(from the device shell, with `~/Eudora` granted). Read `batch06.review.txt`,
replace handle greetings in the JSON (`Dear <first>,` → `Hello,`; surname-first
names like "Huang Kevin" → the given name), append a line to `progress.txt`,
then hand Stephen:

    cd ~/ClaudeProjects/Eudora/EudoraMac && swift run -c release eudora-drafts ~/Eudora ~/ClaudeProjects/MAMforTheMasses/PeopleToEmail/batch06.json --apply 2>&1 | tail -30

### 2. Make Person Mailbox… — two known limits, nothing asked for yet

Found on its first real use (Kevin Huynh, 2026nov14), which moved only the
clicked message. Stephen said "you needn't do anything"; record, don't build
unless he asks.
- **Matches the From address only.** Kevin had replied from a new address;
  all his earlier mail was from another. Possible fix: follow `In-Reply-To`
  to the message answered and add its recipients (minus me), shown in the sheet.
- **`__MAM.fol/MISCINQ` has a stale `.toc`** (2,092 entries, 2,088 records,
  4 dead entries — queue item 5), so the command refuses to move out of it
  (`Scan.indexIsStale`). Root fix proposed: `MailboxMutator.removeMany`
  should write the `.toc` back without dead entries instead of deleting it
  (it currently deletes unless *every* entry matches, and the next listing
  then scans and shows uncompacted ghosts) — fixes ordinary Move/Delete too,
  and then the refusal can go. Needs two review agents.

### 3. Watch bounces (unchanged from nov14-2 item 3), plus the new EarthLink rule

### 4. Standing queue — see the archived nov14-1 handoff

---

## Done this session (2026nov14, third part)

All committed; `swift test` passes (840 tests); the app builds and runs.

- **`50bc906` — Make Person Mailbox…** (right-click, single received message,
  under "Open sender's mailbox"). `EudoraStore/PersonMailbox.swift` +
  `PersonMailboxTests` (name, destination, default ticks, exact-match scan);
  AppModel "MARK: mailbox management (Make Person Mailbox…)"; sheet
  `PersonMailboxDialog` at the end of `MoveToMenu.swift` (a real
  `beginSheetModal`, not `runModal` — it opens from inside a main-actor task).
  Index proposes mailboxes, each is read and matched exactly on
  From/To/Cc/Bcc (listed records only; unsent/queued skipped; clicked message
  confirmed by offset + Message-ID; Trash/Junk never read). Read again after
  Create & Move; fingerprint (mbx size+mtime) checked before each write;
  stale-`.toc` mailboxes and index-less Out never moved from; nothing created
  when nothing is movable; an all-failed run deletes the empty mailbox.
  On-screen mailbox moves via selection + `moveSelected(to:notice:)` (new
  `notice` parameter). Three review rounds.
- **Same commit — `HeaderDecoder` fix.** The closing `?=` was searched for from
  the charset, so `=?UTF-8?Q?=C3=89…?=` stopped at `Q?=` and stayed raw —
  every Q-encoded word starting with an encoded byte, app-wide. Now searched
  after `charset?enc?` when the encoding is one letter, old search as fallback.
- **Same commit — `diagnoseHolding` off.**
- **`09f89a4` — EarthLink bounces.** `BounceReport.providerSaysNoMailbox`:
  `ELNK…_403` and 5.x `_402` mean gone ("550 5.5.1 Recipient rejected" alone
  says nothing). From Gordon Green's bounce.
- **MAM4U batches 3, 4, 5** (rows 42–102) written to Out; `progress.txt` is
  current. Gordon Green (batch 4) bounced: EarthLink no-such-mailbox.

Not yet pushed at handoff: Eudora `09f89a4` (if not already) plus this
handoff's commit.

## Key context added this session

- **Device connection drops silently** mid-session; the next `device_bash`
  says no folders are connected. Re-request both ClaudeProjects and
  `~/Eudora` together, and re-test delete permission before git.
- `reference/` holds disposable copies from this session: `*.pre-pm`,
  `pm*.diff`, `pm_*.swift`, `commit-msg.txt`.
- Review agents caught, this time: a captured `var` in a `Task` (won't
  compile), the HeaderDecoder bug above, stale-`.toc` ghost resurrection,
  drafts movable out of Out, a mailbox created before the checks that could
  leave nothing to move into it.
