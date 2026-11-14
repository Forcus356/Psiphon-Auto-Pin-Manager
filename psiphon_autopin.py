#!/usr/bin/env python3
"""Forcus Psiphon Auto-Pin v4.1.3: controlled server selection + SOCKS-only geolocation."""
import argparse
import datetime as dt
import fcntl
import ipaddress
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import shlex
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
ENV_FILE=Path('/etc/default/vps-psiphon')
INSTANCE=1
POLICY={}

def configure_instance(number):
    global INSTANCE,BASE,DATA,CONFIG,CONTAINER,STATE,CACHE,ENV_FILE,PROXY
    if not 1<=number<=99:raise ValueError('instance must be 1..99')
    INSTANCE=number
    suffix='' if number==1 else f'-{number}'
    BASE=Path('/opt/psiphon-autopin'+suffix)
    DATA=Path('/var/lib/psiphon-autopin'+suffix)
    CONTAINER='vps-psiphon'+suffix
    CONFIG=Path('/opt')/CONTAINER/'config/psiphon.config'
    STATE=DATA/'state.json';CACHE=DATA/'server-entry-cache.json'
    ENV_FILE=Path('/etc/default')/CONTAINER
    PROXY=f'127.0.0.1:{40000+2*(number-1)}'

def monitor_unit():
    return 'psiphon-autopin'+('' if INSTANCE==1 else f'-{INSTANCE}')+'.service'

def countries(value):
    rows=value.replace(',',' ').upper().split() if isinstance(value,str) else list(value or [])
    if any(not re.fullmatch('[A-Z]{2}',x) for x in rows):raise ValueError('countries must be two-letter codes')
    return list(dict.fromkeys(rows))

def speed_reason(speed):
    floor=float(POLICY.get('min_speed_kib',0))
    return f'Slow exit: {speed:.1f} < {floor:.1f} KiB/s' if floor and speed is not None and speed<floor else ''

def save_region(region):
    update_region_env(region)
    clear_target(region)
    cfg=read_json(DATA/'settings.json',{}) or {};cfg['region']=region
    atomic_json(DATA/'settings.json',cfg)
    STATE.unlink(missing_ok=True)

def rotation_regions(region):
    pool=countries(POLICY.get('region_pool',[]))
    if len(pool)<2:return [region]
    if region in pool:
        i=pool.index(region)+1;return pool[i:]+pool[:i]
    return pool

def remember_pin(candidate,region):
    path=DATA/'verified-reserve.json'
    data=read_json(path,{}) or {}
    rows=[x for x in data.get(region,[]) if x.get('diagnostic')!=candidate['diagnostic']]
    data[region]=[candidate,*rows][:8]
    atomic_json(path,data)

def prioritized_candidates(rows,region):
    saved=(read_json(DATA/'verified-reserve.json',{}) or {}).get(region,[])
    # Only fresh DB entries are used; the reserve changes ordering, never invents credentials.
    rank={x.get('diagnostic'):i for i,x in enumerate(saved)}
    random.shuffle(rows)
    return sorted(rows,key=lambda x:rank.get(x['diagnostic'],1000))

def log(message):
    print(dt.datetime.now().astimezone().isoformat(timespec='seconds'),message,flush=True)

def run(args, timeout=60, merge=False, accepted_codes=(0,)):
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT if merge else subprocess.PIPE,text=True,timeout=timeout)
    if p.returncode not in accepted_codes:
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

def backend():
    value=(read_json(DATA/'settings.json',{}) or {}).get('backend','console')
    if value not in ('console','vps-psiphon'):raise RuntimeError('Invalid saved backend')
    return value

def tunnel_action(action):
    # A --rm container owned by systemd cannot be stopped/restarted via Docker:
    # systemd would race discovery and reopen BoltDB while the exporter reads it.
    if backend()=='vps-psiphon':
        return run(['systemctl',action,CONTAINER+'.service'],timeout=120)
    return run(['docker',action,CONTAINER],timeout=90)

