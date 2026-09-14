#!/usr/bin/env python3
"""
hermes-remap-paths.py — ganti path absolut HERMES_HOME lama → baru setelah restore.

Kenapa perlu: setelah restore ke server dengan lokasi home berbeda
(mis. /root/.hermes → /home/hermes), database & file teks masih menyimpan path lama
(sessions.cwd, isi pesan, system prompt, cron, config, transcript). Akibatnya sesi
tidak menemukan workspace-nya, cron menunjuk path hilang, dan integrasi gagal.

Dipakai otomatis oleh hermes-migrate.sh (restore). Bisa juga manual:

  hermes-remap-paths.py --hermes-home /home/hermes                 # auto-deteksi path lama
  hermes-remap-paths.py --hermes-home /home/hermes --old /root/.hermes
  hermes-remap-paths.py --hermes-home /home/hermes --dry-run
"""
import argparse, glob, os, re, sqlite3, sys
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument("--hermes-home", required=True, help="HERMES_HOME BARU (mis. /home/hermes)")
ap.add_argument("--old", default="", help="path lama (kosong = auto-deteksi)")
ap.add_argument("--dry-run", action="store_true")
ap.add_argument("--quiet", action="store_true")
ap.add_argument("--skip-files", action="store_true", help="hanya database, lewati file teks")
a = ap.parse_args()

NEW = a.hermes_home.rstrip("/")
if not os.path.isdir(NEW):
    sys.exit(f"HERMES_HOME tidak ada: {NEW}")

SKIP_DIR = {"node", "models", "runtimes", "checkpoints", "hermes-agent", "cache"}
TEXT_EXT = {".json", ".jsonl", ".yaml", ".yml", ".md", ".txt", ".env", ".toml", ".ini", ".cfg", ".log", ".sh", ".py"}
FTS_SHADOW = re.compile(r"(_fts|_fts_content|_fts_data|_fts_idx|_fts_docsize|_fts_config|_fts_trigram|_fts_trigram_content|_fts_trigram_data|_fts_trigram_idx|_fts_trigram_docsize|_fts_trigram_config)$")


def walk(root):
    for r, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIR]
        yield r, dirs, files


def dbs():
    out = []
    for r, _, files in walk(NEW):
        for f in files:
            if f.endswith((".sqlite", ".db")):
                out.append(os.path.join(r, f))
    return sorted(out)


# ── 1. tentukan path lama ───────────────────────────────────────────────────
PAT = re.compile(r"((?:/[A-Za-z0-9._-]+)+/?\.hermes)")
OLD = a.old.rstrip("/")
if not OLD:
    c = Counter()
    for db in dbs():
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            for t in [x[0] for x in con.execute("select name from sqlite_master where type='table'")]:
                if FTS_SHADOW.search(t):
                    continue
                cols = [x[1] for x in con.execute(f'pragma table_info("{t}")')]
                for col in cols:
                    try:
                        rows = con.execute(f'select "{col}" from "{t}" where "{col}" like ?', ("%/.hermes%",)).fetchall()
                    except Exception:
                        continue
                    for (v,) in rows:
                        if isinstance(v, str):
                            for m in PAT.findall(v):
                                if m.rstrip("/") != NEW:
                                    c[m.rstrip("/")] += 1
            con.close()
        except Exception:
            pass
    if not c:
        if not a.quiet:
            print("path lama tidak ditemukan di database — tidak ada yang perlu diubah")
        print("REMAP_OK old=none new=%s rows=0 files=0 links=0" % NEW)
        sys.exit(0)
    OLD = c.most_common(1)[0][0]
    if not a.quiet:
        print(f"path lama terdeteksi: {OLD} ({c[OLD]} kemunculan di database)")

if OLD == NEW:
    if not a.quiet:
        print("path lama == baru — tidak ada yang perlu diubah")
    print("REMAP_OK old=same new=%s rows=0 files=0 links=0" % NEW)
    sys.exit(0)

rows_total = 0

