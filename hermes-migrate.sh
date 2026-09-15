#!/usr/bin/env bash
# ============================================================================
#  ⬢ hermes-migrate.sh — backup & restore/migrasi Hermes Agent antar server
#  Repo: https://github.com/ujang0311/hermes-tools
#  Ambil versi TERBARU (menghindari cache CDN):
#    curl -sS -H 'Accept: application/vnd.github.raw' \
#      'https://api.github.com/repos/ujang0311/hermes-tools/contents/hermes-migrate.sh?ref=main' | bash -s -- detect
#
#  Semua path (HERMES_HOME, user, install dir, service, port) DETEKSI OTOMATIS.
#
#  DETEKSI : curl -sS .../hermes-migrate.sh | bash -s -- detect
#  BACKUP  : curl -sS .../hermes-migrate.sh | bash -s -- backup
#  RESTORE : curl -sS .../hermes-migrate.sh | bash -s -- restore --archive <zip> --safe-channels
#
#  Butuh: python3 (verifikasi zip otomatis pakai unzip bila ada)
#  Opsi: --dry-run · --safe-channels · --no-start · --skip-verify · --no-transfer
#  Bash >= 4.2
# ============================================================================
set -u -o pipefail

VERSION_SCRIPT="1.4.1"
SELF_URL="${HERMES_MIGRATE_URL:-https://raw.githubusercontent.com/ujang0311/hermes-tools/main/hermes-migrate.sh}"
REPO_RAW="${HERMES_TOOLS_RAW:-https://raw.githubusercontent.com/ujang0311/hermes-tools/main}"
SERVICES_CANDIDATES=("${HERMES_SERVICE:-hermes-agent}" hermes-gateway hermes-dashboard)
BACKUP_DIR_DEFAULT="${HERMES_BACKUP_DIR:-/root/hermes-backups}"
DEFAULT_PORT="${HERMES_GATEWAY_PORT:-18790}"

ACTION="${1:-}"; [ $# -gt 0 ] && shift || true
DRY_RUN=0; STATE_DIR="" ; OC_USER=""; TRANSFER=""; ARCHIVE=""; SAFE_CH=0; NO_START=0; SKIP_VERIFY=0

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
  _bl "⬢  Hermes Migrate  v$VERSION_SCRIPT" "  ${PRP}⬢${R}  ${B}Hermes Migrate${R}  ${GRY}v$VERSION_SCRIPT${R}"
  _bl "backup · restore · migrasi antar server (auto-detect)" "  ${GRY}backup · restore · migrasi antar server (auto-detect)${R}"
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
  "$@" >/tmp/hermes-migrate-cmd.log 2>&1 & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf "\r    ${PRP}%s${R} ${GRY}%s…${R} ${BLD}%ss${R}   " "${spin[$((i%10))]}" "$label" "$t"; sleep 1; i=$((i+1)); t=$((t+1)); done
  wait "$pid" || rc=$?; _clr; HB_ELAPSED=$t; return $rc; }
zip_check(){ # $1 = file zip → 0 kalau valid (pakai unzip, fallback python)
  local f="$1"
  if command -v unzip >/dev/null 2>&1; then unzip -tq "$f"
  else
    python3 - "$f" <<'PY'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        bad = z.testzip(); n = len(z.infolist())
    print(f"zip valid ({n} entri)")
    sys.exit(0 if bad is None else 1)
except Exception as e:
    print(f"zip bermasalah: {e}"); sys.exit(1)
PY
  fi
}
zip_entries(){ if command -v unzip >/dev/null 2>&1; then unzip -l "$1" 2>/dev/null | tail -1 | awk '{print $2}'
  else python3 -c "import zipfile,sys;print(len(zipfile.ZipFile(sys.argv[1]).infolist()))" "$1" 2>/dev/null || echo "?"; fi; }
hsize(){ du -sh "$1" 2>/dev/null | cut -f1; }
elapsed(){ printf '%ss' "$SECONDS"; }
svc_state(){ local s; [ -n "${SERVICE:-}" ] || { printf 'n/a'; return; }; s=$(systemctl is-active "$SERVICE" 2>/dev/null); [ -n "$s" ] && printf '%s' "$s" || printf 'n/a'; }

