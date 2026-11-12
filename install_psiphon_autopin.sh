
#!/usr/bin/env bash
# Forcus Psiphon Auto-Pin Manager
# Ubuntu/Debian x86_64
set -Eeuo pipefail

trap 'echo "[ERROR] line $LINENO. Check journalctl -u psiphon-autopin.service -n 80" >&2' ERR

[[ $EUID -eq 0 ]] || {
    echo 'Run as root' >&2
    exit 1
}

. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) echo 'Ubuntu/Debian only' >&2; exit 1 ;;
esac

[[ $(uname -m) == x86_64 ]] || {
    echo 'Currently x86_64 only' >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive

ROOT=/opt/vps-psiphon
CONF=$ROOT/config
APP=/opt/psiphon-autopin
DATA=/var/lib/psiphon-autopin
CONTAINER=vps-psiphon
REGION=''

while (($#)); do
    case "$1" in
        --region)
            REGION=${2:?Missing country}
            shift 2
            ;;
        --help)
            echo 'Usage: install_psiphon_autopin.sh [--region DE|SE|NL|AUTO]'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z $REGION ]]; then
    echo 'Psiphon egress country (DE, SE, NL, PL, LT ... or AUTO):'
    if [[ -r /dev/tty ]]; then
        read -r -p 'Country [DE]: ' REGION </dev/tty
    else
        echo 'Non-interactive install: use --region DE' >&2
        exit 2
    fi
    REGION=${REGION:-DE}
fi

REGION=${REGION^^}

[[ $REGION == AUTO || $REGION =~ ^[A-Z]{2}$ ]] || {
    echo 'Invalid ISO country code' >&2
    exit 2
}

[[ $REGION == AUTO ]] && REGION=''

echo "[INFO] Selected Psiphon region: ${REGION:-AUTO}"

mkdir -p "$APP" "$DATA" "$CONF"

# Install dependencies if missing.
if ! command -v docker >/dev/null ||
   ! command -v curl >/dev/null ||
   ! command -v jq >/dev/null ||
   ! command -v python3 >/dev/null ||
   ! command -v column >/dev/null; then

    apt-get update
    apt-get install -y \
        ca-certificates curl python3 jq \
        util-linux bsdextrautils docker.io
fi

systemctl enable --now docker

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    echo '[INFO] Existing Psiphon found. Preserving container.'

    [[ -f "$CONF/psiphon.config" ]] || {
        echo "[ERROR] Configuration not found at $CONF" >&2
        docker inspect "$CONTAINER" --format '{{json .Mounts}}' >&2
        exit 2
    }

    docker start "$CONTAINER" >/dev/null || true
else
    [[ ! -f "$CONF/psiphon.config" ]] || {
        echo '[ERROR] Existing config without expected container.' >&2
        exit 2
    }

    if ss -ltnH 2>/dev/null |
       awk '{print $4}' |
       grep -Eq '(^|:)40000$'; then
        echo '[ERROR] Port 40000 is already in use.' >&2
        exit 2
    fi

    echo '[INFO] Installing Psiphon...'

    docker pull swarupsengupta2007/psiphon:latest

    docker run --rm \
        --entrypoint cat \
        swarupsengupta2007/psiphon:latest \
        /etc/psiphon/psiphon.config \
        > "$CONF/psiphon.config"

    chmod 600 "$CONF/psiphon.config"

    python3 - "$CONF/psiphon.config" "$REGION" <<'PYSET'
import json
import sys

path, region = sys.argv[1:]

with open(path) as f:
    config = json.load(f)

config.update({
    'EgressRegion': region,
    'LocalSocksProxyPort': 40000,
    'LocalSocksProxyListenAddress': '127.0.0.1',
    'LocalHttpProxyPort': 40001,
    'LocalHttpProxyListenAddress': '127.0.0.1',
    'TunnelPoolSize': 1,
    'EmitDiagnosticNotices': True
})

