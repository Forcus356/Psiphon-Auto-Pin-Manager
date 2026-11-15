#!/usr/bin/env python3
"""Forcus Psiphon Auto-Pin v4.3.1: controlled server selection + SOCKS-only geolocation."""
import argparse
import contextlib
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

class GoogleGeoUnknown(RuntimeError):
    """No Google/YouTube country was observed through the selected proxy."""

def youtube_enabled():
    return POLICY.get('youtube_mode',False) is True

def geo_reason(geo,region,strict=False):
    # RU is mandatory in YouTube mode, regardless of the ordinary deny/strict policy.
    # The saved policies remain untouched for when YouTube mode is disabled.
    if youtube_enabled():
        return '' if geo=='RU' else f'YouTube requires Google=RU; got {geo or "UNKNOWN"}'
    if geo in POLICY.get('deny_regions',['RU']):return f'Google={geo}'
    if strict and region and geo!=region:return f'Google={geo} != requested {region}'
    return ''

def boot_id():
    try:return Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    except OSError:return ''

def youtube_report(status,ip=None,geo=None,diag=None,speed=None,pin=False,detail=''):
    if not youtube_enabled():return
    path=DATA/'youtube-status.json';old=read_json(path,{}) or {}
    now=dt.datetime.now(dt.timezone.utc).isoformat()
    try:session=started_at()
    except Exception:session=None
    obj={'status':status,'ip':ip,'google_region':geo or 'UNKNOWN',
         'diagnostic_id':diag,'speed_kib_s':speed,'pin_verified':bool(pin),
         'checked_at':now,'boot_id':boot_id(),'container_started_at':session,
         'last_success_at':old.get('last_success_at'),'detail':detail}
    if geo=='RU' and status in ('RU VERIFIED','PIN VERIFIED'):obj['last_success_at']=now
    atomic_json(path,obj)

def youtube_observation(ip,geo,verdict,speed,reason='',pin=False,diag=None):
    if not youtube_enabled():return
    speed_unknown=bool(POLICY.get('min_speed_kib')) and speed is None
    detail=reason or speed_reason(speed) or ('Speed probe UNKNOWN; awaiting a new sample' if speed_unknown else '')
    status=('UNKNOWN' if not re.fullmatch('[A-Z]{2}',str(geo or '')) else
            'SEARCHING' if geo!='RU' else
            'DEGRADED' if detail else
            'PIN VERIFIED' if pin else 'RU VERIFIED')
    youtube_report(status,ip,geo,diag,speed,pin and status=='PIN VERIFIED',detail)

def youtube_status(settings=None,live=True):
    cfg=settings if settings is not None else POLICY
    if not cfg.get('youtube_mode',False):return {'status':'DISABLED'}
    obj=read_json(DATA/'youtube-status.json',{}) or {'status':'UNKNOWN'}
    stale=obj.get('boot_id')!=boot_id()
    try:
        age=(dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(obj['checked_at'])).total_seconds()
        stale=stale or not 0<=age<=max(600,2*int(cfg.get('interval',300)))
        if live and obj.get('status') in ('RU VERIFIED','PIN VERIFIED'):
            stale=stale or obj.get('container_started_at')!=started_at()
    except (KeyError,ValueError,TypeError,RuntimeError,subprocess.SubprocessError,OSError):stale=True
    if stale:
        obj=dict(obj,last_status=obj.get('status'),status='UNKNOWN',pin_verified=False,detail='A fresh check is required after a restart or stale observation')
    return obj

