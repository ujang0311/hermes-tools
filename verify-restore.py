#!/usr/bin/env python3
"""Verifikasi isi HERMES_HOME hasil restore."""
import sqlite3, sys, os

HOME = sys.argv[1] if len(sys.argv) > 1 else "/home/hermes"
db = os.path.join(HOME, "state.db")
print(f"state.db : {os.path.getsize(db)/1e6:.1f} MB" if os.path.exists(db) else "state.db: TIDAK ADA")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for t in ("sessions", "messages", "cron_jobs", "memories", "skills"):
    try:
        print(f"  {t:10s}: {con.execute('select count(*) from ' + t).fetchone()[0]} baris")
    except Exception:
        pass
# sisa path lama?
hits = 0
for tbl, col in (("sessions", "cwd"), ("messages", "content"), ("system_prompts", "prompt")):
    try:
        hits += con.execute(f"select count(*) from {tbl} where {col} like ?", ("%/root/.hermes%",)).fetchone()[0]
    except Exception:
        pass
print(f"  sisa '/root/.hermes' di DB: {hits} baris")
con.close()
for p in ("config.yaml", "SOUL.md", "cron/jobs.json", "gateway_state.json"):
    fp = os.path.join(HOME, p)
    print(f"  {p:20s}: {'ada' if os.path.exists(fp) else 'TIDAK ADA'}")
print(f"  skills: {len(os.listdir(os.path.join(HOME,'skills'))) if os.path.isdir(os.path.join(HOME,'skills')) else 0} folder")
print(f"  sessions dir: {len(os.listdir(os.path.join(HOME,'sessions'))) if os.path.isdir(os.path.join(HOME,'sessions')) else 0} file")
