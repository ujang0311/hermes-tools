#!/usr/bin/env bash
# ============================================================================
#  ⬢ hermes-upgrade.sh — perbaiki + upgrade Hermes Agent (auto-detect path)
#  Repo: https://github.com/ujang0311/hermes-tools
#  Ambil versi TERBARU (menghindari cache CDN):
#    curl -sS -H 'Accept: application/vnd.github.raw' \
#      'https://api.github.com/repos/ujang0311/hermes-tools/contents/hermes-migrate.sh?ref=main' | bash -s -- detect
#
#  CEK   : curl -sS .../hermes-upgrade.sh | bash -s -- --check
#  PERBAIKI + UPGRADE : curl -sS .../hermes-upgrade.sh | bash
#
#  Khusus VM App Catalog (instalasi editable yang menunjuk folder sementara,
#  mis. /tmp/hermes-agent-clone, sehingga `hermes` error ModuleNotFoundError):
#  script ini meng-clone ulang source ke lokasi PERMANEN lalu pip install -e.
#
#  Opsi: --check · --repair-only · --branch NAME · --no-backup · --no-restart · --dry-run
#  Bash >= 4.2 · butuh root
# ============================================================================
set -u -o pipefail

VERSION_SCRIPT="1.3.0"
SELF_URL="${HERMES_UPGRADE_URL:-https://raw.githubusercontent.com/ujang0311/hermes-tools/main/hermes-upgrade.sh}"
REPO_GIT="${HERMES_REPO_URL:-https://github.com/NousResearch/hermes-agent}"
SERVICES_CANDIDATES=("${HERMES_SERVICE:-hermes-agent}" hermes-gateway hermes-dashboard)
BACKUP_DIR="${HERMES_BACKUP_DIR:-/var/backups/hermes}"
DEFAULT_PORT="${HERMES_GATEWAY_PORT:-18790}"

DRY=0; CHECK=0; REPAIR_ONLY=0; BRANCH=""; DO_BACKUP=1; DO_RESTART=1

# ── UI ──────────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; R=$'\033[0m'; GRN=$'\033[38;5;47m'; YLW=$'\033[38;5;221m'
  RED=$'\033[38;5;203m'; CYN=$'\033[38;5;45m'; PRP=$'\033[38;5;141m'; GRY=$'\033[38;5;245m'; BLD=$'\033[38;5;81m'
