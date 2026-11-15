"""Template installation, cancellation, port isolation and the first-run terminal."""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from test_menu import u,Terminal
import test_installation as installation
from test_dual_mode import multi_instance_fake


class TemplateTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        p=patch.object(u,'ROOT',self.base);p.start();self.addCleanup(p.stop)
        self.installer=self.base/'install.sh';self.installer.touch()
        p=patch.object(u,'runtime_status',return_value={key:{'state':'unknown','autostart':'unknown'} for key in ('tunnel','monitor')})
        p.start();self.addCleanup(p.stop)
    def save(self,config):
        u.atomic_json(u.paths(config['instance'])['data']/'settings.json',config)
        p=u.paths(config['instance'])['manager'];p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    def install_child(self,argv,**kwargs):
        n=int(argv[argv.index('--instance')+1]);config=u.defaults(n)
        config.update(port=int(argv[argv.index('--port')+1]),region=argv[argv.index('--region')+1],
                      youtube_mode='--youtube-mode' in argv,gemini_check='--gemini-check' in argv)
        if config['region']=='AUTO':config['region']=''
        self.save(config)
        return subprocess.CompletedProcess(argv,0)
    def test_first_run_enter_opens_templates_and_cancel_writes_nothing(self):
        terminal=Terminal(['','0','0'])
        with patch.object(u.subprocess,'run') as run:self.assertEqual(u.Menu(terminal).run(),0)
        run.assert_not_called();self.assertEqual(u.discover(),[])
        self.assertIn('Enter — Шаблоны',terminal.output.getvalue())
        self.assertLess(terminal.output.getvalue().index('t. Шаблоны'),terminal.output.getvalue().index('1. Easy Mode'))
    def test_all_three_templates_emit_their_distinct_mode_policies(self):
        for choice,expected in [('1',[(True,False),(False,True)]),('2',[(True,False)]),('3',[(False,True)])]:
            with self.subTest(choice=choice):
                target=self.base/('plan'+choice+'.json');terminal=Terminal(['t',choice,'y','y'])
                with patch.object(u.subprocess,'run') as run:u.Menu(terminal,emit_args=target).run()
                run.assert_not_called();args=json.loads(target.read_text())
                self.assertEqual([('--gemini-check' in a,'--youtube-mode' in a) for a in args],expected)
                self.assertEqual(len({a[a.index('--port')+1] for a in args}),len(expected))
                self.assertEqual(u.discover(),[])
    def test_both_modes_start_sequential_children_then_return_to_main(self):
        terminal=Terminal(['t','1','y','1','0']);menu=u.Menu(terminal,installer=self.installer)
        with patch.object(u.subprocess,'run',side_effect=self.install_child) as run:self.assertEqual(menu.run(),0)
        self.assertEqual(run.call_count,2)
        for call in run.call_args_list:
            self.assertEqual(call.kwargs['env']['AUTOPIN_MENU_PARENT'],'1')
            self.assertEqual(call.kwargs['env']['AUTOPIN_CREATE_ONLY'],'1')
        self.assertEqual(u.discover(),[1,2])
        self.assertEqual((u.load_config(1)['gemini_check'],u.load_config(1)['youtube_mode']),(True,False))
        self.assertEqual((u.load_config(2)['gemini_check'],u.load_config(2)['youtube_mode']),(False,True))
        self.assertIn('Экземпляры: 1 — Gemini, SOCKS 40000; 2 — YouTube, SOCKS 40002',terminal.output.getvalue())
        self.assertIn('Запуск служб ещё не означает найденный',terminal.output.getvalue())
    def test_cancel_at_common_confirmation_starts_neither_mode(self):
        terminal=Terminal(['1','y','n'])
        with patch.object(u.subprocess,'run') as run:self.assertFalse(u.Menu(terminal).templates())
        run.assert_not_called();self.assertEqual(u.discover(),[])
    def test_existing_instances_are_never_reused_or_modified_by_template(self):
        original=u.defaults(1);original.update(port=41000,interval=420,min_speed_kib=1234,region='DE')
        self.save(original);path=u.paths(1)['data']/'settings.json';before=path.read_bytes()
        plan=u.template_plan('1',1)
        self.assertEqual([c['instance'] for c in plan],[2,3])
        with patch.object(u.subprocess,'run',side_effect=self.install_child):
            self.assertTrue(u.Menu(Terminal(['y']),installer=self.installer).apply_template_plan(plan))
        self.assertEqual(path.read_bytes(),before);self.assertEqual(u.load_config(1),original)
    def test_allocator_skips_reserved_http_and_live_listening_ports(self):
        original=u.defaults(9);original.update(port=40000);self.save(original)
        sock=socket.socket();sock.bind(('127.0.0.1',40002));self.addCleanup(sock.close)
        plan=u.template_plan('1')
        self.assertEqual([c['port'] for c in plan],[40004,40006]);u.validate_template_plan(plan)
    def test_overlapping_socks_http_ports_are_rejected_before_any_install(self):
        plan=u.template_plan('1');plan[1]['port']=plan[0]['port']+1
        with patch.object(u.subprocess,'run') as run:self.assertFalse(u.Menu(Terminal([])).apply_template_plan(plan))
        run.assert_not_called();self.assertEqual(u.discover(),[])
    def test_ports_claimed_during_confirmation_are_rechecked(self):
        plan=u.template_plan('1');menu=u.Menu(Terminal([]),installer=self.installer);sockets=[]
        def occupied(_):
            sock=socket.socket();sock.bind(('127.0.0.1',plan[1]['port']));sockets.append(sock);return True
        try:
            with patch.object(menu,'confirm',side_effect=occupied),patch.object(u.subprocess,'run') as run:
                self.assertFalse(menu.apply_template_plan(plan))
            run.assert_not_called()
        finally:
            for sock in sockets:sock.close()
    def test_partial_failure_preserves_first_mode_and_reports_second_failed(self):
        plan=u.template_plan('1');terminal=Terminal(['y']);menu=u.Menu(terminal,installer=self.installer)
        def install(argv,**kwargs):
            if '--youtube-mode' in argv:return subprocess.CompletedProcess(argv,7)
            return self.install_child(argv,**kwargs)
        with patch.object(u.subprocess,'run',side_effect=install):self.assertFalse(menu.apply_template_plan(plan))
        self.assertEqual(u.discover(),[1]);self.assertEqual(menu.instance,1)
        self.assertIn('кодом 7',terminal.output.getvalue());self.assertIn('Уже установлены и сохранены: Gemini',terminal.output.getvalue())
        self.assertNotIn('Шаблон установлен. Запуск служб',terminal.output.getvalue())
    def test_template_basic_fields_are_editable_before_common_confirmation(self):
        emitted=self.base/'args.json'
        # Gemini region / YouTube port / YouTube watchdog / YouTube floor.
        menu=u.Menu(Terminal(['t','1','1','DE','6','42000','7','2','9','2200','y','y']),emit_args=emitted)
        menu.run();gm,yt=json.loads(emitted.read_text())
        self.assertEqual(gm[gm.index('--region')+1],'DE')
        self.assertEqual(yt[yt.index('--port')+1],'42000');self.assertEqual(yt[yt.index('--interval')+1],'120')
        self.assertEqual(yt[yt.index('--min-speed')+1],'2200');self.assertEqual(yt[yt.index('--region')+1],'AUTO')
    def test_boolean_prompt_explains_numeric_choices_and_enter(self):
        field=next(f for f in u.FIELDS if f.key=='youtube_mode')
        for answer,expected in [('1',True),('0',False),('да',True),('нет',False),('',False)]:
            terminal=Terminal([answer]);menu=u.Menu(terminal)
            self.assertIs(menu.input_field(field,False),expected)
            output=terminal.output.getvalue()
            self.assertIn('1 — Да (включить), 0 — Нет (выключить)',output)
            self.assertIn('Enter — оставить «нет»',output)
    def test_invalid_confirmation_is_reprompted_instead_of_silently_cancelled(self):
        terminal=Terminal(['?','1']);self.assertTrue(u.Menu(terminal).confirm('Применить?'))
        self.assertIn('Введите y или 1',terminal.output.getvalue())


