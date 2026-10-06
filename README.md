# wifihop

Keeps a Mac or Linux machine online by switching to the next known Wi-Fi network when the current one has no internet.

Your computer already switches networks when a Wi-Fi network **disappears**. It does nothing when the network is still there but the internet behind it is dead: the router is up, the ISP is down, and you stay stuck. wifihop handles that case.

- **No list to maintain:** it uses the networks the machine already knows, in their saved order.
- **Checks real internet, not just the link:** the check goes out through the Wi-Fi interface itself, so a plugged-in Ethernet cable can't hide a dead Wi-Fi.
- **Comes back:** while on a backup network, it checks every few minutes whether your main network has recovered.
- **Runs as a system service:** it starts at boot, works before anyone logs in, and restarts if it crashes.
- **A single bash script** with no dependencies beyond what the OS ships (plus NetworkManager on Linux).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/phcodesage/wifihop/main/install.sh | sudo bash
```

Or from a clone:

```sh
git clone https://github.com/phcodesage/wifihop.git
cd wifihop
sudo ./install.sh
```

The installer checks requirements, installs the `wifihop` command, creates `/etc/wifihop.conf`, sets up the service (launchd on macOS, systemd on Linux), starts it, and shows the networks it will use.

### Installer options

```sh
sudo ./install.sh --prefer "Office-WiFi" --exclude "My iPhone" --interval 15
curl -fsSL https://raw.githubusercontent.com/phcodesage/wifihop/main/install.sh | sudo bash -s -- --exclude "My iPhone"
```

| Option | What it does |
|---|---|
| `--prefer SSID` | Try this network first (repeatable, in order) |
| `--exclude SSID` | Never auto-join this network, e.g. a phone hotspot (repeatable) |
| `--interval SECONDS` | How often to check the internet (default 10) |
| `--fails N` | Failed checks (out of the last 5) before switching (default 3) |
| `--config FILE` | Install your own config file |
| `--no-start` | Install everything, but don't start the service yet |
| `--authorize` | macOS, optional: approve keychain access for direct joins (not needed for switching) |
| `--force` | Install even if no Wi-Fi interface is detected right now |
| `--uninstall [--purge]` | Remove wifihop (`--purge` also deletes the config) |

## Requirements

| | macOS | Linux |
|---|---|---|
| Version | macOS 12 or later (tested on macOS 27) | Any distro with systemd |
| Wi-Fi control | `networksetup` (built in) | NetworkManager (`nmcli`) |
| Service | launchd | systemd |

NetworkManager is the default on Ubuntu, Fedora, Debian desktop, Linux Mint, Pop!_OS, Manjaro and Raspberry Pi OS (Bookworm and later). Systems that manage Wi-Fi only with wpa_supplicant, iwd or systemd-networkd aren't supported yet.

## Runs in the background

Once installed, wifihop runs as a root system service, not as an app or a terminal process:

| | macOS | Linux |
|---|---|---|
| Service | `/Library/LaunchDaemons/io.github.phcodesage.wifihop.plist` | `/etc/systemd/system/wifihop.service` |
| Starts at boot | yes (`RunAtLoad`), before anyone logs in | yes (`enabled`, `multi-user.target`) |
| Restarts if it stops | yes (`KeepAlive`) | yes (`Restart=always`) |
| Check it | `sudo launchctl print system/io.github.phcodesage.wifihop` | `systemctl status wifihop` |

Closing the terminal, logging out, or rebooting doesn't stop it. Only `--uninstall` does.

## Usage

```sh
wifihop status        # interface, current network, internet status, recent activity
wifihop list          # the networks it will try, in order
wifihop check         # test internet over Wi-Fi once (exit code 0 = online)
sudo wifihop switch   # hop to the next working network right now
sudo wifihop diagnose # read-only troubleshooting report, never changes the network
sudo wifihop authorize # macOS, optional: allow direct joins using saved passwords
```

Logs:

```sh
tail -f /var/log/wifihop.log      # macOS
journalctl -u wifihop -f          # Linux
```

## How it works

1. Every `check_interval` seconds it fetches a known page (Apple's captive-portal check, with Google's `generate_204` as a second opinion) **through the Wi-Fi interface**. Both use DNS on purpose, because a network with broken DNS is unusable too.
2. As soon as a check fails, it rechecks every `recheck_interval` seconds. When `fails_before_switch` of the last `window` checks have failed (not necessarily in a row, so flaky networks are caught), it scans for networks in range and walks down the list, skipping the current network, excluded networks and networks that aren't in range.
3. For each candidate it joins the network, then waits up to `join_wait` seconds for real internet. It stays on the first network that works.
4. While on a backup network, it tries the top network again every `primary_retry` seconds.

**Network order**
- macOS: System Settings → Wi-Fi → Known Networks, in their saved order.
- Linux: NetworkManager Wi-Fi connections, highest `connection.autoconnect-priority` first.

`prefer` entries in the config always go first.

**Passwords** come from the machine itself:
- macOS: wifihop never needs them. To switch, it disconnects from the dead network and lets macOS auto-join another known network. macOS skips the network it just left and uses the passwords it already has. If that lands on another dead network, it repeats, then finally turns Wi-Fi off and on. `prefer = Name | password` in the config, or the optional `sudo wifihop authorize`, also lets it join one specific network directly.
- Linux: NetworkManager's saved connections.

You only need to put a password in the config for a network the machine has never joined.

## Configuration

`/etc/wifihop.conf` is optional and readable by root only. Changes are picked up on the next check, so no restart is needed.

```ini
check_interval = 10        # seconds between internet checks
fails_before_switch = 3    # switch when this many of the last `window` checks failed
window = 5
recheck_interval = 3       # seconds between checks while the internet looks down
join_wait = 20             # seconds to wait for a new network to reach the internet
primary_retry = 300        # how often to try returning to the top network (0 = never)

