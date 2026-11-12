#!/usr/bin/env bash
# Forcus Psiphon Auto-Pin Manager v3.3
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
PORT_EXPLICIT=0
while (($#)); do
    case "$1" in
        --region) REGION=${2:?Missing region}; shift 2 ;;
        --port) SOCKS_PORT=${2:?Missing port}; PORT_EXPLICIT=1; shift 2 ;;
        --interval) INTERVAL=${2:?Missing interval}; shift 2 ;;
        --wait) WAIT=${2:?Missing wait}; shift 2 ;;
        --delay) DELAY=${2:?Missing delay}; shift 2 ;;
        --help) echo 'Usage: install_psiphon_autopin.sh [--region DE|AUTO] [--port 40000] [--interval 3600] [--wait 75] [--delay 12]'; exit 0 ;;
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
(( INTERVAL >= 60 && WAIT >= 20 && DELAY >= 2 )) || { echo 'Require interval>=60, wait>=20, delay>=2' >&2; exit 2; }
[[ $REGION == AUTO ]] && REGION=''
mkdir -p "$ROOT" "$CONF" "$APP" "$DATA"
chmod 700 "$DATA"
echo "[INFO] Region=${REGION:-AUTO}; SOCKS5=127.0.0.1:$SOCKS_PORT; manager v3.3"

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

# Check both listeners when creating a container or changing its ports.
port_occupied() {
    ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$1$"
}

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    [[ -f $CONF/psiphon.config ]] || { echo "Missing $CONF/psiphon.config" >&2; exit 1; }
    echo '[INFO] Existing Psiphon container preserved.'
    CURRENT_SOCKS_PORT=$(python3 - "$CONF/psiphon.config" <<'PYOLDPORT'
import json,sys
print(json.load(open(sys.argv[1])).get('LocalSocksProxyPort',40000))
PYOLDPORT
)
    if [[ "$CURRENT_SOCKS_PORT" != "$SOCKS_PORT" ]]; then
        if port_occupied "$SOCKS_PORT" || port_occupied "$HTTP_PORT"; then
            echo "[ERROR] New SOCKS/HTTP port $SOCKS_PORT/$HTTP_PORT occupied" >&2; exit 1
        fi
    fi
    docker start "$CONTAINER" >/dev/null || true
else
    [[ ! -e $CONF/psiphon.config ]] || { echo 'Config exists but container missing; refusing overwrite.' >&2; exit 1; }
    if port_occupied "$SOCKS_PORT" || port_occupied "$HTTP_PORT"; then
        echo "SOCKS/HTTP port $SOCKS_PORT/$HTTP_PORT already occupied" >&2; exit 1
    fi
    echo '[INFO] Bootstrapping Psiphon...'
    docker pull swarupsengupta2007/psiphon:latest
    docker run --rm --entrypoint cat swarupsengupta2007/psiphon:latest /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
    chmod 600 "$CONF/psiphon.config"
    python3 - "$CONF/psiphon.config" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" <<'CONFIG_INIT'
import json,sys
p,r,socks,http=sys.argv[1:]
c=json.load(open(p))
c.update(EgressRegion=r,LocalSocksProxyPort=int(socks),LocalSocksProxyListenAddress='127.0.0.1',LocalHttpProxyPort=int(http),LocalHttpProxyListenAddress='127.0.0.1',TunnelPoolSize=1,EmitDiagnosticNotices=True,DisableReplay=True)
with open(p,'w') as f: json.dump(c,f,indent=2); f.write('\n')
CONFIG_INIT
    tree=$(mktemp)
    curl --fail --location --silent --show-error --retry 3 'https://api.github.com/repos/Psiphon-Labs/psiphon-tunnel-core-binaries/git/trees/master?recursive=1' -o "$tree"
    path=$(python3 - "$tree" <<'PICK_BINARY'
import json,sys
rows=json.load(open(sys.argv[1]))['tree']
m=[v['path'] for v in rows if v['type']=='blob' and v['path'].startswith('linux/') and any(x in v['path'].lower() for x in ('amd64','x86_64')) and any(x in v['path'].lower() for x in ('consoleclient','psiphon-tunnel-core'))]
if len(m)!=1: raise SystemExit('Expected one official executable: '+str(m))
print(m[0])
PICK_BINARY
)
    rm -f "$tree"
    curl --fail --location --silent --show-error --retry 3 "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/$path" -o "$ROOT/ConsoleClient"
    chmod 755 "$ROOT/ConsoleClient"
    cat > "$ROOT/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY ConsoleClient /usr/local/bin/ConsoleClient
