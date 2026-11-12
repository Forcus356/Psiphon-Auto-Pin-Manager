<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**Automatic Psiphon server rotation and Google-region-aware egress pinning**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) ![Arch](https://img.shields.io/badge/arch-x86__64-lightgrey) [![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

A lightweight Linux installer and systemd monitor for **Psiphon Tunnel Core**. It selects individual Psiphon servers, checks the public exit IP and Google country **through the local SOCKS5h tunnel**, and keeps a verified non-RU exit pinned. If the exit is subsequently classified as RU, it searches again.

## ✨ Features

- Controlled server selection using `TargetServerEntry` (not just transport changes)
- Read-only BoltDB server inventory and server-by-server attempts
- SOCKS5h-based exit IP and Google region checks, with no direct fallback for those checks
- Verification before saving the pin; hourly monitoring and automatic recovery
- Configurable egress country, local SOCKS5 port, and retry intervals
- Works with existing Docker CE or Ubuntu `docker.io` (does not intentionally replace a working Docker installation)

## 📋 Requirements

Ubuntu or Debian **x86_64**, root access, systemd, outbound internet connectivity, and enough space for Docker and Go. Other platforms are not supported by the installer. The installer fetches external scripts and images; review the source before running it as root. Confirm that your hosting provider permits proxy/VPN software.

## 🚀 Quick start

Choose a country and local port interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### Non-interactive examples

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ Installer options

| Option | Default | Description |
|---|---|---|
| `--region DE` | Prompt; `[DE]` | Choose Psiphon egress country (ISO 3166-1 alpha-2, such as `DE`, `PL`, `NL`). `AUTO` does not restrict the country. |
| `--port 40000` | Prompt; `40000` | Local SOCKS5 listening port, range **1024–65534**. The HTTP proxy uses port + 1. |
| `--interval 3600` | `3600` | Monitoring interval in seconds; minimum **60**. |
| `--wait 75` | `75` | Seconds allowed for Psiphon to become ready; minimum **20**. |
| `--delay 12` | `12` | Delay between server attempts in seconds; minimum **2**. |
| `--help` | — | Display installer usage. |

## 🧰 Manager commands

The installer creates `/opt/psiphon-autopin/psiphon_autopin.py`. Its positional commands are `status`, `check`, `search`, and `monitor`.

| Command | Description |
|---|---|
| `status` | Show configured region, SOCKS proxy and stored pin information; does not connect. |
| `check` | Probe current exit IP and Google country via Psiphon SOCKS5h. Exit code `0` for non-RU, `2` for RU; failures return `1`. |
| `search` | Run a server-by-server search until a verified non-RU exit is found. Stop the systemd monitor first to avoid the lock conflict. |
| `monitor` | Run the continuous monitor (normally managed by systemd); defaults: interval 3600, wait 75, delay 12. |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

### Manager options

The manager also supports `--region`, `--port`, `--interval`, `--wait`, and `--delay`. Defaults for `--region` and `--port` come from the saved installation settings.

## 🛠️ Service and diagnostics

| Action | Command |
|---|---|
| Live logs | `journalctl -u psiphon-autopin -f` |
| Recent logs | `journalctl -u psiphon-autopin -n 80 --no-pager` |
| Service status | `systemctl status psiphon-autopin --no-pager` |
| Restart monitoring | `systemctl restart psiphon-autopin` |
| Stop monitoring | `systemctl stop psiphon-autopin` |
| Enable monitoring | `systemctl enable --now psiphon-autopin` |
| Start monitoring | `systemctl start psiphon-autopin` |
| Psiphon container logs | `docker logs --tail 80 vps-psiphon` |
| Show container | `docker ps -a --filter name=vps-psiphon` |

## 📌 Useful examples

```bash
# Check the exit strictly through Psiphon SOCKS5h
curl -4 -fsS --max-time 15 --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search (stop the monitor to release its lock)
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin

# Stop/start the monitor (does not stop the Psiphon container)
systemctl stop psiphon-autopin
systemctl start psiphon-autopin
```

## 🔄 How it works

On first installation, Psiphon connects and populates its local server datastore. The monitor reads known server entries via a Go/BoltDB exporter, picks a specific server, sets `TargetServerEntry`, restarts the container, then checks the actual outgoing IPv4 and Google classification using SOCKS5h. A suitable exit is checked again and saved. It is periodically rechecked; only an RU result confirmed twice triggers rotation. A temporary probe failure is not treated as RU.

## ⚠️ Important notes

- **`--region PL` does not require `Google=PL`.** Current acceptance criterion is `Google != RU`.
- **Server IP is not necessarily the exit IP.** The monitor classifies the exit seen via SOCKS5h.
- **Local-only listeners:** SOCKS5 binds to `127.0.0.1:<port>` and the HTTP proxy uses `<port+1>`. Do not expose them publicly.
- **IP checks use the proxy.** Installer dependency downloads, Docker pulls and bootstrap network traffic can use the VPS direct connection.
- Switching servers interrupts existing connections. No particular region, IP, or service access is guaranteed.
- `search` and `monitor` use an exclusive lock. Do not run both at once.
- When changing ports or region, rerun the installer with the appropriate flags. It may restart Psiphon and invalidate the old pin.
- Do not run this on a host whose policy prohibits proxies or VPNs.

## 🩺 Troubleshooting

| Error | Resolution |
|---|---|
| `containerd.io : Conflicts: containerd` | Usually means Docker CE and the Ubuntu `docker.io` package were mixed. The v3.3 installer checks for an existing Docker command first. Avoid blindly removing Docker or containerd; inspect the installation. |
| `Config exists but container missing` | An existing or partially installed `/opt/vps-psiphon/config/psiphon.config` was found. Back it up and identify its owner before moving it; the installer intentionally refuses to overwrite it. |
| `SOCKS/HTTP port ... occupied` | The chosen SOCKS port or the following HTTP port is in use. Inspect with `ss -lntp` and select another `--port`. |
| `No known servers in region` | Psiphon may not yet have populated its BoltDB datastore, or that region has no known entries. Check Docker logs and outbound access. |
| `Another search/monitor is running` | Stop `psiphon-autopin.service` before running `search` manually. |

## 📂 Installed paths

| Path | Purpose |
|---|---|
| `/opt/vps-psiphon/config/psiphon.config` | Psiphon configuration |
| `/opt/psiphon-autopin/psiphon_autopin.py` | Manager |
| `/opt/psiphon-autopin/psiphon-server-export` | Read-only BoltDB exporter |
| `/opt/psiphon-autopin/ipregion.sh` | Google/service region detector |
| `/var/lib/psiphon-autopin/settings.json` | Saved region and port |
| `/var/lib/psiphon-autopin/state.json` | Last verified pin |
| `/etc/systemd/system/psiphon-autopin.service` | systemd unit |

## 📄 License and credits

Released under [GPL-3.0](LICENSE). Project by [Forcus356](https://github.com/Forcus356). Uses [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core), [ipregion](https://github.com/Davoyan/ipregion) and [bbolt](https://github.com/etcd-io/bbolt). This project is independent and is not an official Psiphon product.