else B=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; PRP=""; GRY=""; BLD=""; fi
UIW=68
_slen(){ printf '%s' "$1" | wc -m | tr -d ' '; }
_top(){ printf "  ${PRP}${B}╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_bot(){ printf "  ${PRP}${B}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_bl(){ local plain="$1" colored="${2:-$1}" len pad; colored="${colored#"${colored%%[![:space:]]*}"}"
  len=$(_slen "$plain"); pad=$(( UIW-6-len )); [ "$pad" -lt 0 ] && pad=0
  printf "  ${PRP}${B}│${R}  %s%*s${PRP}${B}│${R}\n" "$colored" "$pad" ""; }
_blc(){ local plain="${1:-}" colored="${2:-}" c="${3:-$PRP}" len pad; colored="${colored#"${colored%%[![:space:]]*}"}"
  len=$(_slen "$plain"); pad=$(( UIW-6-len )); [ "$pad" -lt 0 ] && pad=0
  printf "  ${c}│${R}  %s%*s${c}│${R}\n" "$colored" "$pad" ""; }
_header(){ printf "\n"; printf "  ${2}╭─ ${B}%s${R}${2} %s╮${R}\n" "$1" "$(printf '─%.0s' $(seq 1 $((UIW-8-$(_slen "$1")))))"; }
_foot(){ printf "  ${1}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_clr(){ printf "\r%*s\r" "$UIW" ""; }
_fit(){ local t="$1" max="$2"; if [ "$(_slen "$t")" -gt "$max" ]; then printf '…%s' "$(printf '%s' "$t" | rev | cut -c1-$((max-1)) | rev)"; else printf '%s' "$t"; fi; }
_banner(){ printf "\n"; _top
  _bl "⬢  Hermes Upgrade  v$VERSION_SCRIPT" "  ${PRP}⬢${R}  ${B}Hermes Upgrade${R}  ${GRY}v$VERSION_SCRIPT${R}"
  _bl "self-heal instalasi → cek Python → backup → update → health check" "  ${GRY}self-heal instalasi → cek Python → backup → update → health check${R}"
  _bot; printf "\n"; }
sec(){ printf "  ${CYN}◆${R} ${B}%s${R}${2:+  ${GRY}%s${R}}\n" "$1" "${2:-}"; }
tree(){ printf "    ${GRY}%s${R} %s\n" "$1" "$2"; }
ok(){ printf "    ${GRN}✔${R} %s\n" "$1"; }
warn(){ printf "    ${YLW}▲${R} ${YLW}%s${R}\n" "$1"; }
bad(){ printf "    ${RED}✖${R} ${RED}%s${R}\n" "$1"; }
info(){ printf "    ${GRY}·${R} ${GRY}%s${R}\n" "$1"; }
kv(){ printf "    ${GRY}%-13s${R} %s\n" "$1" "$2"; }
hint(){ printf "      ${GRY}└─ %s${R}\n" "$1"; }
die(){ printf "\n  ${RED}${B}╭─ GAGAL ──────────────────────────────────────────────────────────────╮${R}\n"
       printf "  ${RED}${B}│${R}  ${RED}✖ %s${R}\n" "$1"
       printf "  ${RED}${B}╰──────────────────────────────────────────────────────────────────────╯${R}\n\n"; exit 1; }
hb(){ local label="$1"; shift; local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 t=0 rc=0
  "$@" >/tmp/hermes-upgrade-cmd.log 2>&1 & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf "\r    ${PRP}%s${R} ${GRY}%s…${R} ${BLD}%ss${R}   " "${spin[$((i%10))]}" "$label" "$t"; sleep 1; i=$((i+1)); t=$((t+1)); done
  wait "$pid" || rc=$?; _clr; HB_ELAPSED=$t; return $rc; }
hsize(){ du -sh "$1" 2>/dev/null | cut -f1; }
elapsed(){ printf '%ss' "$SECONDS"; }
svc_state(){ local s; [ -n "${SERVICE:-}" ] || { printf 'n/a'; return; }; s=$(systemctl is-active "$SERVICE" 2>/dev/null); [ -n "$s" ] && printf '%s' "$s" || printf 'n/a'; }
systemctl_scoped(){ [ "${SCOPE:-}" = user ] && systemctl --user "$@" || systemctl "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --repair-only) REPAIR_ONLY=1 ;;
    --branch) shift; BRANCH="${1:-}" ;;
    --branch=*) BRANCH="${1#*=}" ;;
    --no-backup) DO_BACKUP=0 ;;
    --no-restart) DO_RESTART=0 ;;
    --dry-run) DRY=1; CHECK=1 ;;
    -h|--help) _banner; sed -n '3,16p' "$0" 2>/dev/null; exit 0 ;;
    *) die "Opsi tidak dikenal: $1" ;;
  esac
  shift
done

printf "\n"
[ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null && exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $*" || die "Butuh root/sudo"; }
T0=$SECONDS; _banner

# ══════════════════ [1/7] DETEKSI OTOMATIS ══════════════════════════════════
HERMES_BIN=""
command -v hermes >/dev/null 2>&1 && HERMES_BIN=$(command -v hermes)
if [ -z "$HERMES_BIN" ]; then
  for c in /opt/hermes-agent/venv/bin/hermes /usr/local/lib/hermes-agent/venv/bin/hermes "$HOME/.local/bin/hermes" /usr/local/bin/hermes; do
    [ -e "$c" ] && { HERMES_BIN="$c"; break; }
  done
fi
[ -n "$HERMES_BIN" ] || die "CLI hermes tidak ditemukan (install: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash)"
HERMES_BIN=$(readlink -f "$HERMES_BIN")
# ── cari venv & install dir (hermes bisa berupa symlink ATAU script wrapper)
VENV=""
case "$HERMES_BIN" in */venv/bin/hermes) VENV=$(dirname "$(dirname "$HERMES_BIN")") ;; esac
if [ -z "$VENV" ] && [ -f "$HERMES_BIN" ]; then
  P=$(grep -aoE '/[^ "'"'"']*/venv/bin/(python[0-9.]*|hermes)' "$HERMES_BIN" 2>/dev/null | head -1)
  [ -n "$P" ] && VENV=$(dirname "$(dirname "$P")")
