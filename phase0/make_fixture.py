#!/usr/bin/env python3
"""
make_fixture.py — fabricate a synthetic Eudora 7.1 (Windows) mail tree.

Purpose: give the Phase 0 spike something realistic to read WITHOUT touching
decades of real mail. Generator and reader share one on-disk convention, so the
whole read pipeline (hierarchy -> mailbox -> message -> attachments) gets
exercised, including deliberate edge cases.

On-disk convention produced here (Windows Eudora 7.x shape):

  <root>/
    descmap.pce            one per directory: DisplayName,Filename,TypeChar,Unread
    In.mbx / In.toc        modified mbox + binary index
    ...
    Projects/              a mailbox *folder* == subdirectory (has its own descmap)
      descmap.pce
      Baidarka.mbx / .toc
      Music.mbx            (NO .toc on purpose -> exercises scan-rebuild path)

descmap.pce TypeChar (our fixture convention, approximating Eudora; the real
letters must be re-verified against a genuine descmap.pce before we rely on
them for write-back):
    I=In  O=Out  T=Trash  J=Junk  F=Folder  M=regular mailbox

.mbx: RFC-822 messages, CRLF endings, each preceded by a Eudora pseudo-envelope
separator line:  From ???@??? <asctime>\r\n   (verified against pop.cpp:687)

.toc: binary index. 104-byte folder header + N x 218-byte entries, matching the
field sizes reverse-engineered by eudora2unix (win_folder / win_entry). Offsets
and lengths are little-endian and point at the start of each message record (the
'From ???@???' line). These struct layouts are eudora2unix's best guess and are
adequate for a self-consistent fixture; validate against real .toc bytes before
Phase 3 write-back.
"""
import os, struct, shutil, sys, time

CRLF = "\r\n"

# ---- .toc binary layout (little-endian), sizes from eudora2unix win_* ----
FOLDER_FMT = "<2s6s32sHHH8sHHHHHHHH2s30sH"      # = 104 bytes
ENTRY_FMT  = "<II4sBxHBx32s64s64s8s2s4s26s"      # = 218 bytes
FOLDER_SIZE = struct.calcsize(FOLDER_FMT)
ENTRY_SIZE  = struct.calcsize(ENTRY_FMT)
assert FOLDER_SIZE == 104, FOLDER_SIZE
assert ENTRY_SIZE  == 218, ENTRY_SIZE

VERSION = b"\x00\x30"   # 0x3000-ish, Windows Pro-era marker

# status byte (subset, from eudora2unix win_entry notes)
ST_UNREAD, ST_READ, ST_REPLIED, ST_FORWARDED, ST_REDIRECT, ST_SENT = 1, 2, 3, 3, 4, 8
# priority byte: 1=highest .. 4=normal .. 7=lowest (fixture convention)


def sep_line(when_epoch):
    return "From ???@??? " + time.asctime(time.gmtime(when_epoch)) + CRLF


def msg(headers, body, charset="us-ascii"):
    """Build one RFC-822 message (bytes) with CRLF endings.
    `body` may be str (encoded per charset) or bytes (used verbatim)."""
    lines = [f"{k}: {v}" for k, v in headers]
    head = CRLF.join(lines) + CRLF + CRLF
    head_b = head.encode("ascii", "replace")
    body_b = body if isinstance(body, bytes) else body.encode(charset)
    return head_b + body_b


def multipart(headers, boundary, parts):
    """parts: list of (part_headers:list, part_body:bytes)."""
    out = []
    top = [f"{k}: {v}" for k, v in headers if k.lower() != "x-mp"]
    top.append(f'Content-Type: multipart/{headers_ctype(headers)}; boundary="{boundary}"')
    out.append(CRLF.join(top) + CRLF + CRLF)
    out.append("This is a MIME multipart message." + CRLF)
    for ph, pb in parts:
        out.append(CRLF + "--" + boundary + CRLF)
        out.append(CRLF.join(f"{k}: {v}" for k, v in ph) + CRLF + CRLF)
        seg = pb if isinstance(pb, bytes) else pb.encode("utf-8")
        out.append(seg.decode("latin-1"))  # carry bytes through as latin-1
    out.append(CRLF + "--" + boundary + "--" + CRLF)
    return "".join(out).encode("latin-1")


def headers_ctype(headers):
    for k, v in headers:
        if k.lower() == "x-mp":
            return v
    return "mixed"


