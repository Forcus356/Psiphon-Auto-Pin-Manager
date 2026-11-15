"""Execute the real installer in a temporary filesystem with fake host commands."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
FAKE=r'''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
base=Path(os.environ['AUTOPIN_TEST_ROOT']);cmd=Path(sys.argv[0]).name;args=sys.argv[1:]
with (base/'commands').open('a') as f:f.write(json.dumps([cmd,*args])+'\n')
state_path=base/'state';state=json.loads(state_path.read_text())
conf=base/'opt/vps-psiphon/config'
def save():state_path.write_text(json.dumps(state))
if cmd=='systemctl':
    if args[:2]==['cat','vps-psiphon.service']:
        print('[Service]\nExecStart=/usr/local/sbin/vps-psiphon-run');sys.exit(0 if state['legacy'] or (base/'etc/systemd/system/vps-psiphon.service').exists() else 1)
    if args[:2]==['stop','vps-psiphon.service']:
        if not state['legacy'] and not (base/'etc/systemd/system/vps-psiphon.service').exists():sys.exit(5)
        state['running']=False;save()
    if args[:2] in (['start','vps-psiphon.service'],['restart','vps-psiphon.service']):
        sys.exit(subprocess.run(['bash',str(base/'usr/local/sbin/vps-psiphon-run')]).returncode)
elif cmd=='docker':
    if args==['--version']:print('Docker test')
    elif args[:2]==['container','inspect']:sys.exit(0 if state['running'] else 1)
    elif args and args[0]=='inspect':
        if not state['running']:sys.exit(1)
        fmt=args[args.index('-f')+1]
        if '.Config.Image' in fmt:print(state['image'])
        elif '.NetworkMode' in fmt:print('host' if state['console'] else 'bridge')
        elif '.Mounts' in fmt:print(conf)
        elif '.PortBindings' in fmt:print(json.dumps(state['ports']))
    elif args[:2]==['rm','-f']:state['running']=False;save()
    elif args and args[0]=='run':
        if '--entrypoint' in args and args[args.index('--entrypoint')+1]=='cat':print(json.dumps({'EgressRegion':'SG','SponsorId':'test'}))
        else:
            state['ports']={}
            for i,v in enumerate(args):
                if v=='-p':
                    bind,host,internal=args[i+1].split(':')
                    state['ports'][internal+'/tcp']=[{'HostIp':bind,'HostPort':host}]
            state['running']=True;save()
    elif args and args[0] in ('start','restart'):state['running']=True;save()
    elif args and args[0]=='stop':state['running']=False;save()
elif cmd=='curl':
    if '-o' in args:
        dest=Path(args[args.index('-o')+1])
        if any('ipregion.sh' in v for v in args):dest.write_text('#!/bin/bash\n# socks5://$PROXY_ADDR\n')
        elif any('psiphon-tunnel-core-binaries/' in v for v in args):dest.write_bytes(b'verified-console-fixture\n')
        else:raise SystemExit('Unexpected network request')
    else:
        flag=base/'bootstrap-failure'
        if flag.exists():flag.unlink();sys.exit(1)
        print('192.0.2.10')
elif cmd=='go':
    if args==['version']:print('go version go1.26.0 linux/amd64')
    elif '-o' in args:
        dest=Path(args[args.index('-o')+1]);dest.write_text('#!/bin/sh\nexit 0\n');dest.chmod(0o700)
elif cmd=='ss':
    if state['console'] and state['running']:
        print('LISTEN 0 128 127.0.0.1:40000 0.0.0.0:*')
        print('LISTEN 0 128 127.0.0.1:40001 0.0.0.0:*')
elif cmd in ('apt-get','apt-cache'):raise SystemExit('Unexpected package installation')
'''


DEPENDENCY_COMMANDS=r"""elif cmd=='dpkg-query':
    for package in sorted(state.get('packages',[])):print(package+'\tinstalled')
elif cmd=='apt-cache':sys.exit(1)
elif cmd=='apt-get':
    packages=set(state.get('packages',[]))
    if args and args[0]=='update':pass
    elif args and args[0]=='install':
        requested={x for x in args[1:] if not x.startswith('-')};packages.update(requested)
        if 'golang-go' in requested:
            packages.update(['golang-src','golang-1.26-go','golang-1.26-src'])
            target=base/'bin/go';target.write_text(Path(sys.argv[0]).read_text());target.chmod(0o755)
        if 'docker.io' in requested:
            packages.update(['containerd','runc'])
            target=base/'bin/docker';target.write_text(Path(sys.argv[0]).read_text());target.chmod(0o755)
        state['packages']=sorted(packages);save()
    elif 'purge' in args:
        requested=args[args.index('--')+1:]
        if '-s' in args:
            for package in requested:print('Purg '+package)
        else:
            if state.get('purge_fail'):raise SystemExit(100)
            packages.difference_update(requested);state['packages']=sorted(packages);save()
            if 'docker.io' in requested:(base/'bin/docker').unlink(missing_ok=True)
            if 'golang-go' in requested:(base/'bin/go').unlink(missing_ok=True)
    else:raise SystemExit('Unexpected apt operation')
