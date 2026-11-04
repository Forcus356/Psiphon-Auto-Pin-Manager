#!/usr/bin/env python3
"""Psiphon Auto-Pin Manager. Requires existing Docker Psiphon setup."""
import argparse, datetime, ipaddress, json, os, re, shutil, subprocess, tempfile, time
from pathlib import Path

UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'

def cmd(*args, timeout=45, check=True):
    p=subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode: raise RuntimeError(f'{args[0]} failed: {p.stderr[-350:]}')
    return p.stdout

def curl(url, proxy, timeout=18):
    return cmd('curl','-4','-fsSL','--compressed','--max-time',str(timeout),'--proxy',f'socks5h://{proxy}', '-A',UA,'-H','Accept-Language: en-US,en;q=0.9',url,timeout=timeout+5)

def exit_ip(proxy):
    ip=curl('https://api.ipify.org',proxy).strip()
    ipaddress.ip_address(ip)
    return ip

def google_region(proxy):
    html=curl('https://www.google.com/',proxy)
    # Same primary signal as Davoyan/ipregion lookup_google: locale marker.
    vals=re.findall(r'"[a-z]{2}[_-]([A-Z]{2})"',html)
    vals=[x for x in vals if x not in ('WW','EU')]
    if not vals: raise RuntimeError('Google country marker not found (UNKNOWN, not RU)')
    return vals[-1]

def check(proxy):
    ip1=exit_ip(proxy)
    region=google_region(proxy)
    ip2=exit_ip(proxy)
    if ip1!=ip2: raise RuntimeError(f'Exit IP changed during test: {ip1} -> {ip2}')
    return ip1,region

def latest_diagnostic(container):
    logs=cmd('docker','logs','--tail','3000',container)
    ids=[]
    for line in logs.splitlines():
        try: obj=json.loads(line)
        except ValueError: continue
        if obj.get('noticeType')=='ServerTimestamp':
            v=obj.get('data',{}).get('diagnosticID','')
            if re.fullmatch(r'[A-Za-z0-9]{8}',v): ids.append(v)
    if not ids: raise RuntimeError('No valid ServerTimestamp diagnosticID in Docker logs')
    return ids[-1]

def get_entry(db, diagnostic, region):
    raw=db.read_bytes().decode('utf-8',errors='replace')
    decoder=json.JSONDecoder(); matches=[]
    for m in re.finditer(r'\{',raw):
        try: entry,end=decoder.raw_decode(raw,m.start())
        except ValueError: continue
        if not isinstance(entry,dict): continue
        if not str(entry.get('tag','')).startswith(diagnostic): continue
        if not entry.get('ipAddress') or not entry.get('capabilities'): continue
        if '\ufffd' in raw[m.start():end]: continue
        if region and entry.get('region')!=region: continue
        matches.append(entry)
    if not matches: raise RuntimeError('No matching server entry in BoltDB; refusing to pin')
    if len({e['ipAddress'] for e in matches})!=1: raise RuntimeError('Ambiguous server entries; refusing to pin')
    return max(matches,key=lambda e:int(e.get('configurationVersion',0)))

