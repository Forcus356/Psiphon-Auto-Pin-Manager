"""Menu transactions and persistence through the real installer."""
import importlib.util
import io
import json
import os
import pty
import select
import signal
import time
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_autopin import ROOT,heredoc,m
import test_installation

spec=importlib.util.spec_from_file_location('autopin_menu_test',ROOT/'autopin_menu.py')
u=importlib.util.module_from_spec(spec);sys.modules[spec.name]=u;spec.loader.exec_module(u)

class Terminal:
    def __init__(self,answers):self.answers=iter(answers);self.output=io.StringIO()
    def write(self,text):return self.output.write(text)
    def flush(self):pass
    def readline(self):
        try:return next(self.answers)+'\n'
        except StopIteration:return ''

class MenuTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        p=patch.object(u,'ROOT',self.root);p.start();self.addCleanup(p.stop)
        status=patch.object(u,'runtime_status',return_value={key:{'state':'unknown','autostart':'unknown'} for key in ('tunnel','monitor')});status.start();self.addCleanup(status.stop)
    def save(self,n,**changes):
        c=u.defaults(n);c.update(changes)
        p=u.paths(n)['data']/'settings.json';u.atomic_json(p,c)
        return p,c
    def test_embedded_menu_matches_source(self):
        self.assertEqual(heredoc('PY_MENU'),(ROOT/'autopin_menu.py').read_text())
    def test_cancel_leaves_saved_settings_and_services_untouched(self):
        path,_=self.save(1,region_pool=['NL','DE'],min_speed_kib=1200,tunnel_pool=3)
        before=path.read_bytes();emitted=self.root/'args.json'
        terminal=Terminal(['1','3','нет','2','2','y','нет','0','0'])
        with patch.object(u.subprocess,'run') as run:
            self.assertEqual(u.Menu(terminal,emit_args=emitted).run(),0)
        run.assert_not_called();self.assertFalse(emitted.exists());self.assertEqual(path.read_bytes(),before)
        self.assertIn('Отменено',terminal.output.getvalue())
    def test_easy_apply_preserves_hidden_advanced_values(self):
        path,original=self.save(2,region_pool=['NL','DE'],min_speed_kib=1200,probe_mb=1,tunnel_pool=3,publish_http=False)
        terminal=Terminal(['1','3','нет','2','2','y','да']);emitted=self.root/'args.json'
        self.assertEqual(u.Menu(terminal,instance=2,emit_args=emitted).run(),0)
        args=json.loads(emitted.read_text())
        for flag,value in [('--instance','2'),('--connection','xray'),('--tunnel-pool','3'),('--region-pool','NL,DE'),('--min-speed','1200')]:
            self.assertEqual(args[args.index(flag)+1],value)
        self.assertIn('--no-gemini-check',args);self.assertIn('--no-http',args)
        self.assertEqual(json.loads(path.read_text()),original)
    def test_easy_watchdog_minutes_become_seconds(self):
        self.save(2,interval=300)
        emitted=self.root/'watchdog-args.json'
        terminal=Terminal(['1','5','2','y','да'])
        u.Menu(terminal,instance=2,emit_args=emitted).run()
        args=json.loads(emitted.read_text())
        self.assertEqual(args[args.index('--interval')+1],'120')
        self.assertIn('Watchdog',terminal.output.getvalue())
    def test_advanced_watchdog_accepts_fractional_minutes(self):
        emitted=self.root/'watchdog-args.json'
        u.Menu(Terminal(['2','15','7,5','y','да']),emit_args=emitted).run()
        args=json.loads(emitted.read_text())
        self.assertEqual(args[args.index('--interval')+1],'450')
    def test_watchdog_validation_and_old_seconds_are_preserved(self):
        field=next(f for f in u.FIELDS if f.key=='interval')
        self.assertEqual(u.parse_field(field,'1.5'),90)
        for text in ('0','0.5','NaN','Infinity','1.0001','1e999999999'):
            with self.subTest(text=text),self.assertRaises(ValueError):u.parse_field(field,text)
        _,original=self.save(1,interval=75)
        loaded=u.load_config(1)
        self.assertEqual(loaded['interval'],75)
        self.assertEqual(u.display(field,75),'1 мин 15 с')
        args=u.build_args(loaded)
        self.assertEqual(args[args.index('--interval')+1],'75')
    def test_advanced_exposes_every_installer_setting(self):
        required={'region','connection_type','gemini_check','port','publish_http','bind','region_pool','tunnel_pool','deny_regions','strict_region','min_speed_kib','probe_mb','slow_threshold','fail_threshold','interval','wait','delay','impersonate','backend','youtube_mode'}
        self.assertEqual({f.key for f in u.FIELDS},required)
        terminal=Terminal(['2','0','0']);self.assertEqual(u.Menu(terminal).run(),0)
        for f in u.FIELDS:self.assertIn(f.label,terminal.output.getvalue())
    def test_invalid_values_fail_before_argument_emission(self):
        for key,value in [('port',9),('port',65535),('tunnel_pool',33),('region','NL; touch x'),('bind','0.0.0.0'),('region_pool',['NL;touch']),('gemini_check','false'),('connection_type','shell'),('instance',100)]:
            c=u.defaults();c[key]=value
            with self.subTest(key=key),self.assertRaises((ValueError,TypeError)):u.build_args(c)
    def test_country_outside_old_pool_clears_pool(self):
        self.save(1,region_pool=['NL','DE'])
        menu=u.Menu(Terminal(['1','1','US','0','0']));menu.run()
        self.assertEqual(menu.config['region'],'US');self.assertEqual(menu.config['region_pool'],[])
    def test_new_pool_selects_first_country_if_needed(self):
        menu=u.Menu(Terminal(['2','7','DE,PL','0','0']));menu.run()
        self.assertEqual(menu.config['region'],'DE');self.assertEqual(menu.config['region_pool'],['DE','PL'])
    def test_xray_is_socks_endpoint_and_private_file(self):
        c=u.defaults(3);c.update(connection_type='xray',bind='172.17.0.1',port=41000)
        u.write_connection(c);data=u.paths(3)['data'];value=json.loads((data/'xray-outbound.json').read_text())
        self.assertEqual(value['settings']['servers'],[{'address':'172.17.0.1','port':41000}])
        self.assertEqual(value['protocol'],'socks');self.assertEqual(value['tag'],'psiphon-out-3')
        self.assertEqual((data/'xray-outbound.json').stat().st_mode & 0o777,0o600)
        c['connection_type']='socks5';u.write_connection(c)
        self.assertFalse((data/'xray-outbound.json').exists())
        self.assertEqual(json.loads((data/'connection.json').read_text())['uri'],'socks5h://172.17.0.1:41000')
    def test_instance_selection_loads_separate_settings(self):
        self.save(2,region='DE');self.save(3,region='PL')
        menu=u.Menu(Terminal(['4','3','0']),instance=2);menu.run()
        self.assertEqual((menu.instance,menu.config['region'],menu.config['port']),(3,'PL',40004))
    def test_new_instance_can_use_existing_local_installer(self):
        app=u.paths(3)['app'];app.mkdir(parents=True);(app/'psiphon_autopin.py').touch();(app/'install_psiphon_autopin.sh').touch()
        self.assertEqual(u.discover(),[3]);self.assertEqual(u.installer_for(4),app/'install_psiphon_autopin.sh')
    def test_apply_failure_is_not_reported_as_success(self):
        path,_=self.save(1);installer=self.root/'install.sh';installer.touch()
        terminal=Terminal(['да']);menu=u.Menu(terminal,installer=installer);menu.config['gemini_check']=False
        with patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],1)):
            self.assertFalse(menu.apply())
        self.assertTrue(json.loads(path.read_text())['gemini_check']);self.assertIn('не подтверждено',terminal.output.getvalue())
    def test_service_management_is_scoped_and_confirmed(self):
        manager=u.paths(2)['manager'];manager.parent.mkdir(parents=True);manager.touch()
        with patch.object(u.subprocess,'run') as run:u.Menu(Terminal(['4','нет']),instance=2).manage()
        run.assert_not_called()
        with patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as run:u.Menu(Terminal(['4','да']),instance=2).manage()
        self.assertEqual(run.call_args.args[0],[sys.executable,str(manager),'stop','--instance','2'])
    def test_real_controlling_terminal_opens_menu_and_cancels(self):
        pid,fd=pty.fork()
        if pid==0:
            with patch.object(u.os,'geteuid',return_value=0):
                code=u.main(['--instance','1'])
            os._exit(code)
        raw=bytearray();sent=False;status=None;deadline=time.monotonic()+10
        try:
            while time.monotonic()<deadline:
                if select.select([fd],[],[],0.2)[0]:
                    try:data=os.read(fd,8192)
                    except OSError:data=b''
                    if not data:break
                    raw.extend(data)
                    if not sent and 'Выбор [Enter'.encode() in raw:
                        os.write(fd,b'0\n');sent=True
            waited,status=os.waitpid(pid,os.WNOHANG)
            if not waited:
                os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
                self.fail('Menu did not exit after cancel: '+raw.decode(errors='replace'))
            self.assertTrue(sent,raw.decode(errors='replace'))
            self.assertEqual(os.waitstatus_to_exitcode(status),0)
            self.assertFalse((u.paths(1)['data']/'settings.json').exists())
        finally:os.close(fd)
    def test_malformed_utf8_in_terminal_cannot_apply_or_crash_menu(self):
        emitted=self.root/'terminal-args.json'
        pid,fd=pty.fork()
        if pid==0:
            with patch.object(u.os,'geteuid',return_value=0):
                code=u.main(['--instance','1','--emit-args',str(emitted)])
            os._exit(code)
        raw=bytearray();cursor=0;reaped=False
        def expect(text):
            nonlocal cursor
            target=text.encode();deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                found=raw.find(target,cursor)
                if found>=0:cursor=found+len(target);return
                if select.select([fd],[],[],0.1)[0]:
                    try:chunk=os.read(fd,65536)
                    except OSError:chunk=b''
                    if not chunk:break
                    raw.extend(chunk)
            self.fail('Expected prompt missing: '+text+'\n'+raw.decode(errors='replace'))
        try:
            expect('Выбор [Enter');os.write(fd,b'1\n');expect('Выбор: ')
            os.write(fd,b'y\xd1\n');expect('Некорректная кодировка ввода');expect('Выбор: ')
            self.assertFalse(emitted.exists())
            os.write(fd,b'y\n');expect('Применить эти настройки?')
            os.write(fd,b'y\xd1\n');expect('Некорректная кодировка ввода')
            expect('[y/n, по умолчанию n]: ');self.assertFalse(emitted.exists())
            os.write(fd,b'y\n')
            deadline=time.monotonic()+10;status=None
            while time.monotonic()<deadline:
                waited,status=os.waitpid(pid,os.WNOHANG)
                if waited:reaped=True;break
                time.sleep(0.05)
            self.assertTrue(reaped,'Menu did not finish after valid y confirmation')
            self.assertEqual(os.waitstatus_to_exitcode(status),0)
            args=json.loads(emitted.read_text())
            self.assertIn('--region',args);self.assertNotIn(b"codec can't decode",raw)
        finally:
            if not reaped:
                os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
            os.close(fd)
    def test_menu_without_controlling_tty_fails_cleanly(self):
        with patch.object(u.os,'geteuid',return_value=0),patch('builtins.open',side_effect=OSError('no controlling terminal')),patch('sys.stderr',new_callable=io.StringIO):
            self.assertEqual(u.main(['--instance','2']),1)
    def test_manager_dispatch_preserves_selected_instance(self):
        with patch.object(sys,'argv',['psiphon-autopin','menu','--instance','2']),patch.object(m,'configure_instance') as configure,patch.object(m.subprocess,'call',return_value=0) as call:
            self.assertEqual(m.main(),0)
        configure.assert_called_once_with(2);self.assertEqual(call.call_args.args[0][-2:],['--instance','2'])

