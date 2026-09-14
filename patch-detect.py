import re, sys

SNIP = '''HERMES_BIN=$(readlink -f "$HERMES_BIN")
# ── cari venv & install dir (hermes bisa berupa symlink ATAU script wrapper)
VENV=""
case "$HERMES_BIN" in */venv/bin/hermes) VENV=$(dirname "$(dirname "$HERMES_BIN")") ;; esac
if [ -z "$VENV" ] && [ -f "$HERMES_BIN" ]; then
  P=$(grep -aoE '/[^ "'"'"']*/venv/bin/python[0-9.]*' "$HERMES_BIN" 2>/dev/null | head -1)
  [ -n "$P" ] && VENV=$(dirname "$(dirname "$P")")
fi
if [ -z "$VENV" ]; then
  for d in "${HERMES_INSTALL_DIR:-}" /opt/hermes-agent /usr/local/lib/hermes-agent "$HOME/.local/share/hermes-agent" "$HOME/.hermes/hermes-agent"; do
    [ -n "$d" ] && [ -x "$d/venv/bin/hermes" ] && { VENV="$d/venv"; break; }
  done
fi
if [ -n "$VENV" ]; then VPY="$VENV/bin/python"; VPIP="$VENV/bin/pip"; INSTALL_DIR=$(dirname "$VENV")
else INSTALL_DIR=$(dirname "$HERMES_BIN"); VPY=$(command -v python3); VPIP=$(command -v pip3); fi
'''

# ── hermes-migrate.sh ───────────────────────────────────────────────────────
p = "/root/hermes-tools/hermes-migrate.sh"
s = open(p).read()
old = '''  HERMES_BIN=$(readlink -f "$HERMES_BIN")
  case "$HERMES_BIN" in */venv/bin/hermes) INSTALL_DIR=$(dirname "$(dirname "$(dirname "$HERMES_BIN")")") ;;
    *) INSTALL_DIR=$(dirname "$HERMES_BIN") ;; esac
  HERMES_VER=$("$HERMES_BIN" --version 2>&1 | head -1)
  PY_VER=$("$INSTALL_DIR/venv/bin/python" -V 2>&1 | awk '{print $2}')
  [ -n "$PY_VER" ] || PY_VER=$(python3 -V 2>&1 | awk '{print $2}')'''
new = SNIP + '''  HERMES_VER=$("$HERMES_BIN" --version 2>&1 | head -1)
  PY_VER=$("$VPY" -V 2>&1 | awk '{print $2}')
  [ -n "$PY_VER" ] || PY_VER=$(python3 -V 2>&1 | awk '{print $2}')'''
assert old in s, "migrate: blok bin tidak ketemu"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("migrate dipatch")

# ── hermes-upgrade.sh ───────────────────────────────────────────────────────
p = "/root/hermes-tools/hermes-upgrade.sh"
s = open(p).read()
old2 = '''HERMES_BIN=$(readlink -f "$HERMES_BIN")
case "$HERMES_BIN" in */venv/bin/hermes) INSTALL_DIR=$(dirname "$(dirname "$(dirname "$HERMES_BIN")")") ;;
  *) INSTALL_DIR=$(dirname "$HERMES_BIN") ;; esac
VENV="$INSTALL_DIR/venv"; VPY="$VENV/bin/python"; VPIP="$VENV/bin/pip"'''
assert old2 in s, "upgrade: blok bin tidak ketemu"
s = s.replace(old2, SNIP.rstrip(), 1)
open(p, "w").write(s)
print("upgrade dipatch")
