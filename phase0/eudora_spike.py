#!/usr/bin/env python3
"""
eudora_spike.py — Phase 0 format spike for the macOS Eudora successor.

Proves we can read a Eudora 7.x (Windows) tree end to end WITHOUT migrating it:
  * reconstruct the mailbox/folder hierarchy from descmap.pce
  * list a mailbox's messages using the binary .toc  (with a scan fallback when
    the .toc is missing or stale)
  * dump one message: headers, tolerant-charset-decoded body, and attachments

This is a reference implementation to be ported to Swift in Phase 1. It has NO
third-party dependencies (standard library only).

Usage:
    python3 eudora_spike.py <root> tree
    python3 eudora_spike.py <root> list  <mailbox>          # e.g. In   or  Projects/Music
    python3 eudora_spike.py <root> dump  <mailbox> <index>  # index is 1-based
    python3 eudora_spike.py <root> dump  <mailbox> <index> --save <dir>

Design stance: the .mbx is the source of truth; the .toc is a rebuildable cache.
So listing verifies each .toc offset actually lands on a 'From ???@???' record,
and falls back to scanning the .mbx if the .toc is absent or disagrees.
"""
import os, sys, struct, email
from email import policy

SEP = b"From ???@??? "          # Eudora pseudo-envelope prefix (verified: pop.cpp)
FOLDER_FMT = "<2s6s32sHHH8sHHHHHHHH2s30sH"     # 104 bytes  (eudora2unix win_folder)
ENTRY_FMT  = "<II4sBxHBx32s64s64s8s2s4s26s"     # 218 bytes  (eudora2unix win_entry)
FOLDER_SIZE = struct.calcsize(FOLDER_FMT)
ENTRY_SIZE  = struct.calcsize(ENTRY_FMT)

TYPE_NAME = {"I": "In", "O": "Out", "T": "Trash", "J": "Junk", "F": "folder", "M": "mailbox"}


# --------------------------------------------------------------- hierarchy ----
def read_descmap(dir_path):
    """Return list of dicts: {display, filename, type, unread} for one directory."""
    path = os.path.join(dir_path, "descmap.pce")
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="latin-1") as f:
        for raw in f:
            line = raw.rstrip("\r\n")
            if not line:
                continue
            parts = line.split(",")
            if len(parts) < 3:
                continue
            display, filename, typ = parts[0], parts[1], parts[2].upper()
            unread = parts[3] if len(parts) > 3 else ""
            rows.append({"display": display, "filename": filename,
                         "type": typ, "unread": unread})
    return rows


def walk_tree(root):
    """Yield (depth, row, abspath, is_folder) in descmap order, recursively."""
    def _walk(dir_path, depth):
        for row in read_descmap(dir_path):
            child = os.path.join(dir_path, row["filename"])
            is_folder = row["type"] == "F"
            yield depth, row, child, is_folder
            if is_folder:
                yield from _walk(child, depth + 1)
    yield from _walk(root, 0)


def count_messages(mbx_path):
    if not os.path.exists(mbx_path):
        return 0
    with open(mbx_path, "rb") as f:
        data = f.read()
    return len(find_records(data))


def cmd_tree(root):
    print(os.path.abspath(root))
    for depth, row, child, is_folder in walk_tree(root):
        indent = "  " * (depth + 1)
        if is_folder:
            print(f"{indent}{row['display']}/    [{TYPE_NAME.get(row['type'], row['type'])}]")
        else:
            n = count_messages(child + ".mbx")
            flag = "  *unread*" if row["unread"].upper().startswith("N") else ""
            kind = TYPE_NAME.get(row["type"], row["type"])
            print(f"{indent}{row['display']}  ({n} msg) [{kind}]{flag}")


# ------------------------------------------------------------ mbx records ----
def find_records(data):
    """Split a .mbx into (offset, length) records by locating separator lines.
    A separator is SEP at start-of-file or immediately after a newline."""
    offs = []
    i = data.find(SEP)
    while i != -1:
        if i == 0 or data[i - 1] in (0x0a, 0x0d):
            offs.append(i)
        i = data.find(SEP, i + 1)
    recs = []
    for k, start in enumerate(offs):
        end = offs[k + 1] if k + 1 < len(offs) else len(data)
        recs.append((start, end - start))
    return recs


def record_to_message(data, offset, length):
    """Slice one record, strip the 'From ???@???' line, parse as RFC-822 bytes."""
    blob = data[offset:offset + length]
    nl = blob.find(b"\n")
    body = blob[nl + 1:] if nl != -1 else blob
    return email.message_from_bytes(body, policy=policy.compat32)


# --------------------------------------------------------------- toc read ----
def read_toc(toc_path):
    """Return list of entry dicts, or None if unreadable."""
    try:
        with open(toc_path, "rb") as f:
            blob = f.read()
    except OSError:
        return None
    if len(blob) < FOLDER_SIZE:
        return None
    entries = []
    pos = FOLDER_SIZE
    while pos + ENTRY_SIZE <= len(blob):
        (offset, length, _gmt, status, switches, prio,
         date, to, subj, _win, _p2, _p3, _pad) = struct.unpack(
            ENTRY_FMT, blob[pos:pos + ENTRY_SIZE])
        entries.append({
            "offset": offset, "length": length, "status": status, "priority": prio,
            "date": cstr(date), "to": cstr(to), "subject": cstr(subj),
        })
        pos += ENTRY_SIZE
    return entries


def cstr(b):
    return b.split(b"\x00", 1)[0].decode("latin-1", "replace")


