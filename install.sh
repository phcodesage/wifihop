#!/usr/bin/env bash
# wifihop installer for macOS and Linux.
# https://github.com/phcodesage/wifihop
#
# Install from a clone:      sudo ./install.sh
# Install straight from web: curl -fsSL https://raw.githubusercontent.com/phcodesage/wifihop/main/install.sh | sudo bash
# Uninstall:                 sudo ./uninstall.sh   (or: sudo ./install.sh --uninstall)
#
# Run ./install.sh --help for every option.

set -euo pipefail

REPO="phcodesage/wifihop"
REF="${WIFIHOP_REF:-main}"
RAW_URL="https://raw.githubusercontent.com/$REPO/$REF"

BIN="/usr/local/bin/wifihop"
CONF="/etc/wifihop.conf"
STATE="/var/run/wifihop.current"
MAC_LABEL="io.github.phcodesage.wifihop"
MAC_PLIST="/Library/LaunchDaemons/$MAC_LABEL.plist"
MAC_LOG="/var/log/wifihop.log"
MAC_NEWSYSLOG="/etc/newsyslog.d/wifihop.conf"
LINUX_UNIT="/etc/systemd/system/wifihop.service"

ACTION="install"
PURGE=0
START=1
FORCE=0
AUTHORIZE=0
CONFIG_SRC=""
SET_INTERVAL=""
SET_FAILS=""
PREFERS=()
EXCLUDES=()

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf '\n%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
wifihop installer — keeps a Mac or Linux machine online by switching to the next
known Wi-Fi network when the current one has no internet.

Usage: sudo ./install.sh [options]
       curl -fsSL $RAW_URL/install.sh | sudo bash -s -- [options]

Install options:
  --config FILE        Install FILE as $CONF (replaces any existing config)
  --prefer SSID        Try SSID before the machine's other known networks (repeatable)
  --exclude SSID       Never auto-join SSID, e.g. a phone hotspot (repeatable)
  --interval SECONDS   How often to check the internet (default 10)
  --fails N            Failed checks (out of the last 5) before switching (default 3)
  --no-start           Install everything but don't start the service yet
  --force              Install even if no Wi-Fi interface is detected right now
  --authorize          macOS, optional: approve keychain access so wifihop can join a
                       specific network directly (not needed; see README)

Removal:
  --uninstall          Stop and remove wifihop (keeps $CONF)
  --purge              With --uninstall, also delete $CONF

Other:
  -h, --help           Show this help

Environment:
  WIFIHOP_REF          Git branch or tag to download when installing from the web (default: main)

The --prefer, --exclude, --interval and --fails options are written into $CONF.
EOF
}

# ---------------------------------------------------------------- arguments

ORIG_ARGS=("$@")
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || fail "$1 needs a value (see --help)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config)    need_arg "$@"; CONFIG_SRC="$2"; shift 2 ;;
    --prefer)    need_arg "$@"; PREFERS+=("$2"); shift 2 ;;
    --exclude)   need_arg "$@"; EXCLUDES+=("$2"); shift 2 ;;
    --interval)  need_arg "$@"; SET_INTERVAL="$2"; shift 2 ;;
    --fails)     need_arg "$@"; SET_FAILS="$2"; shift 2 ;;
    --no-start)  START=0; shift ;;
    --force)     FORCE=1; shift ;;
    --authorize) AUTHORIZE=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --purge)     PURGE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           fail "unknown option: $1 (see --help)" ;;
  esac
done

is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
[ -z "$SET_INTERVAL" ] || { is_uint "$SET_INTERVAL" && [ "$SET_INTERVAL" -ge 1 ]; } || fail "--interval must be a positive whole number"
[ -z "$SET_FAILS" ]    || { is_uint "$SET_FAILS" && [ "$SET_FAILS" -ge 1 ]; }       || fail "--fails must be a positive whole number"
[ -z "$CONFIG_SRC" ]   || [ -r "$CONFIG_SRC" ] || fail "config file not found: $CONFIG_SRC"

# ---------------------------------------------------------------- environment checks

OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="macOS $(sw_vers -productVersion 2>/dev/null)" ;;
  Linux)  PLATFORM="Linux ($( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown distro}" || echo "unknown distro"))" ;;
  *)      fail "wifihop supports macOS and Linux only (this is $OS)" ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  # When run from a file, re-launch through sudo; when piped from curl, $0 is just "bash".
  if [ -f "${BASH_SOURCE[0]:-}" ] && command -v sudo >/dev/null; then
    echo "wifihop needs administrator rights to install a system service; asking for your password..."
    exec sudo bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  fail "please run as root, e.g.: curl -fsSL $RAW_URL/install.sh | sudo bash"
fi

# Directory holding this installer, if it was run from a clone (empty when piped from curl).
SRC_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ---------------------------------------------------------------- uninstall

uninstall() {
  step "Uninstalling wifihop from $PLATFORM"
  if [ "$OS" = Darwin ]; then
    if launchctl print "system/$MAC_LABEL" >/dev/null 2>&1; then
      launchctl bootout "system/$MAC_LABEL" 2>/dev/null || true
      ok "stopped the service"
    fi
    rm -f "$MAC_PLIST" "$MAC_NEWSYSLOG"
    ok "removed $MAC_PLIST"
    info "the log at $MAC_LOG was kept; delete it if you don't need it"
  else
    if command -v systemctl >/dev/null; then
      systemctl disable --now wifihop >/dev/null 2>&1 || true
      rm -f "$LINUX_UNIT"
      systemctl daemon-reload
      ok "stopped and removed the systemd service"
    fi
  fi
  rm -f "$BIN" "$STATE" /etc/wifihop.keychain-authorized
  ok "removed $BIN"
  if [ $PURGE -eq 1 ] && [ -f "$CONF" ]; then
    rm -f "$CONF" "$CONF.bak"; ok "removed $CONF"
  elif [ -f "$CONF" ]; then
    info "kept $CONF (use --uninstall --purge to delete it)"
  fi
  printf '\n%swifihop has been removed.%s\n' "$GREEN" "$RESET"
}

if [ "$ACTION" = uninstall ]; then uninstall; exit 0; fi

# ---------------------------------------------------------------- install: dependencies

printf '%swifihop installer%s — %s\n' "$BOLD" "$RESET" "$PLATFORM"

install_linux_pkg() {
  local pkg="$1"
  {
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq "$pkg"
  elif command -v dnf     >/dev/null; then dnf install -y -q "$pkg"
  elif command -v yum     >/dev/null; then yum install -y -q "$pkg"
  elif command -v pacman  >/dev/null; then pacman -Sy --noconfirm --needed "$pkg"
  elif command -v zypper  >/dev/null; then zypper --non-interactive install "$pkg"
  elif command -v apk     >/dev/null; then apk add --quiet "$pkg"
  else return 1
  fi
  } >/dev/null 2>&1
}

step "Checking requirements"
if [ "$OS" = Darwin ]; then
  for c in networksetup launchctl curl security; do
    command -v "$c" >/dev/null || fail "$c is missing; it ships with macOS, so this install looks damaged"
  done
  ok "networksetup, launchctl, curl and security are available"
  WIFI_IF="$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')"
else
  if ! command -v curl >/dev/null; then
    info "curl not found; installing it"
    install_linux_pkg curl || fail "couldn't install curl automatically; install it with your package manager and re-run"
  fi
  ok "curl is available"

  command -v systemctl >/dev/null && [ -d /run/systemd/system ] ||
    fail "wifihop needs systemd to run as a service, and this system isn't using it"
  ok "systemd is running"

  if ! command -v nmcli >/dev/null; then
    cat >&2 <<EOF

${RED}Error:${RESET} NetworkManager (nmcli) was not found.

wifihop controls Wi-Fi on Linux through NetworkManager, which Ubuntu, Fedora, Debian
desktop, Linux Mint, Pop!_OS, Manjaro and Raspberry Pi OS (Bookworm+) use by default.
Install and enable it, then re-run this installer:

  Debian/Ubuntu:  sudo apt install network-manager && sudo systemctl enable --now NetworkManager
  Fedora/RHEL:    sudo dnf install NetworkManager-wifi && sudo systemctl enable --now NetworkManager
  Arch:           sudo pacman -S networkmanager && sudo systemctl enable --now NetworkManager

Systems that manage Wi-Fi only with wpa_supplicant, iwd or netplan+networkd aren't supported yet.
EOF
    exit 1
  fi
  systemctl is-active --quiet NetworkManager ||
    fail "NetworkManager is installed but not running. Start it with: sudo systemctl enable --now NetworkManager"
  ok "NetworkManager is running"
  WIFI_IF="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