usage(){ _banner; cat <<EOF
  ${B}Deteksi otomatis${R}: HERMES_HOME, user, install dir, service, port — dibaca dari
  unit systemd, env proses, CLI Hermes, lalu pemindaian filesystem.

  ${B}BACKUP${R}   (server sumber)
    hermes-migrate.sh backup [--output DIR] [--transfer user@host:/dir]

  ${B}RESTORE${R}  (server target)
    hermes-migrate.sh restore --archive FILE [opsi]
      --safe-channels   matikan platform (telegram/discord/whatsapp/slack) setelah restore
      --no-start        jangan nyalakan gateway (uji aman)
      --skip-verify     lanjut walau verifikasi zip gagal
      --no-transfer     (backup) cukup buat arsip, jangan kirim

  ${B}DETEKSI${R}  hermes-migrate.sh detect

  Umum: --dry-run · --help
EOF
  printf "\n"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --output) shift; BACKUP_DIR_DEFAULT="${1:-}" ;;
    --output=*) BACKUP_DIR_DEFAULT="${1#*=}" ;;
    --transfer) shift; TRANSFER="${1:-}" ;;
    --transfer=*) TRANSFER="${1#*=}" ;;
    --archive) shift; ARCHIVE="${1:-}" ;;
    --archive=*) ARCHIVE="${1#*=}" ;;
    --state-dir|--hermes-home) shift; STATE_DIR="${1:-}" ;;
    --state-dir=*|--hermes-home=*) STATE_DIR="${1#*=}" ;;
    --user) shift; OC_USER="${1:-}" ;;
    --user=*) OC_USER="${1#*=}" ;;
    --safe-channels) SAFE_CH=1 ;;
    --no-start) NO_START=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --no-transfer) NO_TRANSFER=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $1 (pakai --help)" ;;
  esac
  shift
done
NO_TRANSFER="${NO_TRANSFER:-0}"

case "$ACTION" in backup|restore|detect) ;; ""|-h|--help) usage; exit 0 ;;
  *) die "Aksi tidak dikenal: '$ACTION' (pakai: backup | restore | detect)";; esac

if [ "$ACTION" != detect ] && [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Butuh root (atau sudo)."
  exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $ACTION $(printf '%q ' "$@")"
fi
T0=$SECONDS

# ══════════════════ DETEKSI OTOMATIS ════════════════════════════════════════
detect() {
  # ── install dir + binary hermes
  HERMES_BIN=""
  if command -v hermes >/dev/null 2>&1; then HERMES_BIN=$(command -v hermes); fi
  SRC_BIN="PATH"
  if [ -z "$HERMES_BIN" ]; then
    for c in /opt/hermes-agent/venv/bin/hermes /usr/local/lib/hermes-agent/venv/bin/hermes "$HOME/.local/bin/hermes" /usr/local/bin/hermes; do
      [ -x "$c" ] && { HERMES_BIN="$c"; SRC_BIN="pemindaian lokasi umum"; break; }
    done
  fi
  [ -n "$HERMES_BIN" ] || die "CLI hermes tidak ditemukan di server ini (install: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash)"
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
  if HERMES_VER=$("$HERMES_BIN" --version 2>/dev/null | head -1) && [ -n "$HERMES_VER" ]; then :; else HERMES_VER=""; fi
  PY_VER=$("$VPY" -V 2>&1 | awk '{print $2}')
  [ -n "$PY_VER" ] || PY_VER=$(python3 -V 2>&1 | awk '{print $2}')

  # ── service + port + user dari unit systemd
SERVICE=""; SCOPE=""; UNIT_ENV=""; GW_PID=""
# pilih unit yang AKTIF lebih dulu (system → user), baru yang sekadar ada
for phase in active any; do
  for sc in system user; do
    for cand in "${SERVICES_CANDIDATES[@]}"; do
      if [ "$sc" = system ]; then systemctl cat "$cand" >/dev/null 2>&1 || continue
      else systemctl --user cat "$cand" >/dev/null 2>&1 || continue; fi
      if [ "$phase" = active ]; then
        if [ "$sc" = system ]; then st=$(systemctl is-active "$cand" 2>/dev/null)
        else st=$(systemctl --user is-active "$cand" 2>/dev/null); fi
        [ "$st" = active ] || continue
      fi
      SERVICE="$cand"; SCOPE="$sc"; break 2
    done
  done
  [ -n "$SERVICE" ] && break
done
if [ -n "$SERVICE" ]; then
  if [ "$SCOPE" = user ]; then
    UNIT_ENV=$(systemctl --user show "$SERVICE" -p Environment --value 2>/dev/null || echo "")
    GW_PID=$(systemctl --user show "$SERVICE" -p MainPID --value 2>/dev/null || true)
  else
    UNIT_ENV=$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null || echo "")
    OC_USER=$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)
    GW_PID=$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)
  fi