class InstallerMenuTests(unittest.TestCase):
    install=test_installation.InstallationTests.install
    def test_watchdog_menu_value_reaches_settings_and_systemd(self):
        config=u.defaults();config['interval']=u.parse_field(next(f for f in u.FIELDS if f.key=='interval'),'3')
        base,proc=self.install(extra_args=tuple(u.build_args(config)))
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        settings=json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())
        self.assertEqual(settings['interval'],180)
        self.assertIn('--interval 180 ',(base/'etc/systemd/system/psiphon-autopin.service').read_text())
    def test_saved_installer_reapplies_after_original_file_is_deleted(self):
        base,proc=self.install(extra_args=('--connection','xray','--no-gemini-check'))
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        app=base/'opt/psiphon-autopin';saved=app/'install_psiphon_autopin.sh'
        self.assertTrue((app/'autopin_menu.py').exists());self.assertTrue((base/'usr/local/sbin/auto-pin').exists())
        self.assertEqual(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['connection_type'],'xray')
        self.assertTrue((base/'var/lib/psiphon-autopin/xray-outbound.json').exists())
        (base/'install.sh').unlink()
        p=subprocess.run(['bash','-n',str(saved)],text=True,capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr)
        p=subprocess.run(['bash',str(saved),'--instance','1'],text=True,capture_output=True,timeout=20,
            env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)})
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertFalse(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['gemini_check'])
        self.assertEqual(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['connection_type'],'xray')

if __name__=='__main__':unittest.main()