def xray_routing(youtube_instance,gemini_instance):
    """Export a fragment only. Never read or modify an Xray installation."""
    if youtube_instance==gemini_instance:raise ValueError('YouTube and Gemini require different instances')
    out=[];configs=[]
    for number,tag in ((youtube_instance,'psiphon-youtube'),(gemini_instance,'psiphon-gemini')):
        if not 1<=number<=99:raise ValueError('instance must be 1..99')
        directory=DATA.parent/('psiphon-autopin'+('' if number==1 else f'-{number}'))
        cfg=read_json(directory/'settings.json',{}) or {}
        if not cfg:raise ValueError(f'Instance {number} is not installed')
        configs.append(cfg);address=cfg.get('bind','127.0.0.1');port=int(cfg['port'])
        if not 1024<=port<=65534:raise ValueError('invalid saved port')
        out.append({'tag':tag,'protocol':'socks','settings':{'servers':[{'address':address,'port':port}]}})
    yt,gm=configs
    if not yt.get('youtube_mode') or yt.get('gemini_check'):raise ValueError('YouTube instance must enable YouTube and disable Gemini')
    if not gm.get('gemini_check') or gm.get('youtube_mode'):raise ValueError('Gemini instance must enable Gemini and disable YouTube')
    if yt.get('tunnel_pool',1)!=1 or not ipaddress.ip_address(yt.get('bind','127.0.0.1')).is_loopback:
        raise ValueError('YouTube requires one tunnel on loopback')
    ports=[set((int(c['port']),int(c['port'])+1)) if c.get('publish_http',True) else {int(c['port'])} for c in configs]
    if ports[0]&ports[1]:raise ValueError('Instance proxy ports overlap')
    yt_domains=['domain:youtube.com','domain:youtu.be','domain:googlevideo.com','domain:ytimg.com','full:youtubei.googleapis.com']
    gm_domains=['domain:gemini.google.com','domain:aistudio.google.com','full:generativelanguage.googleapis.com']
    out.append({'tag':'psiphon-quic-block','protocol':'blackhole','settings':{}})
    rules=[{'type':'field','network':'udp','port':'443','domain':yt_domains+gm_domains,'outboundTag':'psiphon-quic-block'},
           {'type':'field','network':'tcp','domain':yt_domains,'outboundTag':'psiphon-youtube'},
           {'type':'field','network':'tcp','domain':gm_domains,'outboundTag':'psiphon-gemini'}]
    return {'outbounds':out,'routing':{'domainStrategy':'AsIs','rules':rules}}

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
        # Persist the rename as well as its contents across an unclean reboot.
        directory=os.open(p.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
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
        directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
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
    if youtube_enabled() or not POLICY.get('legacy_geo_fallback',False):raise GoogleGeoUnknown('Google country UNKNOWN')
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
    if len(geo)!=1 or not re.fullmatch('[A-Z]{2}',geo[0]):raise GoogleGeoUnknown(f'Google region UNKNOWN: {geo}')
    return geo[0]

def probe():
    first=socks_ip()
    for attempt in range(3 if youtube_enabled() else 1):
        try:country=google_region();break
        except GoogleGeoUnknown:
            if not youtube_enabled() or attempt==2:raise
            youtube_report('UNKNOWN',ip=first,detail='Retrying Google GeoIP through SOCKS5h')
            time.sleep(10)
    last=socks_ip()
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
    reason=geo_reason(geo,region,strict) or ('Gemini REFUSED' if verdict=='REFUSED' else 'Gemini CAPTCHA' if verdict=='CAPTCHA' else '')
    youtube_observation(ip,geo,verdict,speed,reason)
    return ip,geo,verdict,speed,reason

def adopt_current(region,gemini,mb,strict,observed=None,auto_pin=True):
    """Keep a healthy tunnel; recover an existing target only against the cached DB entry."""
    config=read_json(CONFIG,{}) or {}
    ip,geo,verdict,speed,reason = observed if observed is not None else evaluate_exit(region,gemini,mb,strict)
    if reason or geo_reason(geo,region,strict) or speed_reason(speed):return False
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
        youtube_observation(ip,geo,verdict,speed,pin=True,diag=diag)
        log(f'RECOVERED VERIFIED PIN: exit={ip} Google={geo} Gemini={verdict} '
            f'server={row["server_ip"]} ID={diag}; no restart')
        return True
    atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,
        'diagnostic_id':diag,'server_ip':None,'gemini':verdict,
        'speed_kib_s':speed,'adopted_unpinned':True,
        'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
    youtube_observation(ip,geo,verdict,speed,diag=diag)
    log(f'ADOPTED HEALTHY exit={ip} Google={geo} Gemini={verdict} ID={diag}; no restart (not targeted pin)')
    if auto_pin:auto_pin_current(region,gemini,mb,strict)
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
    if not reason and not geo_reason(geo,region) and ip==state.get('ip') and diag==state.get('diagnostic_id'):
        state.update(pin_prepared=False,adopted_unpinned=False,
                     verified_at=dt.datetime.now(dt.timezone.utc).isoformat())
        state.pop('prepared_container_started_at',None)
        atomic_json(STATE,state)
        youtube_observation(ip,geo,state.get('gemini'),state.get('speed_kib_s'),pin=True,diag=diag)
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

def export_candidates_stopped(region):
    raw=run([str(BASE/'psiphon-server-export'),str(db_path()),region],timeout=120)
    rows=[json.loads(line) for line in raw.splitlines() if line.strip()]
    rows=[v for v in rows if v.get('server_ip') and v.get('diagnostic') and v.get('encoded')]
    if not rows:raise RuntimeError(f'No known servers in region {region or "AUTO"}')
    cache_candidates(rows,region)
    log(f'Loaded {len(rows)} distinct servers')
    return rows

def collect_candidates(region):
    log('Exporting distinct server entries from read-only BoltDB...')
    tunnel_action('stop')
    try:return export_candidates_stopped(region)
    finally:tunnel_action('start')

def auto_pin_current(region,gemini=False,mb=0,strict=False,wait=None):
    """Populate the stopped DB cache, connect to the observed server, then verify."""
    cfg=read_json(CONFIG,{}) or {};state=read_json(STATE,{}) or {}
    if int(POLICY.get('tunnel_pool',1))!=1 or cfg.get('TargetServerEntry') or not state.get('adopted_unpinned') or speed_reason(state.get('speed_kib_s')) or geo_reason(state.get('google_region'),region):
        return False
    retry_path=DATA/'initial-pin-attempt.json'
    retry=read_json(retry_path,{}) or {};now=time.time()
    if retry.get('region')==region and float(retry.get('retry_after',0))>now:return False
    # Failure never causes a tight reconnect loop; retry on a later normal health cycle.
    atomic_json(retry_path,{'region':region,'retry_after':now+max(60,int(POLICY.get('interval',300)))})
    expected=state.get('diagnostic_id');initial_ip=state.get('ip');changed=False
    wait=int(wait if wait is not None else POLICY.get('wait',75))
    try:
        if not expected or connected_id()!=expected or socks_ip()!=initial_ip:
            raise RuntimeError('Current exit changed before initial pin')
        old_start=started_at()
        log(f'INITIAL PIN: building cache for ID={expected}; one controlled reconnect')
        tunnel_action('stop')
        try:
            export_candidates_stopped(region)
            candidate=candidate_for_connected_server(expected,region)
            if candidate is None:raise RuntimeError('Current server has no unique datastore entry')
            changed=True
            pending=dict(state);pending.update(pin_prepared=True,prepared_container_started_at=old_start)
            atomic_json(STATE,pending)
            apply_candidate(candidate,region)
        finally:
            tunnel_action('start')
        wait_ready(wait)
        if started_at()==old_start:raise RuntimeError('No new container start observed')
        ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
        if reason or speed_reason(speed):raise RuntimeError('Pinned exit did not pass current policy')
        if connected_id()!=expected:raise RuntimeError('Pinned server ID mismatch')
        time.sleep(2)
        if socks_ip()!=ip or connected_id()!=expected:raise RuntimeError('Pinned exit changed during verification')
        if youtube_enabled():
            confirmed_ip,confirmed_geo=probe()
            if confirmed_ip!=ip or geo_reason(confirmed_geo,region,strict):raise RuntimeError('YouTube GeoIP changed during PIN verification')
        if (read_json(CONFIG,{}) or {}).get('TargetServerEntry')!=candidate['encoded']:
            raise RuntimeError('Configured target changed during verification')
        atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,'gemini':verdict,
            'speed_kib_s':speed,'diagnostic_id':expected,'server_ip':candidate['server_ip'],
            'adopted_unpinned':False,'pin_prepared':False,
            'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
    except Exception as exc:
        youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail='Initial PIN deferred: '+str(exc))
        if changed:
            atomic_json(CONFIG,cfg);atomic_json(STATE,state)
            try:docker_restart(wait)
            except Exception as restore_error:
                raise RuntimeError('Initial PIN rollback could not restore proxy') from restore_error
        else:
            try:wait_ready(wait)
            except Exception as recovery_error:
                raise RuntimeError('Initial PIN attempt left proxy unavailable') from recovery_error
        log(f'INITIAL PIN DEFERRED: {exc}; no verified PIN claimed; retry on a later health cycle')
        return False
    retry_path.unlink(missing_ok=True)
    try:remember_pin(candidate,region)
    except Exception as exc:log(f'PIN verified; reserve update deferred: {type(exc).__name__}')
    youtube_observation(ip,geo,verdict,speed,pin=True,diag=expected)
    log(f'INITIAL PIN VERIFIED: exit={ip} Google={geo} Gemini={verdict} ID={expected}; initial exit={initial_ip}')
    return True


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
    if ip==state['ip'] and not reason and not geo_reason(geo,region,strict) and not speed_reason(speed) and diag==state.get('diagnostic_id'):
        youtube_observation(ip,geo,verdict,speed,pin=True,diag=diag)
        log(f'Existing pin healthy: {ip}, {geo}, server={diag}')
        return True
    return False

