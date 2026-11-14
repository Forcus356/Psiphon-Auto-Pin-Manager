# Forcus Psiphon Auto-Pin Manager 4.2

Our Psiphon manager with local SOCKS5, verified server pinning, Google/Gemini checks and automatic recovery. Operational features studied in Chara are implemented in our own Python monitor. There is no Chara installer or second watchdog at runtime.

[Полная инструкция на русском](README.ru_RU.md)

## Features

- First healthy single-tunnel connections automatically acquire a cache, apply their server entry and verify the PIN after a controlled reconnect.
- Optional dependency-aware removal with `uninstall --purge-deps`; preexisting Docker/Go remain installed.

- Minimum throughput with consecutive low-speed confirmation; transfer rate excludes time before the first byte.
- Country pools, persistent rotation and preference for previously verified servers still present in the current datastore.
- Up to 99 independent instances, each with its own ports, config, datastore, lock and services.
- Optional browser TLS profile for CAPTCHA detection; a parallel HTTP/2 transfer keeps anonymous Gemini generation active.
- Denied countries, fast Google-country checks and recovery after transport failures.
- Local CLI for status, checks, rotation, regions, country pools, speed, service lifecycle, logs and instance uninstall.
- Optional SOCKS-only publication, private IPv4 binding, Xray outbound output and pools of 2–32 simultaneous tunnels.
- Original TargetServerEntry selection, diagnostic-ID verification and deferred PIN preparation remain available with one tunnel.

## Interactive setup

Use Latin `y` to review/apply, then confirm with `y` / `n`. Malformed UTF-8 input is rejected and reprompted without exiting or accepting a corrupted confirmation.

Watchdog timing is editable in Easy (item 5) and Advanced, in minutes. Minimum 1 minute, default 5; fractional minutes such as 1.5 are supported when they represent whole seconds. This controls the built-in monitor's regular checks; failure retries remain faster. Existing JSON `interval` and CLI `--interval` retain seconds without rounding old values. The footer shows the saved period and uses bright colors without the faint attribute.

Menus use framed sections and a status footer showing the script version, tunnel/monitor state, autostart, saved ports and region, last exit IP, Google/Gemini result and check time. These are saved monitoring results; opening the menu does not run network probes. Unapplied edits are marked separately. The frame adapts to terminal width and wraps long lines. Use `NO_COLOR=1 auto-pin` to disable colors; `TERM=dumb` also selects ASCII borders.

Run the installer without arguments in a terminal:

```bash
sudo bash install_psiphon_autopin.sh
```

Choose **Easy Mode** for country, SOCKS5 address / Xray JSON, Gemini checks, the SOCKS port and watchdog interval in minutes. **Advanced Mode** exposes all installer settings. The main menu also selects an instance (1–99) and provides status, checks, lifecycle, rotation/search, logs, speed, PIN/cache tools and scoped uninstall.

Edit numbered fields, then choose `y` to review and apply. Enter keeps a field; `-` clears a country list. Application requires confirmation and may restart the selected tunnel. Cancel leaves files/services unchanged. Easy preserves existing Advanced values.

Reopen it with `sudo auto-pin`, `sudo auto-pin --instance 2`, or `sudo psiphon-autopin-2 menu`. Effective settings, output format and last menu mode persist in the instance's `settings.json`. `connection.json` contains the selected connection; Xray output also produces `xray-outbound.json` (mode 0600). Add that outbound and routing to Xray yourself; its process must reach the SOCKS address.

Ordinary flags bypass the menu for automation. `--menu` / `--interactive` explicitly opens the wizard and accepts optional `--instance N`. An executable installer copy is saved locally so reopening does not need a fresh installer download; applying settings may still download missing packages, images or browser profiles.

## Install

Ubuntu/Debian x86_64, root and systemd. Run the new release file locally, or the repository installer after publishing this version:

```bash
sudo bash install_psiphon_autopin.sh --region NL,DE --port 40000
sudo bash install_psiphon_autopin.sh --instance 2 --region DE
sudo bash install_psiphon_autopin.sh --impersonate --no-http
```

Instance 1 uses SOCKS `127.0.0.1:40000 → 1080` inside Docker and HTTP `40001 → 8080`. Instance 2 defaults to ports 40002/40003. The address defaults to loopback; `--bind` accepts an existing private IPv4 address for bridge-container access. Public bindings are rejected.

Fresh-install defaults: one tunnel, 300-second checks, Gemini enabled, 800 KiB/s floor, two consecutive slow samples and a 4 MiB throughput sample. Existing saved options are retained unless overridden. `--min-speed 0` disables speed-based rotation. At `--probe-mb 0` an enabled speed floor measures a page instead of an extra download. A 4 MiB sample every five minutes costs roughly 34 GiB/month before search traffic.

## Commands

```bash
psiphon-autopin status
psiphon-autopin check
psiphon-autopin rotate
psiphon-autopin region NL
psiphon-autopin pool NL,DE,PL
psiphon-autopin pool ''
psiphon-autopin speed
psiphon-autopin logs 80
psiphon-autopin stop
psiphon-autopin start
psiphon-autopin restart
psiphon-autopin xray
psiphon-autopin-2 uninstall
```

