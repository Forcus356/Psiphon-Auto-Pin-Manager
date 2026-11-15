"""Policy and lifecycle checks with deterministic GeoIP, not claims about advertisements."""
import copy
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch,MagicMock
from test_autopin import m,ROOT,heredoc
from test_menu import u,Terminal
import test_installation as installation

class YouTubePolicyTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        for key,value in {'BASE':self.base/'app','DATA':self.base/'data','CONFIG':self.base/'config/psiphon.config','STATE':self.base/'data/state.json','CACHE':self.base/'data/cache.json','INSTANCE':1,'PROXY':'127.0.0.1:40002','POLICY':{'youtube_mode':True,'gemini_check':False,'deny_regions':['RU','BY'],'region_pool':['NL','DE'],'strict_region':True,'min_speed_kib':0}}.items():
            p=patch.object(m,key,value);p.start();self.addCleanup(p.stop)
        m.atomic_json(m.CONFIG,{'EgressRegion':'NL','TargetServerEntry':''})
        m.atomic_json(m.DATA/'settings.json',{'region':'NL','gemini_check':False,'youtube_mode':True,'port':40002,'backend':'vps-psiphon'})
        p=patch.object(m,'started_at',return_value='session-1');p.start();self.addCleanup(p.stop)
    def test_default_off_retains_normal_gemini_and_deny_policies(self):
        m.POLICY.pop('youtube_mode')
        with patch.object(m,'probe',return_value=('192.0.2.1','RU')),patch.object(m,'gemini_verdict',return_value='SERVING'):
            self.assertEqual(m.evaluate_exit('NL',True,0)[-1],'Google=RU')
        self.assertFalse((m.DATA/'youtube-status.json').exists())
    def test_youtube_requires_ru_independent_of_deny_and_requested_country(self):
        before=copy.deepcopy(m.POLICY)
        with patch.object(m,'probe',return_value=('192.0.2.1','RU')),patch.object(m,'gemini_verdict',return_value='DISABLED'):
            self.assertEqual(m.evaluate_exit('NL',False,0,True)[-1],'')
        self.assertEqual(m.POLICY,before)
        status=m.youtube_status();self.assertEqual(status['status'],'RU VERIFIED');self.assertFalse(status['pin_verified'])
    def test_failed_video_speed_sample_is_reported_degraded(self):
        m.POLICY['min_speed_kib']=1500
        with patch.object(m,'probe',return_value=('192.0.2.1','RU')),patch.object(m,'gemini_verdict',return_value='DISABLED'),patch.object(m,'speed_probe',side_effect=RuntimeError('sample unavailable')):
            m.evaluate_exit('NL',False,4)
        self.assertEqual(m.youtube_status()['status'],'DEGRADED')
        self.assertIsNone(m.youtube_status()['speed_kib_s'])
    def test_every_other_or_unknown_country_is_rejected(self):
        for geo in ['NL','DE','US','SG','UNKNOWN','',None]:
            with self.subTest(geo=geo),patch.object(m,'probe',return_value=('192.0.2.1',geo)),patch.object(m,'gemini_verdict',return_value='DISABLED'):
                self.assertTrue(m.evaluate_exit('NL',False,0)[-1])
                self.assertNotIn(m.youtube_status()['status'],('RU VERIFIED','PIN VERIFIED'))
    def test_geo_probe_is_bound_to_the_selected_socks5h(self):
        with patch.object(m,'run',return_value='{"GL":"RU"}') as command:
            self.assertEqual(m.google_region(),'RU')
        args=command.call_args.args[0];self.assertIn('socks5h://127.0.0.1:40002',args);self.assertIn('--noproxy',args)
        self.assertEqual(args[args.index('--noproxy')+1],'')
    def test_unknown_geo_retries_and_never_uses_legacy_fallback_in_youtube(self):
        m.POLICY['legacy_geo_fallback']=True
        with patch.object(m,'socks_ip',return_value='192.0.2.1'),patch.object(m,'run',return_value='consent page') as run,patch.object(m.time,'sleep') as sleep:
            with self.assertRaises(m.GoogleGeoUnknown):m.probe()
        self.assertEqual(run.call_count,3);self.assertEqual([c.args for c in sleep.call_args_list],[(10,),(10,)])
        self.assertEqual(m.youtube_status()['status'],'UNKNOWN')
    def test_unknown_geo_does_not_trigger_restart_even_after_many_retries(self):
        with patch.object(m,'wait_ready'),patch.object(m,'evaluate_exit',side_effect=m.GoogleGeoUnknown('UNKNOWN')),patch.object(m,'docker_restart') as restart,patch.object(m,'search') as search,patch.object(m.time,'sleep',side_effect=[None,None,None,KeyboardInterrupt]) as sleep:
            with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,75,12)
        restart.assert_not_called();search.assert_not_called();self.assertEqual(sleep.call_args.args,(30,))
    def test_changed_country_is_confirmed_before_ru_search(self):
        m.atomic_json(m.STATE,{'ip':'192.0.2.1','diagnostic_id':'abcdefgh','google_region':'RU','adopted_unpinned':False})
        with patch.object(m,'wait_ready'),patch.object(m,'probe',return_value=('192.0.2.1','NL')),patch.object(m,'gemini_verdict',return_value='DISABLED'),patch.object(m,'connected_id',return_value='abcdefgh'),patch.object(m,'search') as search,patch.object(m.time,'sleep',side_effect=[None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,75,12)
        search.assert_called_once_with('NL',75,12,False,0,False)
    def test_ru_search_verifies_second_geo_and_candidate_id(self):
        m.POLICY['region_pool']=[]
        rows=[{'diagnostic':'aaaaaaaa','server_ip':'192.0.2.10','encoded':'entry-a'}, {'diagnostic':'bbbbbbbb','server_ip':'192.0.2.20','encoded':'entry-b'}]
        with patch.object(m,'verify_pin_current',return_value=False),patch.object(m,'adopt_current',return_value=False),patch.object(m,'clear_target'),patch.object(m,'collect_candidates',return_value=rows),patch.object(m,'prioritized_candidates',side_effect=lambda rows,region:rows),patch.object(m,'docker_restart',side_effect=['192.0.2.1','192.0.2.1','192.0.2.2']),patch.object(m,'connected_id',side_effect=['aaaaaaaa','bbbbbbbb','bbbbbbbb']),patch.object(m,'probe',side_effect=[('192.0.2.1','NL'),('192.0.2.2','RU'),('192.0.2.2','RU')]),patch.object(m,'gemini_verdict',return_value='DISABLED'),patch.object(m.time,'sleep') as sleep:
            self.assertTrue(m.search('NL',75,12))
        state=m.read_json(m.STATE);self.assertEqual(state['google_region'],'RU');self.assertFalse(state['adopted_unpinned'])
        self.assertEqual(m.read_json(m.CONFIG)['TargetServerEntry'],'entry-b');self.assertEqual(m.youtube_status()['status'],'PIN VERIFIED')
        self.assertEqual(sum(c.args==(12,) for c in sleep.call_args_list),2)
    def test_staged_pin_cannot_be_promoted_after_google_changed(self):
        state={'pin_prepared':True,'prepared_container_started_at':'old','ip':'192.0.2.1','diagnostic_id':'abcdefgh'}
        self.assertFalse(m.pin_prepared_verification('NL','192.0.2.1','NL','abcdefgh','',state))
    def test_adoption_cannot_bypass_required_geo_policy(self):
        self.assertFalse(m.adopt_current('NL',False,0,False,observed=('192.0.2.1','NL','DISABLED',None,'')))
        self.assertFalse(m.STATE.exists())
    def test_old_ru_status_becomes_unknown_after_docker_or_os_restart(self):
        m.youtube_report('PIN VERIFIED','192.0.2.1','RU','abcdefgh',1000,True)
        self.assertEqual(m.youtube_status()['status'],'PIN VERIFIED')
        with patch.object(m,'started_at',return_value='new-container'):
            self.assertEqual(m.youtube_status()['status'],'UNKNOWN')
        with patch.object(m,'boot_id',return_value='new-boot'):
            self.assertEqual(m.youtube_status()['status'],'UNKNOWN')
        last=m.youtube_status()['last_success_at'];m.youtube_report('DEGRADED',detail='outage')
        self.assertEqual(m.youtube_status()['last_success_at'],last)
    def test_fresh_failure_status_is_not_lost_when_docker_is_unavailable(self):
        m.youtube_report('DEGRADED',detail='connection unavailable')
        with patch.object(m,'started_at',side_effect=RuntimeError('Docker unavailable')):
            self.assertEqual(m.youtube_status()['status'],'DEGRADED')
            m.youtube_report('PIN VERIFIED',geo='RU',pin=True)
            self.assertEqual(m.youtube_status()['status'],'UNKNOWN')
    def test_stale_observation_is_not_a_current_verification(self):
        m.youtube_report('RU VERIFIED',geo='RU');p=m.DATA/'youtube-status.json';obj=m.read_json(p)
        obj['checked_at']='2000-01-01T00:00:00+00:00';m.atomic_json(p,obj)
        self.assertEqual(m.youtube_status()['status'],'UNKNOWN')
        self.assertEqual(m.youtube_status({'youtube_mode':False})['status'],'DISABLED')
    def test_same_instance_gemini_conflict_fails_before_changing_services(self):
        with patch.object(sys,'argv',['autopin','check','--gemini-check']),patch.object(m,'run') as run:
            with self.assertRaises(SystemExit):m.main()
        run.assert_not_called()
    def test_corrupt_multi_tunnel_youtube_config_is_rejected(self):
        with self.assertRaises(ValueError):m.pool_monitor('NL',300,75,12)
    def test_routing_export_separates_services_without_broad_google_rules(self):
        gm=self.base/'psiphon-autopin-2/settings.json';yt=self.base/'psiphon-autopin/settings.json'
        m.atomic_json(yt,{'youtube_mode':True,'gemini_check':False,'port':41000,'bind':'127.0.0.1'})
        m.atomic_json(gm,{'youtube_mode':False,'gemini_check':True,'port':42000,'bind':'127.0.0.1'})
        with patch.object(m,'DATA',self.base/'psiphon-autopin'):
            data=m.xray_routing(1,2)
            with self.assertRaises(ValueError):m.xray_routing(1,1)
            cfg=m.read_json(gm);cfg['port']=41001;m.atomic_json(gm,cfg)
            with self.assertRaises(ValueError):m.xray_routing(1,2)
        self.assertEqual([o['settings']['servers'][0]['port'] for o in data['outbounds'][:2]],[41000,42000])
        domains=[d for rule in data['routing']['rules'] for d in rule['domain']]
        self.assertIn('domain:googlevideo.com',domains);self.assertIn('full:youtubei.googleapis.com',domains)
        self.assertNotIn('domain:google.com',domains);self.assertNotIn('domain:googleapis.com',domains)
        self.assertEqual(data['routing']['rules'][0]['network'],'udp')

class YouTubeMenuTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.base=Path(tmp.name)
        p=patch.object(u,'ROOT',self.base);p.start();self.addCleanup(p.stop)
        p=patch.object(u,'runtime_status',return_value={key:{'state':'unknown','autostart':'unknown'} for key in ('tunnel','monitor')});p.start();self.addCleanup(p.stop)
    def test_old_settings_default_to_disabled_and_easy_has_toggle(self):
        u.atomic_json(u.paths(1)['data']/'settings.json',{'region':'NL','port':40000})
        self.assertFalse(u.load_config(1)['youtube_mode']);self.assertIn('youtube_mode',u.EASY_KEYS)
    def test_easy_creates_independent_youtube_config_and_emits_it(self):
        saved=u.defaults();u.atomic_json(u.paths(1)['data']/'settings.json',saved)
        before=(u.paths(1)['data']/'settings.json').read_bytes();out=self.base/'args.json'
        terminal=Terminal(['1','6','да','1','y','да'])
        with patch.object(u.socket,'socket') as factory:
            factory.return_value=MagicMock()
            menu=u.Menu(terminal,emit_args=out);menu.run()
        args=json.loads(out.read_text());self.assertEqual(args[args.index('--instance')+1],'2')
        self.assertIn('--youtube-mode',args);self.assertIn('--no-gemini-check',args)
        self.assertEqual(args[args.index('--min-speed')+1],'1500');self.assertEqual(args[args.index('--region')+1],'AUTO');self.assertEqual(args[args.index('--port')+1],'40002')
        self.assertEqual((u.paths(1)['data']/'settings.json').read_bytes(),before)
    def test_easy_video_speed_can_be_changed_without_advanced(self):
        c=u.defaults();c.update(youtube_mode=True,gemini_check=False,min_speed_kib=1500)
        u.atomic_json(u.paths(1)['data']/'settings.json',c);out=self.base/'args.json'
        menu=u.Menu(Terminal(['1','7','2000','y','да']),emit_args=out);menu.run()
        args=json.loads(out.read_text());self.assertEqual(args[args.index('--min-speed')+1],'2000')
    def test_disable_youtube_does_not_change_other_policies(self):
        c=u.defaults();c.update(youtube_mode=True,gemini_check=False);u.atomic_json(u.paths(1)['data']/'settings.json',c)
        menu=u.Menu(Terminal(['1','6','нет','0','0']));menu.run()
        self.assertFalse(menu.config['youtube_mode']);self.assertFalse(menu.config['gemini_check']);self.assertEqual(menu.config['deny_regions'],c['deny_regions'])
    def test_conflicting_modes_or_pool_cannot_be_applied(self):
        for changes in ({'youtube_mode':True},{'youtube_mode':True,'gemini_check':False,'tunnel_pool':3}):
            c=u.defaults();c.update(changes)
            with self.assertRaises(ValueError):u.build_args(c)

class YouTubeInstallerTests(unittest.TestCase):
    install=installation.InstallationTests.install
    # Inherit installer regression tests along with new mode integration cases.
    def test_youtube_flags_are_saved_and_reapply_retains_them(self):
        base,p=self.install(extra_args=('--youtube-mode','--no-gemini-check'))
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        path=base/'var/lib/psiphon-autopin/settings.json';cfg=json.loads(path.read_text())
        self.assertTrue(cfg['youtube_mode']);self.assertFalse(cfg['gemini_check']);self.assertIn('RU',cfg['deny_regions'])
        env={**__import__('os').environ,'PATH':str(base/'bin')+__import__('os').pathsep+__import__('os').environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)}
        p=subprocess.run(['bash',str(base/'install.sh'),'--instance','1'],env=env,capture_output=True,text=True,timeout=20)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr);self.assertTrue(json.loads(path.read_text())['youtube_mode'])
    def test_youtube_and_gemini_conflict_does_not_stop_existing_service(self):
        base,p=self.install(extra_args=('--youtube-mode',))
        self.assertNotEqual(p.returncode,0);self.assertIn('separate instances',p.stderr)
        commands=(base/'commands').read_text() if (base/'commands').exists() else ''
        self.assertNotIn('"stop"',commands)
    def test_youtube_refuses_pool_and_private_lan_binding(self):
        for extra in (('--tunnel-pool','3'),('--bind','172.17.0.1')):
            base,p=self.install(extra_args=('--youtube-mode','--no-gemini-check',*extra))
            self.assertNotEqual(p.returncode,0)