fi
[ -n "${GW_PID:-}" ] && [ "${GW_PID:-0}" = 0 ] && GW_PID=""
[ -z "${GW_PID:-}" ] && GW_PID=$(pgrep -f "hermes.*(gateway|serve)" 2>/dev/null | head -1 || true)
SRC_SVC="tidak ada unit systemd"
[ -n "$SERVICE" ] && SRC_SVC="unit $SCOPE"
  # ── HERMES_HOME: override → env → unit → env proses → CLI → pemindaian
  SRC_STATE=""
  if [ -n "$STATE_DIR" ]; then SRC_STATE="override (--hermes-home)"
  elif [ -n "${HERMES_HOME:-}" ]; then STATE_DIR="$HERMES_HOME"; SRC_STATE="env HERMES_HOME"
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
    else
      for c in /home/hermes /root/.hermes /opt/hermes-agent/.hermes /opt/hermes/.hermes /home/*/.hermes; do
        { [ -f "$c/config.yaml" ] || [ -f "$c/state.db" ]; } && { STATE_DIR="$c"; SRC_STATE="pemindaian filesystem"; break; }
      done
    fi
  fi
  [ -n "${STATE_DIR:-}" ] || STATE_DIR="/root/.hermes"

  # ── user: unit → owner HERMES_HOME → user hermes → root
  SRC_USER="$SRC_SVC"
  if [ -z "${OC_USER:-}" ]; then
    if [ -d "$STATE_DIR" ]; then OC_USER=$(stat -c %U "$STATE_DIR"); SRC_USER="owner $STATE_DIR"
    elif id hermes >/dev/null 2>&1; then OC_USER=hermes; SRC_USER="user 'hermes' ada"
    else OC_USER=root; SRC_USER="default"; fi
  fi
  OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER")
  OC_HOME=$(getent passwd "$OC_USER" | cut -d: -f6); [ -n "$OC_HOME" ] && [ "$OC_HOME" != "/" ] || OC_HOME="$STATE_DIR"
  UNIT_HOME=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1)
  [ -n "${UNIT_HOME:-}" ] && OC_HOME="$UNIT_HOME"

  # ── port
  PORT=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HERMES_GATEWAY_PORT=//p' | head -1)
  [ -n "${PORT:-}" ] || PORT=$(grep -oE 'Gateway Port: *[0-9]+' /etc/idch-app-info 2>/dev/null | grep -oE '[0-9]+' | head -1)
  [ -n "${PORT:-}" ] || PORT=$(sed -n 's/^GATEWAY_PORT=\([0-9]*\).*/\1/p' /etc/hermes-agent/hermes-agent.env 2>/dev/null | head -1)
  [ -n "${PORT:-}" ] || PORT="$DEFAULT_PORT"

  RUNMODE=$( [ -n "$SERVICE" ] && echo "$SCOPE" || echo "manual" )
}
run_hermes(){ # jalankan CLI dengan HOME/HERMES_HOME & cwd yang benar (NON-login shell:
  # login shell bisa mereset HERMES_HOME dari profil, sehingga CLI jatuh ke install dir)
  local cmd="$1"
  if [ "$OC_USER" = root ]; then
    bash -c "export HOME='$STATE_DIR' HERMES_HOME='$STATE_DIR'; cd '$STATE_DIR' 2>/dev/null || true; $cmd"
  else
    sudo -u "$OC_USER" -H bash -c "export HOME='$OC_HOME' HERMES_HOME='$STATE_DIR'; cd '$STATE_DIR' 2>/dev/null || true; $cmd"
  fi
}
as_hermes(){ run_hermes "$1"; }
show_detect(){
  sec "Deteksi otomatis" "$(elapsed)"
  tree "├" "hermes home  ${B}$STATE_DIR${R}$( [ -d "$STATE_DIR" ] && echo "  ${GRY}($(hsize "$STATE_DIR"))${R}" || echo "  ${YLW}(belum ada)${R}" )"
  tree "│" "${GRY}└ sumber      $SRC_STATE${R}"
  tree "├" "owner        ${OC_USER}:${OC_GROUP}  ${GRY}(${SRC_USER})${R}"
  if [ -n "$HERMES_VER" ]; then tree "├" "versi        ${HERMES_VER}"
  else tree "├" "versi        ${YLW}CLI rusak/tidak lengkap — perlu self-heal${R}${GRY} (hermes-upgrade.sh)${R}"; fi
  tree "├" "install dir  $INSTALL_DIR  ${GRY}(python $PY_VER)${R}"
  tree "├" "service      ${SERVICE:-tidak ada}  ${GRY}(${SRC_SVC}) · port $PORT · ${GRN}$(svc_state)${R}"
  tree "└" "cli          ${GRY}$HERMES_BIN${R}"
}

