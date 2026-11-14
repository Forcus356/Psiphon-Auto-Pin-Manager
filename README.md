# Forcus Psiphon Auto-Pin Manager 4.0

Our Psiphon manager with local SOCKS5, verified server pinning, Google/Gemini checks and automatic recovery. Operational features studied in Chara are implemented in our own Python monitor. There is no Chara installer or second watchdog at runtime.

[Полная инструкция на русском](README.ru_RU.md)

## Features

- Minimum throughput with consecutive low-speed confirmation; transfer rate excludes time before the first byte.
- Country pools, persistent rotation and preference for previously verified servers still present in the current datastore.
- Up to 99 independent instances, each with its own ports, config, datastore, lock and services.
- Optional browser TLS profile for CAPTCHA detection; a parallel HTTP/2 transfer keeps anonymous Gemini generation active.
- Denied countries, fast Google-country checks and recovery after transport failures.
- Local CLI for status, checks, rotation, regions, country pools, speed, service lifecycle, logs and instance uninstall.
- Optional SOCKS-only publication, private IPv4 binding, Xray outbound output and pools of 2–32 simultaneous tunnels.
- Original TargetServerEntry selection, diagnostic-ID verification and deferred PIN preparation remain available with one tunnel.

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

## Checks and attribution

```bash
python3 -m unittest discover -s tests -v
bash -n install_psiphon_autopin.sh
```

Tests enforce that the standalone manager/probe match their embedded installer copies. The installer remains a standalone curl-to-bash file.

Uses [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core), [psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker), [bbolt](https://github.com/etcd-io/bbolt) and optionally [curl-impersonate](https://github.com/lexiforest/curl-impersonate). Operational approaches were studied in [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon); its installer/watchdog is not used. [GPL-3.0](LICENSE).