with open(path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYSET

    TREE=$(mktemp)

    curl -fLsS --retry 3 \
        'https://api.github.com/repos/Psiphon-Labs/psiphon-tunnel-core-binaries/git/trees/master?recursive=1' \
        -o "$TREE"

    BINARY_PATH=$(python3 - "$TREE" <<'PYBIN'
import json
import sys

with open(sys.argv[1]) as f:
    tree = json.load(f)['tree']

matches = [
    x['path'] for x in tree
    if x['type'] == 'blob'
    and x['path'].startswith('linux/')
    and (
        'amd64' in x['path'].lower()
        or 'x86_64' in x['path'].lower()
    )
    and (
        'consoleclient' in x['path'].lower()
        or 'psiphon-tunnel-core' in x['path'].lower()
    )
]

if len(matches) != 1:
    sys.exit('Cannot identify official binary: ' + repr(matches))

print(matches[0])
PYBIN
)

    rm -f "$TREE"

    curl -fLsS --retry 3 \
        "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/$BINARY_PATH" \
        -o "$ROOT/ConsoleClient"

    chmod 755 "$ROOT/ConsoleClient"

    cat > "$ROOT/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY ConsoleClient /usr/local/bin/ConsoleClient
WORKDIR /config
CMD ["/usr/local/bin/ConsoleClient", "-config", "/config/psiphon.config", "-dataRootDirectory", "/config"]
DOCKERFILE

    docker build -t local-psiphon-console:latest "$ROOT"

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network host \
        -v "$CONF:/config" \
        local-psiphon-console:latest >/dev/null

    echo '[OK] Psiphon container created.'
fi

# Repair missing bootstrap parameters only if proxy is not working.
if ! curl -4 -fsS --max-time 12 \
    --proxy socks5h://127.0.0.1:40000 \
    https://api.ipify.org >/dev/null 2>&1; then

    echo '[INFO] Checking Psiphon bootstrap configuration...'

    docker pull swarupsengupta2007/psiphon:latest

    TEMPLATE=$(mktemp)

    docker run --rm \
        --entrypoint cat \
        swarupsengupta2007/psiphon:latest \
        /etc/psiphon/psiphon.config > "$TEMPLATE"

    python3 - "$CONF/psiphon.config" "$TEMPLATE" <<'PYMERGE'
import datetime
import json
import shutil
import sys

path, template_path = sys.argv[1:]

with open(path) as f:
    current = json.load(f)

with open(template_path) as f:
    template = json.load(f)

keys = [
    'RemoteServerListURLs',
    'RemoteServerListSignaturePublicKey',
    'ObfuscatedServerListRootURLs',
    'ObfuscatedServerListSignaturePublicKey',
    'ServerEntrySignaturePublicKey',
    'SponsorId',
    'PropagationChannelId'
]

missing = [
    key for key in keys
    if not current.get(key) and template.get(key)
]

if missing:
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    shutil.copy2(path, path + '.before-bootstrap-' + stamp)

    for key in missing:
        current[key] = template[key]

    with open(path, 'w') as f:
        json.dump(current, f, indent=2)
        f.write('\n')

    print('[INFO] Added bootstrap keys:', ', '.join(missing))
else:
    print('[INFO] No missing bootstrap keys')
PYMERGE

    rm -f "$TEMPLATE"
    docker restart "$CONTAINER" >/dev/null
else
    echo '[OK] Existing SOCKS5 tunnel is responding.'
fi

# Install Google region detector.
if [[ ! -s "$APP/ipregion.sh" ]]; then
    curl -fLsS --retry 3 \
        https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh \
        -o "$APP/ipregion.sh"
fi

chmod 755 "$APP/ipregion.sh"

# Embedded Python manager.
cat > "$APP/psiphon_autopin.py" <<'AUTOPIN_MANAGER_SOURCE'
#!/usr/bin/env python3
"""Psiphon Auto-Pin Manager."""

import argparse
import datetime as dt
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

BASE = Path('/opt/psiphon-autopin')
STATE_DIR = Path('/var/lib/psiphon-autopin')
CONFIG = Path('/opt/vps-psiphon/config/psiphon.config')

CONTAINER = 'vps-psiphon'
PROXY = '127.0.0.1:40000'
IPREGION = BASE / 'ipregion.sh'


def log(message):
    timestamp = (
        dt.datetime.now(dt.timezone.utc)
        .astimezone()
        .isoformat(timespec='seconds')
    )
    print(timestamp, message, flush=True)


def run(args, timeout=40, check=True, merge=False):
    process = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if merge else subprocess.PIPE,
        text=True,
        timeout=timeout
    )

    if check and process.returncode:
        error = process.stdout if merge else process.stderr
        raise RuntimeError(
            f'{args[0]} exited {process.returncode}: {error[-600:]}'
        )

    return process.stdout