fi
if [ -z "$VENV" ]; then
  for d in "${HERMES_INSTALL_DIR:-}" /opt/hermes-agent /usr/local/lib/hermes-agent "$HOME/.local/share/hermes-agent" "$HOME/.hermes/hermes-agent"; do
    [ -n "$d" ] && [ -x "$d/venv/bin/hermes" ] && { VENV="$d/venv"; break; }
  done
fi
if [ -n "$VENV" ]; then VPY="$VENV/bin/python"; VPIP="$VENV/bin/pip"; INSTALL_DIR=$(dirname "$VENV")
else INSTALL_DIR=$(dirname "$HERMES_BIN"); VPY=$(command -v python3); VPIP=$(command -v pip3); fi

SERVICE=""; SCOPE=""; UNIT_ENV=""; GW_PID=""
for cand in "${SERVICES_CANDIDATES[@]}"; do
  if systemctl cat "$cand" >/dev/null 2>&1; then SERVICE="$cand"; SCOPE="system"; break
  elif systemctl --user cat "$cand" >/dev/null 2>&1; then SERVICE="$cand"; SCOPE="user"; break; fi
done
if [ -n "$SERVICE" ]; then
  if [ "$SCOPE" = user ]; then UNIT_ENV=$(systemctl --user show "$SERVICE" -p Environment --value 2>/dev/null || echo "")
  else UNIT_ENV=$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null || echo "")
       OC_USER=$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true); fi
  GW_PID=$( { [ "$SCOPE" = user ] && systemctl --user show "$SERVICE" -p MainPID --value; } 2>/dev/null || true )
  [ -z "$GW_PID" ] && [ "$SCOPE" = system ] && GW_PID=$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)
fi
[ -n "${GW_PID:-}" ] && [ "${GW_PID:-0}" = 0 ] && GW_PID=""
[ -z "${GW_PID:-}" ] && GW_PID=$(pgrep -f "hermes.*(gateway|serve)" 2>/dev/null | head -1 || true)

SRC_STATE=""
if [ -n "${HERMES_HOME:-}" ]; then STATE_DIR="$HERMES_HOME"; SRC_STATE="env HERMES_HOME"
else
  v=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HERMES_HOME=//p' | head -1)
  if [ -n "${v:-}" ]; then STATE_DIR="$v"; SRC_STATE="unit systemd"
  elif [ -n "${GW_PID:-}" ] && [ -r "/proc/$GW_PID/environ" ]; then
    v=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | sed -n 's/^HERMES_HOME=//p' | head -1)
    if [ -n "${v:-}" ]; then STATE_DIR="$v"; SRC_STATE="proses gateway (pid $GW_PID)"
    else v=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)
      [ -n "${v:-}" ] && { STATE_DIR="$v/.hermes"; SRC_STATE="HOME proses gateway (pid $GW_PID)"; }
    fi
  fi