# ---------------------------------------------------------------- messages ----
def build_messages():
    """Return dict: mailbox filename -> list of (record_bytes, meta) where meta =
    (status, priority, date_str, to_str, subj_str)."""
    boxes = {}
    t0 = 1_040_000_000  # ~2002

    # ---------- In.mbx : the interesting one ----------
    inbox = []

    # 1. plain ascii, read
    m = msg([("From", "Steve Dorner <dorner@example.edu>"),
             ("To", "stephen@example.com"),
             ("Subject", "Welcome to the fixture"),
             ("Date", "Tue, 16 Dec 2002 10:00:00 -0600"),
             ("Content-Type", "text/plain; charset=us-ascii")],
            "Plain ASCII body. Nothing tricky here." + CRLF)
    inbox.append((m, ST_READ, 4, "Tue Dec 16 2002", "stephen@example.com", "Welcome to the fixture"))

    # 2. plain, UNREAD, high priority
    m = msg([("From", "list@kayak.org"),
             ("To", "stephen@example.com"),
             ("Subject", "Baidarka build night"),
             ("Date", "Wed, 17 Dec 2002 09:04:22 -0600"),
             ("Content-Type", "text/plain; charset=us-ascii")],
            "Bring your Greenland paddle." + CRLF)
    inbox.append((m, ST_UNREAD, 1, "Wed Dec 17 2002", "stephen@example.com", "Baidarka build night"))

    # 3. CHARSET TRAP: bytes are UTF-8 but header LIES and says iso-8859-1
    utf8_body = ("Fee: 5€. Café résumé naïve." + CRLF).encode("utf-8")
    m = msg([("From", "euro@example.fr"),
             ("To", "stephen@example.com"),
             ("Subject", "Cafe test (utf8 mislabeled as latin1)"),
             ("Date", "Thu, 18 Dec 2002 12:00:00 +0100"),
             ("Content-Type", "text/plain; charset=iso-8859-1")],  # <-- the lie
            utf8_body)
    inbox.append((m, ST_READ, 4, "Thu Dec 18 2002", "stephen@example.com", "Cafe test (utf8-as-latin1)"))

    # 4. genuine iso-8859-1 bytes, correctly declared
    latin_body = ("Na\xefve caf\xe9 — latin1.".replace("—", "-") + CRLF).encode("iso-8859-1")
    m = msg([("From", "pierre@example.fr"),
             ("To", "stephen@example.com"),
             ("Subject", "Vrai latin-1"),
             ("Date", "Fri, 19 Dec 2002 08:00:00 +0100"),
             ("Content-Type", "text/plain; charset=iso-8859-1")],
            latin_body)
    inbox.append((m, ST_REPLIED, 4, "Fri Dec 19 2002", "stephen@example.com", "Vrai latin-1"))

    # 5. multipart/alternative (text + html)
    body = multipart(
        [("From", "news@example.com"), ("To", "stephen@example.com"),
         ("Subject", "HTML or text"), ("Date", "Sat, 20 Dec 2002 00:00:00 -0600"),
         ("MIME-Version", "1.0"), ("x-mp", "alternative")],
        "BOUNDARY-ALT-1",
        [([("Content-Type", "text/plain; charset=us-ascii")], b"The plain version.\r\n"),
         ([("Content-Type", "text/html; charset=us-ascii")],
          b"<html><body><p>The <b>HTML</b> version.</p></body></html>\r\n")])
    inbox.append((body, ST_READ, 4, "Sat Dec 20 2002", "stephen@example.com", "HTML or text"))

    # 6. multipart/mixed with a text attachment
    body = multipart(
        [("From", "attach@example.com"), ("To", "stephen@example.com"),
         ("Subject", "Here is the file"), ("Date", "Sun, 21 Dec 2002 00:00:00 -0600"),
         ("MIME-Version", "1.0"), ("x-mp", "mixed")],
        "BOUNDARY-MIX-1",
        [([("Content-Type", "text/plain; charset=us-ascii")], b"See attached notes.\r\n"),
         ([("Content-Type", "text/plain; name=\"notes.txt\""),
           ("Content-Disposition", 'attachment; filename="notes.txt"')],
          b"line one of the attachment\r\nline two\r\n")])
    inbox.append((body, ST_READ, 4, "Sun Dec 21 2002", "stephen@example.com", "Here is the file"))

    boxes["In"] = inbox

    # ---------- Out.mbx ----------
    out = []
    m = msg([("From", "stephen@example.com"), ("To", "dorner@example.edu"),
             ("Subject", "Re: Welcome to the fixture"),
             ("Date", "Tue, 16 Dec 2002 10:30:00 -0600"),
             ("Content-Type", "text/plain; charset=us-ascii")],
            "Thanks! Replying from the Out box." + CRLF)
    out.append((m, ST_SENT, 4, "Tue Dec 16 2002", "dorner@example.edu", "Re: Welcome to the fixture"))
    boxes["Out"] = out

    # ---------- Trash / Junk ----------
    boxes["Trash"] = [(msg([("From", "spam@bad.example"), ("To", "stephen@example.com"),
                            ("Subject", "deleted thing"), ("Date", "Mon, 1 Jan 2003 00:00:00 -0600"),
                            ("Content-Type", "text/plain; charset=us-ascii")],
                           "you already trashed me" + CRLF),
                       ST_READ, 4, "Wed Jan 01 2003", "stephen@example.com", "deleted thing")]
    boxes["Junk"] = [(msg([("From", "promo@bad.example"), ("To", "stephen@example.com"),
                           ("Subject", "WIN BIG"), ("Date", "Mon, 1 Jan 2003 00:00:00 -0600"),
                           ("Content-Type", "text/plain; charset=us-ascii")],
                          "definitely junk" + CRLF),
                      ST_UNREAD, 4, "Wed Jan 01 2003", "stephen@example.com", "WIN BIG")]

    # ---------- Projects/ (folder) ----------
    boxes["Projects/Baidarka"] = [
        (msg([("From", "george@example.org"), ("To", "stephen@example.com"),
              ("Subject", "Skin-on-frame plans"), ("Date", "Wed, 5 Feb 2003 00:00:00 -0600"),
              ("Content-Type", "text/plain; charset=us-ascii")],
             "Attached lines for the baidarka." + CRLF),
         ST_READ, 4, "Wed Feb 05 2003", "stephen@example.com", "Skin-on-frame plans")]
    # Music: TWO messages, and we will deliberately NOT write a .toc for it.
    boxes["Projects/Music"] = [
        (msg([("From", "bach@example.org"), ("To", "stephen@example.com"),
              ("Subject", "Fugue in G minor"), ("Date", "Thu, 6 Feb 2003 00:00:00 -0600"),
              ("Content-Type", "text/plain; charset=us-ascii")],
             "The little one, BWV 578." + CRLF),
         ST_READ, 4, "Thu Feb 06 2003", "stephen@example.com", "Fugue in G minor"),
        (msg([("From", "handel@example.org"), ("To", "stephen@example.com"),
              ("Subject", "Water Music"), ("Date", "Fri, 7 Feb 2003 00:00:00 -0600"),
              ("Content-Type", "text/plain; charset=us-ascii")],
             "Suite in F, HWV 348." + CRLF),
         ST_READ, 4, "Fri Feb 07 2003", "stephen@example.com", "Water Music")]

    return boxes, t0