def read_json(path, fallback=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return fallback


def write_json_atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    stat = path.stat() if path.exists() else None
    tmp = None

    try:
        with tempfile.NamedTemporaryFile(
            'w',
            encoding='utf8',
            dir=path.parent,
            prefix='.autopin-',
            delete=False
        ) as f:
            tmp = f.name
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())

        if stat:
            os.chown(tmp, stat.st_uid, stat.st_gid)
            os.chmod(tmp, stat.st_mode & 0o777)
        else:
            os.chmod(tmp, 0o600)

        os.replace(tmp, path)

    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def update_config(changes):
    if not CONFIG.is_file():
        raise RuntimeError(f'Missing config: {CONFIG}')

    old = read_json(CONFIG)

    if not isinstance(old, dict):
        raise RuntimeError('Psiphon config is not valid JSON')

    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup = CONFIG.with_name(
        CONFIG.name + '.autopin-backup-' + stamp
    )

    shutil.copy2(CONFIG, backup)

    new = dict(old)
    new.update(changes)
    write_json_atomic(CONFIG, new)

    log(f'Config backed up: {backup}')
    return backup


def restore_config(backup):
    if backup and Path(backup).is_file():
        shutil.copy2(backup, CONFIG)
        log(f'Restored previous config: {backup}')


def get_ip():
    value = run([
        'curl', '-4', '-fsS',
        '--max-time', '12',
        '--proxy', f'socks5h://{PROXY}',
        'https://api.ipify.org'
    ], timeout=16).strip()

    if ipaddress.ip_address(value).version != 4:
        raise RuntimeError('Expected IPv4 exit')

    return value


def google_region():
    if not IPREGION.is_file():
        raise RuntimeError(f'Missing {IPREGION}')

    result = run([
        'bash', str(IPREGION),
        '--proxy', PROXY,
        '--ipv4',
        '--group', 'custom',
        '--json'
    ], timeout=210)

    report = json.loads(result)
    rows = report.get('results', {}).get('custom', [])

    values = [
        str(row.get('ipv4', '')).strip().upper()
        for row in rows
        if row.get('service') == 'Google'
    ]

    if len(values) != 1 or not re.fullmatch(r'[A-Z]{2}', values[0]):
        raise RuntimeError(f'Google country UNKNOWN: {values}')

    return values[0]


def probe():
    before = get_ip()
    region = google_region()
    after = get_ip()

    if before != after:
        raise RuntimeError(
            f'Exit changed during check: {before} -> {after}'
        )

    log(f'Exit={after}, Google={region}')
    return after, region


def docker_started_at():
    return run([
        'docker', 'inspect',
        '-f', '{{.State.StartedAt}}',
        CONTAINER
    ]).strip()


def live_diagnostic():
    logs = run([
        'docker', 'logs',
        '--since', docker_started_at(),
        CONTAINER
    ], timeout=30, merge=True)

    connected = None
    timestamp = None

    for line in logs.splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        kind = obj.get('noticeType')
        data = obj.get('data') or {}

        if kind == 'ConnectedServer':
            connected = data.get('diagnosticID')
        elif kind == 'ServerTimestamp':
            timestamp = data.get('diagnosticID')

    if not connected or connected != timestamp:
        raise RuntimeError(
            f'Current server ID ambiguous '
            f'(Connected={connected}, Timestamp={timestamp})'
        )

    if not re.fullmatch(r'[A-Za-z0-9+/]{8}', connected):
        raise RuntimeError('Invalid diagnosticID')

    return connected


def find_datastore():
    root = CONFIG.parent

    exact = (
        root /
        'ca.psiphon.PsiphonTunnel.tunnel-core/datastore/psiphon.boltdb'
    )

    if exact.is_file():
        return exact

    matches = list(root.glob('**/psiphon.boltdb'))

    if len(matches) != 1:
        raise RuntimeError(
            f'Expected one BoltDB in {root}, found {len(matches)}'
        )

    return matches[0]


def server_entry(diagnostic, region):
    raw = (
        find_datastore()
        .read_bytes()
        .decode('utf-8', errors='replace')
    )

    decoder = json.JSONDecoder()
    matches = []

    for match in re.finditer(r'\{', raw):
        try:
            entry, end = decoder.raw_decode(raw, match.start())
        except (ValueError, RecursionError):
            continue

        if not isinstance(entry, dict):
            continue

        if not str(entry.get('tag', '')).startswith(diagnostic):
            continue

        if not entry.get('ipAddress') or not entry.get('capabilities'):
            continue

        if '\ufffd' in raw[match.start():end]:
            continue

        if region and entry.get('region') != region:
            continue

        matches.append(entry)

    if not matches or len({
        value['ipAddress'] for value in matches
    }) != 1:
        raise RuntimeError(
            f'Server entry missing or ambiguous: {len(matches)}'
        )

    return max(
        matches,
        key=lambda value: int(
            value.get('configurationVersion', 0)
        )
    )


