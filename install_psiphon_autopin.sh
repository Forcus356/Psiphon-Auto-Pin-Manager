#!/usr/bin/env bash
# Forcus Psiphon Auto-Pin Manager v3.4.1
# Author: https://github.com/Forcus356
# Ubuntu/Debian x86_64
set -Eeuo pipefail
trap 'echo "[ERROR] Line $LINENO; journalctl -u psiphon-autopin -n 80 --no-pager" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || { echo 'Ubuntu/Debian only' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'x86_64 only' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
ROOT=/opt/vps-psiphon; CONF="$ROOT/config"; APP=/opt/psiphon-autopin
DATA=/var/lib/psiphon-autopin; CONTAINER=vps-psiphon
REGION=''; INTERVAL=3600; WAIT=75; DELAY=12; SOCKS_PORT=''
GEMINI_CHECK=0; PROBE_MB=0; FAIL_THRESHOLD=3; STRICT_REGION=0
PORT_EXPLICIT=0
while (($#)); do
    case "$1" in
        --region) REGION=${2:?Missing region}; shift 2 ;;
        --port) SOCKS_PORT=${2:?Missing port}; PORT_EXPLICIT=1; shift 2 ;;
        --interval) INTERVAL=${2:?Missing interval}; shift 2 ;;
        --wait) WAIT=${2:?Missing wait}; shift 2 ;;
        --delay) DELAY=${2:?Missing delay}; shift 2 ;;
        --gemini-check) GEMINI_CHECK=1; shift ;;
        --no-gemini-check) GEMINI_CHECK=0; shift ;;
        --strict-region) STRICT_REGION=1; shift ;;
        --probe-mb) PROBE_MB=${2:?Missing MB}; shift 2 ;;
        --fail-threshold) FAIL_THRESHOLD=${2:?Missing threshold}; shift 2 ;;
        --help) echo 'Usage: install_psiphon_autopin.sh [--region DE|AUTO] [--port 40000] [--interval 3600] [--wait 75] [--delay 12] [--gemini-check] [--probe-mb 0..10] [--strict-region] [--fail-threshold 3]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -z $REGION ]]; then
    if [[ -r /dev/tty ]]; then
        read -r -p 'Psiphon country [DE] (or AUTO): ' REGION </dev/tty
        REGION=${REGION:-DE}
    else
        echo 'Noninteractive install: specify --region DE' >&2; exit 2
    fi
fi
# On interactive installs, ask for a SOCKS5 port, with Enter accepting 40000.
# The /dev/tty input works even with curl | sudo bash.
if [[ -z $SOCKS_PORT ]]; then
    if [[ -r /dev/tty ]]; then
        read -r -p 'SOCKS5 port [40000]: ' SOCKS_PORT </dev/tty
        SOCKS_PORT=${SOCKS_PORT:-40000}
    else
        SOCKS_PORT=40000
    fi
fi
[[ $SOCKS_PORT =~ ^[0-9]+$ ]] || { echo 'Port must be numeric' >&2; exit 2; }
SOCKS_PORT=$((10#$SOCKS_PORT))
(( SOCKS_PORT >= 1024 && SOCKS_PORT <= 65534 )) || {
    echo 'Choose SOCKS5 port 1024..65534 (HTTP uses port+1)' >&2; exit 2;
}
HTTP_PORT=$((SOCKS_PORT + 1))
REGION=${REGION^^}
[[ $REGION == AUTO || $REGION =~ ^[A-Z]{2}$ ]] || { echo 'Invalid country' >&2; exit 2; }
[[ $INTERVAL =~ ^[0-9]+$ && $WAIT =~ ^[0-9]+$ && $DELAY =~ ^[0-9]+$ ]] || exit 2
[[ $PROBE_MB =~ ^[0-9]+$ && $FAIL_THRESHOLD =~ ^[0-9]+$ ]] || { echo 'Invalid probe size or failure threshold' >&2; exit 2; }
(( PROBE_MB <= 10 && FAIL_THRESHOLD >= 2 && FAIL_THRESHOLD <= 20 )) || { echo 'Require --probe-mb 0..10, --fail-threshold 2..20' >&2; exit 2; }
(( INTERVAL >= 60 && WAIT >= 20 && DELAY >= 2 )) || { echo 'Require interval>=60, wait>=20, delay>=2' >&2; exit 2; }
[[ $REGION == AUTO ]] && REGION=''
mkdir -p "$ROOT" "$CONF" "$APP" "$DATA"
chmod 700 "$DATA"
echo "[INFO] Region=${REGION:-AUTO}; SOCKS5=127.0.0.1:$SOCKS_PORT; manager v3.4.1"

# Stop old writer before updating executable/config. This does not stop the VPN container.
systemctl stop psiphon-autopin.service 2>/dev/null || true

# Install only missing packages. Never replace Docker CE with Ubuntu docker.io.
PACKAGES=()
command -v curl >/dev/null 2>&1 || PACKAGES+=(curl)
command -v jq >/dev/null 2>&1 || PACKAGES+=(jq)
command -v python3 >/dev/null 2>&1 || PACKAGES+=(python3)
command -v column >/dev/null 2>&1 || PACKAGES+=(bsdextrautils)
command -v go >/dev/null 2>&1 || PACKAGES+=(golang-go)
command -v ss >/dev/null 2>&1 || PACKAGES+=(iproute2)
if ((${#PACKAGES[@]})); then
    apt-get update
    apt-get install -y ca-certificates "${PACKAGES[@]}"
fi
if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    if apt-cache show docker-ce 2>/dev/null | grep -q '^Package: docker-ce$'; then
        apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        apt-get install -y docker.io
    fi
else
    echo "[OK] Using existing $(docker --version)"
fi
systemctl enable --now docker
if ! docker info >/dev/null 2>&1; then
    echo '[ERROR] Docker daemon not responding' >&2; exit 1
fi