Use `psiphon-autopin-N` for instance N. The `vps-psiphon[-N]` aliases invoke the same manager. `uninstall` removes only that instance, retaining migration backups under `/var/backups/psiphon-autopin` and images referenced by other containers.

`check` returns 0 for an accepted observation, 2 for a refusal/denied country/low speed/strict-region mismatch, and 1 for a probe error. Gemini `INCONCLUSIVE` is neither a successful model reply nor a rotation reason by itself. `SERVING` describes the anonymous probe, not an authenticated browser account.

Technical commands are still supported:

```bash
psiphon-autopin refresh-cache --allow-interruption
psiphon-autopin prepare-pin
psiphon-autopin search
```

Cache refresh interrupts the connection. A prepared pin is only promoted after a new container start confirms the IP and diagnostic ID. Ctrl+C stops a long search and resumes a previously active monitor.

## Options

| Flag | Meaning |
|---|---|
| `--region NL` / `--region NL,DE` | Country or pool; AUTO removes the restriction |
| `--region-pool NL,DE` | Explicit country pool |
| `--menu` / `--interactive` | Open the terminal wizard; optional `--instance N` |
| `--connection socks5\|xray` | Persist the connection output format |
| `--menu-mode easy\|advanced` | Persist the menu mode |
| `--instance N` | Independent instance 1–99 |
| `--port N` | Host SOCKS port; HTTP uses port+1 |
| `--bind ADDR` / `--bind-loopback` | Private IPv4 address / default 127.0.0.1 |
| `--no-http` / `--http` | Disable / enable HTTP publication |
| `--interval N`, `--wait N`, `--delay N` | Check period, readiness deadline and attempt delay |
| `--probe-mb N` | 0–10 MiB per throughput sample |
| `--min-speed N` | KiB/s floor; 0 disables it |
| `--slow-threshold N` | 2–20 consecutive slow samples |
| `--fail-threshold N` | 2–20 failures before recovery |
| `--deny-regions 'CC CC ...'` | Default RU BY IR SY CU KP CN VE; an empty string disables |
| `--gemini-check` / `--no-gemini-check` | Enable / disable Gemini probe |
| `--impersonate` / `--no-impersonate` | Browser TLS for CAPTCHA checks |
| `--strict-region` | Require Google country to match the requested country |
| `--tunnel-pool N` | 1 uses PIN; 2–32 samples multiple tunnels without a single-IP PIN claim |
| `--backend auto\|console\|vps-psiphon` | Preserve/detect an existing backend or select one |

Xray running in a bridge container cannot reach host loopback. Use host networking or an existing private host IPv4 via `--bind`; `xray` prints outbound JSON without changing your panel. The proxy is TCP-oriented.

IP, country, Gemini and throughput checks use SOCKS with remote DNS and no direct fallback. Installation downloads may use the VPS connection. Unknown classifications remain unknown. Switching servers can interrupt sessions, and neither a country, an unchanged exit IP nor service access is guaranteed. WARP is not removed automatically.

## Initial PIN and dependency-aware uninstall

Single-tunnel mode now creates its missing cache automatically. The datastore is exported only while Psiphon is stopped; the current server's unique entry is applied before startup. A new container start, matching diagnostic ID, stable exit and current policies are verified before reporting `INITIAL PIN VERIFIED`. Failure restores the original target/state and reconnects; retries are bounded by the normal check period. Verified targets and multi-tunnel pools are not repeatedly re-pinned. Manual `prepare-pin` stays deferred.

A server may provide a different public exit IP after reconnecting; the recorded state reflects the verified new connection. Gemini `INCONCLUSIVE` is allowed by the existing policy and remains explicitly inconclusive even when the server PIN is verified.

```bash
sudo psiphon-autopin uninstall                 # instance only
sudo psiphon-autopin uninstall --purge-deps    # instance + eligible owned Docker/Go
sudo psiphon-autopin-2 uninstall --purge-deps  # selected instance
```

The operational menu includes the latter as item 14. A private receipt at `/var/lib/psiphon-autopin-system/dependencies.json` records packages first installed by Auto-Pin 4.2. Ownership is tracked per component. Preexisting or unknown-origin dependencies are retained, including legacy installations without receipts. Other Auto-Pin instances retain both components; other running/stopped containers or unknown Docker usage retain Docker. APT simulation blocks removal of packages outside the receipt. Installation and cleanup share a process lock.

No autoremove, arbitrary Docker-data deletion or manual `/usr/local/go` deletion is performed. Python, curl, GCC and unrelated tools are kept. Plain uninstall relinquishes ownership when the final instance is removed and leaves dependencies installed. Migration backups remain. If package removal fails, the command reports an error and keeps the receipt; retry from downloaded sources with `sudo python3 autopin_system.py cleanup --purge` after fixing APT.

## Checks and attribution

```bash
python3 -m unittest discover -s tests -v
bash -n install_psiphon_autopin.sh
```

Tests enforce that the standalone manager/probe match their embedded installer copies. The installer remains a standalone curl-to-bash file.

Uses [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core), [psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker), [bbolt](https://github.com/etcd-io/bbolt) and optionally [curl-impersonate](https://github.com/lexiforest/curl-impersonate). Operational approaches were studied in [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon); its installer/watchdog is not used. [GPL-3.0](LICENSE).