detect
_banner
[ "$ACTION" = detect ] && { show_detect; printf "\n  ${GRY}Tidak ada perubahan (mode deteksi).${R}\n\n"; exit 0; }
show_detect

# ══════════════════════════════ BACKUP ═════════════════════════════════════
if [ "$ACTION" = backup ]; then
  [ -d "$STATE_DIR" ] || die "HERMES_HOME tidak ditemukan: $STATE_DIR"
  printf "\n"
  sec "[1/3] Membuat arsip" "$(elapsed)"
  kv "output" "$BACKUP_DIR_DEFAULT"
  mkdir -p "$BACKUP_DIR_DEFAULT"; chmod 700 "$BACKUP_DIR_DEFAULT" 2>/dev/null || true
  chown "$OC_USER:$OC_GROUP" "$BACKUP_DIR_DEFAULT" 2>/dev/null || true
  TS=$(date +%Y%m%d-%H%M%S); ZIP="$BACKUP_DIR_DEFAULT/hermes-$TS.zip"
  # staging: user service (mis. `hermes`) tidak bisa menulis ke /root (mode 700)
  STAGING=$(mktemp -d /tmp/hermes-backup-XXXXXX); chown "$OC_USER:$OC_GROUP" "$STAGING" 2>/dev/null || true
  ZIP_STAGE="$STAGING/hermes-$TS.zip"
  info "staging: $STAGING  →  tujuan: $BACKUP_DIR_DEFAULT"
  CMD="'$HERMES_BIN' backup -o '$ZIP_STAGE'"
  if [ "$DRY_RUN" -eq 1 ]; then info "dry-run: $CMD"
  else
    if hb "membuat arsip zip" run_hermes "$CMD"; then
      if mv -f "$ZIP_STAGE" "$ZIP" 2>/dev/null; then
        chown root:root "$ZIP" 2>/dev/null || true; chmod 600 "$ZIP" 2>/dev/null || true
        ok "arsip dipindahkan ke $BACKUP_DIR_DEFAULT"
      else
        ZIP="$ZIP_STAGE"; warn "gagal memindahkan ke $BACKUP_DIR_DEFAULT — arsip tetap di $ZIP"
      fi
      rm -rf "$STAGING" 2>/dev/null || true
      ok "arsip jadi ${GRN}${B}$(basename "$ZIP")${R}  ${GRY}($(hsize "$ZIP") · ${HB_ELAPSED}s)${R}"
      if hb "verifikasi isi zip" zip_check "$ZIP"; then ok "verifikasi zip OK"; else warn "verifikasi zip menemukan masalah"; fi
      grep -iE "restore with|excluded" /tmp/hermes-migrate-cmd.log 2>/dev/null | head -2 | sed 's/^/      /'
    else
      rm -rf "$STAGING" 2>/dev/null || true
      tail -5 /tmp/hermes-migrate-cmd.log | sed 's/^/      /'
      printf "\n"
      _header "✖ BACKUP GAGAL" "$RED"
      _blc "sebab        lihat pesan error di atas" "  ${GRY}sebab${R}        ${YLW}lihat pesan error di atas${R}"
      _blc "saran        --output ke folder yang bisa ditulis user $OC_USER" "  ${GRY}saran${R}        ${YLW}--output ke folder yang bisa ditulis user $OC_USER${R}"
      _blc "             (atau perbaiki instalasi: hermes-upgrade.sh)" "  ${GRY}${R}        ${GRY}(atau perbaiki instalasi: hermes-upgrade.sh)${R}"
      _blc "" ""; _foot "$RED"; printf "\n"
      exit 1
    fi
  fi

  printf "\n"; sec "[2/3] Transfer" "$(elapsed)"
  if [ -n "$TRANSFER" ] && [ "$NO_TRANSFER" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then info "dry-run: scp $(basename "${ZIP:-arsip}") → $TRANSFER"
    else hb "mengirim arsip ke $TRANSFER" scp -o StrictHostKeyChecking=accept-new "${ZIP:-/dev/null}" "$TRANSFER"/ && ok "terkirim (${HB_ELAPSED}s)" || warn "scp gagal"; fi
  else
    info "opsional — kirim manual atau pakai --transfer user@host:/dir"
    hint "scp ${ZIP:-<arsip>} user@host:/root/"
  fi

  printf "\n"; sec "[3/3] Ringkasan" "$(elapsed)"
  _header "✔ BACKUP SELESAI" "$GRN"; _blc "" ""
  _blc "arsip        $( [ -n "${ZIP:-}" ] && basename "$ZIP" || echo 'belum dibuat (dry-run)')" "  ${GRY}arsip${R}        $( [ -n "${ZIP:-}" ] && basename "$ZIP" || echo "${GRY}belum dibuat (dry-run)${R}")"
  _blc "ukuran       $( [ -f "${ZIP:-}" ] && hsize "$ZIP" || echo -)" "  ${GRY}ukuran${R}       $( [ -f "${ZIP:-}" ] && hsize "$ZIP" || echo -)"
  _blc "hermes home  $(_fit "$STATE_DIR" 38) ($(hsize "$STATE_DIR"))" "  ${GRY}hermes home${R}  $(_fit "$STATE_DIR" 38) ${GRY}($(hsize "$STATE_DIR"))${R}"
  _blc "versi        $HERMES_VER" "  ${GRY}versi${R}        $HERMES_VER"
  _blc "durasi       $(elapsed)" "  ${GRY}durasi${R}       $(elapsed)"
  _blc "" ""; _foot "$GRN"
  printf "\n  ${GRY}Langkah berikutnya:${R} restore di server target\\n"
  printf "    ${GRY}${B}hermes-migrate.sh restore --archive <arsip.zip> --safe-channels${R}\\n\\n"
  exit 0
fi

# ══════════════════════════════ RESTORE ════════════════════════════════════
[ -n "$ARCHIVE" ] || die "Wajib: --archive <file.zip>"
[ -f "$ARCHIVE" ] || die "Arsip tidak ditemukan: $ARCHIVE"
TS=$(date +%Y%m%d-%H%M%S); PRE="/var/backups/hermes/pre-restore-$TS.tar.gz"; mkdir -p "$(dirname "$PRE")"
printf "\n"
sec "[1/7] Verifikasi arsip" "$(elapsed)"
kv "arsip" "$(basename "$ARCHIVE") ($(hsize "$ARCHIVE"))"
if hb "memeriksa isi zip" zip_check "$ARCHIVE"; then ok "zip valid ${GRY}(${HB_ELAPSED}s · $(zip_entries "$ARCHIVE") entri)${R}"
else
  if [ "$SKIP_VERIFY" -eq 1 ]; then warn "verifikasi gagal — --skip-verify aktif, lanjut"
  else tail -3 /tmp/hermes-migrate-cmd.log | sed 's/^/      /'; die "arsip TIDAK valid — restore dibatalkan (atau pakai --skip-verify)"; fi
fi
# CLI hermes harus bisa jalan (kalau tidak, import tidak mungkin)
if ! "$HERMES_BIN" --version >/dev/null 2>&1; then
  bad "CLI hermes di server ini rusak/tidak lengkap: $HERMES_BIN"
  hint "perbaiki dulu: curl -sS $REPO_RAW/hermes-upgrade.sh | bash"
  die "instalasi Hermes belum sehat — restore dibatalkan"
fi
kv "versi lokal" "$HERMES_VER"

printf "\n"; sec "[2/7] Rencana" "$(elapsed)"
kv "hermes home" "$STATE_DIR$( [ -d "$STATE_DIR" ] && echo " ($(hsize "$STATE_DIR"))" || echo ' (kosong)')"
kv "user" "$OC_USER:$OC_GROUP"
kv "gateway" "${SERVICE:-manual} · port $PORT · $(svc_state)"
if [ "$DRY_RUN" -eq 1 ]; then
  kv "akan" "stop service → rollback point → hermes import → remap path → chown → start"
  [ "$SAFE_CH" -eq 1 ] && kv "tambahan" "matikan platform telegram/discord/whatsapp/slack"
  printf "\n  ${CYN}${B}◆ DRY-RUN — tidak ada perubahan.${R}\n\n"; exit 0
fi

printf "\n"; sec "[3/7] Hentikan service" "$(elapsed)"
if [ -n "$SERVICE" ]; then hb "stop $SERVICE" systemctl ${SCOPE:+$([ "$SCOPE" = user ] && echo --user)} stop "$SERVICE" 2>/dev/null || true; ok "service dihentikan"
else pkill -f "hermes.*(gateway|serve)" 2>/dev/null || true; ok "proses gateway dihentikan"; fi

printf "\n"; sec "[4/7] Rollback point" "$(elapsed)"
if [ -d "$STATE_DIR" ]; then
  if hb "mengamankan kondisi sekarang" tar czf "$PRE" --exclude=node --exclude=models --exclude=runtimes --exclude=checkpoints --exclude=cache -C "$(dirname "$STATE_DIR")" "$(basename "$STATE_DIR")"; then
    ok "$PRE ${GRY}($(hsize "$PRE") · ${HB_ELAPSED}s)${R}"
  else warn "gagal membuat rollback point"; fi
else info "HERMES_HOME belum ada — dilewati"; fi

printf "\n"; sec "[5/7] Import arsip + remap path" "$(elapsed)"
mkdir -p "$STATE_DIR"; chown "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
# user service (mis. `hermes`) biasanya tidak bisa membaca /root/... → salin bila perlu
IMP_ARCHIVE="$ARCHIVE"; COPIED_ARCHIVE=0
if [ "$OC_USER" != root ]; then
  if ! sudo -u "$OC_USER" -H test -r "$ARCHIVE" 2>/dev/null; then
    IMP_ARCHIVE="$OC_HOME/$(basename "$ARCHIVE")"
    info "salin arsip → $IMP_ARCHIVE (agar terbaca user $OC_USER)"
    cp -f "$ARCHIVE" "$IMP_ARCHIVE" && chown "$OC_USER:$OC_GROUP" "$IMP_ARCHIVE" && chmod 600 "$IMP_ARCHIVE" && COPIED_ARCHIVE=1 \
      || warn "gagal menyalin arsip — import mungkin gagal karena izin"
  fi
fi
CMD="'$HERMES_BIN' import '$IMP_ARCHIVE' --force"
if hb "hermes import (config, skill, sesi, memori)" run_hermes "$CMD"; then
  ok "import selesai ${GRY}(${HB_ELAPSED}s)${R}"
  grep -iE "restored|preserved|warning|skipped" /tmp/hermes-migrate-cmd.log | head -6 | sed 's/^/      /'
else
  tail -6 /tmp/hermes-migrate-cmd.log | sed 's/^/      /'; die "hermes import gagal"
fi
chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
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
fi

# path lokal server lama di dalam DB/transcript → petakan ke lokasi baru (otomatis)
OLDP=$(python3 - "$STATE_DIR" <<'PY' 2>/dev/null || true
import sqlite3, glob, os, re, sys
from collections import Counter
new = sys.argv[1].rstrip('/'); pat = re.compile(r'((?:/[A-Za-z0-9._-]+)+/\.hermes)')
c = Counter()
for db in glob.glob(os.path.join(new, '**', '*.db'), recursive=True) + glob.glob(os.path.join(new, '**', '*.sqlite'), recursive=True):
    try: con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    except Exception: continue
    for t in [x[0] for x in con.execute("select name from sqlite_master where type='table'")]:
        if t.endswith(('_fts','_content','_data','_idx','_docsize','_config')): continue
        for col in [x[1] for x in con.execute(f'pragma table_info("{t}")')]:
            try: rows = con.execute(f'select "{col}" from "{t}" where "{col}" like ?', ('%/.hermes%',)).fetchall()
            except Exception: continue
            for (v,) in rows:
                if isinstance(v, str):
                    for m in pat.findall(v):
                        if m.rstrip('/') != new: c[m.rstrip('/')] += 1
    con.close()
print(c.most_common(1)[0][0] if c else '')
PY
)
REMAP=/tmp/hermes-remap-paths.py
[ -s "$REMAP" ] || curl -fsS -m 30 "$REPO_RAW/hermes-remap-paths.py" -o "$REMAP" 2>/dev/null || true
if [ -s "$REMAP" ]; then
  ROUT=$(python3 "$REMAP" --hermes-home "$STATE_DIR" ${OLDP:+--old "$OLDP"} --quiet 2>&1 | tail -1)
  case "$ROUT" in
    REMAP_OK*) ok "path lama dipetakan ${GRY}(${ROUT#REMAP_OK })${R}"; chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" ;;
    *) info "remap path: tidak ada perubahan" ;;
  esac