def search(region,wait,delay,gemini=False,mb=0,strict=False):
    youtube_report('SEARCHING',detail='Searching for Google GeoIP RU')
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
                if second!=first or geo_reason(geo2,region,strict) or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,
                                   'server_ip':server,'gemini':verdict,'speed_kib_s':speed,
                                   'adopted_unpinned':False,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                remember_pin(candidate,region)
                youtube_observation(first,geo2,verdict,speed,pin=True,diag=expected)
                log(f'PIN VERIFIED: exit={first} Google={geo2} Gemini={verdict} server={server} ID={expected}')
                return True
            except Exception as exc:
                youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail=str(exc))
                log(f'Server {server} failed: {exc}')
            finally:
                time.sleep(delay)
        log('All candidates exhausted. Refreshing discovery and repeating in 60s...')
        clear_target(region)
        try:docker_restart(wait)
        except Exception as e:log(f'Discovery connection warning: {e}')
        time.sleep(60)
        # After a full cycle, the same exit could have been reclassified by Google.
        seen_exits.clear()

def monitor(region,interval,wait,delay,gemini=False,mb=0,strict=False,threshold=3):
    log(f'Monitor v4.3: region={region or "AUTO"} interval={interval}s Gemini={gemini} speedMB={mb}')
    youtube_report('UNKNOWN',detail='Waiting for startup verification')
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
            youtube_observation(ip,geo,verdict,speed,reason,pin=bool(config.get('TargetServerEntry') and not state.get('adopted_unpinned',True) and not state.get('pin_prepared') and diag==state.get('diagnostic_id') and ip==state.get('ip')),diag=diag)
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
                    if auto_pin_current(region,gemini,mb,strict,wait):
                        failures=0;time.sleep(interval);continue
                log(f'Healthy exit unchanged: {ip} Google={geo} Gemini={verdict}; '
                    + ('adopted (not pinned)' if state.get('adopted_unpinned') else 'pinned'))
        except Exception as exc:
            youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail=str(exc))
            if youtube_enabled() and isinstance(exc,GoogleGeoUnknown):
                log('YouTube GeoIP UNKNOWN; retrying without accepting or restarting the server')
                failures=0;time.sleep(min(interval,30));continue
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
    if youtube_enabled():raise ValueError('YouTube mode requires a single tunnel for verified PIN')
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