def restart(wait_seconds):
    run(['docker', 'restart', CONTAINER], timeout=90)

    deadline = time.monotonic() + wait_seconds

    while time.monotonic() < deadline:
        try:
            return get_ip()
        except Exception:
            time.sleep(2)

    raise RuntimeError(
        f'Psiphon not ready after {wait_seconds}s'
    )


def pin_current(ip, geo, region, wait_seconds):
    diagnostic = live_diagnostic()
    entry = server_entry(diagnostic, region)

    target = (
        '0 0 0 0 ' +
        json.dumps(entry, separators=(',', ':'))
    ).encode().hex()

    before = update_config({
        'TargetServerEntry': target,
        'TunnelPoolSize': 1,
        'EgressRegion': region,
        'DisableTactics': True,
        'InitialLimitTunnelProtocols': [],
        'InitialLimitTunnelProtocolsCandidateCount': 0,
        'EmitDiagnosticNotices': True,
        'EmitDiagnosticNetworkParameters': False
    })

    log(
        f'Pinning diagnosticID={diagnostic}, '
        f'server={entry["ipAddress"]}, exit={ip}'
    )

    try:
        restart(wait_seconds)
        new_ip, new_geo = probe()

        if new_ip != ip or new_geo != geo:
            raise RuntimeError(
                f'Pin verification failed: '
                f'{new_ip} Google={new_geo}, '
                f'expected {ip} {geo}'
            )

        write_json_atomic(
            STATE_DIR / 'state.json',
            {
                'ip': ip,
                'google_region': geo,
                'region': region,
                'verified_at': (
                    dt.datetime.now(dt.timezone.utc).isoformat()
                ),
                'diagnostic_id': diagnostic
            }
        )

        log(f'PIN VERIFIED: {ip}, Google={geo}')
        return True

    except Exception:
        restore_config(before)

        try:
            restart(wait_seconds)
        except Exception as error:
            log(f'Warning: recovery restart failed: {error}')

        raise