WORKDIR /config
CMD ["/usr/local/bin/ConsoleClient", "-config", "/config/psiphon.config", "-dataRootDirectory", "/config"]
DOCKERFILE
    docker build -t local-psiphon-console:latest "$ROOT"
    docker run -d --name "$CONTAINER" --restart unless-stopped --network host -v "$CONF:/config" local-psiphon-console:latest >/dev/null
    echo '[OK] Created Psiphon container.'
fi

# Update the region on re-install. Invalidate stale pin state when region changes.
SYNC_CHANGED=$(python3 - "$CONF/psiphon.config" "$DATA/state.json" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" <<'SYNC_REGION'
import json,sys,os,shutil,datetime
p,s,r,socks,http=sys.argv[1:];c=json.load(open(p))
changed=(c.get('EgressRegion','')!=r or c.get('LocalSocksProxyPort')!=int(socks) or c.get('LocalHttpProxyPort')!=int(http))
if changed:
    shutil.copy2(p,p+'.before-region-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    c['EgressRegion']=r
    c['LocalSocksProxyPort']=int(socks)
    c['LocalSocksProxyListenAddress']='127.0.0.1'
    c['LocalHttpProxyPort']=int(http)
    c['LocalHttpProxyListenAddress']='127.0.0.1'
    c.pop('TargetServerEntry',None)
    with open(p,'w') as f:json.dump(c,f,indent=2);f.write('\n')
    if os.path.isfile(s):os.unlink(s)
    print('changed')
SYNC_REGION
)
if [[ "$SYNC_CHANGED" == changed ]]; then
    echo "[INFO] Region or proxy port changed: restarting Psiphon"
    docker restart "$CONTAINER" >/dev/null
fi

# Recover bootstrap fields if an existing installation does not respond through SOCKS5.
# Check ONLY through the proxy. A failure must never fall back to a direct IP probe.
if ! curl -4 -fsS --max-time 15 --noproxy '' --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org >/dev/null 2>&1; then
    echo '[INFO] Checking bootstrap fields (SOCKS5 not yet responding)...'
    docker pull swarupsengupta2007/psiphon:latest
    template=$(mktemp)
    docker run --rm --entrypoint cat swarupsengupta2007/psiphon:latest /etc/psiphon/psiphon.config > "$template"
    python3 - "$CONF/psiphon.config" "$template" <<'BOOTSTRAP'
import json,sys,shutil,datetime
p,t=sys.argv[1:]; a=json.load(open(p)); b=json.load(open(t))
keys=('RemoteServerListURLs','RemoteServerListSignaturePublicKey','ObfuscatedServerListRootURLs','ObfuscatedServerListSignaturePublicKey','ServerEntrySignaturePublicKey','SponsorId','PropagationChannelId')
missing=[k for k in keys if not a.get(k) and b.get(k)]
if missing:
    shutil.copy2(p,p+'.bootstrap-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    for k in missing:a[k]=b[k]
    with open(p,'w') as f:json.dump(a,f,indent=2);f.write('\n')
print('Bootstrap fields added:',missing)
BOOTSTRAP
    rm -f "$template"
    docker restart "$CONTAINER" >/dev/null
fi

# Google region classifier from Davoyan. Force its proxy requests to use remote SOCKS DNS.
curl -fLsS --retry 3 https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh -o "$APP/ipregion.sh"
python3 - "$APP/ipregion.sh" <<'PATCH_IPREGION'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
if 'socks5://$PROXY_ADDR' not in s: raise SystemExit('ipregion proxy usage changed: review before deployment')
s=s.replace('socks5://$PROXY_ADDR','socks5h://$PROXY_ADDR')
p.write_text(s)
PATCH_IPREGION
chmod 700 "$APP/ipregion.sh"

cat > "$APP/psiphon-server-export.go" <<'GO_EXPORTER'
package main

import (
    "encoding/hex"
    "encoding/json"
    "fmt"
    "net"
    "os"
    "sort"
    "strings"
    "time"
    bolt "go.etcd.io/bbolt"
)

type Entry struct {
    Tag string `json:"tag"`
    IP string `json:"ipAddress"`
    Region string `json:"region"`
    Port string `json:"webServerPort"`
    Secret string `json:"webServerSecret"`
    Cert string `json:"webServerCertificate"`
    Capabilities []string `json:"capabilities"`
    Version int `json:"configurationVersion"`
}
type Candidate struct {
    ServerIP string `json:"server_ip"`
    Region string `json:"region"`
    Diagnostic string `json:"diagnostic"`
    Encoded string `json:"encoded"`
    Version int `json:"-"`
}
func main() {
    if len(os.Args)!=3 { fmt.Fprintln(os.Stderr,"usage: exporter DATABASE REGION");os.Exit(2) }
    db,err:=bolt.Open(os.Args[1],0400,&bolt.Options{ReadOnly:true,Timeout:5*time.Second})
    if err!=nil {panic(err)}
    defer db.Close()
    found:=make(map[string]Candidate)
    err=db.View(func(tx *bolt.Tx) error {
        var walk func(*bolt.Bucket) error
        walk=func(b *bolt.Bucket) error {
            return b.ForEach(func(k,v []byte) error {
                if v==nil {child:=b.Bucket(k);if child!=nil{return walk(child)};return nil}
                var e Entry
                if json.Unmarshal(v,&e)!=nil{return nil}
                if net.ParseIP(e.IP)==nil || len(e.Tag)<8 || len(e.Capabilities)==0 || (os.Args[2]!="" && e.Region!=os.Args[2]) {return nil}
                fields:=[]string{"0","0","0","0"}
                if e.Cert!="" {fields=[]string{e.IP,e.Port,e.Secret,e.Cert}}
                // JSON bytes originate in Psiphon's datastore. No credentials are printed.
                enc:=hex.EncodeToString([]byte(strings.Join(fields," ")+" "+string(v)))
                candidate:=Candidate{ServerIP:e.IP,Region:e.Region,Diagnostic:e.Tag[:8],Encoded:enc,Version:e.Version}
                if old,exists:=found[e.IP];!exists || e.Version>old.Version {found[e.IP]=candidate}
                return nil
            })
        }
        return tx.ForEach(func(_ []byte,b *bolt.Bucket) error{return walk(b)})
    })
    if err!=nil {panic(err)}
    keys:=make([]string,0,len(found))
    for ip:=range found {keys=append(keys,ip)}
    sort.Strings(keys)
    for _,ip:=range keys {b,_:=json.Marshal(found[ip]);fmt.Println(string(b))}
}
GO_EXPORTER

# Build the exporter only when its source changes.
if [[ ! -x "$APP/psiphon-server-export" || "$APP/psiphon-server-export.go" -nt "$APP/psiphon-server-export" ]]; then
    builddir=$(mktemp -d)
    cp "$APP/psiphon-server-export.go" "$builddir/main.go"
    ( cd "$builddir" && go mod init foc.us/psiphon-exporter >/dev/null && go get go.etcd.io/bbolt@v1.3.11 && go build -o "$APP/psiphon-server-export" . )
    rm -rf "$builddir"
    chmod 700 "$APP/psiphon-server-export"
fi

cat > "$APP/psiphon_autopin.py" <<'PY_MANAGER'
#!/usr/bin/env python3
"""Forcus Psiphon Auto-Pin v3.3: controlled server selection + SOCKS-only geolocation."""
import argparse
import datetime as dt
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

BASE=Path('/opt/psiphon-autopin')
DATA=Path('/var/lib/psiphon-autopin')
CONFIG=Path('/opt/vps-psiphon/config/psiphon.config')
CONTAINER='vps-psiphon'
PROXY='127.0.0.1:40000'  # Updated from settings / --port in main()
STATE=DATA/'state.json'

def log(message):
    print(dt.datetime.now().astimezone().isoformat(timespec='seconds'),message,flush=True)

def run(args, timeout=60, merge=False):
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT if merge else subprocess.PIPE,text=True,timeout=timeout)
    if p.returncode:
        error=p.stdout if merge else p.stderr
        raise RuntimeError(f'{args[0]} rc={p.returncode}: {(error or "")[-450:]}')
    return p.stdout

def read_json(p, default=None):
    try:return json.loads(Path(p).read_text())
    except (OSError,ValueError):return default

def atomic_json(p, obj):
    p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    st=p.stat() if p.exists() else None
    name=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=p.parent,prefix='.autopin-',delete=False) as f:
            name=f.name;json.dump(obj,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        if st:os.chown(name,st.st_uid,st.st_gid);os.chmod(name,st.st_mode & 0o777)
        else:os.chmod(name,0o600)
        os.replace(name,p)
    finally:
        if name and os.path.exists(name):os.unlink(name)

def change_config(updates):
    obj=read_json(CONFIG)
    if not isinstance(obj,dict):raise RuntimeError('Invalid Psiphon configuration')
    obj.update(updates)
    atomic_json(CONFIG,obj)

def socks_ip():
    # Explicit SOCKS5h proxy, remote DNS, no direct fallback or proxy bypass.
    ip=run(['curl','-4','-fsS','--connect-timeout','7','--max-time','15','--noproxy','', '--proxy',f'socks5h://{PROXY}','https://api.ipify.org'],timeout=20).strip()
    if ipaddress.ip_address(ip).version!=4:raise RuntimeError('Unexpected IPv4 address')
    return ip

def google_region():
    script=BASE/'ipregion.sh'
    if not script.is_file():raise RuntimeError('ipregion missing')
    env=os.environ.copy()
    # Also force any helper curl executed by ipregion through Psiphon.
    # run() does not accept env, so call subprocess explicitly here.
    env.update(ALL_PROXY=f'socks5h://{PROXY}',HTTP_PROXY=f'socks5h://{PROXY}',HTTPS_PROXY=f'socks5h://{PROXY}',http_proxy=f'socks5h://{PROXY}',https_proxy=f'socks5h://{PROXY}',all_proxy=f'socks5h://{PROXY}',NO_PROXY='',no_proxy='')
    cmd=['bash',str(script),'--proxy',PROXY,'--ipv4','--group','custom','--json']
    p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=210,env=env)
    if p.returncode:raise RuntimeError(f'ipregion failed: {p.stderr[-350:]}')
    report=json.loads(p.stdout)
    rows=report.get('results',{}).get('custom',[])
    geo=[str(x.get('ipv4','')).strip().upper() for x in rows if x.get('service')=='Google']
    if len(geo)!=1 or not re.fullmatch('[A-Z]{2}',geo[0]):raise RuntimeError(f'Google region UNKNOWN: {geo}')
    return geo[0]