def update_region_env(region):
    if backend()!='vps-psiphon':return
    path=ENV_FILE
    lines=path.read_text().splitlines()
    lines=[line for line in lines if line.split('=',1)[0] not in ('EGRESS_REGION','REGION_POOL')]
    # Same-directory atomic replacement, retaining owner/mode of the env file.
    st=path.stat();name=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=path.parent,delete=False) as f:
            name=f.name
            f.write('\n'.join(lines+[f'EGRESS_REGION={region}',"REGION_POOL=''"])+ '\n')
            f.flush();os.fsync(f.fileno())
        os.chown(name,st.st_uid,st.st_gid);os.chmod(name,st.st_mode & 0o777)
        os.replace(name,path)
    finally:
        if name and os.path.exists(name):os.unlink(name)

def set_region(region,wait,clear_pool=False):
    """Persist region, discard the old target and reconnect under the writer lock."""
    settings=read_json(DATA/'settings.json',{}) or {}
    config=read_json(CONFIG)
    if not isinstance(config,dict):raise RuntimeError('Invalid Psiphon configuration')
    env_matches=True
    if backend()=='vps-psiphon':
        values=[shlex.split(line.split('=',1)[1],comments=True)
                for line in ENV_FILE.read_text().splitlines() if line.startswith('EGRESS_REGION=')]
        env_matches=(values==[[region]] if region else values==[[]] or values==[['']])
    if env_matches and settings.get('region','')==region and config.get('EgressRegion','')==region:
        if clear_pool:
            settings['region_pool']=[];atomic_json(DATA/'settings.json',settings);POLICY['region_pool']=[]
        log(f'Region already {region or "AUTO"}; tunnel unchanged')
        return
    stamp=dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
    backup=DATA/f'region-backup-{stamp}'
    backup.mkdir(mode=0o700)
    for path in (CONFIG,DATA/'settings.json',STATE,CACHE):
        if path.is_file():shutil.copy2(path,backup/path.name)
    if backend()=='vps-psiphon':
        shutil.copy2(ENV_FILE,backup/'vps-psiphon')
    update_region_env(region)
    change_config({'EgressRegion':region,'TargetServerEntry':'','TunnelPoolSize':int(POLICY.get('tunnel_pool',1))})
    settings['region']=region
    if clear_pool:settings['region_pool']=[];POLICY['region_pool']=[]
    atomic_json(DATA/'settings.json',settings)
    STATE.unlink(missing_ok=True);CACHE.unlink(missing_ok=True)
    log(f'Region saved: {region or "AUTO"}; backup={backup}; reconnecting')
    docker_restart(wait)
    log('SOCKS5 tunnel ready; the monitor will check Google/Gemini separately')

def socks_ip():
    # Explicit SOCKS5h proxy, remote DNS, no direct fallback or proxy bypass.
    ip=run(['curl','-4','-fsS','--connect-timeout','7','--max-time','15','--noproxy','', '--proxy',f'socks5h://{PROXY}','https://api.ipify.org'],timeout=20).strip()
    if ipaddress.ip_address(ip).version!=4:raise RuntimeError('Unexpected IPv4 address')
    return ip

def google_region():
    try:
        page=run(['curl','-4','-fsS','--max-time','25','--noproxy','','--proxy',f'socks5h://{PROXY}',
                  '-H','Accept-Language: en-US','https://www.youtube.com/'],timeout=30)
        found=re.search(r'"GL"\s*:\s*"([A-Z]{2})"',page)
        if found:return found.group(1)
    except Exception as exc:log('Fast Google classifier unavailable: '+str(exc))
    if not POLICY.get('legacy_geo_fallback',False):raise RuntimeError('Google country UNKNOWN')
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
    cmd=['python3',str(BASE/'gemini_probe.py'),'--port',port,'--host',PROXY.rsplit(':',1)[0]]
    if POLICY.get('impersonate'):
        cmd+=['--impersonate-dir',str(BASE/'curl-impersonate')]
    p=subprocess.run(cmd,
                     stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=185)
    label={0:'SERVING',1:'REFUSED',2:'INCONCLUSIVE',3:'CAPTCHA'}.get(p.returncode,'INCONCLUSIVE')
    log('Gemini '+label+': '+(p.stdout or p.stderr).strip()[-180:])
    return label

