# Handoff: Eudora — 2026jul23

## Goal
Native macOS Eudora replacement. Today's thread: make the **Who column** show
the *other* party (not Stephen's own name) and mark message **direction**,
driven by a configurable "me" identity set. Read the project `CLAUDE.md` first —
especially: Claude can't compile (Stephen builds, pastes errors), ask questions
in plain prose (no multiple-choice widget), new files in `EudoraApp/Sources/`
need `xcodegen generate`, files in `EudoraMac/` are picked up automatically.

## Completed (committed 824d3d7, builds & runs — Stephen confirmed)
- **Rename** for the sidebar mailbox/folder right-click menu (earlier commit
  `cad613c`): display-name-only edit of `descmap.pce` field 1, id stable.
- **Who column rework**, per-message instead of the old per-mailbox
  `outgoing = (item.type == .outbox)` flag:
  - `EudoraStore/EmailAddress.swift` — bare-address extraction from
    From/To/Cc/Bcc (quoted-comma names, `(comment)` forms).
  - `EudoraStore/MeIdentity.swift` — identity set: exact addresses + whole-domain
    rules (`*@musanim.com`), Codable, `matches()`, plus `MeIdentityHarvest`.
  - `EudoraStore/CorrespondentResolver.swift` — `resolve(from:to:cc:bcc:me:)`
    → `ResolvedWho{name, sortKey, direction}`. **Name rule: first non-me
    scanning From→To→Cc→Bcc**; `+N` overflow only on Stephen's own sends;
    direction = `.fromMe/.toMe/.selfToSelf/.neither`; sortKey = bare name.
  - `MessageDigest` gained `cc`/`bcc`; `MailStore.senderAddresses(at:)`.
  - `MessageRow` gained `whoSort` + `direction`; enrichment calls the resolver;
    Who **sort** keys on `whoSort`. Old `AppModel.correspondent/displayName`
    deleted (resolver is the one source).
  - `MeIdentityStore` (UserDefaults, global key) + `AppModel.me` with
    add/remove/rescan (re-lists open mailbox on change).
  - **Settings → "Me — for the Who column"**: add/remove addresses, "Scan Out
    mailbox" button. Text field uses `.roundedBorder` (was invisible before).
  - Tests: `EmailAddressTests`, `MeIdentityTests`, `CorrespondentResolverTests`
    (all green; logic also Python-modelled against real mail).
- Stephen has populated his me-set in Settings and is happy with it.

## Current state
Feature is live and working. **Direction is computed and stored on every row but
NOT yet drawn.** That glyph is the only remaining piece of this thread. Nothing
is half-edited — the tree is clean at `824d3d7`.

## Next steps
1. **Render the direction glyph (task #19)** in the Who cell —
   `EudoraApp/Sources/ContentView.swift` ~line 2068, the `TableColumn("Who")`
   currently `Text(r.who)`. Stephen's design ("S → name / name → S"): a
   fixed-width **leading** slot (shown for `.fromMe`) and a **trailing**
   right-aligned slot (shown for `.toMe`), both reserving width even when empty
   so names stay column-aligned; `.neither`/`.selfToSelf` show no glyph. The
   glyph graphic is "to be designed" — propose a simple arrow (e.g. leading vs
   trailing `arrow.right`, secondary color), build it, let Stephen react
   visually. `WhoDirection` is in EudoraStore (ContentView already imports it).
2. Optional **in-app "me appears nowhere" scan (task #20)** — Stephen may not
   need it now (the one-off Python scan already surfaced his forgotten
   addresses), so ask before building.

## Key context
- **Design settled with Stephen**: name = first non-me across From→To→Cc→Bcc
  (unifies incoming/outgoing; handles his bulk sends — himself in To, audience
  in Bcc). `+N` = first name + count of other non-me recipients, only on sends.
  Sort on the bare name so "Bob"/"Bob +2" cluster. Domain rule form is
  `*@musanim.com` (he owns the domain). Seed source: **type-in-Settings, no
  hardcoded seed** (repo is public — don't commit his addresses).
- **Rescan-Out** reads the whole Out mailbox synchronously on the main thread —
  fine for now, could stall if Out is ever huge (noted, not a bug).
- **One-off scan artifacts** (from scanning all 238k messages in `phaseX`):
  `/tmp/scan.py` and the ranked lists were shown; the outputs (`me-candidates*`,
  `me-less-addresses-full.txt`) went to the session outputs folder. 11,572 of
  238,337 messages had no me-address; most are real correspondents, and the long
  `stephen.xxxxxx@aol.com` tail is spam spoofing his name.
- **Can't compile in-sandbox**; verify library logic with `swift test` reasoning
  + Python models against `phaseX` (real 12 GB mail, gitignored). Use a
  `general-purpose` review agent before handing non-trivial changes over — it
  caught real issues this thread.
- Task list #16–18 done, **#19 (glyph) is the live task**, #20 optional.

The user will likely ask you to build the Who-column direction glyph (#19).
