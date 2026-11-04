#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: installation failed" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
[[ -r /etc/os-release ]] && . /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || { echo 'Ubuntu/Debian required'; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'Only x86_64 supported'; exit 1; }
BASE=/opt/vps-psiphon
CONF=$BASE/config
mkdir -p "$CONF" /opt/psiphon-autopin /var/lib/psiphon-autopin
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io python3 curl ca-certificates
systemctl enable --now docker
EXISTING=0
if docker container inspect vps-psiphon >/dev/null 2>&1; then
  EXISTING=1
  echo '[OK] Existing vps-psiphon container found. Keeping it intact.'
elif [[ -e $CONF/psiphon.config ]]; then
  echo '[ERROR] Existing config without vps-psiphon container. Refusing to overwrite unknown installation.' >&2
  exit 1
fi
read -rp 'Psiphon egress country ISO code (SE/DE/NL/etc): ' REGION
REGION=${REGION^^}
[[ $REGION =~ ^[A-Z]{2}$ ]] || { echo 'Invalid ISO code'; exit 1; }
if [[ $EXISTING -eq 0 ]]; then
echo '[INFO] Psiphon not found: installing...'
# Official repository API: resolve the current Linux amd64 ConsoleClient artifact.
TREE=$(mktemp)
trap 'rm -f "$TREE"' EXIT
curl -fLsS --retry 3 'https://api.github.com/repos/Psiphon-Labs/psiphon-tunnel-core-binaries/git/trees/master?recursive=1' -o "$TREE"
BINARY_PATH=$(python3 - "$TREE" <<'PY'
import json,sys
items=json.load(open(sys.argv[1]))['tree']
paths=[x['path'] for x in items if x['type']=='blob' and x['path'].startswith('linux/') and ('amd64' in x['path'].lower() or 'x86_64' in x['path'].lower()) and ('consoleclient' in x['path'].lower() or 'psiphon-tunnel-core' in x['path'].lower())]
if len(paths)!=1: sys.exit('Cannot unambiguously identify official Linux ConsoleClient binary: '+repr(paths))
print(paths[0])
PY
)
echo "Downloading official Psiphon binary: $BINARY_PATH"
curl -fLsS --retry 3 "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/$BINARY_PATH" -o "$BASE/ConsoleClient"
chmod 755 "$BASE/ConsoleClient"
file "$BASE/ConsoleClient" 2>/dev/null || true
# IDs shown in upstream public README are example values, not guaranteed production bootstrap credentials.
cat > "$CONF/psiphon.config" <<EOF
{
  "LocalSocksProxyPort": 40000,
  "LocalHttpProxyPort": 40001,
  "PropagationChannelId": "24BCA4EE20BEB92C",
  "SponsorId": "721AE60D76700F5A",
  "EgressRegion": "$REGION",
  "TunnelPoolSize": 1,
  "EmitDiagnosticNotices": true
}
EOF
chmod 600 "$CONF/psiphon.config"
cat > "$BASE/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY ConsoleClient /usr/local/bin/ConsoleClient
WORKDIR /config
CMD ["/usr/local/bin/ConsoleClient", "-config", "/config/psiphon.config", "-dataRootDirectory", "/config"]
EOF
# Host networking is required for the proxy to bind 127.0.0.1 on the host.
docker build -t local-psiphon-console:latest "$BASE"
docker run -d --name vps-psiphon --restart unless-stopped --network host \
  -v "$CONF:/config" local-psiphon-console:latest
else
docker start vps-psiphon >/dev/null || true
if [[ ! -f $CONF/psiphon.config ]]; then
  echo '[ERROR] Existing container uses a different config path. Inspect docker mounts before proceeding.' >&2
  docker inspect vps-psiphon --format '{{json .Mounts}}' >&2
  exit 1
fi
fi
curl -fLsS --retry 3 'https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/psiphon_autopin.py' -o /opt/psiphon-autopin/psiphon_autopin.py
python3 -m py_compile /opt/psiphon-autopin/psiphon_autopin.py
cat > /etc/systemd/system/psiphon-autopin.service <<EOF
[Unit]
Description=Psiphon Auto Pin Monitor
Requires=docker.service
After=docker.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/psiphon-autopin/psiphon_autopin.py monitor --region $REGION
Restart=always
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# Do not enable monitoring until initial connection is verified.
echo
 echo 'Setup completed; verifying SOCKS and Google geo before starting monitoring:'
echo '  docker logs --tail 40 vps-psiphon'
echo '  curl -fsS --max-time 30 --proxy socks5h://127.0.0.1:40000 https://api.ipify.org'
echo '  python3 /opt/psiphon-autopin/psiphon_autopin.py search --region '"$REGION"
echo '  systemctl enable --now psiphon-autopin.service'
echo '[INFO] Waiting for Psiphon to connect (up to 90s)...'
CONNECTED=0
for i in $(seq 1 18); do
  if curl -fsS --max-time 5 --proxy socks5h://127.0.0.1:40000 https://api.ipify.org >/dev/null 2>&1; then CONNECTED=1; break; fi
  sleep 5
done
if [[ $CONNECTED -eq 0 ]]; then
  echo '[WARNING] Psiphon SOCKS5 did not connect. Check: docker logs --tail 100 vps-psiphon' >&2
  echo '[WARNING] Monitoring not enabled. Check bootstrap configuration and container logs.' >&2
  exit 2
fi
# The datastore can be created only after the first successful connection.
if python3 /opt/psiphon-autopin/psiphon_autopin.py search --region "$REGION" --attempts 12 --wait 35; then
  systemctl enable --now psiphon-autopin.service
  echo '[OK] Initial pin verified; monitoring enabled.'
else
  echo '[WARNING] No verified pin yet. Monitor was not enabled.' >&2
  exit 3
fi
echo 'SOCKS5: 127.0.0.1:40000 (localhost only)'
echo 'NOTE: The public upstream sample SponsorId/PropagationChannelId may require replacement with valid credentials.'
