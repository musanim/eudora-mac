Project folder: /Users/stephenmalinowski/ClaudeProjects/Eudora

# Handoff: Eudora — 2026nov16 (1)

**Supersedes `Eudora_handoff_2026nov15-1.md`.** What no longer applies from
it: "Next session" item 1 (MAM4U section B — done, and section C too). Its
items 2–5 (Make Person Mailbox limit, bounces, index follow-ups, standing
queue) still stand unchanged, as does the "Carried forward" section of
`handoffs/archive/Eudora_handoff_2026nov14-1.md` it points to.

---

## ▶ START HERE

Follow `/Users/stephenmalinowski/ClaudeProjects/GenericClaudeSessionStartup.md`:

1. Mount `/Users/stephenmalinowski/ClaudeProjects` (pass the path directly)
   and read `claude-conventions.md`. Ask for `~/Eudora` too if mail reading
   is likely; for the quartet mailing below also ask for the Fantasy in F
   project folder (see item 1) — request all together.
2. Read this project's `CLAUDE.md`.
2a. Read `ClaudeProjects/ClaudeManagement/CLAIMS.md` and `LOG.md`. Claim
   before editing anything outside `Eudora/` (MAM4U, formerly MAMforTheMasses; the site
   mirror `~/Documents/Active/HTMirror/musanim`).
3. Read this handoff, then nov15-1's items 2–5.
4. Wait for Stephen.

**One step at a time** — one command, then wait. Nothing actionable after a
command block. No multiple-choice widget; ask in prose. The device shell has
**no Swift**: `eudora-drafts` and `swift test` run on his Mac.

---

## Next session

### 1. Fantasy in F (string quartet version) → string quartets

Stephen's own composition (piano 1979–81; quartet arrangement early 2000s;
never performed). Page: https://www.musanim.com/FantasyInF/ . The **new**
video to send is https://www.youtube.com/watch?v=R3khj_-d5as (an earlier
one, BnvEGQstMy0, went to several quartets in Sep–Oct 2026).

Files, both in `Eudora/reference/` (gitignored — built from private mail):
- `string_quartets_FantasyInF_2026nov15.xlsx` — 49 string quartets he has
  corresponded with: years, message count, whether the quartet version was
  already sent (green rows: Alexander, Del Sol, Eclipse, Friction, Miró,
  Thalea, probably Novello), **"Send score to"** address and **role** of that
  contact. Rule he set: the quartet's own address; else the best member
  (founder / first violin — or violist, he jokes); else management. Roles
  marked `*` are from general knowledge, unverified. Dover, Escher, Omer:
  web form only, no address. Girls Quartet removed (vocal). Notes column
  flags possibly defunct quartets / agencies and bounced addresses.
  (`string_quartets_FantasyInF_2026nov15.tsv` is the superseded first draft.)
- `FantasyInF_quartet_email_draft.txt` — the email, revised with him on
  nov15–16. Stephen said he'd read it the morning of nov16; expect edits.
  Content agreed so far: video is Instrument X (AI-driven virtual
  performer) **heavily edited by Stephen** to match how he hears it — don't
  call it "sampled", don't call it unrelated to the intended interpretation;
  Robin Sutherland (SF Symphony Principal Pianist; Stephen **sent him the
  score**, they never met) letter 1991may15, scan at
  https://www.musanim.com/pdf/RobinSutherland_1991may15.pdf (also in the
  mirror's `pdf/`); Stéphane Delplace's email was **in French** — the
  draft's English quote is our translation; the French original is in a
  footnote below the draft (not part of the email). "brillantissime
  animation" praises the *animation*, not the music's energy.

**Still to do:**
- Build the **ZIP of score and parts.** Parts were last sent as four PDFs
  from `~/Documents/Active/Projects/MalinowskiMusic/FantasyInF/OriginalBarlines/FantasyInFStringQuartet parts/`
  (FantasyInFViolinI/ViolinII/Viola/Violoncello.pdf; score
  FantasyInFStringQuartet.pdf). Confirm with Stephen which files and folder
  are current before zipping; request access to that folder.
- How to send: per-quartet greeting + address from the spreadsheet. Check
  whether `eudora-drafts` supports attachments (not checked); if not,
  Stephen attaches by hand or the tool gets that feature.
- Don't resend to the green rows without asking.

### 2. MAM4U mailing — finished (record)

All three sections of `MAM4U/PeopleToEmail/PeopleToEmail_2026nov14.txt`
were turned into drafts: A (batches 1–14), B (B01–B04: Tapper/Tantrum/
Harmonizer replies lead with a link — MIDI Tapper, TantrumToy, the new
Harmonizer page — after Stephen's reply to Bruno De Florence), C (C01–C02,
plain template), plus Herbert Anton Kellner (Tantrum mailbox, not on the
list). Andort (B row 37) skipped at Stephen's word. `progress.txt` there has
every batch and greeting decision. `mam4u_batch.py` gained `--section B|C`,
per-program fill-ins and leads — committed in the MAM4U repo (formerly MAMforTheMasses)
(`e17a6b8`), claim removed, LOG line added.

Known gap, Stephen not interested now: the list builder skipped
`____ORGANIZATIONS` (e.g. a 2000 Classic Arts Showcase enquiry about the
Bach animations).

### 3. Tantrum / TantrumToy — moved to its own project

TantrumToy doesn't work for Stephen. Provenance and the first diagnosis are
in `ClaudeProjects/Tantrum/handoffs/Tantrum_handoff_2026nov15-1.md`. Not
this project's work.

---

## Key context added this session

- **`grep --include=*.mbx` is case-sensitive**: it skips the 288 old
  uppercase `.MBX` mailboxes (8.3 names, e.g. `PEOPLE.fol/M.FOL/MICHAELD.MBX`).
  Any sweep of the live tree needs `--include=*.mbx --include=*.MBX` (or
  `find -iname`). Found while building the quartet list.
- Sweeps for "people in group X" over-attribute through shared addresses:
  a quartet mailbox cc'ing Christine or Etienne Abelin, or a bounce from
  mailer-daemon, pulls their whole correspondence in. Use only From
  addresses of the group's own mailbox, and drop addresses seen in many
  such mailboxes.
- Out holds only unsent records; Stephen clears sent ones. "Written to Out"
  in progress notes means drafts written there, which he then sends.
- Scratch scripts from this session live in the session's `/tmp` only
  (gone); the method is described above.