class TemplateInstallerTests(unittest.TestCase):
    install=installation.InstallationTests.install
    def test_create_only_guard_keeps_existing_configuration_and_services(self):
        base,p=self.install(fresh=True);self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        target=base/'var/lib/psiphon-autopin/settings.json';before=target.read_bytes()
        commands=base/'commands';commands.write_text('')
        env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base),'AUTOPIN_CREATE_ONLY':'1'}
        p=subprocess.run(['bash',str(base/'install.sh'),'--instance','1','--region','DE'],capture_output=True,text=True,env=env,timeout=20)
        self.assertNotEqual(p.returncode,0);self.assertIn('will not overwrite',p.stderr)
        self.assertEqual(target.read_bytes(),before)
        self.assertNotIn('"stop"',commands.read_text());self.assertTrue(json.loads((base/'state').read_text())['running'])
    def test_first_install_real_pty_runs_each_template_and_reopens_main(self):
        for choice in ('1','2','3'):
            with self.subTest(template=choice):self.run_bootstrap(choice)
    def test_first_install_easy_without_templates_still_returns_to_main(self):
        self.run_bootstrap(None)
    def run_bootstrap(self,choice):
        with patch.object(installation,'FAKE',multi_instance_fake()):base,p=self.install(fresh=True)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        for folder in ('opt/psiphon-autopin','var/lib/psiphon-autopin','opt/vps-psiphon'):
            shutil.rmtree(base/folder)
        for file in ('etc/systemd/system/vps-psiphon.service','etc/systemd/system/psiphon-autopin.service',
                     'etc/default/vps-psiphon','usr/local/sbin/vps-psiphon-run'):
            (base/file).unlink(missing_ok=True)
        state=json.loads((base/'state').read_text());state.update(running=False,legacy=False,ports={});(base/'state').write_text(json.dumps(state))
        installer=base/'install.sh';source=installer.read_text()
        first=source.index("<<'PY_MENU'\n")+len("<<'PY_MENU'\n");last=source.index('\nPY_MENU\n',first)
        module=source[first:last].replace("ROOT=Path('/')",'ROOT=Path('+repr(str(base))+')')
        # The fake-host fixture already rewrites absolute shell/Python paths;
        # located() applies ROOT itself, so undo that extra prefix for its inputs.
        module=module.replace("located('"+str(base)+"/","located('/")
        module=module.replace("if os.geteuid()!=0:print",'if False:print')
        installer.write_text(source[:first]+module+source[last:])
        private_tmp=base/'tmp';private_tmp.mkdir()
        env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base),'TMPDIR':str(private_tmp)}
        pid,fd=pty.fork()
        if pid==0:os.execve('/bin/bash',['bash',str(installer),'--menu'],env)
        raw=bytearray();cursor=0;reaped=False
        def expect(text,timeout=45):
            nonlocal cursor
            target=text.encode();deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                found=raw.find(target,cursor)
                if found>=0:cursor=found+len(target);return
                if select.select([fd],[],[],0.1)[0]:
                    try:chunk=os.read(fd,65536)
                    except OSError:chunk=b''
                    if not chunk:break
                    raw.extend(chunk)
            self.fail('Missing prompt '+text+'\n'+raw.decode(errors='replace'))
        try:
            expect('Выбор [Enter — Шаблоны]')
            if choice is None:
                os.write(fd,b'1\n');expect('Выбор: ');os.write(fd,b'y\n')
                expect('Применить эти настройки?');os.write(fd,b'y\n')
            else:
                os.write(fd,b'\n');expect('Выберите шаблон');os.write(fd,(choice+'\n').encode())
                expect('Выбор [y — установить');os.write(fd,b'y\n')
                expect('Установить выбранный шаблон?');os.write(fd,b'y\n')
                expect('Шаблон установлен. Запуск служб',75)
            if choice=='1':expect('Экземпляры: 1 — Gemini, SOCKS 40000; 2 — YouTube, SOCKS 40002')
            expect('Выбор [Enter — Easy]');os.write(fd,b'0\n')
            end=time.monotonic()+10
            while time.monotonic()<end:
                waited,status=os.waitpid(pid,os.WNOHANG)
                if waited:
                    reaped=True;self.assertEqual(os.waitstatus_to_exitcode(status),0);break
                time.sleep(0.05)
            self.assertTrue(reaped,'Bootstrap menu did not exit')
            roles=('gemini',) if choice is None else u.TEMPLATES[choice][1]
            for number,role in enumerate(roles,1):
                suffix='' if number==1 else '-'+str(number)
                config=json.loads((base/('var/lib/psiphon-autopin'+suffix+'/settings.json')).read_text())
                self.assertEqual((config['gemini_check'],config['youtube_mode'],config['port']),
                                 (role=='gemini',role=='youtube',40000+2*(number-1)))
                self.assertEqual(config['min_speed_kib'],1500 if role=='youtube' else 800)
                self.assertEqual(config['region'],'' if role=='youtube' else 'NL');self.assertEqual(config['probe_mb'],4)
            if len(roles)==1:self.assertFalse((base/'var/lib/psiphon-autopin-2/settings.json').exists())
            self.assertEqual(list(private_tmp.iterdir()),[],'Temporary installer must be cleaned after menu exit')
            self.assertEqual(raw.count('Установить выбранный шаблон?'.encode()),0 if choice is None else 1)
        finally:
            if not reaped:os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
            os.close(fd)


if __name__=='__main__':unittest.main()
