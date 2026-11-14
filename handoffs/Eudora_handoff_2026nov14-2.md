Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026nov14 (2)

**Supersedes `Eudora_handoff_2026nov14-1.md`** (already in `handoffs/archive/`).
What no longer applies from it: its "Next session" item 1 (the bounce/response
design is now built — see below) and item 2's "scripts are gone" (they are
rebuilt and committed). **Everything under its heading "Carried forward from
Eudora_handoff_2026nov13-1.md" is still current** — the queue (items 4–15), the
four diagnostics, and all of Key context. Read that section there; it is not
repeated here.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects` (pass the path directly)
   and read `claude-conventions.md`.
2. Read this project's `CLAUDE.md`.
3. Read this handoff, then the "Carried forward" section of
   `handoffs/archive/Eudora_handoff_2026nov14-1.md`.
4. Start on item 1 under "Next session" — the design is already agreed, so
   confirm only the open details listed there, then write code.

**One step at a time** — one command, then wait. **Nothing actionable after a
command block.** No multiple-choice widget; ask in prose.

---

## Next session

### 1. Make Person Mailbox… (right-click command) — design agreed, not started

For a reply from someone whose earlier mail is in MISCINQ or another group
folder rather than a PEOPLE mailbox of their own. Agreed with Stephen:
- A **right-click command** on the message (not automatic on arrival).
- Name prefilled from the From line, editable ("a b"-type names happen).
- Destination `PEOPLE.fol/<first letter>/` — into the two-letter subgroup when
  one exists (J has `JA.fol`, `JO.fol`, …; "Jo…" → `J/JO`), else the letter.
  Mailboxes are named "First Last". The letter-group auto-sort (queue 8,
  single-character display name) places it; two-letter groups don't auto-sort.
- The sheet lists every mailbox holding mail with their address in From/To/Cc,
  with a count and a checkbox. **Default ticked: all, except** In, Out, Trash,
  SCAMS, HOLDING, and other people's PEOPLE mailboxes (where they were probably
  only CC'd). Stephen confirmed this default.
- Create & Move, then the index rebuild comes free: `moveSelected` →
  `filingIsUnfamiliar` → `relearnPending` → `maybeRelearnFiling`.
- Existing pieces: `AppModel.createMailbox(named:…)` (~6665),
  `createMailboxAndMoveSelection`, `MailboxMutator.moveMany`,
  `SearchIndex.mailboxesFiledInto` (but it returns counts per mailbox, not the
  records — moving needs the records; `SearchHit` has `mailbox` + `offset`, so a
  query returning hits for an address is the likely addition), `peopleFolder()`.
- Writes real mail: **two review agents** before handing over.

### 2. Batch 3 of the MAM4U announcement, when Stephen asks

Starts at **row 42** of section A (the row after Daniel Levy).

    cd ~/ClaudeProjects/MAMforTheMasses/PeopleToEmail && python3 ../tools/mam4u_batch.py <live Eudora mount> PeopleToEmail_2026nov14.txt 42 20 batch03.json

Run it from the device shell with `~/Eudora` granted (mounts as `$HOME/mnt/Eudora`).
Show Stephen `batch03.review.txt`; fix greetings by hand in the JSON (batch 2
needed "Dear Dennis," for `creaturenet.de - mail (Dennis)`). Then: dry run →
he quits Eudora → `--apply` (commands as in nov14-1) → append to `progress.txt`.

### 3. Watch the bounce handling on real mail

Batches 1 and 2 are sent; bounces arrive over days. On the first ones, check:
`grep '\[bounce\]' ~/Library/Logs/Eudora-diagnostics.log` (one line per
recognised report: gone addresses → destination or "In"), and
`~/Library/Application Support/Eudora/FailedAddresses.txt`. The `[bounce]`
lines are unconditional `eudoraDiag` calls, not behind a flag.

### 4. Standing items — unchanged from nov13 (see the archived handoff)

---

## Done this session (2026nov14, second half)

All committed; Stephen built, ran and confirmed; `swift test` passes.

- **`9acc6ee` + `739f510` (Eudora) — bounces.**
  - `EudoraStore/BounceReport.swift`: RFC 3464 reports, strict (root
    `multipart/report`, direct `message/delivery-status` child). `report(in:)`
    gives failures, `Arrival-Date`, the returned original's Message-ID.
    `addressIsGone` rule measured on phaseX's 913 reports (address codes 5.1.1/
    5.1.2/5.1.3/5.1.6/5.1.10/5.2.1/5.4.4 count alone; generic 5.x needs gone
    wording and no spam/policy/relay/sender wording; codes embedded in text
    count). Original-Recipient is the key; `forwardedTo` notes Final-Recipient.
  - `EudoraStore/FailedAddresses.swift`: the list, tab-separated, at
    `~/Library/Application Support/Eudora/FailedAddresses.txt`. Keeps unparsed
    lines verbatim; address-only and day-only lines count; forwarding note
    format lives in `Entry.diagnostic(_:forwardedTo:)` / `Entry.forwardedTo`.
  - `SearchIndex.mailboxesFiledInto(senderOnly:)`, `HoldingRule.senderCounts`.
  - `AppModel` "MARK: bounces": `bounceDecision` during Check Mail. Records only
    what is actually written (batched per account, before the delete pass).
    Files into a PEOPLE mailbox only when every gone address agrees on it, it is
    the top sender-only hit with ≥ half, the address is its strictly most
    frequent non-me sender, the original's Message-ID is in Out or that mailbox,
    `.mbx` ≤ 64 MB, tree unchanged. A failed write falls back to In. Notice says
    "bounce filed in X".
  - Composer: orange line under Bcc per listed recipient, with Forget.
    Context menu: Record Bad Address (rows that look like bounces; lenient for
    flattened Eudora 7 reports; non-gone failures labelled "may still work").
  - Three review rounds. Accepted, known: a write that fails after the `.mbx`
    append can leave a copy in both places; a Find running during one check can
    send a second account's copy to In; Forget is not a tombstone (a re-fetched
    old bounce re-marks the address, with its old date); a bounce HOLDING takes
    is never examined.
- **`4707a47` (MAMforTheMasses) — `tools/mam4u_batch.py`.** Rebuilds a batch
  from the list; reproduced batch 1 identically for 16 of 20 (3 chose another
  early message from the same person — batch 1 had judgement in it). Falls back
  to the best-scoring message, marked BEST AVAILABLE in the review file.
  MAMforTheMasses has **no git identity**: commit with
  `git -c user.name=… -c user.email=…` copied from the Eudora repo's config.
- **Batch 2** (rows 21–41, 20 people) written to Out and sent by Stephen.

Not yet pushed at handoff: Eudora 1 commit (`739f510`) plus this handoff;
MAMforTheMasses 1 commit (`4707a47`).

## Key context added this session

- `reference/` (gitignored) holds this session's review diffs
  (`piece2*.diff`) and `commit-msg.txt`; disposable.
- Device-side copies `~/AppModel.swift.orig`, `.round2`, `~/bcheck.py`,
  `~/check01.json` are in the device shell's `$HOME`, outside the mounts —
  invisible to Stephen, gone with the session.
- **Don't parallelise an edit and a copy of the same file**: committing a file
  to the Mac in the same tool batch as the sed that edited it shipped the old
  version (the first `swift test` crash this session).
- The sandbox has ~430 MB free; read `~/Eudora` in place, don't copy it.

The user will likely ask you to build Make Person Mailbox…, or to prepare
batch 3.