def search(region, wait, delay, rotate_first=False):
    log(
        f'Search indefinitely for region={region or "AUTO"}'
    )

    cfg = read_json(CONFIG)

    if not isinstance(cfg, dict):
        raise RuntimeError('Psiphon config missing or invalid')

    seen = set()
    count = 0
    same = 0
    last = None
    needs_restart = rotate_first

    while True:
        count += 1

        if needs_restart:
            log(f'Attempt {count}: rotating Psiphon')

            try:
                restart(wait)
            except Exception as error:
                log(f'Restart/readiness problem: {error}')
                time.sleep(delay)
                continue
        else:
            log(f'Attempt {count}: checking current tunnel first')

        needs_restart = True

        try:
            ip = get_ip()
        except Exception as error:
            log(f'No exit: {error}')
            time.sleep(delay)
            continue

        if ip == last:
            same += 1
        else:
            same = 0

        last = ip

        if ip in seen:
            log(
                f'Exit {ip} already checked; '
                f'repeating (same streak={same})'
            )

            time.sleep(
                min(300, delay * (1 + same // 4))
            )
            continue

        try:
            geo = google_region()

            if get_ip() != ip:
                raise RuntimeError(
                    'Exit changed during geo test'
                )

        except Exception as error:
            log(f'Google check UNKNOWN for {ip}: {error}')
            time.sleep(delay)
            continue

        log(f'Exit {ip}, Google={geo}')
        seen.add(ip)

        if geo == 'RU':
            current = read_json(CONFIG) or {}

            if current.get('TargetServerEntry'):
                update_config({
                    'TargetServerEntry': '',
                    'DisableTactics': False,
                    'EgressRegion': region
                })

            continue

        try:
            if pin_current(ip, geo, region, wait):
                return True
        except Exception as error:
            log(f'Pin failed: {error}; seeking another candidate')
            time.sleep(delay)


def monitor(region, interval, wait, delay):
    log(
        f'Monitor active: check every {interval}s, '
        f'Psiphon region={region or "AUTO"}'
    )

    while True:
        try:
            ip, geo = probe()

            state = (
                read_json(
                    STATE_DIR / 'state.json', {}
                ) or {}
            )

            if geo == 'RU':
                log('Google=RU; confirming before rotation')
                time.sleep(15)

                ip2, geo2 = probe()

                if geo2 == 'RU':
                    log(
                        f'Confirmed RU on {ip2}; '
                        'searching until success'
                    )
                    search(region, wait, delay)

            elif state.get('ip') and ip != state['ip']:
                log(
                    f'Exit changed {state["ip"]} -> {ip}'
                )

                try:
                    pin_current(ip, geo, region, wait)
                except Exception as error:
                    log(
                        f'Could not pin changed exit: {error}'
                    )
                    search(region, wait, delay)

            elif not state.get('ip'):
                log('No verified pin state; searching for pin')
                search(region, wait, delay)

            else:
                log('Healthy; no change needed')

        except Exception as error:
            log(
                f'CHECK UNKNOWN / outage: {error} '
                '(do not classify as RU)'
            )

            state = (
                read_json(
                    STATE_DIR / 'state.json', {}
                ) or {}
            )

            if not state.get('ip'):
                log(
                    'No verified pinned exit: '
                    'searching/recovering'
                )
                search(region, wait, delay)

        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(
        description='Psiphon Auto-Pin Manager'
    )

    parser.add_argument(
        'command',
        choices=['check', 'search', 'monitor', 'status']
    )

    parser.add_argument('--region', default=None)
    parser.add_argument('--interval', type=int, default=3600)
    parser.add_argument('--wait', type=int, default=60)
    parser.add_argument('--delay', type=int, default=12)

    args = parser.parse_args()

    settings = (
        read_json(
            STATE_DIR / 'settings.json', {}
        ) or {}
    )

    region = (
        args.region
        if args.region is not None
        else settings.get('region', '')
    ).upper()

    if region == 'AUTO':
        region = ''

    if region and not re.fullmatch('[A-Z]{2}', region):
        parser.error('invalid --region')

    if args.interval < 60 or args.wait < 10 or args.delay < 2:
        parser.error(
            'interval >= 60, wait >= 10, delay >= 2 required'
        )

    if args.command == 'status':
        print(
            json.dumps(
                {
                    'config': str(CONFIG),
                    'region': region,
                    'state': read_json(
                        STATE_DIR / 'state.json', {}
                    )
                },
                ensure_ascii=False,
                indent=2
            )
        )
        return 0

    if args.command == 'check':
        ip, geo = probe()
        return 0 if geo != 'RU' else 2

    STATE_DIR.mkdir(parents=True, exist_ok=True)

    with open(STATE_DIR / 'lock', 'w') as lock:
        try:
            fcntl.flock(
                lock,
                fcntl.LOCK_EX | fcntl.LOCK_NB
            )
        except BlockingIOError:
            raise RuntimeError(
                'Another search/monitor is running'
            )

        if args.command == 'search':
            search(region, args.wait, args.delay)
        else:
            monitor(
                region,
                args.interval,
                args.wait,
                args.delay
            )

    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())

    except KeyboardInterrupt:
        log('Stopped by user')
        sys.exit(130)

    except Exception as error:
        log(f'ERROR: {error}')
        sys.exit(1)
AUTOPIN_MANAGER_SOURCE

chmod 755 "$APP/psiphon_autopin.py"

python3 -m py_compile "$APP/psiphon_autopin.py"

python3 - "$DATA/settings.json" "$REGION" <<'PYSETTINGS'
import json
import sys

path, region = sys.argv[1:]

with open(path, 'w') as f:
    json.dump({'region': region}, f)
PYSETTINGS

chmod 600 "$DATA/settings.json"

cat > /etc/systemd/system/psiphon-autopin.service <<EOF
[Unit]
Description=Psiphon Auto-Pin region monitor and endless recovery
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP/psiphon_autopin.py monitor --region ${REGION:-AUTO} --interval 3600 --wait 60 --delay 12
Restart=always
RestartSec=30
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable psiphon-autopin.service
systemctl restart psiphon-autopin.service

echo
echo '[OK] Psiphon Auto-Pin Manager installed.'
echo '[OK] Hourly monitor enabled.'
echo '[OK] SOCKS5 for host Xray: 127.0.0.1:40000'
echo
echo 'Status: systemctl status psiphon-autopin --no-pager'
echo 'Logs: journalctl -u psiphon-autopin -f'
echo 'Check: python3 /opt/psiphon-autopin/psiphon_autopin.py check'
echo
echo 'NOTE: Search has no attempt limit.'
echo 'NOTE: A suitable exit is not guaranteed.'
