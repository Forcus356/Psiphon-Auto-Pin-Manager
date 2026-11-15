import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_autopin import m,ROOT

spec=importlib.util.spec_from_file_location('gemini',ROOT/'gemini_probe.py')
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)

class Features(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        base=Path(self.tmp.name)
        for name,value in {'BASE':base/'app','DATA':base/'data','CONFIG':base/'config/psiphon.config','STATE':base/'data/state.json','CACHE':base/'data/cache.json','ENV_FILE':base/'env','CONTAINER':'vps-psiphon','INSTANCE':1,'PROXY':'127.0.0.1:40000','POLICY':{}}.items():
            mock=patch.object(m,name,value);mock.start();self.addCleanup(mock.stop)
        m.atomic_json(m.DATA/'settings.json',{'region':'NL','backend':'vps-psiphon'})
        m.atomic_json(m.CONFIG,{'EgressRegion':'NL','TargetServerEntry':'test-target'})
        m.atomic_json(m.STATE,{'region':'NL','ip':'192.0.2.1','diagnostic_id':'abcdefgh'})
        m.ENV_FILE.write_text('EGRESS_REGION=NL\n');m.BASE.mkdir()

    def test_country_pool_wraps_and_starts_after_current(self):
        m.POLICY={'region_pool':['NL','DE','PL']}
        self.assertEqual(m.rotation_regions('DE'),['PL','NL','DE'])
        self.assertEqual(m.rotation_regions('US'),['NL','DE','PL'])
        self.assertEqual(m.countries('nl,DE nl'),['NL','DE'])
        with self.assertRaises(ValueError):m.countries("NL;touch /tmp/x")

    def test_speed_excludes_connection_setup(self):
        with patch.object(m,'run',return_value='1048576 3 4 200') as run:
            self.assertEqual(m.speed_probe(1),1024)
        args=run.call_args.args[0]
        self.assertIn('socks5h://127.0.0.1:40000',args)
        self.assertIn('--noproxy',args)

    def test_small_or_invalid_speed_sample_not_accepted(self):
        for reply in ('100 0 1 200','100000 1 1 200','100000 1 2 503'):
            with patch.object(m,'run',return_value=reply):
                with self.assertRaises(RuntimeError):m.speed_probe(1)

    def test_no_bulk_mode_measures_page_when_floor_enabled(self):
        m.POLICY={'min_speed_kib':800}
        with patch.object(m,'run',return_value='102400 0.1 0.2 200') as run:m.speed_probe(0)
        self.assertEqual(run.call_args.args[0][-1],'https://www.youtube.com/')

    def test_fast_google_classifier_never_connects_directly(self):
        with patch.object(m,'run',return_value='prefix {"GL":"NL"} suffix') as run:
            self.assertEqual(m.google_region(),'NL')
        self.assertIn('--proxy',run.call_args.args[0]);self.assertIn('--noproxy',run.call_args.args[0])

    def test_missing_google_country_is_unknown(self):
        with patch.object(m,'run',return_value='<html>captcha</html>'):
            with self.assertRaises(RuntimeError):m.google_region()

    def test_deny_list_and_captcha_are_decisive(self):
        m.POLICY={'deny_regions':['RU','BY']}
        with patch.object(m,'probe',return_value=('192.0.2.1','BY')),patch.object(m,'gemini_verdict',return_value='SERVING'):
            self.assertEqual(m.evaluate_exit('DE',True,0)[-1],'Google=BY')
        with patch.object(m,'probe',return_value=('192.0.2.1','NL')),patch.object(m,'gemini_verdict',return_value='CAPTCHA'):
            self.assertEqual(m.evaluate_exit('NL',True,0)[-1],'Gemini CAPTCHA')

    def test_verified_reserve_prioritizes_only_current_database_entries(self):
        m.remember_pin({'diagnostic':'saved','encoded':'OLD secret','server_ip':'192.0.2.1'},'NL')
        rows=[{'diagnostic':'other','encoded':'fresh1'}, {'diagnostic':'saved','encoded':'fresh2'}]
        result=m.prioritized_candidates(rows,'NL')
        self.assertEqual(result[0]['encoded'],'fresh2')
        self.assertEqual((m.DATA/'verified-reserve.json').stat().st_mode & 0o777,0o600)

    def test_slow_speed_requires_two_consecutive_checks(self):
        m.POLICY={'min_speed_kib':800,'slow_threshold':2}
        with patch.object(m,'wait_ready'),patch.object(m,'evaluate_exit',return_value=('192.0.2.1','NL','SERVING',100,'')),patch.object(m,'connected_id',return_value='abcdefgh'),patch.object(m,'started_at',return_value='t1'),patch.object(m,'search') as search,patch.object(m.time,'sleep',side_effect=[None,KeyboardInterrupt]) as sleep:
            with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,75,12)
        search.assert_called_once();self.assertEqual(sleep.call_args_list[0].args,(30,))

    def test_slow_speed_streak_resets_on_recovery(self):
        m.POLICY={'min_speed_kib':800,'slow_threshold':2}
        values=[('192.0.2.1','NL','SERVING',100,''),('192.0.2.1','NL','SERVING',1000,''),('192.0.2.1','NL','SERVING',100,'')]
        with patch.object(m,'wait_ready'),patch.object(m,'evaluate_exit',side_effect=values),patch.object(m,'connected_id',return_value='abcdefgh'),patch.object(m,'started_at',return_value='t1'),patch.object(m,'search') as search,patch.object(m.time,'sleep',side_effect=[None,None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,75,12)
        search.assert_not_called()

    def test_slow_speed_streak_resets_after_container_restart(self):
        m.POLICY={'min_speed_kib':800,'slow_threshold':2}
        with patch.object(m,'wait_ready'),patch.object(m,'evaluate_exit',return_value=('192.0.2.1','NL','SERVING',100,'')),patch.object(m,'connected_id',return_value='abcdefgh'),patch.object(m,'started_at',side_effect=['t1','t2']),patch.object(m,'search') as search,patch.object(m.time,'sleep',side_effect=[None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,75,12)
        search.assert_not_called()

    def test_instance_paths_and_units_are_independent(self):
        m.configure_instance(2)
        self.assertEqual(str(m.DATA),'/var/lib/psiphon-autopin-2')
        self.assertEqual(str(m.CONFIG),'/opt/vps-psiphon-2/config/psiphon.config')
        self.assertEqual(m.monitor_unit(),'psiphon-autopin-2.service')
        self.assertEqual(m.PROXY,'127.0.0.1:40002')
        with patch.object(m,'backend',return_value='vps-psiphon'),patch.object(m,'run') as run:m.tunnel_action('restart')
        self.assertEqual(run.call_args.args[0],['systemctl','restart','vps-psiphon-2.service'])

    def test_browser_captcha_is_distinguished_from_generic_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile=Path(tmp)/'curl_chrome140';profile.touch()
            def fake(args,timeout=90,executable='curl'):
                Path(args[args.index('-D')+1]).write_text('HTTP/2 302\nLocation: https://www.google.com/sorry/index\n')
                return 0,'',''
            with patch.object(g,'curl',side_effect=fake):self.assertEqual(g.check(40000,tmp)[0],'CAPTCHA')

    def test_missing_browser_binary_is_not_a_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(g.check(40000,tmp)[0],'INCONCLUSIVE')

    def test_uninstall_removes_only_the_selected_instance(self):
        base=Path(self.tmp.name)
        m.INSTANCE=2;m.CONTAINER='vps-psiphon-2';m.CONFIG=base/'vps2/config/psiphon.config'
        for directory in (m.BASE,m.DATA,m.CONFIG.parent.parent):directory.mkdir(parents=True,exist_ok=True)
        sentinel=base/'instance-1-data';sentinel.write_text('keep')
        original_path=Path
        def sandbox_path(value):
            p=original_path(value)
            if str(p).startswith(('/etc/','/usr/local/')):return base/'system'/str(p).lstrip('/')
            return p
        def fake_run(args,**kwargs):
            if '.Mounts' in ' '.join(args):return str(m.CONFIG.parent)
            if '.Config.Image' in ' '.join(args):return 'shared-psiphon:latest'
            return ''
        with patch.object(m,'Path',side_effect=sandbox_path),patch.object(m.os,'geteuid',return_value=0),patch.object(m,'run',side_effect=fake_run),patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as commands:
            m.uninstall()
        self.assertEqual(sentinel.read_text(),'keep')
        self.assertFalse(m.BASE.exists());self.assertFalse(m.DATA.exists())
        all_args=[call.args[0] for call in commands.call_args_list]
        self.assertIn(['docker','rm','-f','vps-psiphon-2'],all_args)
        self.assertNotIn(['docker','rm','-f','vps-psiphon'],all_args)

    def test_keepalive_finishes_when_model_response_is_done(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);binary=base/'curl'
            binary.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\na=sys.argv\nPath(a[a.index("-o")+1]).write_text("model-result")\nsys.stderr.write("autopin-model-done");sys.stderr.flush()\nsys.stdin.buffer.read()\n')
            binary.chmod(0o755)
            with patch.dict(os.environ,{'PATH':str(base)+os.pathsep+os.environ['PATH']}):
                rc,out,_=g.model_request(['--noproxy','','--proxy','socks5h://127.0.0.1:40000'],'f.req=test','https://example.invalid',tmp)
            self.assertEqual((rc,out),(0,'model-result'))

    def test_two_tunnel_mode_rotates_after_confirmed_low_speed(self):
        m.POLICY={'tunnel_pool':2,'region_pool':['NL','DE'],'min_speed_kib':800,'slow_threshold':2,'deny_regions':[]}
        with patch.object(m,'socks_ip',return_value='192.0.2.1'),patch.object(m,'google_region',return_value='NL'),patch.object(m,'gemini_verdict',return_value='SERVING'),patch.object(m,'speed_probe',return_value=100),patch.object(m,'save_region') as save,patch.object(m,'docker_restart') as restart,patch.object(m.time,'sleep',side_effect=[None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.pool_monitor('NL',60,75,12,True,1)
        save.assert_called_once_with('DE');restart.assert_called_once_with(75)

    def test_partial_curl_timeout_can_still_supply_a_speed_sample(self):
        result=subprocess.CompletedProcess([],28,stdout='1048576 1 3 200',stderr='timeout')
        with patch.object(m.subprocess,'run',return_value=result):
            self.assertEqual(m.speed_probe(1),512)

    def test_recovery_does_not_promote_a_staged_pin_before_restart(self):
        m.atomic_json(m.STATE,{'pin_prepared':True,'adopted_unpinned':True,'prepared_container_started_at':'current'})
        with patch.object(m,'connected_id',return_value='abcdefgh'),patch.object(m,'started_at',return_value='current'):
            self.assertTrue(m.adopt_current('NL',True,0,False,observed=('192.0.2.1','NL','SERVING',None,'')))
        self.assertTrue(m.read_json(m.STATE)['pin_prepared'])
        self.assertTrue(m.read_json(m.STATE)['adopted_unpinned'])

    def test_probe_source_matches_embedded_copy(self):
        from test_autopin import heredoc
        self.assertEqual(heredoc('PY_GEMINI'),(ROOT/'gemini_probe.py').read_text())

if __name__=='__main__':unittest.main()
