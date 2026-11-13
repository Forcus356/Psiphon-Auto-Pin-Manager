#!/usr/bin/env bash
# Forcus Psiphon Auto-Pin Manager v3.4.2
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
echo "[INFO] Region=${REGION:-AUTO}; SOCKS5=127.0.0.1:$SOCKS_PORT; manager v3.4.2"

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
    # Never adopt a foreign container with the same name: legacy installations
    # commonly publish 40000:1080 and ignore the new port in the JSON.
    IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")
    NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER")
    MOUNT_OK=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
    if [[ "$IMAGE" != 'local-psiphon-console:latest' || "$NETMODE" != 'host' || "$MOUNT_OK" != "$CONF" ]]; then
        echo "[ERROR] Existing $CONTAINER is not ours (image=$IMAGE network=$NETMODE mount=$MOUNT_OK)." >&2
        echo '[ERROR] Stop legacy psiphon services and migrate explicitly; no container was replaced.' >&2
        exit 1
    fi
    echo '[INFO] Existing compatible Psiphon container preserved.'
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
c.update(EgressRegion=r,ListenInterface='lo',LocalSocksProxyPort=int(socks),LocalHttpProxyPort=int(http),TunnelPoolSize=1,EmitDiagnosticNotices=True,DisableReplay=True)
c.pop('LocalSocksProxyListenAddress',None)
c.pop('LocalHttpProxyListenAddress',None)
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
routing_changed=(c.get('EgressRegion','')!=r or c.get('LocalSocksProxyPort')!=int(socks) or c.get('LocalHttpProxyPort')!=int(http))
security_changed=(c.get('ListenInterface')!='lo' or 'LocalSocksProxyListenAddress' in c or 'LocalHttpProxyListenAddress' in c)
if routing_changed or security_changed:
    shutil.copy2(p,p+'.before-update-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    c['EgressRegion']=r
    c['ListenInterface']='lo'
    c['LocalSocksProxyPort']=int(socks)
    c['LocalHttpProxyPort']=int(http)
    c.pop('LocalSocksProxyListenAddress',None)
    c.pop('LocalHttpProxyListenAddress',None)
    if routing_changed:
        c.pop('TargetServerEntry',None)
        if os.path.isfile(s):os.unlink(s)
    with open(p,'w') as f:json.dump(c,f,indent=2);f.write('\n')
    print('security_changed' if security_changed and not routing_changed else 'changed')
SYNC_REGION
)
if [[ -n "$SYNC_CHANGED" ]]; then
    echo "[INFO] Region, port or loopback security settings changed: restarting Psiphon"
    docker restart "$CONTAINER" >/dev/null
fi

