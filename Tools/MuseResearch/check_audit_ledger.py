#!/usr/bin/env python3
"""Verify exact pinned candidate bytes and inspect generated assets without execution."""
import csv
import hashlib
import re
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path, PurePosixPath

PIN = "1b894f551e64416e2844452ec6056ec56d6a10f1"
ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / "docs/research/muse-runtime-audit-ledger-2026-10-31.tsv"
PREFIX = "esp32/components/muse/"
FONTS = {"fonts/muse_font_cjk_16.c": ("muse_font_cjk_16", 1),
         "fonts/muse_font_cjk_noto_16.c": ("muse_font_cjk_noto_16", 4)}
TTF = {"eink/fonts/montserrat.ttf": 693, "eink/fonts/unscii.ttf": 192,
       "eink/fonts/symbols.ttf": 62}

def check(condition, message):
    if not condition:
        raise ValueError(message)

def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()

def inspect_generated(data, name, expected_bpp):
    source = data.decode("utf-8")
    check(re.search(r"\blv_font_t\s+" + re.escape(name) + r"\b", source),
          f"{name}: exported font missing")
    for pattern in (r"\bglyph_bitmap\s*\[", r"\bglyph_dsc\s*\[", r"\bcmaps\s*\["):
        check(re.search(pattern, source), f"{name}: table missing: {pattern}")
    bpp = re.findall(r"\.bpp\s*=\s*(\d+)", source)
    check(bpp == [str(expected_bpp)], f"{name}: expected bpp {expected_bpp}, got {bpp}")
    cmap = re.findall(r"\.cmap_num\s*=\s*(\d+)", source)
    check(cmap == [str(130 if expected_bpp == 1 else 42)], f"{name}: cmap descriptor changed: {cmap}")
    print(f"GENERATED {name} bytes={len(data)} sha={blob_sha(data)} bpp={expected_bpp} cmap_num={','.join(cmap)}")
    # Emit only bounded provenance header lines, not glyph bytes or font files.
    for line in source[:2048].splitlines()[:22]:
        if any(word in line.lower() for word in ("font", "license", "copyright", "size", "bpp")):
            print("  metadata:", line[:200])

def inspect_ttf(data, expected_glyphs):
    magic, count = struct.unpack_from(">IH", data)
    check(magic == 0x00010000 and 12 + count * 16 <= len(data), "invalid sfnt directory")
    tables = {}
    for pos in range(12, 12 + count * 16, 16):
        tag, _, offset, size = struct.unpack_from(">4sIII", data, pos)
        check(offset + size <= len(data), f"sfnt table {tag!r} out of bounds")
        tables[tag] = (offset, size)
    check(b"maxp" in tables and tables[b"maxp"][1] >= 6, "missing maxp")
    glyphs = struct.unpack_from(">H", data, tables[b"maxp"][0] + 4)[0]
    check(glyphs == expected_glyphs, f"glyph count {glyphs} != {expected_glyphs}")
    return glyphs, count

def main():
    upstream = Path(sys.argv[1]).resolve()
    revision = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
    check(revision == PIN, "wrong upstream revision")
    with LEDGER.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        check(reader.fieldnames == ["path", "blob_sha", "size_bytes", "provisional_kind", "content_status",
                                    "review_role", "entrypoint", "trust_boundary", "failure_cleanup",
                                    "license_evidence", "test_evidence", "disposition"], "ledger columns changed")
        rows = list(reader)
    check(len(rows) == len({row["path"] for row in rows}) == 322, "candidate count/uniqueness")
    statuses = Counter()
    generated = set()
    assets = set()
    for row in rows:
        check(None not in row and all(row.values()), "missing ledger cell")
        rel = PurePosixPath(row["path"])
        check(not rel.is_absolute() and ".." not in rel.parts, "unsafe path")
        path = upstream / rel
        check(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(upstream),
              f"not a regular pinned file: {rel}")
        data = path.read_bytes()
        check(len(data) == int(row["size_bytes"]) and blob_sha(data) == row["blob_sha"],
              f"byte identity mismatch: {rel}")
        status = row["content_status"]
        check(status == "content-reviewed-this-pass", f"unreconciled candidate: {rel}")
        check(row["provisional_kind"] in {"executable-source", "header", "build-config",
                                         "binary-asset", "documentation", "static-glyph-data",
                                         "generated-font-source"}, f"unreconciled kind: {rel}")
        statuses[status] += 1
        local = row["path"].removeprefix(PREFIX)
        if local in FONTS:
            inspect_generated(data, *FONTS[local])
            generated.add(local)
        elif local in TTF:
            glyphs, count = inspect_ttf(data, TTF[local])
            print(f"ASSET {local} bytes={len(data)} glyphs={glyphs} tables={count}")
            assets.add(local)
        elif local == "test_reply.mp3":
            check(data[:5] == b"ID3\x04\x00" and data[45:49] == bytes.fromhex("fff384c0"),
                  "MP3 metadata changed")
            print(f"ASSET {local} bytes={len(data)} ID3v2.4 MPEG-header-offset=45")
            assets.add(local)
    check(generated == set(FONTS) and assets == {*TTF, "test_reply.mp3"}, "missing asset evidence")
    print("LEDGER PASS: 322 exact blob bytes, unique paths, full fields;", dict(statuses))
    print("Metadata only: no font/audio redistribution, rendering, firmware or physical capability verified.")

if __name__ == "__main__":
    main()
