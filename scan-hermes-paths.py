#!/usr/bin/env python3
"""Scan path absolut HERMES_HOME lama di seluruh data Hermes (DB sqlite + file teks)."""
import glob, os, re, sqlite3, sys

HOME = sys.argv[1] if len(sys.argv) > 1 else "/root/.hermes"
NEEDLE = sys.argv[2] if len(sys.argv) > 2 else HOME
print(f"scan: {HOME}\ncari: {NEEDLE}\n")

TEXT_EXT = {".json", ".jsonl", ".yaml", ".yml", ".md", ".txt", ".env", ".toml", ".ini", ".cfg", ".log", ".sh", ".py"}
SKIP_DIR = {"hermes-agent", "node", "models", "runtimes", "checkpoints", "cache", "audio_cache", "image_cache"}

# ── sqlite
dbs = []
for root, dirs, files in os.walk(HOME):
    dirs[:] = [d for d in dirs if d not in SKIP_DIR]
    for f in files:
        if f.endswith((".sqlite", ".db")):
            dbs.append(os.path.join(root, f))
print(f"== database ({len(dbs)}) ==")
for db in dbs:
    hits = []
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        for _t in con.execute("select name from sqlite_master where type='table'"):
            t = _t[0]
            for _row in con.execute(f'pragma table_info("{t}")'):
                c = _row[1]
                try:
                    n = con.execute(f'select count(*) from "{t}" where "{c}" like ?', (f"%{NEEDLE}%",)).fetchone()[0]
                except Exception:
                    continue
                if n:
                    hits.append((t, c, n))
        con.close()
    except Exception as e:
        print(f"  {os.path.relpath(db, HOME)}: ERROR {e}"); continue
    if hits:
        print(f"  {os.path.relpath(db, HOME)}")
        for t, c, n in hits:
            print(f"      {t}.{c}: {n} baris")
    else:
        print(f"  {os.path.relpath(db, HOME)}: bersih")

# ── file teks
print(f"\n== file teks ==")
txt_hits = 0
for root, dirs, files in os.walk(HOME):
    dirs[:] = [d for d in dirs if d not in SKIP_DIR]
    for f in files:
        p = os.path.join(root, f)
        if os.path.splitext(f)[1].lower() not in TEXT_EXT:
            continue
        try:
            if os.path.getsize(p) > 20_000_000:
                continue
            with open(p, "r", errors="ignore") as fh:
                n = fh.read().count(NEEDLE)
        except Exception:
            continue
        if n:
            txt_hits += 1
            if txt_hits <= 25:
                print(f"  {os.path.relpath(p, HOME)}: {n} kemunculan")
if txt_hits > 25:
    print(f"  … dan {txt_hits - 25} file lain")
print(f"total file teks terdampak: {txt_hits}")

# ── symlink absolut
print(f"\n== symlink absolut ==")
n = 0
for root, dirs, files in os.walk(HOME):
    for f in files + dirs:
        p = os.path.join(root, f)
        if os.path.islink(p):
            t = os.readlink(p)
            if t.startswith("/") and NEEDLE in t:
                n += 1
                if n <= 10:
                    print(f"  {os.path.relpath(p, HOME)} -> {t}")
print(f"total symlink absolut: {n}")
