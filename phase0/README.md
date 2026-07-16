# Phase 0 — Eudora format spike

A no-UI, no-dependency proof that we can read a Eudora 7.x (Windows) mail tree
end to end **without migrating it**. This de-risks the interop layer against a
*synthetic* fixture before any real mail (or any app scaffolding) is involved.

Written in Python on purpose: it can be run and verified immediately, and it
serves as the reference implementation to port to Swift in Phase 1. Standard
library only — `python3` (3.8+) is all you need.

## Files

- `make_fixture.py` — fabricates a realistic synthetic Eudora tree.
- `eudora_spike.py` — the reader: `tree`, `list`, `dump`.
- `sample-tree/` — a fixture already generated for you (regenerate any time).

## Run it

```sh
cd phase0
python3 make_fixture.py sample-tree          # (re)generate the fixture

python3 eudora_spike.py sample-tree tree                 # mailbox hierarchy
python3 eudora_spike.py sample-tree list In              # list via .toc
python3 eudora_spike.py sample-tree list Projects/Music  # list via SCAN (no .toc)
python3 eudora_spike.py sample-tree dump In 3            # decode one message
python3 eudora_spike.py sample-tree dump In 6 --save ./out   # + extract attachments
```

## What the fixture deliberately exercises

| Case | Where | Proves |
|------|-------|--------|
| Nested folder hierarchy | `Projects/` | descmap.pce recursion, display vs. filename |
| System mailboxes | In/Out/Junk/Trash | TypeChar handling |
| `.toc` fast path | `In` | binary index parse, offsets, cached metadata |
| Missing `.toc` | `Projects/Music` | scan-rebuild fallback from `From ???@???` records |
| Stale `.toc` | (corrupt one to test) | offset-disagreement detection → scan fallback |
| **UTF-8 mislabeled as iso-8859-1** | `In #3` | the real Eudora charset trap, auto-repaired |
| Genuine iso-8859-1 | `In #4` | correct decode when the label is honest |
| multipart/alternative | `In #5` | text + HTML part walking |
| Attachment | `In #6` | detection + extraction to disk |

## Design stance (carried into Phase 1)

- **`.mbx` is the source of truth; `.toc` is a rebuildable cache.** `list`
  verifies each `.toc` offset actually lands on a record and falls back to
  scanning the `.mbx` when the index is missing or disagrees. This is what makes
  eventual write-back safe rather than scary.
- **Tolerant decoding.** Eudora-for-Windows routinely mislabeled UTF-8 as
  iso-8859-1. `smart_decode()` prefers UTF-8 when the bytes are valid multibyte
  UTF-8 but the header claims a single-byte charset, and reports what it did.

## Honest caveats (things to validate against REAL data later)

1. **`.toc` struct layout** (104-byte header, 218-byte entries) comes from the
   `eudora2unix` reverse-engineering, and the fixture's generator and reader
   share it — so it's self-consistent, not field-validated against a genuine
   `.toc`. Before Phase 3 (write-back), confirm every field against real files.
2. **descmap.pce TypeChar letters** (I/O/T/J/F/M) are our approximation. The
   real letters must be read off a genuine `descmap.pce`.
3. Attachment storage here is inline MIME; real Eudora also keeps loose files in
   a separate attachments directory referenced by the message. Both paths will
   be needed.

None of these block Phase 0's purpose — proving the read pipeline — but they're
the first things to check the day real mail is available.
