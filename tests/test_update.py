"""Immutable update fetch, explicit apply and mixed-version menu selection."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import test_menu as menu
from test_autopin import ROOT,heredoc,m,INSTALLER
import test_installation as installation
u=menu.u

def metadata(source,commit='1'*40):
    raw=source if isinstance(source,bytes) else source.encode()
    return [{'sha':commit},{'type':'file','path':'install_psiphon_autopin.sh','encoding':'base64','content':base64.b64encode(raw).decode(),'sha':hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()}]

class UpdateTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.base=Path(temp.name)
        p=patch.object(u,'ROOT',self.base);p.start();self.addCleanup(p.stop)
        app=u.paths(2)['app'];app.mkdir(parents=True);(app/'psiphon_autopin.py').touch();(app/'autopin_menu.py').write_text("VERSION='4.4.0'\n")
        config=u.defaults(2);config.update(youtube_mode=True,gemini_check=False,min_speed_kib=1500,region='')
        self.settings=u.paths(2)['data']/'settings.json';u.atomic_json(self.settings,config);self.before=self.settings.read_bytes()
        self.source=INSTALLER.replace('4.4.0','4.4.0')
    def test_fetch_uses_immutable_commit_and_verifies_blob_before_execution(self):
        payload=metadata(self.source)
        with patch.object(u,'update_json',side_effect=payload) as fetch:
            result=u.fetch_update(self.base/'download.sh')
        self.assertEqual(fetch.call_args_list[1].args[0],u.UPDATE_REPO+'/contents/install_psiphon_autopin.sh?ref='+'1'*40)
        self.assertEqual(result['version'],'4.4.0');self.assertEqual(result['sha256'],hashlib.sha256(self.source.encode()).hexdigest())
        self.assertEqual((self.base/'download.sh').stat().st_mode&0o777,0o600)
    def test_bad_blob_is_rejected_without_starting_bash(self):
        payload=metadata(self.source);payload[1]['sha']='0'*40
        with patch.object(u,'update_json',side_effect=payload),patch.object(u.subprocess,'run') as run:
            with self.assertRaises(ValueError):u.fetch_update(self.base/'download.sh')
        run.assert_not_called();self.assertFalse((self.base/'download.sh').exists())
    def test_bad_commit_and_wrong_file_are_rejected(self):
        for payload in ([{'sha':'main'}],[{'sha':None}], [{'sha':'1'*40},{'type':'file','path':'other.sh','encoding':'base64'}]):
            with self.subTest(payload=payload),patch.object(u,'update_json',side_effect=payload),self.assertRaises(ValueError):u.fetch_update(self.base/'bad.sh')
    def test_downgrade_is_rejected_before_apply(self):
        payload=metadata(INSTALLER.replace('4.4.0','4.2.0'))
        terminal=menu.Terminal(['да']);view=u.Menu(terminal,instance=2)
        with patch.object(u,'update_json',side_effect=payload),patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='')) as run:
            self.assertFalse(view.update())
        self.assertEqual(run.call_count,1);self.assertEqual(run.call_args.args[0][:2],['bash','-n'])
        self.assertIn('Откат запрещён',terminal.output.getvalue());self.assertEqual(self.settings.read_bytes(),self.before)
    def test_cancel_downloaded_update_does_not_apply(self):
        view=u.Menu(menu.Terminal(['нет']),instance=2)
        with patch.object(u,'update_json',side_effect=metadata(self.source)),patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='')) as run:
            self.assertFalse(view.update())
        self.assertEqual(run.call_count,1);self.assertEqual(self.settings.read_bytes(),self.before)
    def test_apply_targets_only_selected_instance_and_records_source(self):
        view=u.Menu(menu.Terminal(['да']),instance=2)
        with patch.object(u,'update_json',side_effect=metadata(self.source)),patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='',stderr='')) as run:
            self.assertTrue(view.update())
        args=run.call_args.args[0];self.assertEqual(args[0],'bash');self.assertEqual(args[2:],['--instance','2'])
        self.assertEqual(self.settings.read_bytes(),self.before)
        receipt=u.paths(2)['data']/'update-source.json';obj=json.loads(receipt.read_text());self.assertEqual(obj['commit'],'1'*40);self.assertEqual(obj['version'],'4.4.0');self.assertEqual(receipt.stat().st_mode&0o777,0o600)
    def test_download_failure_keeps_old_installation(self):
        view=u.Menu(menu.Terminal([]),instance=2)
        with patch.object(u,'update_json',side_effect=OSError('network unavailable')),patch.object(u.subprocess,'run') as run:
            self.assertFalse(view.update())
        run.assert_not_called();self.assertEqual(self.settings.read_bytes(),self.before)
    def test_failed_installer_is_not_reported_as_success(self):
        view=u.Menu(menu.Terminal(['да']),instance=2)
        with patch.object(u,'update_json',side_effect=metadata(self.source)),patch.object(u.subprocess,'run',side_effect=[subprocess.CompletedProcess([],0,stdout='',stderr=''),subprocess.CompletedProcess([],7)]):
            self.assertFalse(view.update())
        self.assertFalse((u.paths(2)['data']/'update-source.json').exists())
    def test_running_ui_installer_is_preferred_to_old_instance_copy(self):
        old=u.paths(1)['app']/'install_psiphon_autopin.sh';old.parent.mkdir();old.touch()
        new=u.paths(2)['app']/'install_psiphon_autopin.sh';new.touch()
        self.assertEqual(u.installer_for(1,new),new)
    def test_launcher_prefers_newer_menu_with_numeric_versions(self):
        launcher=heredoc('MENU_LAUNCHER').replace("Path('/opt')","Path("+repr(str(self.base/'opt'))+")")
        for old,new in [('4.2.0','4.4.0'),('4.9.0','4.10.0')]:
            for number,version,label in [(1,old,'OLD'),(2,new,'NEW')]:
                path=u.paths(number)['app']/'autopin_menu.py';path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text("VERSION='"+version+"'\nimport sys\nprint('"+label+" '+' '.join(sys.argv[1:]))\n")
            p=subprocess.run(['bash','-s','--','--instance','2'],input=launcher,text=True,capture_output=True)
            self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout.strip(),'NEW --instance 2')
    def test_cli_update_preserves_instance_selection(self):
        with patch.object(sys,'argv',['manager','update','--instance','2']),patch.object(m,'configure_instance'),patch.object(m,'BASE',u.paths(2)['app']),patch.object(m.subprocess,'call',return_value=0) as call:
            self.assertEqual(m.main(),0)
        self.assertEqual(call.call_args.args[0][-3:],['--instance','2','--update'])

class UpdateInstallerIntegrationTests(unittest.TestCase):
    install=installation.InstallationTests.install
    def test_real_update_preserves_both_normal_and_youtube_saved_policies(self):
        for youtube in (False,True):
            with self.subTest(youtube=youtube):
                extra=('--no-gemini-check','--interval','600','--min-speed','1200')+(('--youtube-mode',) if youtube else ())
                base,p=self.install(fresh=True,extra_args=extra);self.assertEqual(p.returncode,0,p.stdout+p.stderr)
                config=base/'var/lib/psiphon-autopin/settings.json';before=json.loads(config.read_text())
                staged_source=(base/'install.sh').read_bytes()
                env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)}
                with patch.object(u,'ROOT',base),patch.object(u,'update_json',side_effect=metadata(staged_source)),patch.dict(os.environ,env):
                    view=u.Menu(menu.Terminal(['да']),instance=1);self.assertTrue(view.update())
                self.assertEqual(json.loads(config.read_text()),before)
                self.assertTrue((config.parent/'update-source.json').is_file())
