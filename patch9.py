import re

RUN_HELPER = '''run_hermes(){ # jalankan CLI dengan HOME/HERMES_HOME & cwd yang benar (NON-login shell:
  # login shell bisa mereset HERMES_HOME dari profil, sehingga CLI jatuh ke install dir)
  local cmd="$1"
  if [ "$OC_USER" = root ]; then
    bash -c "export HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR'; cd '$STATE_DIR' 2>/dev/null || true; $cmd"
  else
    sudo -u "$OC_USER" -H bash -c "export HOME='$OC_HOME' HERMES_HOME='$STATE_DIR'; cd '$STATE_DIR' 2>/dev/null || true; $cmd"
  fi
}
as_hermes(){ run_hermes "$1"; }
'''

# ══ hermes-migrate.sh ═══════════════════════════════════════════════════════
p = "/root/hermes-tools/hermes-migrate.sh"
s = open(p).read()
# ganti as_hermes lama
s = re.sub(r'as_hermes\(\)\{.*?\n\}\n', RUN_HELPER, s, count=1, flags=re.S)

# backup: pakai run_hermes
s = s.replace('''    if hb "membuat arsip zip" bash -c "$( [ "$OC_USER" = root ] && echo "env HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR' bash -lc \\"$CMD\\"" || echo "sudo -u $OC_USER -H env HOME='$OC_HOME' HERMES_HOME='$STATE_DIR' bash -lc \\"$CMD\\"" )"; then''',
'''    if hb "membuat arsip zip" run_hermes "$CMD"; then''', 1)

# import: pakai run_hermes
s = s.replace('''if hb "hermes import (config, skill, sesi, memori)" bash -c "$( [ "$OC_USER" = root ] && echo "env HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR' bash -lc \\"$CMD\\"" || echo "sudo -u $OC_USER -H env HOME='$OC_HOME' HERMES_HOME='$STATE_DIR' bash -lc \\"$CMD\\"" )"; then''',
'''if hb "hermes import (config, skill, sesi, memori)" run_hermes "$CMD"; then''', 1)

# verifikasi hasil import: pastikan data mendarat di HERMES_HOME
s = s.replace('''chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
[ "$COPIED_ARCHIVE" = 1 ] && rm -f "$IMP_ARCHIVE"''',
'''chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
[ "$COPIED_ARCHIVE" = 1 ] && rm -f "$IMP_ARCHIVE"
# pastikan data benar-benar mendarat di HERMES_HOME (bukan install dir)
DB_SIZE=$(stat -c %s "$STATE_DIR/state.db" 2>/dev/null || echo 0)
DB_SRC=$(python3 -c "
import zipfile,sys
try:
    z=zipfile.ZipFile('$ARCHIVE'); print(max((i.file_size for i in z.infolist() if i.filename.endswith('state.db')), default=0))
except Exception: print(0)" 2>/dev/null || echo 0)
if [ "$DB_SRC" -gt 5000000 ] && [ "$DB_SIZE" -lt $((DB_SRC / 4)) ]; then
  warn "state.db di HERMES_HOME (${DB_SIZE}B) jauh lebih kecil dari isi arsip (${DB_SRC}B)"
  hint "kemungkinan import mendarat di install dir — script mencoba memindahkan otomatis"
  for f in state.db shared-state.db kanban.db config.yaml SOUL.md; do
    [ -f "$INSTALL_DIR/$f" ] && [ ! -f "$STATE_DIR/$f" ] && cp -f "$INSTALL_DIR/$f" "$STATE_DIR/" 2>/dev/null
  done
  for d in skills sessions cron plugin-data state platforms memories hooks kanban; do
    [ -d "$INSTALL_DIR/$d" ] && { mkdir -p "$STATE_DIR/$d"; cp -a "$INSTALL_DIR/$d/." "$STATE_DIR/$d/" 2>/dev/null; }
  done
  chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
  NEW_DB=$(stat -c %s "$STATE_DIR/state.db" 2>/dev/null || echo 0)
  [ "$NEW_DB" -gt "$DB_SIZE" ] && ok "data dipindahkan ke HERMES_HOME (state.db ${NEW_DB}B)" || warn "pemindahan otomatis tidak lengkap — cek manual"
fi''', 1)
open(p, "w").write(s)
print("migrate: run_hermes (non-login) + verifikasi lokasi import")

# ══ hermes-upgrade.sh ═══════════════════════════════════════════════════════
p2 = "/root/hermes-tools/hermes-upgrade.sh"
s2 = open(p2).read()
s2 = re.sub(r'as_hermes\(\)\{.*?\n\}\n', RUN_HELPER, s2, count=1, flags=re.S)

# backup
s2 = s2.replace('''  if hb "hermes backup" bash -c "$( [ "$OC_USER" = root ] && echo "env HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR' bash -lc \\"'$HERMES_BIN' backup -o '$ZIP'\\"" || echo "sudo -u $OC_USER -H env HOME='$OC_HOME' HERMES_HOME='$STATE_DIR' bash -lc \\"'$HERMES_BIN' backup -o '$ZIP'\\"" )"; then''',
'''  if hb "hermes backup" run_hermes "'$HERMES_BIN' backup -o '$ZIP'"; then''', 1)

# update
s2 = s2.replace('''  if hb "hermes update (git pull + dependensi)" bash -c "$( [ "$OC_USER" = root ] && echo "env HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR' bash -lc \\"$UPCMD\\"" || echo "sudo -u $OC_USER -H env HOME='$OC_HOME' HERMES_HOME='$STATE_DIR' bash -lc \\"$UPCMD\\"" )"; then''',
'''  if hb "hermes update (git pull + dependensi)" run_hermes "$UPCMD"; then''', 1)
open(p2, "w").write(s2)
print("upgrade: run_hermes (non-login)")