# Fail closed: ConsoleClient must not expose either unauthenticated proxy on a public interface.
# This includes configurations inherited from a previously installed Psiphon container.
# Inspect actual listening sockets, not just the JSON file.
verify_proxy_binding() {
    local bad
    bad=$(ss -H -ltnp | awk -v socks=":$SOCKS_PORT" -v http=":$HTTP_PORT" '
        {
          addr=$4
          if (addr ~ socks "$" || addr ~ http "$") {
            # Safe: IPv4 loopback, IPv6 loopback. All other bind addresses fail closed.
            if (addr !~ /^127\.[0-9]+\.[0-9]+\.[0-9]+:/ && addr !~ /^\[::1\]:/) print $0
          }
        }')
    if [[ -n $bad ]]; then
        echo "[SECURITY ERROR] Psiphon proxy is listening outside localhost:" >&2
        echo "$bad" >&2
        echo '[SECURITY ERROR] Stopping Psiphon to prevent exposure.' >&2
        docker stop "$CONTAINER" >/dev/null || true
        exit 1
    fi
}
verify_proxy_binding


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

# A conservative, anonymous Gemini availability check through the pinned SOCKS5h exit.
# Only an explicit error 1060 is REFUSED. Changed web internals/errors => INCONCLUSIVE.
# There is no direct-connect fallback. Test request is deliberately low-volume.
cat > "$APP/gemini_probe.py" <<'PY_GEMINI'
#!/usr/bin/env python3
"""Unauthenticated Gemini availability probe. Exit 0 served, 1 refused, 2 inconclusive."""
import argparse
import http.cookiejar
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlencode

APP='https://gemini.google.com/app'
ENDPOINT='https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate'

def curl(args, timeout=90):
    try:
        p=subprocess.run(['curl','-4','-sS','--max-time',str(timeout),*args],
                         capture_output=True, text=True, timeout=timeout+5)
        return p.returncode,p.stdout,p.stderr
    except (OSError,subprocess.TimeoutExpired) as e:
        return 1,'',str(e)

def check(port):
    proxy=f'socks5h://127.0.0.1:{port}'
    with tempfile.TemporaryDirectory(prefix='gemini-check-') as tmp:
        jar=str(Path(tmp)/'cookies')
        common=['--noproxy','','--proxy',proxy,'-A','Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36',
                '-H','Accept-Language: en-US,en;q=0.9','-b',jar,'-c',jar]
        rc,page,err=curl([*common,APP],timeout=30)
        if rc:return 'INCONCLUSIVE',f'page fetch failed: {err[-120:]}'
        # Fields are from the public, unauthenticated application page.
        bl=re.search(r'"cfb2h":"([^"\\]+)"',page)
        sid=re.search(r'"FdrFJe":"([^"\\]+)"',page)
        if not bl or not sid:return 'INCONCLUSIVE','session fields absent; Google page may have changed'
        query=urlencode({'bl':bl.group(1),'f.sid':sid.group(1),'hl':'en','_reqid':'100000','rt':'c'})
        req='f.req=[null,"[[\\"hi\\"],null,null]"]'
        rc,out,err=curl([*common,'-H','Content-Type: application/x-www-form-urlencoded;charset=utf-8',
                          '-H','Origin: https://gemini.google.com','-H','Referer: https://gemini.google.com/',
                          '--data-urlencode',req,ENDPOINT+'?'+query],timeout=90)
        if rc:return 'INCONCLUSIVE',f'request failed: {err[-120:]}'
        if re.search(r'BardErrorInfo\\?\",\\?\[1060(?:\D|$)',out):return 'REFUSED','Gemini error 1060'
        # Do not count a 200 HTML page, captcha or generic response as a successful model reply.
        if re.search(r'SWML_DESCRIPTION',out) and 'wrb.fr' in out:
            return 'SERVING','anonymous model reply detected'
        return 'INCONCLUSIVE','no explicit Gemini verdict'

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--port',type=int,required=True)
    a=ap.parse_args()
    if not 1024<=a.port<=65534:ap.error('invalid port')
    verdict,reason=check(a.port)
    print(f'{verdict}: {reason}',flush=True)
    sys.exit({'SERVING':0,'REFUSED':1,'INCONCLUSIVE':2}[verdict])
PY_GEMINI
chmod 700 "$APP/gemini_probe.py"
python3 -m py_compile "$APP/gemini_probe.py"

cat > "$APP/psiphon_autopin.py" <<'PY_MANAGER'
#!/usr/bin/env python3
"""Forcus Psiphon Auto-Pin v3.4.2: controlled server selection + SOCKS-only geolocation."""
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

def gemini_verdict(enabled):
    """Report only explicit refusal; never treat inconclusive as bad exit."""
    if not enabled:return 'DISABLED'
    port=PROXY.rsplit(':',1)[1]
    p=subprocess.run(['python3',str(BASE/'gemini_probe.py'),'--port',port],
                     stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=130)
    label={0:'SERVING',1:'REFUSED',2:'INCONCLUSIVE'}.get(p.returncode,'INCONCLUSIVE')
    log('Gemini '+label+': '+(p.stdout or p.stderr).strip()[-180:])
    return label

def speed_probe(mb):
    """Optional single-download measurement. Never used as the sole rotation reason."""
    if mb<=0:return None
    url=f'https://speed.cloudflare.com/__down?bytes={mb*1048576}'
    cmd=['curl','-4','-fsS','--noproxy','','--proxy',f'socks5h://{PROXY}',
         '--connect-timeout','8','--max-time','50','-o','/dev/null',
         '-w','%{speed_download}',url]
    out=run(cmd,timeout=55).strip()
    kbps=round(float(out)/1024,1)
    log(f'Speed probe: {kbps} KiB/s, sample={mb} MiB')
    return kbps

def evaluate_exit(region, gemini, mb, strict=False):
    ip,geo=probe()
    verdict=gemini_verdict(gemini)
    speed=None
    if mb:
        try:speed=speed_probe(mb)
        except Exception as exc:log('Optional speed sample failed: '+str(exc))
    # Google classifications can differ from the server's requested country.
    # In strict mode reject *confirmed* mismatch, not an inconclusive Gemini reply.
    reason=('Google=RU' if geo=='RU' else 'Gemini REFUSED' if verdict=='REFUSED' else
            f'Google={geo} != requested {region}' if strict and region and geo!=region else '')
    return ip,geo,verdict,speed,reason

def adopt_current(region,gemini,mb,strict,observed=None):
    """Leave an already healthy connection alone; do not claim it's pinned to a DB entry."""
    config=read_json(CONFIG,{}) or {}
    if config.get('TargetServerEntry'):return False
    ip,geo,verdict,speed,reason = observed if observed is not None else evaluate_exit(region,gemini,mb,strict)
    if reason:return False
    diag=connected_id()
    atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,
        'diagnostic_id':diag,'server_ip':None,'gemini':verdict,
        'speed_kib_s':speed,'adopted_unpinned':True,
        'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
    log(f'ADOPTED HEALTHY exit={ip} Google={geo} Gemini={verdict} ID={diag}; no restart (not targeted pin)')
    prepare_current_pin(region,ip,geo,diag)
    return True

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

# A candidate snapshot is obtained ONLY when Psiphon is already stopped as
# part of normal server discovery. Never open/copy a live BoltDB for staging.
CACHE=DATA/'server-entry-cache.json'

def cache_candidates(rows,region):
    # TargetServerEntry contains server credentials. Store only under mode 0600.
    atomic_json(CACHE, {'region':region,'entries':rows,
        'cached_at':dt.datetime.now(dt.timezone.utc).isoformat()})

def candidate_for_connected_server(diag,region):
    cache=read_json(CACHE,{}) or {}
    if cache.get('region')!=region:return None
    rows=[r for r in cache.get('entries',[]) if r.get('diagnostic')==diag and
          (not region or r.get('region')==region) and r.get('encoded') and r.get('server_ip')]
    # Diagnostic IDs are shortened tags, so do not silently choose between collisions.
    if len(rows)!=1:return None
    return rows[0]

def prepare_current_pin(region,ip,geo,diag):
    """Write next-start target without touching the running tunnel.

    This is staged, NOT verified. We intentionally don't restart ConsoleClient.
    """
    cfg=read_json(CONFIG,{}) or {}
    state=read_json(STATE,{}) or {}
    if cfg.get('TargetServerEntry') or state.get('pin_prepared'):return False
    candidate=candidate_for_connected_server(diag,region)
    if candidate is None:return False
    # Recheck the exit and diagnostic ID across the staging boundary.
    if socks_ip()!=ip or connected_id()!=diag:return False
    running_since=started_at()
    change_config({'TargetServerEntry':candidate['encoded'], 'EgressRegion':region,
                   'TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True})
    state.update(server_ip=candidate['server_ip'],adopted_unpinned=True,
                 pin_prepared=True,prepared_container_started_at=running_since)
    atomic_json(STATE,state)
    log(f'PIN PREPARED: ID={diag}, server={candidate["server_ip"]}; '
        'takes effect on next Psiphon restart; current tunnel unchanged')
    return True

def pin_prepared_verification(region,ip,geo,diag,reason,state):
    """Promote staged pin only after a NEW container instance has confirmed it."""
    if not state.get('pin_prepared'):return False
    if started_at()==state.get('prepared_container_started_at'):
        log(f'Prepared pin pending next restart: {ip} Google={geo}; current tunnel unchanged')
        return True
    if not reason and ip==state.get('ip') and diag==state.get('diagnostic_id'):
        state.update(pin_prepared=False,adopted_unpinned=False,
                     verified_at=dt.datetime.now(dt.timezone.utc).isoformat())
        state.pop('prepared_container_started_at',None)
        atomic_json(STATE,state)
        log(f'PIN VERIFIED AFTER RESTART: exit={ip} Google={geo} ID={diag}')
        return True
    # A prepared target failed to restore the previous verified exit.
    # Do not claim it was pinned; the monitor can run normal recovery.
    log(f'Prepared pin mismatch after restart: current={ip}/{diag}; '
        f'expected={state.get("ip")}/{state.get("diagnostic_id")}')
    return False

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
        cache_candidates(rows,region)
        log(f'Loaded {len(rows)} distinct servers')
        return rows
    finally:
        run(['docker','start',CONTAINER],timeout=90)

def apply_candidate(candidate,region):
    change_config({'EgressRegion':region,'TargetServerEntry':candidate['encoded'],'TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True,'DisableTactics':False})

def clear_target(region):
    change_config({'EgressRegion':region,'TargetServerEntry':'','TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True,'DisableTactics':False})

def verify_pin_current(region,gemini=False,mb=0,strict=False):
    state=read_json(STATE,{}) or {}
    config=read_json(CONFIG,{}) or {}
    if state.get('pin_prepared'):return False
    if state.get('region')!=region or not state.get('ip') or not config.get('TargetServerEntry'):
        return False
    ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
    diag=connected_id()
    if ip==state['ip'] and not reason and diag==state.get('diagnostic_id'):
        log(f'Existing pin healthy: {ip}, {geo}, server={diag}')
        return True
    return False

def search(region,wait,delay,gemini=False,mb=0,strict=False):
    log(f'Server rotation started: {region or "AUTO"}; unlimited cycles')
    # Preserve a known good pin without needless restart.
    try:
        if verify_pin_current(region,gemini,mb,strict):return True
        if adopt_current(region,gemini,mb,strict):return True
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
                first,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
                if first!=exit_ip:raise RuntimeError(f'Exit IP changed: {exit_ip} -> {first}')
                if reason:
                    seen_exits.add(first)
                    log(f'Rejected exit {first}: {reason}')
                    continue
                # Recheck IP/geo, without an unnecessary second Gemini request.
                time.sleep(5)
                second,geo2=probe()
                if second!=first or geo2=='RU' or (strict and region and geo2!=region) or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,
                                   'server_ip':server,'gemini':verdict,'speed_kib_s':speed,
                                   'adopted_unpinned':False,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                log(f'PIN VERIFIED: exit={first} Google={geo2} Gemini={verdict} server={server} ID={expected}')
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

def monitor(region,interval,wait,delay,gemini=False,mb=0,strict=False,threshold=3):
    log(f'Monitor v3.4: region={region or "AUTO"} interval={interval}s Gemini={gemini} speedMB={mb}')
    failures=0
    while True:
        try:
            ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
            state=read_json(STATE,{}) or {}
            config=read_json(CONFIG,{}) or {}
            diag=connected_id()
            changed=bool(state) and (ip!=state.get('ip') or diag!=state.get('diagnostic_id'))
            if not reason and state.get('pin_prepared') and config.get('TargetServerEntry'):
                if pin_prepared_verification(region,ip,geo,diag,reason,state):
                    failures=0
                    time.sleep(interval)
                    continue
            if reason:
                log(f'Bad exit: {reason}; verifying before rotation')
                # Confirm decisive refusals to avoid spurious reboots.
                time.sleep(10)
                ip2,geo2,verdict2,_,reason2=evaluate_exit(region,gemini,0,strict)
                if reason2 and ip2==ip:
                    log(f'Confirmed bad exit ({reason2}); starting search')
                    search(region,wait,delay,gemini,mb,strict)
                else:log('Second check recovered/inconclusive: preserving connection')
                failures=0
            elif not state or (not config.get('TargetServerEntry') and not state.get('adopted_unpinned')):
                # Existing working tunnel is useful even without TargetServerEntry.
                adopt_current(region,gemini,mb,strict,observed=(ip,geo,verdict,speed,reason))
                failures=0
            elif changed or state.get('region')!=region:
                log('Exit/region changed; evaluating current healthy exit')
                if not config.get('TargetServerEntry'):
                    adopt_current(region,gemini,mb,strict,observed=(ip,geo,verdict,speed,reason))
                else:
                    search(region,wait,delay,gemini,mb,strict)
                failures=0
            else:
                failures=0
                # Persist each completed health check, without changing the pin identity.
                if state:
                    state.update(google_region=geo, gemini=verdict, speed_kib_s=speed,
                                 verified_at=dt.datetime.now(dt.timezone.utc).isoformat())
                    atomic_json(STATE,state)
                if state.get('adopted_unpinned') and not config.get('TargetServerEntry'):
                    prepare_current_pin(region,ip,geo,diag)
                log(f'Healthy exit unchanged: {ip} Google={geo} Gemini={verdict}; '
                    + ('adopted (not pinned)' if state.get('adopted_unpinned') else 'pinned'))
        except Exception as exc:
            failures+=1
            log(f'UNKNOWN/OUTAGE {failures}/{threshold}: {exc}; no RU inference')
            if failures>=threshold:
                log('Consecutive failures reached threshold; recovering connection')
                try:
                    docker_restart(wait)
                    # Only run rotation if the restarted tunnel is still unusable.
                    ip,geo,verdict,_,reason=evaluate_exit(region,gemini,0,strict)
                    if reason:
                        search(region,wait,delay,gemini,mb,strict)
                    else:
                        log(f'Recovered without full search: {ip} Google={geo} Gemini={verdict}')
                except Exception as e:
                    log(f'Recovery incomplete: {e}; defer next attempt')
                failures=0
        time.sleep(interval)

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v3.4')
    ap.add_argument('command',choices=['check','search','monitor','status','refresh-cache','prepare-pin'])
    ap.add_argument('--region',default=None)
    ap.add_argument('--allow-interruption',action='store_true',help='Required for refresh-cache (briefly stops Psiphon)')
    ap.add_argument('--port',type=int,default=None)
    ap.add_argument('--interval',type=int,default=3600)
    ap.add_argument('--wait',type=int,default=75)
    ap.add_argument('--delay',type=int,default=12)
    ap.add_argument('--gemini-check',action='store_true',default=None)
    ap.add_argument('--no-gemini-check',dest='gemini_check',action='store_false')
    ap.add_argument('--probe-mb',type=int,default=None)
    ap.add_argument('--strict-region',action='store_true',default=None)
    ap.add_argument('--no-strict-region',dest='strict_region',action='store_false')
    ap.add_argument('--fail-threshold',type=int,default=None)
    args=ap.parse_args()
    settings=read_json(DATA/'settings.json',{}) or {}
    # settings.json stores the effective service configuration for status and CLI.
    # Explicit CLI arguments still win over persisted settings.
    if args.gemini_check is None:args.gemini_check=bool(settings.get('gemini_check',False))
    if args.probe_mb is None:args.probe_mb=int(settings.get('probe_mb',0))
    if args.strict_region is None:args.strict_region=bool(settings.get('strict_region',False))
    if args.fail_threshold is None:args.fail_threshold=int(settings.get('fail_threshold',3))
    region=(args.region if args.region is not None else settings.get('region','')).upper()
    global PROXY
    port=args.port if args.port is not None else int(settings.get('port',40000))
    if not 1024 <= port <= 65534:ap.error('port must be 1024..65534')
    PROXY=f'127.0.0.1:{port}'
    if region=='AUTO':region=''
    if region and not re.fullmatch('[A-Z]{2}',region):ap.error('invalid country')
    if args.interval<60 or args.wait<20 or args.delay<2:ap.error('interval>=60 wait>=20 delay>=2')
    if not 0<=args.probe_mb<=10 or not 2<=args.fail_threshold<=20:ap.error('probe-mb 0..10, fail-threshold 2..20')
    if args.command=='status':
        print(json.dumps({'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}','gemini_check':args.gemini_check,'probe_mb':args.probe_mb,'strict_region':args.strict_region,'fail_threshold':args.fail_threshold},indent=2));return 0
    if args.command=='check':
        _,geo=probe()
        verdict=gemini_verdict(args.gemini_check)
        return 2 if geo=='RU' or verdict=='REFUSED' else 0
    DATA.mkdir(parents=True,exist_ok=True)
    with (DATA/'lock').open('w') as f:
        try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError('Another search/monitor is running')
        if args.command=='refresh-cache':
            # Explicit operator action with an interruption: stop, export, start.
            # Never claim this happens without a connection interruption.
            if not args.allow_interruption:
                raise RuntimeError('refresh-cache interrupts Psiphon; repeat with --allow-interruption')
            collect_candidates(region)
            log('Candidate cache refreshed; Psiphon container restarted (tunnel may change)')
        elif args.command=='prepare-pin':
            ip,geo,verdict,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
            if reason:raise RuntimeError(f'Exit is not eligible for pin staging: {reason}')
            state=read_json(STATE,{}) or {}
            diag=connected_id()
            if not state or state.get('ip')!=ip or state.get('diagnostic_id')!=diag:
                adopt_current(region,args.gemini_check,args.probe_mb,args.strict_region,
                              observed=(ip,geo,verdict,speed,reason))
            if not prepare_current_pin(region,ip,geo,diag):
                log('No unique cached matching server (or pin already prepared); tunnel untouched')
        elif args.command=='search':
            search(region,args.wait,args.delay,args.gemini_check,args.probe_mb,args.strict_region)
        else:
            monitor(region,args.interval,args.wait,args.delay,args.gemini_check,args.probe_mb,args.strict_region,args.fail_threshold)
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:log('Stopped');sys.exit(130)
    except Exception as exc:log(f'FATAL: {exc}');sys.exit(1)
PY_MANAGER
chmod 700 "$APP/psiphon_autopin.py"
python3 -m py_compile "$APP/psiphon_autopin.py"
python3 - "$DATA/settings.json" "$REGION" "$SOCKS_PORT" "$GEMINI_CHECK" "$PROBE_MB" "$STRICT_REGION" "$FAIL_THRESHOLD" <<'SETTINGS'
import json,sys
obj={'region':sys.argv[2],'port':int(sys.argv[3]),
     'gemini_check':bool(int(sys.argv[4])),'probe_mb':int(sys.argv[5]),
     'strict_region':bool(int(sys.argv[6])),'fail_threshold':int(sys.argv[7])}
with open(sys.argv[1],'w') as f:json.dump(obj,f,indent=2);f.write('\n')
SETTINGS
chmod 600 "$DATA/settings.json"

EXTRA_FLAGS="--fail-threshold $FAIL_THRESHOLD --probe-mb $PROBE_MB"
if (( GEMINI_CHECK )); then EXTRA_FLAGS="$EXTRA_FLAGS --gemini-check"; fi
if (( STRICT_REGION )); then EXTRA_FLAGS="$EXTRA_FLAGS --strict-region"; fi
cat > /etc/systemd/system/psiphon-autopin.service <<EOF
[Unit]
Description=Forcus Psiphon Auto-Pin v3.4.2 server rotation and Google geo monitor
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP/psiphon_autopin.py monitor --region ${REGION:-AUTO} --port $SOCKS_PORT --interval $INTERVAL --wait $WAIT --delay $DELAY $EXTRA_FLAGS
Restart=always
RestartSec=30
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
# Confirm that both proxy sockets are bound only to loopback before enabling monitoring.
# A slow Psiphon tunnel need not be ready yet; listener visibility is checked for up to 20s.
for _ in $(seq 1 20); do
    verify_proxy_binding
    if ss -H -ltn | awk -v socks=":$SOCKS_PORT" -v http=":$HTTP_PORT" '
        $4 ~ socks "$" { a=1 } $4 ~ http "$" { b=1 } END { exit !(a && b) }
    '; then
        echo '[OK] Both proxy sockets are bound to loopback.'
        break
    fi
    sleep 1
done
verify_proxy_binding
# Do not start monitor when listeners have not appeared; fail closed and preserve config for diagnostics.
if ! ss -H -ltn | awk -v socks=":$SOCKS_PORT" -v http=":$HTTP_PORT" '
    $4 ~ socks "$" { a=1 } $4 ~ http "$" { b=1 } END { exit !(a && b) }
'; then
    echo '[ERROR] Proxy listeners were not created within 20 seconds; refusing to start monitor.' >&2
    exit 1
fi
systemctl daemon-reload
systemctl enable psiphon-autopin.service
systemctl restart psiphon-autopin.service
printf '\n[OK] Forcus Psiphon Auto-Pin v3.4.2 installed\n'
echo '[OK] Existing healthy unpinned exits are retained; targeted pinning remains available.'
echo "[OK] Gemini checks: $GEMINI_CHECK; optional throughput sample: ${PROBE_MB} MiB; strict region: $STRICT_REGION."
echo "[OK] SOCKS5h: 127.0.0.1:$SOCKS_PORT (Google and IP checks through proxy)."
echo "[OK] Monitoring every ${INTERVAL}s / unlimited search enabled."
echo 'Logs: journalctl -u psiphon-autopin -f'
echo 'Status: python3 /opt/psiphon-autopin/psiphon_autopin.py status'
