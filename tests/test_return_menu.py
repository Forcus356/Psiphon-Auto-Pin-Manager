"""Return to the status menu without leaking the installer transaction lock."""
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from test_autopin import INSTALLER
from test_menu import u,Terminal

def pty_script(script):
    pid,fd=pty.fork()
    if pid==0:os.execv('/bin/bash',['bash','-c',script])
    output=b'';reaped=False;status=None
    try:
        end=time.monotonic()+10
        while time.monotonic()<end:
            if select.select([fd],[],[],0.1)[0]:
                try:output+=os.read(fd,65536)
                except OSError:pass
            waited,status=os.waitpid(pid,os.WNOHANG)
            if waited:reaped=True;break
        if not reaped:raise AssertionError('interactive helper did not finish')
        return os.waitstatus_to_exitcode(status),output.decode('utf-8','replace')
    finally:
        if not reaped:os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
        os.close(fd)

class InstallerReturnTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        self.lock=self.base/'transaction.lock';self.alias=self.base/'auto-pin'
        self.alias.write_text('#!/usr/bin/env python3\nimport fcntl,sys\nfrom pathlib import Path\nwith Path('+repr(str(self.lock))+').open("a") as f:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n print("LOCK_FREE")\nprint("MENU_REOPENED "+" ".join(sys.argv[1:]))\n')
        self.alias.chmod(0o755)
        self.function='autopin_return_to_menu() {\n'+INSTALLER.split('autopin_return_to_menu() {\n',1)[1].split('\n}\n',1)[0]+'\n}\n'
        self.function=self.function.replace('/usr/local/sbin/auto-pin',str(self.alias))
    def test_interactive_return_opens_selected_instance_and_releases_lock(self):
        script='set -euo pipefail\nINSTANCE=7;MENU_REQUESTED=1\nexec {AUTOPIN_TRANSACTION_LOCK_FD}>>'+shlex.quote(str(self.lock))+'\nflock -x "$AUTOPIN_TRANSACTION_LOCK_FD"\n'+self.function+'\nautopin_return_to_menu\necho UNEXPECTED\n'
        code,out=pty_script(script)
        self.assertEqual(code,0,out);self.assertIn('LOCK_FREE',out);self.assertIn('MENU_REOPENED --instance 7',out);self.assertNotIn('UNEXPECTED',out)
    def test_automation_without_tty_does_not_open_a_menu(self):
        script='INSTANCE=1;MENU_REQUESTED=0\n'+self.function+'\nautopin_return_to_menu\necho AUTOMATION_DONE\n'
        p=subprocess.run(['bash'],input=script,text=True,capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout.strip(),'AUTOMATION_DONE')
    def test_parent_menu_does_not_spawn_a_nested_menu(self):
        script='INSTANCE=2;MENU_REQUESTED=1;AUTOPIN_MENU_PARENT=1\n'+self.function+'\nautopin_return_to_menu\necho PARENT_KEPT\n'
        code,out=pty_script(script);self.assertEqual(code,0,out);self.assertIn('PARENT_KEPT',out);self.assertNotIn('MENU_REOPENED',out)

class MenuResultTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        p=patch.object(u,'ROOT',self.base);p.start();self.addCleanup(p.stop)
        app=u.paths(2)['app'];app.mkdir(parents=True);(app/'psiphon_autopin.py').touch()
        c=u.defaults(2);u.atomic_json(u.paths(2)['data']/'settings.json',c)
        self.state=u.paths(2)['data']/'state.json'
        self.status={'monitor':{'state':'active','autostart':'enabled'},'tunnel':{'state':'active','autostart':'enabled','started_at':'2026-11-15T10:00:00Z'}}
    def test_unverified_startup_does_not_claim_a_pin(self):
        u.atomic_json(self.state,{'diagnostic_id':'abcdefgh','adopted_unpinned':False,'verified_at':'2026-11-15T09:00:00Z','ip':'192.0.2.1'})
        terminal=Terminal([])
        with patch.object(u,'runtime_status',return_value=self.status):u.Menu(terminal,instance=2).footer()
        text=terminal.output.getvalue();self.assertIn('результат ещё не подтверждён',text);self.assertNotIn('PIN закреплён',text)
    def test_refresh_shows_completed_pin_without_a_network_probe(self):
        u.atomic_json(self.state,{'verified_at':'2026-11-15T09:00:00Z'})
        case=self
        class Progress(Terminal):
            def readline(self):
                value=super().readline()
                if value=='r\n':u.atomic_json(case.state,{'diagnostic_id':'abcdefgh','adopted_unpinned':False,'verified_at':'2026-11-15T11:00:00Z','ip':'192.0.2.1'})
                return value
        terminal=Progress(['r','0'])
        with patch.object(u,'runtime_status',return_value=self.status) as status:
            u.Menu(terminal,instance=2).run()
        self.assertEqual(status.call_count,2);self.assertIn('PIN закреплён',terminal.output.getvalue());self.assertIn('результат ещё не подтверждён',terminal.output.getvalue())
    def test_update_returns_to_the_new_installed_menu(self):
        view=u.Menu(Terminal(['5']),instance=2)
        with patch.object(u.Menu,'update',return_value=True),patch.object(u.os,'execv') as execv,patch.object(u,'runtime_status',return_value=self.status):
            self.assertEqual(view.run(),0)
        self.assertEqual(execv.call_args.args[1][-3:],[str(u.paths(2)['app']/'autopin_menu.py'),'--instance','2'])
    def test_apply_marks_child_installer_as_owned_by_the_parent_menu(self):
        view=u.Menu(Terminal(['да']),instance=2)
        with patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as run:
            self.assertTrue(view.apply())
        self.assertEqual(run.call_args.kwargs['env']['AUTOPIN_MENU_PARENT'],'1')