fi
if [ -z "${STATE_DIR:-}" ]; then
  v=$("$HERMES_BIN" config path 2>/dev/null | grep -oE '/[^ ]*config\.yaml' | head -1)
  if [ -n "${v:-}" ]; then STATE_DIR="$(dirname "$v")"; SRC_STATE="CLI (hermes config path)"
  else for c in /home/hermes /root/.hermes /opt/hermes-agent/.hermes /home/*/.hermes; do
         { [ -f "$c/config.yaml" ] || [ -f "$c/state.db" ]; } && { STATE_DIR="$c"; SRC_STATE="pemindaian filesystem"; break; }; done; fi
fi
[ -n "${STATE_DIR:-}" ] || STATE_DIR="/root/.hermes"

SRC_USER="unit systemd"
if [ -z "${OC_USER:-}" ]; then
  if [ -d "$STATE_DIR" ]; then OC_USER=$(stat -c %U "$STATE_DIR"); SRC_USER="owner $STATE_DIR"
  elif id hermes >/dev/null 2>&1; then OC_USER=hermes; SRC_USER="user 'hermes' ada"
  else OC_USER=root; SRC_USER="default"; fi
fi
OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER")
OC_HOME=$(getent passwd "$OC_USER" | cut -d: -f6); [ -n "$OC_HOME" ] && [ "$OC_HOME" != "/" ] || OC_HOME="$STATE_DIR"
UNIT_HOME=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1); [ -n "${UNIT_HOME:-}" ] && OC_HOME="$UNIT_HOME"
PORT=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HERMES_GATEWAY_PORT=//p' | head -1)
[ -n "${PORT:-}" ] || PORT=$(grep -oE 'Gateway Port: *[0-9]+' /etc/idch-app-info 2>/dev/null | grep -oE '[0-9]+' | head -1)
[ -n "${PORT:-}" ] || PORT="$DEFAULT_PORT"
PY_VER=$("$VPY" -V 2>&1 | awk '{print $2}'); [ -n "$PY_VER" ] || PY_VER=$(python3 -V 2>&1 | awk '{print $2}')
RUNMODE=$( [ -n "$SERVICE" ] && echo "systemd ($SCOPE)" || echo "manual" )
fix_ownership(){ # pastikan source repo dimiliki user service & git aman dipakai user itu
  local dir="$1"
  [ -d "$dir/.git" ] || return 0
  local owner; owner=$(stat -c %U "$dir" 2>/dev/null || echo root)
  if [ "$owner" != "$OC_USER" ]; then
    info "ownership repo: $owner → $OC_USER (dubious ownership = git menolak jalan)"
    chown -R "$OC_USER:$OC_GROUP" "$dir" 2>/dev/null || true
  fi
  if [ "$OC_USER" = root ]; then git config --global --add safe.directory "$dir" 2>/dev/null || true
  else sudo -u "$OC_USER" -H git config --global --add safe.directory "$dir" 2>/dev/null || true; fi
  ok "ownership & safe.directory siap: $dir"
}
run_hermes(){ # NON-login shell: login shell bisa mereset HERMES_HOME → CLI jatuh ke install dir
  local cmd="$1"
  if [ "$OC_USER" = root ]; then
    bash -c "export HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR'; cd '$STATE_DIR' 2>/dev/null || true; $cmd"
  else
    sudo -u "$OC_USER" -H bash -c "export HOME='$OC_HOME' HERMES_HOME='$STATE_DIR'; cd '$STATE_DIR' 2>/dev/null || true; $cmd"
  fi
}
as_hermes(){ run_hermes "$1"; }

sec "[1/7] Deteksi otomatis" "$(elapsed)"
tree "├" "hermes home  ${B}$STATE_DIR${R}$( [ -d "$STATE_DIR" ] && echo "  ${GRY}($(hsize "$STATE_DIR"))${R}" || echo "  ${YLW}(belum ada)${R}" )"
tree "│" "${GRY}└ sumber      $SRC_STATE${R}"
tree "├" "owner        ${OC_USER}:${OC_GROUP}  ${GRY}(${SRC_USER})${R}"
tree "├" "install dir  $INSTALL_DIR"
tree "├" "python venv  ${PY_VER}  ${GRY}($VPY)${R}"
tree "└" "service      ${SERVICE:-tidak ada} · port $PORT · ${GRN}$(svc_state)${R}"

# ══════════════════ [2/7] KESEHATAN INSTALASI (editable install) ════════════
printf "\n"; sec "[2/7] Cek instalasi & self-heal" "$(elapsed)"
CUR_VER=$("$HERMES_BIN" --version 2>/dev/null | head -1 || true)
CLI_OK=0; "$HERMES_BIN" --version >/dev/null 2>&1 && CLI_OK=1
EDIT_TARGET=$(find "$VENV/lib" -name "__editable__*_finder.py" 2>/dev/null | head -1)
EDIT_PATH=""
if [ -n "$EDIT_TARGET" ]; then
  EDIT_PATH=$(grep -oE "'[^']*'\]" "$EDIT_TARGET" 2>/dev/null | tr -d "']" | head -1)
  [ -n "$EDIT_PATH" ] || EDIT_PATH=$(grep -oE '"/[^"]+"' "$EDIT_TARGET" 2>/dev/null | tr -d '"' | head -1)
fi
EDIT_DIR=""
[ -n "$EDIT_PATH" ] && EDIT_DIR=$(printf '%s' "$EDIT_PATH" | grep -oE '^/[^:]*' | sed 's#/hermes_cli.*##; s#/hermes-agent.*##')
[ -n "$EDIT_DIR" ] || EDIT_DIR=$(printf '%s' "$EDIT_PATH" | cut -d/ -f1-3)

SRC_DIR=""
if [ -n "$EDIT_DIR" ]; then
  if [ -d "$EDIT_DIR/hermes_cli" ] || [ -f "$EDIT_DIR/pyproject.toml" ]; then SRC_DIR="$EDIT_DIR"; ok "editable install sehat → $SRC_DIR"
  else warn "editable install menunjuk folder yang sudah hilang: $EDIT_DIR"; fi
fi
[ -z "$SRC_DIR" ] && [ -d "$INSTALL_DIR/source/hermes_cli" ] && { SRC_DIR="$INSTALL_DIR/source"; ok "source ditemukan di $SRC_DIR"; }

if [ "$CLI_OK" -eq 1 ]; then ok "CLI berjalan (${CUR_VER:-?})"
else
  bad "CLI TIDAK berjalan (mis. ModuleNotFoundError: No module named 'hermes_cli')"
  NEED_REPAIR=1
fi
NEED_REPAIR=${NEED_REPAIR:-0}
[ -z "$SRC_DIR" ] && NEED_REPAIR=1

if [ "$NEED_REPAIR" -eq 1 ]; then
  warn "instalasi rusak/tidak lengkap → perlu self-heal"
  TARGET_SRC="$INSTALL_DIR/source"
  info "rencana: git clone $REPO_GIT → $TARGET_SRC, lalu pip install -e (lokasi PERMANEN, bukan /tmp)"
  if [ "$CHECK" -eq 1 ]; then
    kv "aksi" "self-heal: clone + pip install -e '$TARGET_SRC'"
  else
    command -v git >/dev/null 2>&1 || die "git tidak terpasang (apt-get install -y git)"
    [ -x "$VPIP" ] || die "pip di venv tidak ada: $VPIP"
    rm -rf "$TARGET_SRC.partial"
    if hb "clone source Hermes" git clone --depth 1 ${BRANCH:+--branch "$BRANCH"} "$REPO_GIT" "$TARGET_SRC.partial"; then
      rm -rf "$TARGET_SRC"; mv "$TARGET_SRC.partial" "$TARGET_SRC"; ok "source: $TARGET_SRC"
      chown -R "$OC_USER:$OC_GROUP" "$TARGET_SRC" 2>/dev/null || true
    else tail -4 /tmp/hermes-upgrade-cmd.log | sed 's/^/      /'; rm -rf "$TARGET_SRC.partial"; die "git clone gagal"; fi
    if hb "pip install -e (perbaiki editable install)" "$VPIP" install -e "$TARGET_SRC"; then
      ok "editable install diperbaiki → $TARGET_SRC ${GRY}(${HB_ELAPSED}s)${R}"
    else tail -8 /tmp/hermes-upgrade-cmd.log | sed 's/^/      /'; die "pip install -e gagal"; fi
    [ -f "$TARGET_SRC/requirements.txt" ] && { hb "pasang requirements" "$VPIP" install -r "$TARGET_SRC/requirements.txt" || warn "sebagian requirements gagal dipasang"; }
    SRC_DIR="$TARGET_SRC"
    if "$HERMES_BIN" --version >/dev/null 2>&1; then ok "CLI sekarang berjalan: $(as_hermes "'$HERMES_BIN' --version 2>/dev/null | head -1" 2>/dev/null || "$HERMES_BIN" --version 2>&1 | head -1)"
    else bad "CLI masih belum berjalan — periksa: $VPY -c 'import hermes_cli'"; fi
  fi
else
  ok "instalasi lengkap — tidak perlu self-heal"
fi
[ "$REPAIR_ONLY" -eq 1 ] && { [ "$CHECK" -eq 1 ] || { DO_RESTART=1; }; }

# ══════════════════ [3/7] PYTHON REQUIREMENT ════════════════════════════════
printf "\n"; sec "[3/7] Cek requirement Python" "$(elapsed)"
REQ_PY=""
[ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/pyproject.toml" ] && REQ_PY=$(sed -n 's/^requires-python *= *"\(.*\)".*/\1/p' "$SRC_DIR/pyproject.toml" | head -1)
[ -z "$REQ_PY" ] && [ -f "$INSTALL_DIR/pyproject.toml" ] && REQ_PY=$(sed -n 's/^requires-python *= *"\(.*\)".*/\1/p' "$INSTALL_DIR/pyproject.toml" | head -1)
kv "butuh" "${REQ_PY:-(tidak dideklarasikan)}"
kv "venv" "python $PY_VER"
PY_OK=1
if [ -n "$REQ_PY" ]; then
  if python3 - "$REQ_PY" "$PY_VER" <<'PY' 2>/dev/null