def probe():
    first=socks_ip();country=google_region();last=socks_ip()
    if first!=last:raise RuntimeError(f'Exit changed during check: {first} -> {last}')
    log(f'Exit={last}, Google={country} [SOCKS5h]')
    return last,country

def started_at():
    return run(['docker','inspect','-f','{{.State.StartedAt}}',CONTAINER]).strip()

def connected_id():
    data=run(['docker','logs','--since',started_at(),CONTAINER],timeout=30,merge=True)
    last=None
    for line in data.splitlines():
        try: obj=json.loads(line)
        except ValueError:continue
        if obj.get('noticeType')=='ConnectedServer':last=(obj.get('data') or {}).get('diagnosticID')
    if not last or not re.fullmatch(r'[A-Za-z0-9+/]{8}',last):raise RuntimeError('No valid ConnectedServer ID in current Docker session')
    return last

def db_path():
    matches=list(CONFIG.parent.glob('**/psiphon.boltdb'))
    if len(matches)!=1:raise RuntimeError(f'Expected exactly one BoltDB, got {len(matches)}')
    return matches[0]

def docker_restart(wait):
    run(['docker','restart',CONTAINER],timeout=90)
    deadline=time.monotonic()+wait;error='unknown'
    while time.monotonic()<deadline:
        try:return socks_ip()
        except Exception as exc:error=str(exc);time.sleep(2)
    raise RuntimeError(f'Psiphon not ready in {wait}s: {error}')