fi

if [ -n "$WIFI_IF" ]; then
  ok "Wi-Fi interface: $WIFI_IF"
elif [ $FORCE -eq 1 ]; then
  warn "no Wi-Fi interface found; installing anyway because of --force"
else
  fail "no Wi-Fi interface found on this machine. If a USB Wi-Fi adapter will be plugged in later, re-run with --force"
fi

# ---------------------------------------------------------------- install: files

step "Installing the wifihop command"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/wifihop" ]; then
  cp "$SRC_DIR/wifihop" "$TMP/wifihop"
  info "using the copy in $SRC_DIR"
else
  info "downloading from github.com/$REPO ($REF)"
  curl -fsSL "$RAW_URL/wifihop" -o "$TMP/wifihop" || fail "download failed from $RAW_URL/wifihop"
fi
head -n 1 "$TMP/wifihop" | grep -q bash || fail "the downloaded wifihop script looks wrong (not a bash script)"
bash -n "$TMP/wifihop" || fail "the wifihop script has a syntax error"
mkdir -p "$(dirname "$BIN")"
install -m 755 "$TMP/wifihop" "$BIN"
ok "installed $BIN ($("$BIN" version))"

step "Setting up the config"
write_default_conf() {
  cat > "$CONF" <<'EOF'
# wifihop configuration — https://github.com/phcodesage/wifihop
#
# With no "prefer" lines, wifihop uses this machine's own known Wi-Fi networks:
#   macOS: System Settings > Wi-Fi > Known Networks, in their saved order
#   Linux: NetworkManager Wi-Fi connections, highest autoconnect priority first
# Changes here are picked up automatically on the next check; no restart needed.

# How often to test the internet, in seconds.
check_interval = 10

# Switch networks when this many of the last "window" tests failed.
# (Not "in a row": a flaky network that gets through now and then still gets replaced.)
fails_before_switch = 3
window = 5

# While the internet looks down, test again every this many seconds.
recheck_interval = 3

# How long to wait for a newly joined network to reach the internet, in seconds.
join_wait = 20

# While on a backup network, how often to try going back to the first network
# in the list, in seconds. 0 = stay on the backup until it fails.
primary_retry = 300

# Try these first, in this order. Add "| password" if the machine doesn't have it saved.
# prefer = Office-WiFi
# prefer = Office-Backup | the-password

# Never switch to these automatically (phone hotspots, metered connections...).
# exclude = My iPhone

# Pin a specific Wi-Fi interface instead of auto-detecting it.
# interface = en0
EOF
}

# set_key KEY VALUE: replace an existing "key = ..." line, or append one.
set_key() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*$key[[:space:]]*=" "$CONF"; then
    sed -i.bak -E "s|^[[:space:]]*$key[[:space:]]*=.*|$key = $val|" "$CONF" && rm -f "$CONF.bak"
  else
    printf '%s = %s\n' "$key" "$val" >> "$CONF"
  fi
}

if [ -n "$CONFIG_SRC" ]; then
  [ -f "$CONF" ] && cp "$CONF" "$CONF.bak" && info "backed up the old config to $CONF.bak"
  cp "$CONFIG_SRC" "$CONF"
  ok "installed $CONFIG_SRC as $CONF"
elif [ -f "$CONF" ]; then
  ok "kept existing $CONF"
else
  write_default_conf
  ok "created $CONF with defaults"
fi
[ -n "$SET_INTERVAL" ] && set_key check_interval "$SET_INTERVAL" && ok "check_interval = $SET_INTERVAL"
[ -n "$SET_FAILS" ]    && set_key fails_before_switch "$SET_FAILS" && ok "fails_before_switch = $SET_FAILS"
for s in ${PREFERS[@]+"${PREFERS[@]}"};  do printf 'prefer = %s\n'  "$s" >> "$CONF"; ok "prefer = $s"; done
for s in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do printf 'exclude = %s\n' "$s" >> "$CONF"; ok "exclude = $s"; done
# Root-only: the file may hold Wi-Fi passwords.
chown 0:0 "$CONF"
chmod 600 "$CONF"
info "permissions set to root-only (600) because it can contain passwords"

# ---------------------------------------------------------------- install: service