import re,sys
def norm(v):
    p=[int(x) for x in re.findall(r'\d+', v)[:3]]
    while len(p)<3: p.append(0)
    return tuple(p)
rng, ver = sys.argv[1], sys.argv[2]; v = norm(ver)
for alt in rng.split(','):
    good=True
    for tok in alt.strip().split():
        m=re.match(r'^(>=|<=|>|<|==|!=)?\s*v?([\d.]+)', tok)
        if not m: continue
        op=(m.group(1) or '=='); t=norm(m.group(2))
        if   op=='>=' and v<t: good=False
        elif op=='>'  and v<=t: good=False
        elif op=='<=' and v>t: good=False
        elif op=='<'  and v>=t: good=False
        elif op=='==' and v!=t: good=False
        elif op=='!=' and v==t: good=False
        if not good: break
    if good: sys.exit(0)
sys.exit(1)
PY
  then ok "python $PY_VER memenuhi ${REQ_PY}"
  else PY_OK=0; warn "python $PY_VER TIDAK memenuhi ${REQ_PY}"
       hint "pasang Python yang sesuai lalu buat ulang venv: python3 -m venv $VENV"
  fi
fi

# ══════════════════ [4/7] BACKUP ═══════════════════════════════════════════
printf "\n"; sec "[4/7] Backup sebelum update" "$(elapsed)"
if [ "$DO_BACKUP" -eq 1 ] && [ "$CHECK" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR"; chmod 750 "$BACKUP_DIR" 2>/dev/null || true; chown "$OC_USER:$OC_GROUP" "$BACKUP_DIR" 2>/dev/null || true
  TS=$(date +%Y%m%d-%H%M%S); ZIP="$BACKUP_DIR/hermes-pre-upgrade-$TS.zip"
  if hb "hermes backup" run_hermes "'$HERMES_BIN' backup -o '$ZIP'"; then
    ok "arsip: $(basename "$ZIP") ${GRY}($(hsize "$ZIP") · ${HB_ELAPSED}s)${R}"
  else warn "backup gagal/terlewat — lanjut (lihat /tmp/hermes-upgrade-cmd.log)"; fi
elif [ "$DO_BACKUP" -eq 0 ]; then info "--no-backup: dilewati"
else info "mode cek: dilewati"; fi

# ══════════════════ [5/7] UPDATE ════════════════════════════════════════════
printf "\n"; sec "[5/7] Update Hermes" "$(elapsed)"
PREV_SHA=""
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR/.git" ] && { fix_ownership "$SRC_DIR"; PREV_SHA=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || true); }
AVAIL=$(as_hermes "'$HERMES_BIN' update --check 2>&1 | tail -3" 2>/dev/null || true)
kv "versi kini" "${CUR_VER:-?}"
info "$(printf '%s' "$AVAIL" | tr '\n' ' ' | cut -c1-70)"
if [ "$CHECK" -eq 1 ]; then
  kv "aksi" "hermes update --yes${BRANCH:+ --branch $BRANCH}"
  [ -n "$PREV_SHA" ] && kv "rollback" "git -C '$SRC_DIR' reset --hard $PREV_SHA && $VPIP install -e '$SRC_DIR'"
  printf "\n  ${CYN}${B}◆ %s — tidak ada perubahan.${R}\n\n" "$( [ "$DRY" -eq 1 ] && echo 'DRY-RUN' || echo 'CEK SAJA' )"
  exit 0
fi
if [ "$REPAIR_ONLY" -eq 1 ]; then info "--repair-only: lewati update"; else
  UPCMD="'$HERMES_BIN' update --yes ${BRANCH:+--branch '$BRANCH'} --backup"
  if hb "hermes update (git pull + dependensi)" run_hermes "$UPCMD"; then
    NEW_VER=$("$HERMES_BIN" --version 2>&1 | head -1)
    UPDATE_OK=1
    ok "update selesai ${GRY}(${HB_ELAPSED}s)${R} → ${B}$NEW_VER${R}"
  else
    tail -8 /tmp/hermes-upgrade-cmd.log | sed 's/^/      /'
    UPDATE_OK=0; warn "update gagal — instalasi tetap pada versi lama"
    hint "cek penyebab di log di atas (mis. 'dubious ownership' → script sudah memperbaikinya, ulangi)"
  fi
fi

# ══════════════════ [6/7] RESTART + HEALTH CHECK ════════════════════════════
printf "\n"; sec "[6/7] Jalankan service + health check" "$(elapsed)"
GW_OK=0
if [ "$DO_RESTART" -eq 0 ]; then info "--no-restart: service tidak dijalankan"
elif [ -z "$SERVICE" ]; then
  pkill -f "hermes.*(gateway|serve)" >/dev/null 2>&1 || true
  ( "$HERMES_BIN" gateway run --replace >/tmp/hermes-gateway-manual.log 2>&1 & ) 2>/dev/null || true
  sleep 8
  pgrep -f "hermes.*gateway" >/dev/null 2>&1 && { GW_OK=1; ok "gateway jalan (mode manual)"; } || warn "gateway manual tidak terdeteksi"
else
  systemctl_scoped restart "$SERVICE"
  WMAX="${HERMES_START_TIMEOUT:-180}"; W=0
  while [ "$W" -lt "$WMAX" ]; do
    ST=$(svc_state)
    [ "$ST" = active ] && { GW_OK=1; break; }
    [ "$ST" = failed ] && { bad "service gagal start (status: failed)"; break; }
    printf "\r    ${PRP}⠿${R} ${GRY}menunggu service aktif…${R} ${BLD}%ss${R} ${GRY}(status: %s)${R}   " "$W" "$ST"
    sleep 3; W=$((W+3))
  done
  _clr
  if [ "$GW_OK" -eq 1 ]; then
    ok "service aktif ${GRY}(${W}s)${R}"
    MPID=$(systemctl_scoped show "$SERVICE" -p MainPID --value 2>/dev/null || echo 0)
    [ "${MPID:-0}" != 0 ] && ok "proses gateway hidup (pid $MPID)"
    if ss -tlnH 2>/dev/null | grep -q ":$PORT "; then ok "port :$PORT listening"
    else info "port :$PORT tidak dibuka — normal untuk gateway tanpa platform/HTTP (bukan tanda gagal)"; fi
    ST_OUT=$(run_hermes "'$HERMES_BIN' status 2>&1 | head -6" 2>/dev/null || true)
    [ -n "$ST_OUT" ] && printf '%s\n' "$ST_OUT" | head -4 | sed 's/^/      /'
  else
    warn "service tidak aktif — cek log"
    info "8 baris log terakhir:"; journalctl_scoped -u "$SERVICE" -n 8 --no-pager 2>/dev/null | tail -8 | sed 's/^/      /'
  fi
fi

# ══════════════════ [7/7] ROLLBACK BILA GAGAL ═══════════════════════════════
if [ "$DO_RESTART" -eq 1 ] && [ -n "$SERVICE" ] && [ "$GW_OK" -eq 0 ] && [ -n "$PREV_SHA" ] && [ "$(svc_state)" != active ]; then
  printf "\n"; sec "[7/7] Rollback kode ke $PREV_SHA" "$(elapsed)"
  systemctl_scoped stop "$SERVICE" 2>/dev/null || true
  if hb "kembalikan kode" git -C "$SRC_DIR" reset --hard "$PREV_SHA"; then ok "kode kembali ke $PREV_SHA"; else bad "git reset gagal"; fi
  hb "pasang ulang dependensi" "$VPIP" install -e "$SRC_DIR" || warn "pip install -e gagal"
  systemctl_scoped start "$SERVICE" 2>/dev/null || true
  die "update di-rollback karena gateway tidak sehat (log: journalctl -u $SERVICE -n 50)"
fi

NEW_VER=$("$HERMES_BIN" --version 2>&1 | head -1)
_header "✔ SELESAI" "$GRN"; _blc "" ""
_blc "versi        $NEW_VER" "  ${GRY}versi${R}        ${GRN}${B}$NEW_VER${R}"
_blc "install dir  $(_fit "$INSTALL_DIR" 38)" "  ${GRY}install dir${R}  $(_fit "$INSTALL_DIR" 38)"
_blc "source       $(_fit "${SRC_DIR:-?}" 38)" "  ${GRY}source${R}       $(_fit "${SRC_DIR:-?}" 38)"
_blc "hermes home  $(_fit "$STATE_DIR" 38)" "  ${GRY}hermes home${R}  $(_fit "$STATE_DIR" 38)"
_blc "service      ${SERVICE:-manual} · port $PORT · $(svc_state)" "  ${GRY}service${R}      ${SERVICE:-manual} · port $PORT · $(svc_state)"
[ -n "${ZIP:-}" ] && _blc "backup       $(basename "$ZIP")" "  ${GRY}backup${R}       $(basename "$ZIP")"
[ "${UPDATE_OK:-1}" = 1 ] && _blc "update       berhasil" "  ${GRY}update${R}       ${GRN}berhasil${R}" || _blc "update       gagal (versi tidak berubah)" "  ${GRY}update${R}       ${YLW}gagal — versi tidak berubah${R}"
_blc "durasi       $(elapsed)" "  ${GRY}durasi${R}       $(elapsed)"
_blc "" ""; _foot "$GRN"
printf "\n  ${GRY}Langkah berikutnya:${R}\n"
printf "    ${GRY}1.${R} ${B}$HERMES_BIN status${R}  ${GRY}# cek gateway & platform${R}\n"
printf "    ${GRY}2.${R} ${B}$HERMES_BIN doctor${R}  ${GRY}# pastikan tidak ada catatan${R}\n"
[ -n "$PREV_SHA" ] && printf "    ${GRY}3.${R} rollback: ${B}git -C $SRC_DIR reset --hard $PREV_SHA && $VPIP install -e $SRC_DIR${R}\n"
printf "\n"
exit 0