else warn "helper remap tidak tersedia — lewati pemetaan path"; fi

printf "\n"
if [ "$SAFE_CH" -eq 1 ]; then
  sec "[6/7] Amankan platform" "$(elapsed)"
  for pf in telegram discord whatsapp slack; do
    OUT=$(as_hermes "'$HERMES_BIN' config set platforms.$pf.enabled false" 2>&1 | tail -1)
    VAL=$(as_hermes "'$HERMES_BIN' config get platforms.$pf.enabled" 2>&1 | tail -1)
    case "$VAL" in false|False) ok "platforms.$pf.enabled=false" ;; *) warn "tidak bisa matikan platforms.$pf (nilai: ${VAL:-?})" ;; esac
  done
  chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
  hint "nyalakan hanya di SATU host (token chat tidak boleh dipakai dua gateway)"
else
  sec "[6/7] Platform" "$(elapsed)"
  warn "platform dibiarkan apa adanya"
  hint "kalau token chat masih dipakai server lain → pakai --safe-channels"
fi

printf "\n"; sec "[7/7] Jalankan service + health check" "$(elapsed)"
GW_OK=0
if [ "$NO_START" -eq 1 ]; then info "--no-start: service tidak dinyalakan"
elif [ -n "$SERVICE" ]; then
  systemctl ${SCOPE:+$([ "$SCOPE" = user ] && echo --user)} restart "$SERVICE"
  WMAX="${HERMES_START_TIMEOUT:-180}"; W=0
  while [ "$W" -lt "$WMAX" ]; do
    ST=$(svc_state); [ "$ST" = active ] && { GW_OK=1; break; }; [ "$ST" = failed ] && break
    printf "\r    ${PRP}⠿${R} ${GRY}menunggu service aktif…${R} ${BLD}%ss${R} ${GRY}(status: %s)${R}   " "$W" "$ST"
    sleep 3; W=$((W+3))
  done
  _clr
  if [ "$GW_OK" -eq 1 ]; then
    ok "service aktif ${GRY}(${W}s)${R}"
    if ss -tlnH 2>/dev/null | grep -q ":$PORT "; then ok "port :$PORT listening"
    else info "port :$PORT tidak dibuka — normal untuk gateway tanpa platform/HTTP"; fi
    as_hermes "'$HERMES_BIN' status 2>&1 | head -4" 2>/dev/null | sed 's/^/      /'
  else
    warn "service tidak aktif setelah ${WMAX}s"
    journalctl ${SCOPE:+$([ "$SCOPE" = user ] && echo --user)} -u "$SERVICE" -n 8 --no-pager 2>/dev/null | tail -8 | sed 's/^/      /'
  fi
