#!/usr/bin/env python3
"""Receipts for Docker/Go installed by Auto-Pin; conservative dependency cleanup."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT=Path('/')
GROUPS={
    'docker':re.compile(r'^(docker\.io|docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker-buildx-plugin|docker-compose-plugin|containerd\.io|containerd|runc)$'),
    'go':re.compile(r'^(golang-go|golang-src|golang-[0-9][0-9.]*-(go|src))$'),
}

def system_dir():return ROOT/'var/lib/psiphon-autopin-system'
def ledger_path():return system_dir()/'dependencies.json'
def load_ledger():
    if not ledger_path().exists():return {'version':1,'components':{}}
    data=json.loads(ledger_path().read_text())
    if data.get('version')!=1 or not isinstance(data.get('components'),dict):raise ValueError('Invalid dependency receipt; dependencies will be retained')
    for component,receipt in data['components'].items():
        if component not in GROUPS or not isinstance(receipt,dict) or not isinstance(receipt.get('packages'),list):raise ValueError('Invalid dependency receipt')
        if any(not isinstance(p,str) or not GROUPS[component].fullmatch(p) for p in receipt['packages']):raise ValueError('Unexpected package in dependency receipt')
    return data

def save_ledger(data):
    folder=system_dir();folder.mkdir(parents=True,exist_ok=True,mode=0o700);folder.chmod(0o700)
    name=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=folder,delete=False) as f:
            name=f.name;json.dump(data,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        os.chmod(name,0o600);os.replace(name,ledger_path())
    finally:
        if name and Path(name).exists():Path(name).unlink()

@contextlib.contextmanager
def locked():
    folder=system_dir();folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (folder/'dependencies.lock').open('a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        yield

def inventory():
    p=subprocess.run(['dpkg-query','-W','-f=${binary:Package}\t${db:Status-Status}\n'],capture_output=True,text=True,timeout=30)
    if p.returncode:raise RuntimeError('Cannot determine installed packages; dependencies retained')
    result=set()
    for line in p.stdout.splitlines():
        parts=line.split('\t')
        if len(parts)==2 and parts[1]=='installed':result.add(parts[0].split(':',1)[0])
    return result

def install(component,packages,lock_held=False):
    if component not in (*GROUPS,'tools'):raise ValueError('Unknown component')
    if not packages or any(not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*',p) for p in packages):raise ValueError('Invalid package names')
    with (contextlib.nullcontext() if lock_held else locked()):
        ledger=load_ledger();before=inventory()
        preexisting=False
        if component in GROUPS:
            binary='docker' if component=='docker' else 'go'
            roots={'docker.io','docker-ce','docker-ce-cli'} if component=='docker' else {p for p in before if p=='golang-go' or re.fullmatch(r'golang-[0-9][0-9.]*-go',p)}
            preexisting=bool(shutil.which(binary)) or bool(roots&before)
        try:
            p=subprocess.run(['apt-get','install','-y',*packages],env={**os.environ,'DEBIAN_FRONTEND':'noninteractive'})
            code=p.returncode
        finally:
            after=inventory()
            if component in GROUPS:
                old=ledger['components'].get(component,{})
                added={p for p in after-before if GROUPS[component].fullmatch(p)}
                owned=old.get('owned') is True or (not preexisting and bool(added))
                previous=set(old.get('packages',[])) if old.get('owned') is True else set()
                ledger['components'][component]={'owned':owned,'preexisting':old.get('preexisting',preexisting),'packages':sorted(previous|added) if owned else []}
                save_ledger(ledger)
        return code

def remaining_instances():
    result=set()
    for n in range(1,100):
        suffix='' if n==1 else '-'+str(n)
        paths=[ROOT/('opt/psiphon-autopin'+suffix),ROOT/('opt/vps-psiphon'+suffix),
            ROOT/('var/lib/psiphon-autopin'+suffix),ROOT/('etc/systemd/system/psiphon-autopin'+suffix+'.service'),
            ROOT/('etc/systemd/system/vps-psiphon'+suffix+'.service')]
        if any(p.exists() for p in paths):result.add(n)
    return sorted(result)

def docker_unused():
    if not shutil.which('docker'):return False,'Docker usage cannot be checked'
    try:p=subprocess.run(['docker','ps','-aq'],capture_output=True,text=True,timeout=30)
    except (OSError,subprocess.TimeoutExpired):return False,'Docker usage cannot be checked'
    if p.returncode:return False,'Docker daemon unavailable; usage is unknown'
    if p.stdout.strip():return False,'Other running or stopped Docker containers exist'
    return True,''

def purge_plan(packages,owned):
    p=subprocess.run(['apt-get','-s','purge','--',*packages],capture_output=True,text=True,timeout=120)
    if p.returncode:return False,'APT simulation failed'
    removed={m.group(1).split(':',1)[0] for m in re.finditer(r'^(?:Remv|Purg)\s+([a-zA-Z0-9+.:_-]+)',p.stdout,re.M)}
    if not removed:return False,'APT did not produce a verifiable removal plan'
    if removed-set(owned):return False,'APT would remove packages outside the ownership receipt'
    return True,''

def cleanup_dependencies(purge=False,lock_held=False):
    """Never infer ownership from current binary presence or old Auto-Pin files."""
    result={}
    with (contextlib.nullcontext() if lock_held else locked()):
        ledger=load_ledger();others=remaining_instances()
        if others:return {'retained':'Other Auto-Pin instances still exist','instances':others}
        if not purge:
            # Explicit plain uninstall leaves dependencies as preexisting for a future install.
            save_ledger({'version':1,'components':{}})
            return {'retained':'Plain uninstall keeps dependencies'}
        installed=inventory()
        all_owned={p for r in ledger['components'].values() if r.get('owned') is True for p in r['packages']}
        for component in ('docker','go'):
            receipt=ledger['components'].get(component,{})
            if receipt.get('owned') is not True:
                result[component]={'retained':'Preexisting or no ownership receipt'};continue
            packages=sorted(set(receipt['packages'])&installed)
            if not packages:
                result[component]={'removed':[]};ledger['components'].pop(component,None);continue
            if component=='docker':
                unused,reason=docker_unused()
                if not unused:result[component]={'retained':reason};continue
            allowed,reason=purge_plan(packages,all_owned)
            if not allowed:result[component]={'retained':reason};continue
            p=subprocess.run(['apt-get','-y','purge','--',*packages],env={**os.environ,'DEBIAN_FRONTEND':'noninteractive'})
            now=inventory();left=sorted(set(packages)&now)
            result[component]={'removed':sorted(set(packages)-now),'remaining':left,'exit_code':p.returncode}
            if not left:ledger['components'].pop(component,None)
            installed=now
        save_ledger(ledger)
    return result

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('install');p.add_argument('--lock-held',action='store_true',help=argparse.SUPPRESS);p.add_argument('component',choices=(*GROUPS,'tools'));p.add_argument('packages',nargs='+')
    p=sub.add_parser('cleanup');p.add_argument('--purge',action='store_true')
    args=parser.parse_args(argv)
    if os.geteuid()!=0:raise RuntimeError('Run as root')
    if args.command=='install':return install(args.component,args.packages,args.lock_held)
    print(json.dumps(cleanup_dependencies(args.purge),indent=2));return 0

if __name__=='__main__':raise SystemExit(main())