STATUS = {0: " ", 1: "•", 2: " ", 3: "R", 4: "D", 8: "S"}  # display glyphs


def locate_mailbox(root, name):
    """Accept 'In' or 'Projects/Music' -> return path base (without extension)."""
    base = os.path.join(root, *name.split("/"))
    if os.path.exists(base + ".mbx"):
        return base
    # case-insensitive / display-name fallback via descmap
    for depth, row, child, is_folder in walk_tree(root):
        if not is_folder and (row["display"] == name or row["filename"] == name):
            return child
    return None


def cmd_list(root, name):
    base = locate_mailbox(root, name)
    if not base:
        sys.exit(f"mailbox not found: {name}")
    with open(base + ".mbx", "rb") as f:
        data = f.read()
    recs = find_records(data)
    toc = read_toc(base + ".toc")

    source = "toc"
    if toc is None:
        source = "scan (no .toc)"
    elif len(toc) != len(recs) or any(t["offset"] != r[0] for t, r in zip(toc, recs)):
        source = "scan (.toc stale — offsets disagree)"
        toc = None

    print(f"# {name}   {len(recs)} messages   [index source: {source}]")
    print(f"{'#':>3}  S  Pri  {'Date':<16} {'Size':>7}  {'From/To':<28} Subject")
    for i, (offset, length) in enumerate(recs, 1):
        if toc:
            e = toc[i - 1]
            st = STATUS.get(e["status"], "?")
            pri = e["priority"]
            date = e["date"]
            who = e["to"]
            subj = e["subject"]
        else:
            msg = record_to_message(data, offset, length)
            st, pri = "?", "-"
            date = (msg.get("Date") or "")[:16]
            who = (msg.get("From") or msg.get("To") or "")[:28]
            subj = decode_hdr(msg.get("Subject") or "")
        print(f"{i:>3}  {st}  {str(pri):>3}  {date:<16} {length:>7}  {who[:28]:<28} {subj}")


# -------------------------------------------------------------- dump one ----
def decode_hdr(value):
    from email.header import decode_header
    out = []
    for txt, enc in decode_header(value):
        if isinstance(txt, bytes):
            out.append(txt.decode(enc or "latin-1", "replace"))
        else:
            out.append(txt)
    return "".join(out)


def smart_decode(raw, declared):
    """Tolerant text decode. Eudora-for-Windows often mislabels UTF-8 as
    iso-8859-1/us-ascii, so when the declared charset is one of those but the
    bytes are valid UTF-8 with multibyte sequences, prefer UTF-8.
    Returns (text, charset_used, note)."""
    declared = (declared or "us-ascii").lower()
    looks_utf8 = False
    try:
        u = raw.decode("utf-8")
        looks_utf8 = any(ord(c) > 127 for c in u)
    except UnicodeDecodeError:
        u = None
    if declared in ("us-ascii", "ascii", "iso-8859-1", "latin-1", "windows-1252") and looks_utf8:
        return u, "utf-8", f"declared {declared}, decoded as utf-8 (mislabel repaired)"
    try:
        return raw.decode(declared), declared, ""
    except (UnicodeDecodeError, LookupError):
        return raw.decode("latin-1", "replace"), "latin-1(replace)", f"declared {declared} failed"


def cmd_dump(root, name, index, save_dir=None):
    base = locate_mailbox(root, name)
    if not base:
        sys.exit(f"mailbox not found: {name}")
    with open(base + ".mbx", "rb") as f:
        data = f.read()
    recs = find_records(data)
    if index < 1 or index > len(recs):
        sys.exit(f"index out of range 1..{len(recs)}")
    offset, length = recs[index - 1]
    msg = record_to_message(data, offset, length)

    print(f"===== {name} #{index}  (offset {offset}, {length} bytes) =====")
    for h in ("Date", "From", "To", "Subject"):
        if msg.get(h):
            print(f"{h}: {decode_hdr(msg.get(h))}")
    print("-" * 60)

    attachments = []
    for part in msg.walk():
        if part.get_content_maintype() == "multipart":
            continue
        ctype = part.get_content_type()
        disp = (part.get("Content-Disposition") or "")
        fname = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if fname or "attachment" in disp.lower():
            attachments.append((fname or "(unnamed)", ctype, len(payload), payload))
            continue
        if part.get_content_maintype() == "text":
            text, used, note = smart_decode(payload, part.get_content_charset())
            tag = f"[{ctype}; {used}{'; ' + note if note else ''}]"
            print(tag)
            print(text.rstrip())
            print()

    if attachments:
        print("-" * 60)
        print(f"Attachments: {len(attachments)}")
        for fn, ctype, size, payload in attachments:
            print(f"  - {fn}  ({ctype}, {size} bytes)")
            if save_dir:
                os.makedirs(save_dir, exist_ok=True)
                safe = os.path.basename(fn) if fn != "(unnamed)" else "unnamed.bin"
                with open(os.path.join(save_dir, safe), "wb") as f:
                    f.write(payload)
                print(f"      saved -> {os.path.join(save_dir, safe)}")


# ------------------------------------------------------------------- main ----
def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    root, cmd = argv[1], argv[2]
    if cmd == "tree":
        cmd_tree(root)
    elif cmd == "list" and len(argv) >= 4:
        cmd_list(root, argv[3])
    elif cmd == "dump" and len(argv) >= 5:
        save = None
        if "--save" in argv:
            save = argv[argv.index("--save") + 1]
        cmd_dump(root, argv[3], int(argv[4]), save)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