def speed_probe(mb):
    """Measure after the first byte, so connection setup is not mistaken for poor throughput."""
    if mb<=0 and not POLICY.get('min_speed_kib'):return None
    url=f'https://speed.cloudflare.com/__down?bytes={mb*1048576}' if mb else 'https://www.youtube.com/'
    cmd=['curl','-4','-fsS','--noproxy','','--proxy',f'socks5h://{PROXY}',
         '--connect-timeout','8','--max-time','50','-o','/dev/null',
         '-w','%{size_download} %{time_starttransfer} %{time_total} %{http_code}',url]
    size,first,total,code=run(cmd,timeout=55,accepted_codes=(0,28)).strip().split()
    elapsed=float(total)-float(first)
    if int(code) not in (200,206) or float(size)<50000 or elapsed<=0:raise RuntimeError('Insufficient throughput sample')
    speed=round(float(size)/elapsed/1024,1)
    log(f'Speed probe: {speed} KiB/s after first byte, sample={mb} MiB')
    return speed

def evaluate_exit(region, gemini, mb, strict=False):
    ip,geo=probe()
    verdict=gemini_verdict(gemini)
    speed=None
    if mb or POLICY.get('min_speed_kib'):
        try:speed=speed_probe(mb)
        except Exception as exc:log('Optional speed sample failed: '+str(exc))
    # Google classifications can differ from the server's requested country.
    # In strict mode reject *confirmed* mismatch, not an inconclusive Gemini reply.
    denied=POLICY.get('deny_regions',['RU'])
    reason=(f'Google={geo}' if geo in denied else 'Gemini REFUSED' if verdict=='REFUSED' else
            'Gemini CAPTCHA' if verdict=='CAPTCHA' else
            f'Google={geo} != requested {region}' if strict and region and geo!=region else '')
    return ip,geo,verdict,speed,reason

def adopt_current(region,gemini,mb,strict,observed=None):
    """Keep a healthy tunnel; recover an existing target only against the cached DB entry."""
    config=read_json(CONFIG,{}) or {}
    ip,geo,verdict,speed,reason = observed if observed is not None else evaluate_exit(region,gemini,mb,strict)
    if reason or speed_reason(speed):return False
    diag=connected_id()
    if config.get('TargetServerEntry'):
        staged=read_json(STATE,{}) or {}
        if staged.get('pin_prepared') and started_at()==staged.get('prepared_container_started_at'):
            log('Prepared target still pending a new container start; preserving unverified state')
            return True
        # Search can be interrupted after writing a target but before saving its state.
        # Require both the cached credential blob and the live diagnostic ID to match.
        row=candidate_for_connected_server(diag,region)
        if not row or row['encoded']!=config['TargetServerEntry']:
            log('Healthy targeted tunnel has no matching cached entry; pin remains unverified')
            return False
        if socks_ip()!=ip or connected_id()!=diag:
            raise RuntimeError('Targeted exit changed during pin recovery')
        atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,
            'diagnostic_id':diag,'server_ip':row['server_ip'],'gemini':verdict,
            'speed_kib_s':speed,'adopted_unpinned':False,
            'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
        remember_pin(row,region)
        log(f'RECOVERED VERIFIED PIN: exit={ip} Google={geo} Gemini={verdict} '
            f'server={row["server_ip"]} ID={diag}; no restart')
        return True
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

def wait_ready(wait):
    """Wait for an existing tunnel without restarting a potentially healthy pin."""
    deadline=time.monotonic()+wait;error='unknown'
    while time.monotonic()<deadline:
        try:return socks_ip()
        except Exception as exc:error=str(exc);time.sleep(2)
    raise RuntimeError(f'Psiphon not ready in {wait}s: {error}')

def docker_restart(wait):
    tunnel_action('restart')
    return wait_ready(wait)

def collect_candidates(region):
    # BoltDB is read only with the container stopped; always start it again.
    log('Exporting distinct server entries from read-only BoltDB...')
    tunnel_action('stop')
    try:
        raw=run([str(BASE/'psiphon-server-export'),str(db_path()),region],timeout=120)
        rows=[json.loads(line) for line in raw.splitlines() if line.strip()]
        rows=[v for v in rows if v.get('server_ip') and v.get('diagnostic') and v.get('encoded')]
        if not rows:raise RuntimeError(f'No known servers in region {region or "AUTO"}')
        cache_candidates(rows,region)
        log(f'Loaded {len(rows)} distinct servers')
        return rows
    finally:
        tunnel_action('start')

