"""Independent dashboard observations, provenance and explicit read scopes."""
import argparse
import datetime as dt
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_menu import u,Terminal
from test_autopin import m
import test_installation as installation


class OverviewTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        p=patch.object(u,'ROOT',self.base);p.start();self.addCleanup(p.stop)
        self.now=dt.datetime.now(dt.timezone.utc);self.start=(self.now-dt.timedelta(seconds=30)).isoformat()
        self.status={key:{'state':'active','autostart':'enabled','started_at':self.start} for key in ('tunnel','monitor')}
        p=patch.object(u,'runtime_status',return_value=self.status);p.start();self.addCleanup(p.stop)
        boot=u.located('/proc/sys/kernel/random/boot_id');boot.parent.mkdir(parents=True);boot.write_text('test-boot')
        self.save(1,gemini_check=True)
        self.save(2,youtube_mode=True,gemini_check=False,region='',min_speed_kib=1500)
    def save(self,number,**values):
        config=u.defaults(number);config.update(values)
        u.atomic_json(u.paths(number)['data']/'settings.json',config)
        app=u.paths(number)['app'];app.mkdir(parents=True,exist_ok=True);(app/'psiphon_autopin.py').touch()
        (app/'autopin_menu.py').write_text("VERSION='4.4.0'\n")
        return config
    def ru(self,**changes):
        value={'status':'PIN VERIFIED','ip':'192.0.2.2','google_region':'RU','diagnostic_id':'YTTEST00','speed_kib_s':2500,
               'checked_at':self.now.isoformat(),'last_success_at':self.now.isoformat(),'boot_id':'test-boot',
               'container_started_at':self.start,'pin_verified':True}
        value.update(changes);u.atomic_json(u.paths(2)['data']/'youtube-status.json',value)
    def state(self,number,**changes):
        value={'verified_at':self.now.isoformat(),'ip':'192.0.2.'+str(number),'google_region':'NL','gemini':'SERVING',
               'diagnostic_id':'GEMTEST0','adopted_unpinned':False}
        value.update(changes);u.atomic_json(u.paths(number)['data']/'state.json',value)
    def test_overview_keeps_template_roles_separate_from_manual_instances(self):
        self.save(3,gemini_check=False,region='DE');u.mark_template([1,2]);self.ru();self.state(1)
        terminal=Terminal([]);view=u.Menu(terminal);before=view.config.copy();view.overview();text=terminal.output.getvalue()
        self.assertIn('====== Шаблоны ======',text);self.assertIn('====== Ваши экземпляры ======',text)
        self.assertLess(text.index('Экземпляр 2 — YouTube'),text.index('====== Ваши экземпляры ======'))
        self.assertIn('Экземпляр 3 — Psiphon, SOCKS 40004',text)
        self.assertEqual(view.instance,1);self.assertEqual(view.config,before)
    def test_ru_verified_without_state_is_not_reported_as_still_searching(self):
        self.ru();terminal=Terminal([]);u.Menu(terminal).footer(2,overview=True);text=terminal.output.getvalue()
        self.assertIn('YouTube Mode: PIN VERIFIED',text)
        self.assertNotIn('результат ещё не подтверждён',text);self.assertNotIn('Gemini: выключен',text)
    def test_gemini_block_does_not_report_other_instances_youtube_disabled(self):
        self.state(1);terminal=Terminal([]);u.Menu(terminal).footer(1,overview=True)
        self.assertIn('Gemini: SERVING',terminal.output.getvalue());self.assertNotIn('YouTube Mode: DISABLED',terminal.output.getvalue())
    def test_each_pending_status_is_scoped_to_its_instance(self):
        self.ru(status='SEARCHING',pin_verified=False);self.state(1)
        terminal=Terminal([]);u.Menu(terminal).overview();text=terminal.output.getvalue()
        gm,yt=text.split('--------- YouTube · экземпляр 2 ---------')
        self.assertNotIn('результат ещё не подтверждён',gm);self.assertIn('результат ещё не подтверждён',yt)
    def test_old_serving_result_is_explicitly_previous_after_container_restart(self):
        self.state(1,verified_at=(self.now-dt.timedelta(hours=1)).isoformat())
        terminal=Terminal([]);u.Menu(terminal).footer(1,overview=True);text=terminal.output.getvalue()
        self.assertIn('Предыдущий результат Gemini: SERVING',text)
        self.assertIn('ответ модели ещё не подтверждён',text);self.assertNotIn('Режим: PIN закреплён',text)
    def test_other_instances_broken_settings_do_not_hide_healthy_instances(self):
        self.state(1);(u.paths(2)['data']/'settings.json').write_text('{broken')
        terminal=Terminal([]);u.Menu(terminal).overview()
        self.assertIn('Gemini: SERVING',terminal.output.getvalue());self.assertIn('состояние недоступно',terminal.output.getvalue())
    def test_legacy_pair_is_not_guessed_from_its_policies(self):
        terminal=Terminal([]);u.Menu(terminal).overview()
        self.assertNotIn('====== Шаблоны ======',terminal.output.getvalue())
        self.assertIn('====== Ваши экземпляры ======',terminal.output.getvalue())
    def test_existing_template_grouping_changes_only_origin_receipts(self):
        files=[u.paths(n)['data']/'settings.json' for n in (1,2)];before=[p.read_bytes() for p in files]
        u.Menu(Terminal(['1,2','y'])).group_existing()
        self.assertEqual([p.read_bytes() for p in files],before)
        self.assertEqual(u.instance_origin(1)['group'],u.instance_origin(2)['group'])
    def test_cancel_grouping_writes_no_origin(self):
        u.Menu(Terminal(['1,2','n'])).group_existing();self.assertEqual(u.instance_origin(1),{})
    def test_read_target_selector_supports_one_all_invalid_and_cancel(self):
        for answers,expected in [(['2'],[2]),(['a'],[1,2]),(['0'],[]),(['99','?','1'],[1])]:
            with self.subTest(answers=answers):self.assertEqual(u.Menu(Terminal(answers)).view_targets('Журналы'),expected)
    def test_status_and_logs_choose_targets_before_running_scoped_commands(self):
        for action,answers,expected in [('1',['1','2'],[2]),('8',['8','a','12'],[1,2]),('10',['10','a'],[1,2])]:
            terminal=Terminal(answers)
            with patch.object(u.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as run:
                self.assertFalse(u.Menu(terminal).manage())
            self.assertEqual([int(c.args[0][-1]) for c in run.call_args_list],expected)
            for call in run.call_args_list:
                args=call.args[0];self.assertIn('--instance',args)
                if action=='8':self.assertEqual(args[3],'12')
    def test_cancel_read_scope_runs_nothing(self):
        with patch.object(u.subprocess,'run') as run:u.Menu(Terminal(['1','0'])).manage()
        run.assert_not_called()
    def test_config_all_is_labeled_and_excludes_server_entry_credentials(self):
        terminal=Terminal(['15','a'])
        with patch.object(u.subprocess,'run') as run:u.Menu(terminal).manage()
        run.assert_not_called();text=terminal.output.getvalue()
        self.assertIn('Экземпляр 1 — Gemini',text);self.assertIn('Экземпляр 2 — YouTube',text)
        self.assertIn('"settings"',text);self.assertNotIn('TargetServerEntry',text)
    def test_update_all_visits_both_and_keeps_explicit_success_list(self):
        terminal=Terminal(['a']);menu=u.Menu(terminal);visited=[]
        with patch.object(u.Menu,'update',side_effect=lambda:visited.append(menu.instance) or True):self.assertTrue(menu.update_selected())
        self.assertEqual(visited,[1,2]);self.assertIn('Обновлены экземпляры: 1, 2',terminal.output.getvalue())
    def test_update_partial_failure_does_not_claim_both_updated(self):
        terminal=Terminal(['a']);menu=u.Menu(terminal)
        with patch.object(u.Menu,'update',side_effect=[True,False]):self.assertTrue(menu.update_selected())
        self.assertEqual(menu.instance,1);self.assertNotIn('Обновлены экземпляры: 1, 2',terminal.output.getvalue())
    def test_search_progress_invalidates_an_old_positive_gemini_pin(self):
        self.state(1);u.atomic_json(u.paths(1)['data']/'activity.json',{'status':'SEARCHING','checked_at':self.now.isoformat(),'detail':'Кандидат 3/40'})
        terminal=Terminal([]);u.Menu(terminal).footer(1,overview=True)
        self.assertIn('Кандидат 3/40',terminal.output.getvalue());self.assertNotIn('Режим: PIN закреплён',terminal.output.getvalue())


class ReadCLI(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        p=patch.object(m,'DATA',self.base/'psiphon-autopin');p.start();self.addCleanup(p.stop)
        for n in (1,2):
            suffix='' if n==1 else '-2';m.atomic_json(self.base/('psiphon-autopin'+suffix)/'settings.json',{'instance':n,'gemini_check':n==1,'youtube_mode':n==2})
    def test_all_status_is_json_and_each_subcommand_has_an_explicit_instance(self):
        replies=[subprocess.CompletedProcess([],0,stdout='{"instance":1}',stderr=''),subprocess.CompletedProcess([],0,stdout='{"instance":2}',stderr='')]
        with patch.object(sys,'argv',['manager','status','--all']),patch.object(m.subprocess,'run',side_effect=replies) as run,patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(m.main(),0)
        data=json.loads(output.getvalue());self.assertEqual([v['name'] for v in data],['Gemini','YouTube'])
        self.assertEqual([c.args[0][-2:] for c in run.call_args_list],[['--instance','1'],['--instance','2']])
    def test_all_config_uses_saved_policy_without_subprocess_or_raw_psiphon_config(self):
        with patch.object(sys,'argv',['manager','config','--all']),patch.object(m.subprocess,'run') as run,patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(m.main(),0)
        run.assert_not_called();self.assertEqual([v['instance'] for v in json.loads(output.getvalue())],[1,2])
        self.assertNotIn('TargetServerEntry',output.getvalue())
    def test_all_is_rejected_for_destructive_commands(self):
        with patch.object(sys,'argv',['manager','uninstall','--all']),patch.object(m,'uninstall') as remove:
            with self.assertRaises(SystemExit):m.main()
        remove.assert_not_called()
    def test_failed_single_status_does_not_hide_other_instance_and_returns_failure(self):
        args=argparse.Namespace(command='status',value=None)
        with patch.object(m.subprocess,'run',side_effect=[subprocess.CompletedProcess([],1,stdout='',stderr='failed'),subprocess.CompletedProcess([],0,stdout='{"instance":2}',stderr='')]),patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(m.all_views(args,[1,2]),1)
        self.assertEqual(len(json.loads(output.getvalue())),2)


class OriginUpgradeTests(unittest.TestCase):
    install=installation.InstallationTests.install
    def test_reinstall_keeps_template_origin_and_all_saved_policy(self):
        base,p=self.install(fresh=True);self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        path=base/'var/lib/psiphon-autopin/origin.json';origin={'source':'template','group':'original','role':'Gemini'};path.write_text(json.dumps(origin))
        settings=base/'var/lib/psiphon-autopin/settings.json';before=settings.read_bytes()
        env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)}
        p=subprocess.run(['bash',str(base/'install.sh'),'--instance','1'],capture_output=True,text=True,env=env,timeout=20)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr);self.assertEqual(json.loads(path.read_text()),origin);self.assertEqual(settings.read_bytes(),before)


if __name__=='__main__':unittest.main()