def collect_candidates(region):
    # BoltDB is read only with the container stopped; always start it again.
    log('Exporting distinct server entries from read-only BoltDB...')
    run(['docker','stop',CONTAINER],timeout=90)
    try:
        raw=run([str(BASE/'psiphon-server-export'),str(db_path()),region],timeout=120)
        rows=[json.loads(line) for line in raw.splitlines() if line.strip()]
        rows=[v for v in rows if v.get('server_ip') and v.get('diagnostic') and v.get('encoded')]
        if not rows:raise RuntimeError(f'No known servers in region {region or "AUTO"}')
        log(f'Loaded {len(rows)} distinct servers')
        return rows
    finally:
        run(['docker','start',CONTAINER],timeout=90)

def apply_candidate(candidate,region):
    change_config({'EgressRegion':region,'TargetServerEntry':candidate['encoded'],'TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True,'DisableTactics':False})

def clear_target(region):
    change_config({'EgressRegion':region,'TargetServerEntry':'','TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True,'DisableTactics':False})

def verify_pin_current(region):
    state=read_json(STATE,{}) or {}
    config=read_json(CONFIG,{}) or {}
    if state.get('region')!=region or not state.get('ip') or not config.get('TargetServerEntry'):
        return False
    ip,geo=probe()
    diag=connected_id()
    if ip==state['ip'] and geo!='RU' and diag==state.get('diagnostic_id'):
        log(f'Existing pin healthy: {ip}, {geo}, server={diag}')
        return True
    return False

def search(region,wait,delay):
    log(f'Server rotation started: {region or "AUTO"}; unlimited cycles')
    # Preserve a known good pin without needless restart.
    try:
        if verify_pin_current(region):return True
    except Exception as e:log(f'Existing pin check failed: {e}')
    # Remove old target before discovery. No automatic return to RU state.
    clear_target(region)
    STATE.unlink(missing_ok=True)
    seen_exits=set()
    cycle=0
    while True:
        cycle+=1
        try:
            # Give Psiphon an opportunity to discover new servers before snapshotting the DB.
            docker_restart(wait)
            time.sleep(5)
            candidates=collect_candidates(region)
        except Exception as exc:
            log(f'Cannot collect candidates: {exc}; retry in 30s')
            time.sleep(30)
            continue
        random.shuffle(candidates)
        log(f'Cycle {cycle}: {len(candidates)} unique server IPs')
        for i,candidate in enumerate(candidates,1):
            server=candidate['server_ip'];expected=candidate['diagnostic']
            log(f'Trying server {i}/{len(candidates)}: {server}, ID={expected}')
            try:
                apply_candidate(candidate,region)
                exit_ip=docker_restart(wait)
                actual=connected_id()
                if actual!=expected:
                    raise RuntimeError(f'Wrong server ID: expected {expected}, got {actual}')
                # Do not spend time probing Google for an exit already rejected.
                if exit_ip in seen_exits:
                    log(f'Exit {exit_ip} already rejected in this search; skipping')
                    continue
                first,geo=probe()
                if first!=exit_ip:raise RuntimeError(f'Exit IP changed: {exit_ip} -> {first}')
                if geo=='RU':
                    seen_exits.add(first)
                    log(f'Rejected exit {first}: Google=RU')
                    continue
                # Double-check Google after a short delay, through the same SOCKS5 tunnel.
                time.sleep(5)
                second,geo2=probe()
                if second!=first or geo2=='RU' or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,'server_ip':server,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                log(f'PIN VERIFIED: exit={first} Google={geo2} server={server} ID={expected}')
                return True
            except Exception as exc:
                log(f'Server {server} failed: {exc}')
            time.sleep(delay)
        log('All candidates exhausted. Refreshing discovery and repeating in 60s...')
        clear_target(region)
        try:docker_restart(wait)
        except Exception as e:log(f'Discovery connection warning: {e}')
        time.sleep(60)
        # After a full cycle, the same exit could have been reclassified by Google.
        seen_exits.clear()

def monitor(region,interval,wait,delay):
    log(f'Monitor started: region={region or "AUTO"}, interval={interval}s')
    while True:
        try:
            ip,geo=probe()
            state=read_json(STATE,{}) or {}
            config=read_json(CONFIG,{}) or {}
            wrong_region=state.get('region')!=region
            missing_pin=not state.get('ip') or not config.get('TargetServerEntry')
            changed=(not missing_pin and (ip!=state.get('ip') or connected_id()!=state.get('diagnostic_id')))
            if geo=='RU':
                log('Google=RU; checking again before rotation')
                time.sleep(15)
                _,confirm=probe()
                if confirm=='RU':
                    log('RU confirmed; switching to a different server')
                    search(region,wait,delay)
            elif wrong_region or missing_pin or changed:
                log('No matching verified pin; starting controlled server selection')
                search(region,wait,delay)
            else:log('Healthy pinned SOCKS exit; unchanged')
        except Exception as e:
            log(f'CHECK UNKNOWN / outage: {e} (not treated as RU)')
            state=read_json(STATE,{}) or {}
            if not state.get('ip'):
                try:search(region,wait,delay)
                except Exception as inner:log(f'Search failed: {inner}')
        time.sleep(interval)

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v3.3')
    ap.add_argument('command',choices=['check','search','monitor','status'])
    ap.add_argument('--region',default=None)
    ap.add_argument('--port',type=int,default=None)
    ap.add_argument('--interval',type=int,default=3600)
    ap.add_argument('--wait',type=int,default=75)
    ap.add_argument('--delay',type=int,default=12)
    args=ap.parse_args()
    settings=read_json(DATA/'settings.json',{}) or {}
    region=(args.region if args.region is not None else settings.get('region','')).upper()
    global PROXY
    port=args.port if args.port is not None else int(settings.get('port',40000))
    if not 1024 <= port <= 65534:ap.error('port must be 1024..65534')
    PROXY=f'127.0.0.1:{port}'
    if region=='AUTO':region=''
    if region and not re.fullmatch('[A-Z]{2}',region):ap.error('invalid country')
    if args.interval<60 or args.wait<20 or args.delay<2:ap.error('interval>=60 wait>=20 delay>=2')
    if args.command=='status':
        print(json.dumps({'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}'},indent=2));return 0
    if args.command=='check':
        _,geo=probe();return 0 if geo!='RU' else 2
    DATA.mkdir(parents=True,exist_ok=True)
    with (DATA/'lock').open('w') as f:
        try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError('Another search/monitor is running')
        if args.command=='search':search(region,args.wait,args.delay)
        else:monitor(region,args.interval,args.wait,args.delay)
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:log('Stopped');sys.exit(130)
    except Exception as exc:log(f'FATAL: {exc}');sys.exit(1)
PY_MANAGER
chmod 700 "$APP/psiphon_autopin.py"
python3 -m py_compile "$APP/psiphon_autopin.py"
python3 - "$DATA/settings.json" "$REGION" "$SOCKS_PORT" <<'SETTINGS'
import json,sys
with open(sys.argv[1],'w') as f:json.dump({'region':sys.argv[2],'port':int(sys.argv[3])},f);f.write('\n')
SETTINGS
chmod 600 "$DATA/settings.json"

cat > /etc/systemd/system/psiphon-autopin.service <<EOF
[Unit]
Description=Forcus Psiphon Auto-Pin v3.3 server rotation and Google geo monitor
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP/psiphon_autopin.py monitor --region ${REGION:-AUTO} --port $SOCKS_PORT --interval $INTERVAL --wait $WAIT --delay $DELAY
Restart=always
RestartSec=30
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable psiphon-autopin.service
systemctl restart psiphon-autopin.service
printf '\n[OK] Forcus Psiphon Auto-Pin v3.3 installed\n'
echo '[OK] Distinct Psiphon servers selected via TargetServerEntry.'
echo "[OK] SOCKS5h: 127.0.0.1:$SOCKS_PORT (Google and IP checks through proxy)."
echo "[OK] Monitoring every ${INTERVAL}s / unlimited search enabled."
echo 'Logs: journalctl -u psiphon-autopin -f'
echo 'Status: python3 /opt/psiphon-autopin/psiphon_autopin.py status'