else
  pkill -f "hermes.*(gateway|serve)" >/dev/null 2>&1 || true
  ( "$HERMES_BIN" gateway run --replace >/tmp/hermes-gateway-manual.log 2>&1 & ) 2>/dev/null || true
  sleep 8
  pgrep -f "hermes.*gateway" >/dev/null 2>&1 && { GW_OK=1; ok "gateway jalan (mode manual)"; } || warn "gateway manual tidak terdeteksi"
fi

if [ "$NO_START" -eq 0 ] && [ -n "$SERVICE" ] && [ "$GW_OK" -eq 0 ] && [ "$(svc_state)" != active ]; then
  printf "\n"; sec "Rollback" "$(elapsed)"
  systemctl ${SCOPE:+$([ "$SCOPE" = user ] && echo --user)} stop "$SERVICE" 2>/dev/null || true
  [ -f "$PRE" ] && tar xzf "$PRE" -C "$(dirname "$STATE_DIR")" && chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" && ok "kondisi lama dipulihkan dari $PRE"
  systemctl ${SCOPE:+$([ "$SCOPE" = user ] && echo --user)} start "$SERVICE" 2>/dev/null || true
  die "restore di-rollback: gateway tidak sehat setelah restore"
fi

N_HOME=$(hsize "$STATE_DIR")
_header "✔ RESTORE SELESAI" "$GRN"; _blc "" ""
_blc "versi        $HERMES_VER" "  ${GRY}versi${R}        $HERMES_VER"
_blc "hermes home  $(_fit "$STATE_DIR" 38) ($N_HOME)" "  ${GRY}hermes home${R}  $(_fit "$STATE_DIR" 38) ${GRY}($N_HOME)${R}"
_blc "state.db     $( [ -f "$STATE_DIR/state.db" ] && hsize "$STATE_DIR/state.db" || echo -)" "  ${GRY}state.db${R}     $( [ -f "$STATE_DIR/state.db" ] && hsize "$STATE_DIR/state.db" || echo -)"
_blc "skill        $(ls "$STATE_DIR/skills" 2>/dev/null | wc -l) folder · sesi $(ls "$STATE_DIR/sessions" 2>/dev/null | wc -l) file" "  ${GRY}skill${R}        $(ls "$STATE_DIR/skills" 2>/dev/null | wc -l) folder · sesi $(ls "$STATE_DIR/sessions" 2>/dev/null | wc -l) file"
_blc "service      ${SERVICE:-manual} · port $PORT · $(svc_state)" "  ${GRY}service${R}      ${SERVICE:-manual} · port $PORT · $(svc_state)"
_blc "rollback     $(_fit "$PRE" 46)" "  ${GRY}rollback${R}     $(_fit "$PRE" 46)"
_blc "durasi       $(elapsed)" "  ${GRY}durasi${R}       $(elapsed)"
_blc "" ""; _foot "$GRN"
printf "\n  ${GRY}Langkah berikutnya:${R}\n"
printf "    ${GRY}1.${R} ${B}$HERMES_BIN status${R}   ${GRY}# cek gateway & platform${R}\n"
printf "    ${GRY}2.${R} ${B}$HERMES_BIN doctor${R}   ${GRY}# pastikan tidak ada catatan${R}\n"
printf "    ${GRY}3.${R} uji chat ke bot / buka dashboard\\n"
[ "$SAFE_CH" -eq 1 ] && printf "    ${YLW}4.${R} ${YLW}platform dimatikan — nyalakan hanya di SATU host${R}\n"
printf "\n"
exit 0