step "Installing the background service"
if [ "$OS" = Darwin ]; then
  cat > "$MAC_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MAC_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$MAC_LOG</string>
  <key>StandardErrorPath</key><string>$MAC_LOG</string>
</dict>
</plist>
EOF
  chown root:wheel "$MAC_PLIST"; chmod 644 "$MAC_PLIST"
  plutil -lint "$MAC_PLIST" >/dev/null || fail "generated launchd plist is invalid"
  ok "wrote $MAC_PLIST"

  # Rotate the log: keep 5 compressed copies, roll over at 1 MB.
  mkdir -p "$(dirname "$MAC_NEWSYSLOG")"
  printf '# logfilename        [owner:group]  mode count size(KB) when flags\n%s  root:wheel     644  5     1024     *    J\n' "$MAC_LOG" > "$MAC_NEWSYSLOG"
  ok "log rotation set up for $MAC_LOG"

  launchctl bootout "system/$MAC_LABEL" 2>/dev/null || true
  if [ $START -eq 1 ]; then
    launchctl bootstrap system "$MAC_PLIST" || fail "launchctl couldn't load the service"
    ok "service started (it also starts at every boot)"
  else
    info "not started (--no-start). Start it with: sudo launchctl bootstrap system $MAC_PLIST"
  fi
else
  cat > "$LINUX_UNIT" <<EOF
[Unit]
Description=wifihop - switch to the next known Wi-Fi network when the internet drops
Documentation=https://github.com/$REPO
Wants=NetworkManager.service
After=NetworkManager.service network.target

[Service]
Type=simple
ExecStart=$BIN run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$LINUX_UNIT"
  systemctl daemon-reload
  ok "wrote $LINUX_UNIT"
  if [ $START -eq 1 ]; then
    systemctl enable --now wifihop >/dev/null 2>&1 || fail "systemd couldn't start wifihop; see: journalctl -u wifihop"
    systemctl restart wifihop
    ok "service enabled and started (it also starts at every boot)"
  else
    systemctl enable wifihop >/dev/null 2>&1
    info "enabled but not started (--no-start). Start it with: sudo systemctl start wifihop"
  fi
fi

# ---------------------------------------------------------------- macOS: optional password approval

# Not needed: on macOS wifihop switches by disconnecting and letting macOS auto-join, and macOS
# already has the passwords. --authorize additionally allows direct joins to a chosen network.
if [ "$OS" = Darwin ] && [ $AUTHORIZE -eq 1 ]; then
  step "Allowing wifihop to read saved Wi-Fi passwords (optional)"
  "$BIN" authorize | sed 's/^/  /' || warn "authorize didn't finish; you can re-run: sudo wifihop authorize"
fi

# ---------------------------------------------------------------- verify

if [ $START -eq 1 ]; then
  step "Checking that it's running"
  sleep 2
  if [ "$OS" = Darwin ]; then
    launchctl print "system/$MAC_LABEL" 2>/dev/null | grep -q 'state = running' &&
      ok "wifihop is running" || warn "the service isn't running yet; check $MAC_LOG"
  else
    systemctl is-active --quiet wifihop &&
      ok "wifihop is running" || warn "the service isn't running; check: journalctl -u wifihop"
  fi
fi

echo
"$BIN" list 2>/dev/null | sed 's/^/  /' || true

if [ "$OS" = Darwin ]; then LOGCMD="tail -f $MAC_LOG"; else LOGCMD="journalctl -u wifihop -f"; fi
cat <<EOF

${GREEN}${BOLD}wifihop is installed.${RESET} It runs in the background as a system service,
starts automatically at every boot, and restarts itself if it ever stops.

  wifihop status          current network, internet status, recent activity
  wifihop list            the networks it will try, in order
  sudo wifihop switch     hop to the next working network right now
  sudo wifihop diagnose   read-only troubleshooting report
  $LOGCMD
  sudo nano $CONF   change the order, exclude networks, add passwords

  Stop it:    $([ "$OS" = Darwin ] && echo "sudo launchctl bootout system/$MAC_LABEL" || echo "sudo systemctl stop wifihop")   (starts again at boot)
  Uninstall:  $([ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/uninstall.sh" ] && echo "sudo $SRC_DIR/uninstall.sh" || echo "curl -fsSL $RAW_URL/uninstall.sh | sudo bash")
EOF
