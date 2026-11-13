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