def apply_candidate(candidate,region):
    change_config({'EgressRegion':region,'TargetServerEntry':candidate['encoded'],'TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True})

def clear_target(region):
    update_region_env(region)
    change_config({'EgressRegion':region,'TargetServerEntry':'','TunnelPoolSize':int(POLICY.get('tunnel_pool',1)),'EmitDiagnosticNotices':True,'DisableReplay':True})

def verify_pin_current(region,gemini=False,mb=0,strict=False):
    state=read_json(STATE,{}) or {}
    config=read_json(CONFIG,{}) or {}
    if state.get('pin_prepared'):return False
    if state.get('region')!=region or not state.get('ip') or not config.get('TargetServerEntry'):
        return False
    ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
    diag=connected_id()
    if ip==state['ip'] and not reason and not speed_reason(speed) and diag==state.get('diagnostic_id'):
        log(f'Existing pin healthy: {ip}, {geo}, server={diag}')
        return True
    return False

def search(region,wait,delay,gemini=False,mb=0,strict=False):
    log(f'Server rotation started: {region or "AUTO"}; unlimited cycles')
    # A CLI region override must take effect before accepting the current exit.
    if (read_json(CONFIG,{}) or {}).get('EgressRegion','')!=region:
        clear_target(region)
        STATE.unlink(missing_ok=True)
        docker_restart(wait)
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
    pool=rotation_regions(region)
    while True:
        next_region=pool[cycle % len(pool)]
        if next_region!=region:
            region=next_region;save_region(region)
            log(f'Region pool advanced to {region}')
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
        candidates=prioritized_candidates(candidates,region)
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
                reason=reason or speed_reason(speed)
                if reason:
                    seen_exits.add(first)
                    log(f'Rejected exit {first}: {reason}')
                    continue
                # Recheck IP/geo, without an unnecessary second Gemini request.
                time.sleep(5)
                second,geo2=probe()
                if second!=first or geo2 in POLICY.get('deny_regions',['RU']) or (strict and region and geo2!=region) or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,
                                   'server_ip':server,'gemini':verdict,'speed_kib_s':speed,
                                   'adopted_unpinned':False,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                remember_pin(candidate,region)
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
    log(f'Monitor v4.1: region={region or "AUTO"} interval={interval}s Gemini={gemini} speedMB={mb}')
    failures=0;slow_count=0;slow_identity=None
    try:wait_ready(wait)
    except Exception as exc:log(f'Startup readiness pending: {exc}')
    while True:
        next_check=interval
        region=(read_json(DATA/'settings.json',{}) or {}).get('region',region) if POLICY.get('region_pool') else region
        try:
            ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
            state=read_json(STATE,{}) or {}
            config=read_json(CONFIG,{}) or {}
            diag=connected_id()
            identity=(ip,diag,started_at())
            if identity!=slow_identity:slow_count=0;slow_identity=identity
            slow=speed_reason(speed)
            slow_count=slow_count+1 if slow else 0
            if slow:
                log(f'{slow}; confirmation {slow_count}/{POLICY.get("slow_threshold",2)}')
                if slow_count>=int(POLICY.get('slow_threshold',2)):
                    log('Confirmed low throughput; searching for a faster exit')
                    search(region,wait,delay,gemini,mb,strict)
                    slow_count=0;failures=0
                    time.sleep(interval);continue
                next_check=min(interval,30)
            changed=bool(state) and (ip!=state.get('ip') or diag!=state.get('diagnostic_id'))
            if not reason and not speed_reason(speed) and state.get('pin_prepared') and config.get('TargetServerEntry'):
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
            slow_count=0
            failures+=1
            # An outage must not postpone retries for a full hourly health interval.
            next_check=min(interval,30)
            log(f'UNKNOWN/OUTAGE {failures}/{threshold}: {exc}; no RU inference')
            if failures>=threshold:
                log('Consecutive failures reached threshold; recovering connection')
                try:
                    try:
                        docker_restart(wait)
                    except Exception as restart_error:
                        # A dead TargetServerEntry must not be retried forever.
                        log(f'Restart could not restore SOCKS: {restart_error}; discovering another server')
                        search(region,wait,delay,gemini,mb,strict)
                    else:
                        # A failed Google classifier is not proof of a bad exit.
                        ip,geo,verdict,_,reason=evaluate_exit(region,gemini,0,strict)
                        if reason:
                            search(region,wait,delay,gemini,mb,strict)
                        else:
                            log(f'Recovered without full search: {ip} Google={geo} Gemini={verdict}')
                except Exception as e:
                    log(f'Recovery incomplete: {e}; defer next attempt')
                failures=0
        time.sleep(next_check)

def pool_monitor(region,interval,wait,delay,gemini=False,mb=0,strict=False,threshold=3):
    """Check sampled exits of a multi-tunnel pool; no single-IP PIN claim is made."""
    slow_count=0;failures=0
    log(f'Multi-tunnel monitor: {POLICY.get("tunnel_pool")} tunnels; PIN disabled')
    while True:
        next_check=interval
        try:
            region=(read_json(DATA/'settings.json',{}) or {}).get('region',region)
            ip=socks_ip();geo=google_region();verdict=gemini_verdict(gemini)
            speed=speed_probe(mb) if mb or POLICY.get('min_speed_kib') else None
            reason=(f'Google={geo}' if geo in POLICY.get('deny_regions',['RU']) else
                    verdict if verdict in ('REFUSED','CAPTCHA') else
                    'country mismatch' if strict and region and geo!=region else '')
            slow_count=slow_count+1 if speed_reason(speed) else 0
            if slow_count:
                next_check=min(interval,30)
                log(f'Low pool throughput: confirmation {slow_count}/{POLICY.get("slow_threshold",2)}; {speed_reason(speed)}')
            if reason or slow_count>=int(POLICY.get('slow_threshold',2)):
                region=rotation_regions(region)[0]
                log(f'Rotating pool: {reason or speed_reason(speed)}; next region={region or "AUTO"}')
                save_region(region);docker_restart(wait);slow_count=0
            else:
                atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,'gemini':verdict,
                    'speed_kib_s':speed,'tunnel_pool':int(POLICY.get('tunnel_pool',1)),
                    'adopted_unpinned':True,'pool_sample':True,
                    'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                log(f'Pool sample: exit={ip}, Google={geo}, Gemini={verdict}, speed={speed}')
            failures=0
        except Exception as exc:
            failures+=1;slow_count=0;next_check=min(interval,30)
            log(f'Pool check UNKNOWN {failures}/{threshold}: {exc}')
            if failures>=threshold:
                try:save_region(rotation_regions(region)[0]);docker_restart(wait)
                except Exception as error:log(f'Pool recovery pending: {error}')
                failures=0
        time.sleep(next_check)

def uninstall():
    """Remove just this instance; retain migration backups and any image used by others."""
    if os.geteuid()!=0:raise RuntimeError('Run as root')
    image=''
    try:
        mount=run(['docker','inspect','-f','{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}',CONTAINER]).strip()
        if mount!=str(CONFIG.parent):raise RuntimeError('Foreign container mount; refusing uninstall')
        image=run(['docker','inspect','-f','{{.Config.Image}}',CONTAINER]).strip()
    except RuntimeError as exc:
        if 'Foreign' in str(exc):raise
    for unit in (monitor_unit(),CONTAINER+'.service',CONTAINER+'-watchdog.timer',CONTAINER+'-watchdog.service'):
        subprocess.run(['systemctl','disable','--now',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        (Path('/etc/systemd/system')/unit).unlink(missing_ok=True)
    subprocess.run(['docker','rm','-f',CONTAINER],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for name in (CONTAINER,'psiphon-autopin'+('' if INSTANCE==1 else f'-{INSTANCE}'),CONTAINER+'-run',CONTAINER+'-prestart',CONTAINER+'-watchdog',CONTAINER+'-gemini-check',CONTAINER+'-advance-region'):
        (Path('/usr/local/sbin')/name).unlink(missing_ok=True)
    ENV_FILE.unlink(missing_ok=True)
    for path in (BASE,DATA,CONFIG.parent.parent):
        if path.exists():shutil.rmtree(path)
    run(['systemctl','daemon-reload'])
    if not any(Path('/opt').glob('psiphon-autopin*/autopin_menu.py')):
        launcher=Path('/usr/local/sbin/auto-pin')
        if launcher.is_file() and '# Managed by Forcus Auto-Pin menu' in launcher.read_text():launcher.unlink()
    if image:subprocess.run(['docker','image','rm',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print(f'Removed instance {INSTANCE}; backups under /var/backups/psiphon-autopin are retained')

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v4.1')
    ap.add_argument('command',choices=['menu','check','search','monitor','status','refresh-cache','prepare-pin','set-region','set-pool','region','pool','rotate','start','stop','restart','logs','speed','uninstall','xray'])
    ap.add_argument('value',nargs='?')
    ap.add_argument('--instance',type=int,default=1)
    ap.add_argument('--region-pool',default=None)
    ap.add_argument('--deny-regions',default=None)
    ap.add_argument('--min-speed',type=float,default=None)
    ap.add_argument('--slow-threshold',type=int,default=None)
    ap.add_argument('--impersonate',action='store_true',default=None)
    ap.add_argument('--no-impersonate',dest='impersonate',action='store_false')
    ap.add_argument('--region',default=None)
    ap.add_argument('--allow-interruption',action='store_true',help='Required for refresh-cache (briefly stops Psiphon)')
    ap.add_argument('--port',type=int,default=None)
    ap.add_argument('--interval',type=int,default=None)
    ap.add_argument('--wait',type=int,default=None)
    ap.add_argument('--delay',type=int,default=None)
    ap.add_argument('--gemini-check',action='store_true',default=None)
    ap.add_argument('--no-gemini-check',dest='gemini_check',action='store_false')
    ap.add_argument('--probe-mb',type=int,default=None)
    ap.add_argument('--strict-region',action='store_true',default=None)
    ap.add_argument('--no-strict-region',dest='strict_region',action='store_false')
    ap.add_argument('--fail-threshold',type=int,default=None)
    args=ap.parse_args()
    force_rotate=(args.command=='rotate')
    if not 1<=args.instance<=99:ap.error('instance must be 1..99')
    if args.instance!=1:configure_instance(args.instance)
    if args.command=='menu':
        return subprocess.call([sys.executable,str(BASE/'autopin_menu.py'),'--instance',str(args.instance)])
    if args.command in ('region','pool'):
        if args.value is None:ap.error('region/pool requires a value')
        if args.command=='region':args.region=args.value;args.command='set-region'
        else:args.region_pool=args.value;args.command='set-pool'
    if args.command=='rotate':args.command='search'
    if args.command=='set-region' and args.region is None:ap.error('set-region requires --region CC|AUTO')
    settings=read_json(DATA/'settings.json',{}) or {}
    for key,default in [('interval',300),('wait',75),('delay',12)]:
        if getattr(args,key) is None:setattr(args,key,int(settings.get(key,default)))
    global POLICY
    POLICY=dict(settings)
    for key,value in [('region_pool',args.region_pool),('deny_regions',args.deny_regions)]:
        if value is not None:
            try:POLICY[key]=countries(value)
            except ValueError as exc:ap.error(str(exc))
    if args.min_speed is not None:POLICY['min_speed_kib']=args.min_speed
    if args.slow_threshold is not None:POLICY['slow_threshold']=args.slow_threshold
    if args.impersonate is not None:POLICY['impersonate']=args.impersonate
    if not math.isfinite(float(POLICY.get('min_speed_kib',0))) or float(POLICY.get('min_speed_kib',0))<0 or int(POLICY.get('slow_threshold',2))<2:ap.error('min-speed>=0; slow-threshold>=2')
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
    bind=str(settings.get('bind','127.0.0.1'))
    try:
        if ipaddress.ip_address(bind).version!=4:raise ValueError('IPv4 required')
    except ValueError:ap.error('invalid bind address')
    PROXY=f'{bind}:{port}'
    if region=='AUTO':region=''
    if region and not re.fullmatch('[A-Z]{2}',region):ap.error('invalid country')
    if args.interval<60 or args.wait<20 or args.delay<2:ap.error('interval>=60 wait>=20 delay>=2')
    if not 0<=args.probe_mb<=10 or not 2<=args.fail_threshold<=20:ap.error('probe-mb 0..10, fail-threshold 2..20')
    if args.command=='status':
        print(json.dumps({'instance':INSTANCE,'region_pool':POLICY.get('region_pool',[]),'min_speed_kib':POLICY.get('min_speed_kib',0),'slow_threshold':POLICY.get('slow_threshold',2),'deny_regions':POLICY.get('deny_regions',['RU']),'impersonate':POLICY.get('impersonate',False),'backend':backend(),'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}','gemini_check':args.gemini_check,'probe_mb':args.probe_mb,'strict_region':args.strict_region,'fail_threshold':args.fail_threshold},indent=2));return 0
    if args.command=='xray':
        print(json.dumps({'tag':'psiphon-out'+('' if INSTANCE==1 else f'-{INSTANCE}'),'protocol':'socks','settings':{'servers':[{'address':bind,'port':port}]}},indent=2));return 0
    if args.command=='uninstall':uninstall();return 0
    if args.command=='logs':
        return subprocess.call(['journalctl','-u',monitor_unit(),'-u',CONTAINER+'.service','-n',args.value or '50','--no-pager'])
    if args.command=='speed':speed_probe(args.probe_mb or 4);return 0
    if args.command in ('start','stop','restart'):
        if args.command!='start':run(['systemctl','stop',monitor_unit()])
        tunnel_action(args.command)
        if args.command!='stop':run(['systemctl','start',monitor_unit()])
        return 0
    if args.command=='check':
        _,_,_,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
        return 2 if reason or speed_reason(speed) else 0
    DATA.mkdir(parents=True,exist_ok=True)
    resume_monitor=False
    if args.command in ('set-region','set-pool','search'):
        active=subprocess.run(['systemctl','is-active','--quiet',monitor_unit()]).returncode==0
        if active:
            run(['systemctl','stop',monitor_unit()],timeout=120)
            resume_monitor=True
    try:
        with (DATA/'lock').open('w') as f:
            try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise RuntimeError('Another search/monitor is running')
            if args.region is None:region=(read_json(DATA/'settings.json',{}) or {}).get('region',region)
            if force_rotate:
                pool=rotation_regions(region);region=pool[0]
                save_region(region)
                docker_restart(args.wait)
            if args.command=='set-region':
                set_region(region,args.wait,clear_pool=True)
            elif args.command=='set-pool':
                settings=read_json(DATA/'settings.json',{}) or {}
                if args.region_pool is None:ap.error('set-pool requires --region-pool CC,CC or an empty string')
                settings['region_pool']=countries(args.region_pool)
                atomic_json(DATA/'settings.json',settings)
                POLICY['region_pool']=settings['region_pool']
                if settings['region_pool'] and region not in settings['region_pool']:set_region(settings['region_pool'][0],args.wait)
                log('Region pool saved: '+str(settings['region_pool']))
            elif args.command=='refresh-cache':
                # Explicit operator action with an interruption: stop, export, start.
                # Never claim this happens without a connection interruption.
                if not args.allow_interruption:
                    raise RuntimeError('refresh-cache interrupts Psiphon; repeat with --allow-interruption')
                collect_candidates(region)
                log('Candidate cache refreshed; Psiphon container restarted (tunnel may change)')
            elif args.command=='prepare-pin':
                ip,geo,verdict,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
                if reason or speed_reason(speed):raise RuntimeError(f'Exit is not eligible for pin staging: {reason or speed_reason(speed)}')
                state=read_json(STATE,{}) or {}
                diag=connected_id()
                if not state or state.get('ip')!=ip or state.get('diagnostic_id')!=diag:
                    adopt_current(region,args.gemini_check,args.probe_mb,args.strict_region,
                                  observed=(ip,geo,verdict,speed,reason))
                if not prepare_current_pin(region,ip,geo,diag):
                    log('No unique cached matching server (or pin already prepared); tunnel untouched')
            elif args.command=='search':
                if int(POLICY.get('tunnel_pool',1))>1:
                    if not force_rotate:save_region(rotation_regions(region)[0]);docker_restart(args.wait)
                else:search(region,args.wait,args.delay,args.gemini_check,args.probe_mb,args.strict_region)
            else:
                loop=pool_monitor if int(POLICY.get('tunnel_pool',1))>1 else monitor
                loop(region,args.interval,args.wait,args.delay,args.gemini_check,args.probe_mb,args.strict_region,args.fail_threshold)
    finally:
        if resume_monitor:run(['systemctl','start',monitor_unit()],timeout=120)
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:log('Stopped');sys.exit(130)
    except Exception as exc:log(f'FATAL: {exc}');sys.exit(1)
