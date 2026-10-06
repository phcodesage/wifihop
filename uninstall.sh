#!/usr/bin/env bash
# wifihop uninstaller for macOS and Linux.
# https://github.com/phcodesage/wifihop
#
# From the unzipped folder:  sudo ./uninstall.sh            (keeps /etc/wifihop.conf)
#                            sudo ./uninstall.sh --purge    (removes everything)
# Straight from the web:     curl -fsSL https://raw.githubusercontent.com/phcodesage/wifihop/main/uninstall.sh | sudo bash
#
# Safe to run more than once, and it doesn't touch your Wi-Fi settings or saved networks.

set -euo pipefail

BIN="/usr/local/bin/wifihop"
CONF="/etc/wifihop.conf"
STATE="/var/run/wifihop.current"
AUTH_MARK="/etc/wifihop.keychain-authorized"
MAC_LABEL="io.github.phcodesage.wifihop"
MAC_PLIST="/Library/LaunchDaemons/$MAC_LABEL.plist"
MAC_LOG="/var/log/wifihop.log"
MAC_NEWSYSLOG="/etc/newsyslog.d/wifihop.conf"
LINUX_UNIT="/etc/systemd/system/wifihop.service"

PURGE=0
ASSUME_YES=0

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; BLUE=""; RESET=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
fail() { printf '\n%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
wifihop uninstaller — stops the wifihop service and removes it.

Usage: sudo ./uninstall.sh [options]

  --purge     Also delete $CONF and the log (a full clean-up)
  -y, --yes   Don't ask for confirmation
  -h, --help  Show this help

Your Wi-Fi settings and saved networks are never touched.
EOF
}

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)   PURGE=1; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         fail "unknown option: $1 (see --help)" ;;
  esac
done

OS="$(uname -s)"
case "$OS" in Darwin|Linux) ;; *) fail "wifihop supports macOS and Linux only (this is $OS)" ;; esac

if [ "$(id -u)" -ne 0 ]; then
  if [ -f "${BASH_SOURCE[0]:-}" ] && command -v sudo >/dev/null; then
    echo "Removing a system service needs administrator rights; asking for your password..."
    exec sudo bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  fail "please run as root, e.g.: sudo ./uninstall.sh"
fi

# Nothing installed? Say so instead of pretending to remove things.
if [ ! -e "$BIN" ] && [ ! -e "$MAC_PLIST" ] && [ ! -e "$LINUX_UNIT" ] && { [ $PURGE -eq 0 ] || [ ! -e "$CONF" ]; }; then
  echo "wifihop isn't installed on this machine. Nothing to do."
  exit 0
fi

# Ask before removing, when someone is at a terminal (piped installs read from /dev/tty).
if [ $ASSUME_YES -eq 0 ] && [ -r /dev/tty ] && { [ -t 0 ] || [ -t 1 ]; }; then
  what="wifihop"; [ $PURGE -eq 1 ] && what="wifihop, its config and its log"
  printf 'Remove %s from this machine? [y/N] ' "$what"
  read -r answer < /dev/tty || answer=""
  case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled. Nothing was removed."; exit 0 ;; esac
fi

step "Stopping the service"
if [ "$OS" = Darwin ]; then
  if launchctl print "system/$MAC_LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$MAC_LABEL" 2>/dev/null || true
    ok "stopped $MAC_LABEL"
  else
    info "service wasn't running"
  fi
  # Clear any "disabled" override left by a manual 'launchctl disable', so a reinstall starts cleanly.
  launchctl enable "system/$MAC_LABEL" 2>/dev/null || true
else
  if command -v systemctl >/dev/null && systemctl list-unit-files wifihop.service >/dev/null 2>&1; then
    systemctl disable --now wifihop >/dev/null 2>&1 || true
    ok "stopped and disabled wifihop.service"
  else
    info "service wasn't installed"
  fi
fi
# In case it was started by hand with "sudo wifihop run".
if pkill -f "$BIN run" 2>/dev/null; then ok "stopped a manually started wifihop"; fi

step "Removing files"
remove() { if [ -e "$1" ]; then rm -f "$1"; ok "removed $1"; fi; }
if [ "$OS" = Darwin ]; then
  remove "$MAC_PLIST"
  remove "$MAC_NEWSYSLOG"
else
  remove "$LINUX_UNIT"
  command -v systemctl >/dev/null && systemctl daemon-reload 2>/dev/null || true
fi
remove "$BIN"
remove "$STATE"
remove "$AUTH_MARK"

if [ $PURGE -eq 1 ]; then
  remove "$CONF"
  remove "$CONF.bak"
  if [ "$OS" = Darwin ]; then
    for f in "$MAC_LOG" "$MAC_LOG".*; do [ -e "$f" ] && remove "$f"; done
  else
    command -v journalctl >/dev/null && info "past log lines stay in the system journal until it rotates them"
  fi
else
  [ -e "$CONF" ] && info "kept $CONF (run with --purge to delete it)"
  [ "$OS" = Darwin ] && [ -e "$MAC_LOG" ] && info "kept $MAC_LOG (run with --purge to delete it)"
fi

printf '\n%swifihop has been removed.%s Your Wi-Fi settings and saved networks were not changed.\n' "$GREEN" "$RESET"