def save_config(path, changes):
    original=path.stat(); cfg=json.loads(path.read_text()); cfg.update(changes)
    backup=path.with_name(path.name+'.backup-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    shutil.copy2(path,backup)
    tmp=None
    try:
        with tempfile.NamedTemporaryFile(mode='w',dir=path.parent,delete=False) as f:
            tmp=f.name; json.dump(cfg,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,original.st_uid,original.st_gid)
        os.chmod(tmp,original.st_mode & 0o777)
        os.replace(tmp,path)
    finally:
        if tmp and os.path.exists(tmp): os.unlink(tmp)
    return backup

def restart(container,wait):
    cmd('docker','restart',container,timeout=90)
    time.sleep(wait)

def log(msg): print(datetime.datetime.now().isoformat(timespec='seconds'),msg,flush=True)

def main():
    p=argparse.ArgumentParser(description='Auto-rotate and pin Psiphon based on Google geo signal')
    p.add_argument('action',choices=['check','search','monitor'])
    p.add_argument('--proxy',default='127.0.0.1:40000')
    p.add_argument('--container',default='vps-psiphon')
    p.add_argument('--config',default='/opt/vps-psiphon/config/psiphon.config')
    p.add_argument('--db',default='/opt/vps-psiphon/config/ca.psiphon.PsiphonTunnel.tunnel-core/datastore/psiphon.boltdb')
    p.add_argument('--region',default='SE',help='Psiphon egress region preference')
    p.add_argument('--attempts',type=int,default=12)
    p.add_argument('--wait',type=int,default=35)
    p.add_argument('--interval',type=int,default=900)
    p.add_argument('--state',default='/var/lib/psiphon-autopin/state.json')
    a=p.parse_args(); path=Path(a.config); db=Path(a.db)
    if a.attempts<1 or a.wait<5 or a.interval<30: p.error('invalid timing/attempts')
    def probe():
        try:
            ip,region=check(a.proxy); log(f'IP={ip} Google={region}')
            return ip,region
        except Exception as e:
            log(f'CHECK UNKNOWN: {e}'); return None,None
    def search():
        if not path.is_file() or not db.is_file(): raise RuntimeError('Config or datastore not found')
        cfg=json.loads(path.read_text())
        # Unpin before search. Retain region preference, avoid disabling tactics while searching.
        backup=save_config(path,{'TargetServerEntry':'','EgressRegion':a.region,'DisableTactics':False})
        log(f'Search started; original config backed up: {backup}')
        seen=set()
        for n in range(1,a.attempts+1):
            log(f'Attempt {n}/{a.attempts}: restarting Psiphon')
            restart(a.container,a.wait)
            ip,geo=probe()
            if not ip or not geo: continue
            if ip in seen: log('Repeated exit IP (no guarantee of new address)')
            seen.add(ip)
            if geo=='RU': log('Google=RU, rotating'); continue
            diagnostic=latest_diagnostic(a.container)
            entry=get_entry(db,diagnostic,a.region)
            target=('0 0 0 0 '+json.dumps(entry,separators=(',',':'))).encode().hex()
            pinned_backup=save_config(path,{'TargetServerEntry':target,'TunnelPoolSize':1,'EgressRegion':a.region,'DisableTactics':True,'InitialLimitTunnelProtocols':[],'InitialLimitTunnelProtocolsCandidateCount':0,'EmitDiagnosticNotices':True,'EmitDiagnosticNetworkParameters':False})
            log(f'Candidate Google={geo} exit={ip}; pinning entry={entry["ipAddress"]}; backup={pinned_backup}')
            restart(a.container,a.wait)
            new_ip,new_geo=probe()
            if new_ip==ip and new_geo==geo:
                state=Path(a.state); state.parent.mkdir(parents=True,exist_ok=True)
                state.write_text(json.dumps({'ip':ip,'google_region':geo,'updated':datetime.datetime.now().isoformat()}))
                log(f'PIN VERIFIED: {ip} Google={geo}'); return True
            log('Post-pin verification failed; continuing search')
            # A failed candidate will be unpinned at the next search iteration.
            save_config(path,{'TargetServerEntry':'','DisableTactics':False})
        log('NO VERIFIED CANDIDATE: restored initial config; not forcing a bad pin')
        shutil.copy2(backup,path)
        restart(a.container,a.wait)
        return False
    if a.action=='check':
        ip,geo=probe(); return 0 if ip and geo and geo!='RU' else 1
    if a.action=='search': return 0 if search() else 2
    bad=0
    while True:
        ip,geo=probe()
        try: expected=json.loads(Path(a.state).read_text()).get('ip')
        except (OSError,ValueError): expected=None
        if geo=='RU' or (ip and expected and ip!=expected): bad+=1
        elif geo: bad=0
        else: log('Unknown result; not counting as failure')
        if bad>=2:
            log('Google=RU or exit IP changed twice; searching replacement')
            try: search()
            except Exception as e: log(f'Search error: {e}')
            bad=0
        time.sleep(a.interval)

if __name__=='__main__':
    try: raise SystemExit(main())
    except KeyboardInterrupt: raise SystemExit(130)
    except Exception as e:
        log(f'ERROR: {e}'); raise SystemExit(1)