import test_initial_pin_and_cleanup as initial
class YouTubeInitialPinTests(unittest.TestCase):
    def setUp(self):
        initial.InitialPinTests.setUp(self)
        m.POLICY.update(youtube_mode=True,gemini_check=False,deny_regions=['RU'])
        state=m.read_json(m.STATE);state['google_region']='RU';m.atomic_json(m.STATE,state)
    def test_ru_first_pin_exports_stopped_boltdb_and_verifies_ru_again(self):
        with patch.object(m,'evaluate_exit',return_value=('192.0.2.1','RU','DISABLED',1000,'')),patch.object(m,'probe',return_value=('192.0.2.1','RU')),patch.object(m,'started_at',side_effect=lambda:'new' if self.actions else 'old'):
            self.assertTrue(m.auto_pin_current('NL'))
            self.assertEqual(m.youtube_status()['status'],'PIN VERIFIED')
        self.assertEqual(self.actions,['stop','start']);self.assertFalse(m.read_json(m.STATE)['adopted_unpinned'])
    def test_geo_change_during_pin_recheck_rolls_back_target(self):
        with patch.object(m,'evaluate_exit',return_value=('192.0.2.1','RU','DISABLED',1000,'')),patch.object(m,'probe',return_value=('192.0.2.1','NL')),patch.object(m,'started_at',side_effect=lambda:'new' if self.actions else 'old'),patch.object(m,'docker_restart') as restore:
            self.assertFalse(m.auto_pin_current('NL'));restore.assert_called_once_with(20)
        self.assertFalse(m.read_json(m.CONFIG)['TargetServerEntry']);self.assertTrue(m.read_json(m.STATE)['adopted_unpinned'])
        self.assertNotEqual(m.youtube_status()['status'],'PIN VERIFIED')

class YouTubeVideoDefaultsTests(unittest.TestCase):
    install=installation.InstallationTests.install
    def test_new_youtube_video_floor_and_explicit_zero_override(self):
        for extra,expected in [((),1500),(('--min-speed','0'),0)]:
            base,p=self.install(fresh=True,extra_args=('--youtube-mode','--no-gemini-check',*extra))
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            c=json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())
            self.assertEqual(c['min_speed_kib'],expected);self.assertEqual(c['probe_mb'],4)
    def test_existing_saved_speed_is_not_replaced_when_enabling_youtube(self):
        base,p=self.install(fresh=True,extra_args=('--no-gemini-check','--min-speed','800'))
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        import os
        env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)}
        p=subprocess.run(['bash',str(base/'install.sh'),'--instance','1','--youtube-mode'],env=env,capture_output=True,text=True,timeout=20)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['min_speed_kib'],800)