# ── 2. database: UPDATE kolom teks biasa, lalu rebuild FTS ─────────────────
for db in dbs():
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True) if a.dry_run else sqlite3.connect(db, timeout=30)
    rel = os.path.relpath(db, NEW)
    try:
        tables = [x[0] for x in con.execute("select name from sqlite_master where type='table'")]
        fts = [t for t in tables if FTS_SHADOW.search(t)]
        for t in tables:
            if FTS_SHADOW.search(t):
                continue
            for col in [x[1] for x in con.execute(f'pragma table_info("{t}")')]:
                try:
                    n = con.execute(f'select count(*) from "{t}" where "{col}" like ?', (f"%{OLD}%",)).fetchone()[0]
                except Exception:
                    continue
                if not n:
                    continue
                if a.dry_run:
                    rows_total += n
                    print(f"  [dry] {rel}: {t}.{col} → {n} baris")
                    continue
                try:
                    con.execute(f'update "{t}" set "{col}" = replace("{col}", ?, ?) where "{col}" like ?', (OLD, NEW, f"%{OLD}%"))
                    con.commit()
                    rows_total += con.total_changes
                    print(f"  {rel}: {t}.{col} → {n} baris")
                except sqlite3.IntegrityError:
                    rm = con.execute(f'delete from "{t}" where "{col}" like ?', (f"%{OLD}%",)).rowcount
                    con.commit()
                    rows_total += rm
                    print(f"  {rel}: {t}.{col} → {rm} baris lama DIHAPUS (bentrok unique)")
        # indeks pencarian: rebuild supaya isi FTS ikut path baru
        if not a.dry_run and fts:
            for t in fts:
                if t.endswith("_content") or t.endswith("_data") or t.endswith("_idx") or t.endswith("_docsize") or t.endswith("_config"):
                    continue
                try:
                    con.execute(f'insert into "{t}"("{t}") values("rebuild")')
                    con.commit()
                    print(f"  {rel}: indeks {t} di-rebuild")
                except Exception as e:
                    print(f"  {rel}: rebuild {t} dilewati ({e})")
    except Exception as e:
        print(f"  {rel}: dilewati ({e})")
    finally:
        con.close()

# ── 3. file teks (config, cron, transcript, skill) ─────────────────────────
files_total = 0
if not a.skip_files:
    for r, _, files in walk(NEW):
        for f in files:
            p = os.path.join(r, f)
            if os.path.splitext(f)[1].lower() not in TEXT_EXT:
                continue
            try:
                if os.path.islink(p) or os.path.getsize(p) > 20_000_000:
                    continue
                with open(p, "r", errors="ignore") as fh:
                    body = fh.read()
            except Exception:
                continue
            if OLD not in body:
                continue
            files_total += 1
            if not a.dry_run:
                st = os.stat(p)
                tmp = p + ".remap-tmp"
                with open(tmp, "w") as fh:
                    fh.write(body.replace(OLD, NEW))
                os.chmod(tmp, st.st_mode & 0o7777)
                os.chown(tmp, st.st_uid, st.st_gid) if os.geteuid() == 0 else None
                os.replace(tmp, p)

# ── 4. symlink absolut → relatif / dibuang ─────────────────────────────────
links_fixed = links_dropped = 0
for r, dirs, files in walk(NEW):
    for f in files + dirs:
        p = os.path.join(r, f)
        if not os.path.islink(p):
            continue
        t = os.readlink(p)
        if not t.startswith("/"):
            continue
        if a.dry_run:
            links_fixed += 1
            continue
        if os.path.exists(t):
            rel = os.path.relpath(t, os.path.dirname(p))
            os.remove(p); os.symlink(rel, p); links_fixed += 1
        else:
            os.remove(p); links_dropped += 1

verb = "akan diubah" if a.dry_run else "diubah"
if not a.quiet:
    print(f"\ntotal: {rows_total} baris DB {verb}, {files_total} file teks {verb}, "
          f"{links_fixed} symlink dibuat relatif, {links_dropped} symlink dibuang")
print(f"REMAP_OK old={OLD} new={NEW} rows={rows_total} files={files_total} links={links_fixed}+{links_dropped}")