def uninstall(purge_deps=False):
    """Remove just this instance; retain migration backups and any image used by others."""
    if os.geteuid()!=0:raise RuntimeError('Run as root')
    cleanup=None;dependency_module=None
    if (BASE/'autopin_system.py').is_file():
        import autopin_system
        cleanup=autopin_system.cleanup_dependencies;dependency_module=autopin_system
    elif purge_deps:
        raise RuntimeError('Dependency receipt helper missing; update Auto-Pin first')
    with (dependency_module.locked() if dependency_module else contextlib.nullcontext()):
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
        if cleanup:
            result=cleanup(purge=purge_deps,lock_held=True)
            print(json.dumps({'dependency_cleanup':result},indent=2))
            if any(isinstance(value,dict) and (value.get('exit_code',0)!=0 or value.get('remaining')) for value in result.values()):
                raise RuntimeError('Auto-Pin removed, but some owned dependencies could not be removed; receipt retained')
        print(f'Removed instance {INSTANCE}; backups under /var/backups/psiphon-autopin are retained')

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v4.3')
    ap.add_argument('command',choices=['menu','check','search','monitor','status','refresh-cache','prepare-pin','set-region','set-pool','region','pool','rotate','start','stop','restart','logs','speed','uninstall','xray','xray-routing','update'])
    ap.add_argument('value',nargs='?')
    ap.add_argument('--instance',type=int,default=1)
    ap.add_argument('--youtube-instance',type=int,default=1)
    ap.add_argument('--gemini-instance',type=int,default=2)
    ap.add_argument('--purge-deps',action='store_true',help='With uninstall: remove only Docker/Go installed by Auto-Pin and no longer used')
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
    if args.purge_deps and args.command!='uninstall':ap.error('--purge-deps requires uninstall')
    force_rotate=(args.command=='rotate')
    if not 1<=args.instance<=99:ap.error('instance must be 1..99')
    if args.instance!=1:configure_instance(args.instance)
    if args.command in ('menu','update'):
        return subprocess.call([sys.executable,str(BASE/'autopin_menu.py'),'--instance',str(args.instance),*(['--update'] if args.command=='update' else [])])
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
    if type(POLICY.get('youtube_mode',False)) is not bool:ap.error('youtube_mode must be boolean')
    POLICY.update(interval=args.interval,wait=args.wait)
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
    if args.command=='xray-routing':
        print(json.dumps(xray_routing(args.youtube_instance,args.gemini_instance),indent=2));return 0
    if args.command not in ('status','logs','uninstall','stop','xray') and youtube_enabled():
        if args.gemini_check:ap.error('YouTube and Gemini require separate instances; use --no-gemini-check on the YouTube instance')
        if int(settings.get('tunnel_pool',1))!=1:ap.error('YouTube requires --tunnel-pool 1')
        if not ipaddress.ip_address(bind).is_loopback:ap.error('YouTube requires loopback binding')
    if args.command=='status':
        print(json.dumps({'instance':INSTANCE,'youtube_mode':youtube_enabled(),'youtube':youtube_status(POLICY),'region_pool':POLICY.get('region_pool',[]),'min_speed_kib':POLICY.get('min_speed_kib',0),'slow_threshold':POLICY.get('slow_threshold',2),'deny_regions':POLICY.get('deny_regions',['RU']),'impersonate':POLICY.get('impersonate',False),'backend':backend(),'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}','gemini_check':args.gemini_check,'probe_mb':args.probe_mb,'strict_region':args.strict_region,'fail_threshold':args.fail_threshold},indent=2));return 0
    if args.command=='xray':
        print(json.dumps({'tag':'psiphon-out'+('' if INSTANCE==1 else f'-{INSTANCE}'),'protocol':'socks','settings':{'servers':[{'address':bind,'port':port}]}},indent=2));return 0
    if args.command=='uninstall':uninstall(args.purge_deps);return 0
    if args.command=='logs':
        return subprocess.call(['journalctl','-u',monitor_unit(),'-u',CONTAINER+'.service','-n',args.value or '50','--no-pager'])
    if args.command=='speed':speed_probe(args.probe_mb or 4);return 0
    if args.command in ('start','stop','restart'):
        if args.command!='start':run(['systemctl','stop',monitor_unit()])
        tunnel_action(args.command)
        if args.command!='stop':run(['systemctl','start',monitor_unit()])
        return 0
    if args.command=='check':
        try:
            ip,geo,verdict,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
            youtube_observation(ip,geo,verdict,speed,reason)
        except Exception as exc:
            youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail=str(exc));raise
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
                                  observed=(ip,geo,verdict,speed,reason),auto_pin=False)
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