prefer = Office-WiFi                  # try first, in order
prefer = Office-Backup | the-password # with a password, if the machine doesn't know it
exclude = My iPhone                   # never auto-join

# interface = en0                     # pin an interface instead of auto-detecting
# check_url = http://captive.apple.com/hotspot-detect.html
# check_expect = Success
```

See [`wifihop.conf.example`](wifihop.conf.example).

## Deploying to many machines

- **No device management:** run the one-line install on each machine. Pass `--prefer` and `--exclude` to set the same policy everywhere, or `--config` with a shared file.
- **macOS with MDM (Jamf, Kandji, Mosyle, Intune):** push the Wi-Fi networks and their passwords as a Wi-Fi configuration profile. Then run `install.sh` as a policy or script, so no passwords live in a text file.
- **Linux fleets:** push NetworkManager connection profiles to `/etc/NetworkManager/system-connections/` with your configuration management tool, then run `install.sh`.

## Notes

- **Hidden network names on macOS 15+:** macOS hides Wi-Fi names from background services. wifihop therefore scans and joins inside the logged-in user's session, where names are visible. With nobody logged in, it falls back to turning Wi-Fi off and on, which lets macOS auto-join the top known network.
- **Turning Wi-Fi off:** if you switch Wi-Fi off, wifihop waits and does nothing until it's back on.
- **Only one network around:** wifihop only switches when another known network is in range. If the network you're on is the only one, it leaves Wi-Fi alone and waits for it to recover. It never disconnects or restarts Wi-Fi when there's nothing better to switch to. It also waits, without disconnecting anything, when it can't scan to see what's nearby.
- **Reconnecting:** while Wi-Fi is still connecting (no address yet), checks don't count as failures, so a normal reconnect never triggers a switch.
- **Captive portals:** hotel and airport login pages count as "no internet", so wifihop moves on to the next network.

## Stop or uninstall

Stop it without removing it:

```sh
sudo launchctl bootout system/io.github.phcodesage.wifihop   # macOS (starts again at boot)
sudo systemctl stop wifihop                                   # Linux (starts again at boot)
sudo systemctl disable --now wifihop                          # Linux, stays off after reboot
```

Uninstall:

```sh
sudo ./uninstall.sh           # from the unzipped folder or a clone; keeps /etc/wifihop.conf
sudo ./uninstall.sh --purge   # also removes the config and log
curl -fsSL https://raw.githubusercontent.com/phcodesage/wifihop/main/uninstall.sh | sudo bash
```

The uninstaller asks before removing anything, and it never changes your Wi-Fi settings or saved networks.

## License

[MIT](LICENSE)