"""


class InstallationTests(unittest.TestCase):
    def install(self,console=False,foreign=False,bootstrap_failure=False,fresh=False,extra_args=(),dependency_mode=None):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        base=Path(tmp.name);bin_dir=base/'bin';bin_dir.mkdir()
        fake=FAKE
        if dependency_mode:
            fake=fake.replace("elif cmd in ('apt-get','apt-cache'):raise SystemExit('Unexpected package installation')",DEPENDENCY_COMMANDS)
            fake=fake.replace("elif args[:2]==['rm','-f']:state['running']=False;save()","elif args[:2]==['ps','-aq']:print('\\n'.join(state.get('external_containers',[])))\n    elif args[:2]==['rm','-f']:state['running']=False;save()")
        for name in ('docker','systemctl','curl','go','ss','jq','column','apt-get','apt-cache','dpkg-query'):
            p=bin_dir/name;p.write_text(fake);p.chmod(0o755)
        for folder in ('opt/vps-psiphon/config','opt/psiphon-autopin','etc/default','usr/local/sbin','etc/systemd/system','var/lib/psiphon-autopin'):
            (base/folder).mkdir(parents=True,exist_ok=True)
        config=base/'opt/vps-psiphon/config/psiphon.config'
        config.write_text(json.dumps({'EgressRegion':'PL','TargetServerEntry':'secret','SponsorId':'test',
            'LocalSocksProxyPort':40000 if console else 1080,'LocalHttpProxyPort':40001 if console else 8080,'ListenInterface':'lo' if console else 'any'}))
        config.chmod(0o600)
        image='foreign:image' if foreign else 'local-psiphon-console:latest' if console else 'swarupsengupta2007/psiphon:latest'
        state={'legacy':not console and not fresh,'console':console,'running':not fresh,'image':image,
               'ports':{'1080/tcp':[{'HostIp':'127.0.0.1','HostPort':'40000'}],
                        '8080/tcp':[{'HostIp':'127.0.0.1','HostPort':'8080'}]}}
        if dependency_mode:
            state['packages']=[]
            if dependency_mode not in ('both_missing','docker_missing'):state['packages']+=['docker.io','containerd','runc']
            else:(bin_dir/'docker').unlink()
            if dependency_mode not in ('both_missing','go_missing'):state['packages']+=['golang-go','golang-src','golang-1.26-go','golang-1.26-src']
            else:(bin_dir/'go').unlink()
        (base/'state').write_text(json.dumps(state))
        if bootstrap_failure:(base/'bootstrap-failure').touch()
        if fresh:config.unlink()
        if console:
            (base/'var/lib/psiphon-autopin/settings.json').write_text(json.dumps({'region':'PL','port':40000}))
        elif not fresh:
            (base/'etc/default/vps-psiphon').write_text(f'IMAGE=swarupsengupta2007/psiphon:latest\nNAME=vps-psiphon\nCONF_DIR={config.parent}\nBIND=127.0.0.1\nEGRESS_REGION=PL\nSOCKS_PORT=1080\nHTTP_PORT=8080\n')
            runner=base/'usr/local/sbin/vps-psiphon-run';runner.write_text('#!/bin/bash\n');runner.chmod(0o755)
        script=(ROOT/'install_psiphon_autopin.sh').read_text()
        script=script.replace('faf6873ddc1dab6c00e11a090a711fb3a26cfa7dbc1717e0c3b1978dfff4c105',hashlib.sha256(b'verified-console-fixture\n').hexdigest())
        if dependency_mode:
            first=script.index("<<'PY_SYSTEM'\n")+len("<<'PY_SYSTEM'\n");last=script.index('\nPY_SYSTEM\n',first)
            helper=script[first:last].replace("ROOT=Path('/')",'ROOT=Path('+repr(str(base))+')')
            helper=helper.replace('bool(shutil.which(binary))',"(ROOT/'bin'/binary).is_file()")
            script=script[:first]+helper+script[last:]
            shim='command() { if [[ $1 == -v && ( $2 == docker || $2 == go ) && ! -e '+str(bin_dir)+'/$2 ]]; then return 1; fi; builtin command "$@"; }'
            script=script.replace('autopin_install_main() {','autopin_install_main() {\n'+shim,1)
        script=script.replace('. /etc/os-release','ID=debian')
        script=script.replace("[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }",': # test sandbox')
        for path in ('/var/backups/psiphon-autopin','/opt/vps-psiphon','/opt/psiphon-autopin','/var/lib/psiphon-autopin',
                     '/etc/default/vps-psiphon','/usr/local/sbin/vps-psiphon','/etc/systemd/system'):
            script=script.replace(path,str(base/path.lstrip('/')))
        for prefix in ('/opt/', '/etc/default/', '/etc/systemd/system/', '/usr/local/sbin/', '/var/lib/'):
            script=script.replace(prefix,str(base)+prefix)
        # Collapse paths already rewritten above.
        script=script.replace(str(base)+str(base),str(base))
        script=script.replace("if os.geteuid()!=0:raise RuntimeError('Run as root')","if False:raise RuntimeError('Run as root')")
        for directory in ('/usr/local/sbin','/opt','/var/lib'):
            script=script.replace("Path('"+directory+"')","Path("+repr(str(base/directory.lstrip('/')))+")")
        # Production retains file owners; tests run as an ordinary user.
        script=script.replace('chown 1000:1000',f'chown {os.getuid()}:{os.getgid()}').replace('chown -R 1000:1000',f'chown -R {os.getuid()}:{os.getgid()}')
        installer=base/'install.sh';installer.write_text(script)
        proc=subprocess.run(['bash',str(installer),*(['--region','NL','--port','40000'] if fresh else []),*extra_args],text=True,capture_output=True,timeout=20,
            env={**os.environ,'PATH':str(bin_dir)+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)})
        return base,proc

    def test_migrate_real_installer_preserves_manual_40000_mapping(self):
        base,proc=self.install()
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        settings=json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())
        self.assertEqual((settings['backend'],settings['port'],settings['region']),('vps-psiphon',40000,'PL'))
        config=json.loads((base/'opt/vps-psiphon/config/psiphon.config').read_text())
        self.assertEqual(config['TargetServerEntry'],'secret')
        self.assertEqual(config['LocalSocksProxyPort'],1080)
        state=json.loads((base/'state').read_text())
        self.assertEqual(state['ports']['1080/tcp'],[{'HostIp':'127.0.0.1','HostPort':'40000'}])
        commands=[json.loads(row) for row in (base/'commands').read_text().splitlines()]
        self.assertIn(['systemctl','disable','--now','vps-psiphon-watchdog.timer','vps-psiphon-watchdog.service'],commands)
        backup=list((base/'var/backups/psiphon-autopin/vps-psiphon').glob('backup-*'))[0]
        self.assertEqual(json.loads((backup/'config/psiphon.config').read_text())['LocalSocksProxyPort'],1080)
        self.assertTrue((backup/'vps-psiphon-run').is_file())
        own_unit=(base/'etc/systemd/system/vps-psiphon.service').read_text()
        self.assertIn('Description=Forcus Psiphon tunnel 1',own_unit)
        self.assertNotIn('ExecStartPre',own_unit)
        unit=(base/'etc/systemd/system/psiphon-autopin.service').read_text()
        self.assertNotIn('--region PL',unit)
        self.assertIn('After=network-online.target docker.service vps-psiphon.service',unit)

    def test_existing_console_is_not_migrated(self):
        base,proc=self.install(console=True)
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        settings=json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())
        self.assertEqual(settings['backend'],'console')
        self.assertFalse((base/'usr/local/sbin/vps-psiphon-run').exists())
        self.assertTrue(json.loads((base/'state').read_text())['running'])

    def test_starting_tunnel_not_restarted_when_bootstrap_is_complete(self):
        base,proc=self.install(console=True,bootstrap_failure=True)
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        commands=[json.loads(row) for row in (base/'commands').read_text().splitlines()]
        self.assertNotIn(['docker','restart','vps-psiphon'],commands)
        self.assertTrue(any(cmd[:2]==['docker','build'] for cmd in commands))
        self.assertIn('preserving the starting tunnel',proc.stdout)

    def test_fresh_install_builds_our_service_without_chara_installer(self):
        base,proc=self.install(fresh=True)
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        self.assertTrue((base/'etc/systemd/system/vps-psiphon.service').exists())
        commands=[json.loads(row) for row in (base/'commands').read_text().splitlines()]
        self.assertFalse(any('Chara-Freedom' in arg for cmd in commands for arg in cmd))
        self.assertEqual(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['backend'],'vps-psiphon')

    def test_socks_only_omits_http_host_mapping(self):
        base,proc=self.install(extra_args=('--no-http',))
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        self.assertEqual(set(json.loads((base/'state').read_text())['ports']),{'1080/tcp'})
        self.assertFalse(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['publish_http'])

    def test_private_interface_binding_is_consistent(self):
        base,proc=self.install(extra_args=('--bind','172.17.0.1'))
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        ports=json.loads((base/'state').read_text())['ports']
        self.assertEqual(ports['1080/tcp'][0]['HostIp'],'172.17.0.1')

    def test_public_bind_is_rejected_before_stopping_any_service(self):
        base,proc=self.install(extra_args=('--bind','8.8.8.8'))
        self.assertNotEqual(proc.returncode,0)
        commands=[json.loads(row) for row in (base/'commands').read_text().splitlines()] if (base/'commands').exists() else []
        self.assertFalse(any(cmd[0]=='systemctl' and 'stop' in cmd for cmd in commands))

    def test_foreign_container_not_stopped_or_overwritten(self):
        base,proc=self.install(foreign=True)
        self.assertNotEqual(proc.returncode,0)
        self.assertIn('Foreign vps-psiphon container',proc.stderr)
        commands=[json.loads(row) for row in (base/'commands').read_text().splitlines()]
        self.assertNotIn(['systemctl','stop','vps-psiphon.service'],commands)
        self.assertNotIn(['systemctl','stop','psiphon-autopin.service'],commands)
        self.assertTrue(json.loads((base/'state').read_text())['running'])


if __name__=='__main__':unittest.main()
