"""Two full installer transactions on one fake host, including persisted updates."""
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch
import test_installation as installation

def multi_instance_fake():
    fake=installation.FAKE
    start="state_path=base/'state';state=json.loads(state_path.read_text())\nconf=base/'opt/vps-psiphon/config'\ndef save():state_path.write_text(json.dumps(state))"
    replacement="""state_path=base/'state';whole=json.loads(state_path.read_text());name='vps-psiphon'
if cmd=='systemctl' and len(args)>1 and args[1].startswith('vps-psiphon') and args[1].endswith('.service'):
    name=args[1][:-8]
elif cmd=='docker':
    if '--name' in args:name=args[args.index('--name')+1]
    elif args and args[-1].startswith('vps-psiphon'):name=args[-1]
state=whole if name=='vps-psiphon' else whole.setdefault('instances',{}).setdefault(name,dict(legacy=False,console=False,running=False,image='',ports={}))
conf=base/('opt/'+name+'/config')
def save():state_path.write_text(json.dumps(whole))"""
    assert start in fake;fake=fake.replace(start,replacement)
    fake=fake.replace("if args[:2]==['cat','vps-psiphon.service']:","if args[:2]==['cat',name+'.service']:")
    fake=fake.replace("sys.exit(0 if state['legacy'] else 1)","sys.exit(0 if state['legacy'] or (base/('etc/systemd/system/'+name+'.service')).exists() else 1)")
    fake=fake.replace("if args[:2]==['stop','vps-psiphon.service']:","if args[:2]==['stop',name+'.service']:")
    fake=fake.replace("(base/'etc/systemd/system/vps-psiphon.service')","(base/('etc/systemd/system/'+name+'.service'))")
    fake=fake.replace("(['start','vps-psiphon.service'],['restart','vps-psiphon.service'])","(['start',name+'.service'],['restart',name+'.service'])")
    fake=fake.replace("str(base/'usr/local/sbin/vps-psiphon-run')","str(base/('usr/local/sbin/'+name+'-run'))")
    fake=fake.replace("state['running']=True;save()\n    elif args and args[0] in", "state['image']=next((a for a in args if '@sha256:' in a),'local-psiphon-console:4.4.0');state['running']=True;save()\n    elif args and args[0] in")
    return fake

class DualModeInstallerTests(unittest.TestCase):
    install=installation.InstallationTests.install
    def test_two_modes_export_update_and_disable_without_touching_the_other(self):
        fake=multi_instance_fake()
        with patch.object(installation,'FAKE',fake):base,p=self.install(fresh=True)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)}
        def call(*args):return subprocess.run(['bash',str(base/'install.sh'),*args],capture_output=True,text=True,env=env,timeout=25)
        protected=[base/'var/lib/psiphon-autopin/settings.json',base/'opt/vps-psiphon/config/psiphon.config',base/'etc/default/vps-psiphon']
        before=[p.read_bytes() for p in protected]
        p=call('--instance','2','--region','AUTO','--youtube-mode','--no-gemini-check','--interval','600')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        yt_path=base/'var/lib/psiphon-autopin-2/settings.json';yt=json.loads(yt_path.read_text())
        self.assertEqual((yt['youtube_mode'],yt['gemini_check'],yt['port'],yt['interval']),(True,False,40002,600))
        self.assertEqual([p.read_bytes() for p in protected],before)
        p=call('--instance','2');self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(json.loads(yt_path.read_text()),yt)
        manager=base/'opt/psiphon-autopin/psiphon_autopin.py'
        p=subprocess.run([sys.executable,str(manager),'xray-routing','--youtube-instance','2','--gemini-instance','1'],capture_output=True,text=True,env=env,timeout=10)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        out=json.loads(p.stdout);self.assertEqual([v['settings']['servers'][0]['port'] for v in out['outbounds'][:2]],[40002,40000])
        p=call('--instance','2','--port','40001');self.assertNotEqual(p.returncode,0);self.assertIn('reserved by instance 1',p.stdout+p.stderr)
        self.assertEqual(json.loads(yt_path.read_text()),yt)
        p=call('--instance','2','--no-youtube-mode');self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertFalse(json.loads(yt_path.read_text())['youtube_mode']);self.assertFalse(json.loads(yt_path.read_text())['gemini_check'])
        self.assertEqual([p.read_bytes() for p in protected],before)