def write_mbx_and_toc(dir_path, base, records, t0, write_toc=True):
    os.makedirs(dir_path, exist_ok=True)
    mbx = bytearray()
    entries = []  # (offset, length, status, priority, date, to, subj)
    for i, (rec, status, prio, date, to, subj) in enumerate(records):
        sep = sep_line(t0 + i * 86400).encode("latin-1")
        offset = len(mbx)
        mbx += sep + rec
        length = len(mbx) - offset
        entries.append((offset, length, status, prio, date, to, subj))
    with open(os.path.join(dir_path, base + ".mbx"), "wb") as f:
        f.write(mbx)
    if not write_toc:
        return
    with open(os.path.join(dir_path, base + ".toc"), "wb") as f:
        f.write(struct.pack(FOLDER_FMT, VERSION, b"", base.encode("ascii", "replace")[:32],
                            3, 0, 0, b"", 20, 60, 24, 0, 200, 120, 40, 0, b"", b"", len(entries)))
        for (offset, length, status, prio, date, to, subj) in entries:
            f.write(struct.pack(ENTRY_FMT,
                                offset, length, b"", status, 0, prio,
                                date.encode("ascii", "replace")[:32],
                                to.encode("ascii", "replace")[:64],
                                subj.encode("ascii", "replace")[:64],
                                b"", b"", b"", b""))


def write_descmap(dir_path, rows):
    """rows: list of (display, filename, typechar, unread)."""
    with open(os.path.join(dir_path, "descmap.pce"), "w", newline="\r\n") as f:
        for r in rows:
            f.write("%s,%s,%s,%s\n" % r)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "sample-tree"
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    boxes, t0 = build_messages()

    # top-level mailboxes
    for base in ("In", "Out", "Junk", "Trash"):
        write_mbx_and_toc(root, base, boxes[base], t0)

    # Projects folder
    proj = os.path.join(root, "Projects")
    write_mbx_and_toc(proj, "Baidarka", boxes["Projects/Baidarka"], t0)
    write_mbx_and_toc(proj, "Music", boxes["Projects/Music"], t0, write_toc=False)  # missing toc!
    write_descmap(proj, [
        ("Baidarka", "Baidarka", "M", "R"),
        ("Music", "Music", "M", "R"),
    ])

    # root descmap: system boxes, then the folder
    write_descmap(root, [
        ("In", "In", "I", "N"),
        ("Out", "Out", "O", "R"),
        ("Junk E-Mail", "Junk", "J", "N"),
        ("Trash", "Trash", "T", "R"),
        ("Projects", "Projects", "F", "R"),
    ])

    # a couple of counts for the console
    total = sum(len(v) for v in boxes.values())
    print("Wrote synthetic Eudora tree to: %s" % os.path.abspath(root))
    print("Mailboxes: %d   Messages: %d" % (len(boxes), total))
    print("Edge cases: charset-lie (In #3), true latin-1 (In #4), "
          "multipart alt (In #5), attachment (In #6), missing .toc (Projects/Music).")


if __name__ == "__main__":
    main()
