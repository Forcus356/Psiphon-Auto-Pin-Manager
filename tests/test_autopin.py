"""Offline regressions: no Docker daemon, root, systemd or external traffic required."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
INSTALLER=(ROOT/'install_psiphon_autopin.sh').read_text()
spec=importlib.util.spec_from_file_location('autopin',ROOT/'psiphon_autopin.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def heredoc(name):
    return INSTALLER.split("<<'"+name+"'\n",1)[1].split('\n'+name+'\n',1)[0]+'\n'


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base=Path(self.tmp.name)
        for name,value in {'DATA':base,'STATE':base/'state.json',
                           'CACHE':base/'cache.json','CONFIG':base/'psiphon.config',
                           'ENV_FILE':base/'env','BASE':base,'POLICY':{},'INSTANCE':1}.items():
            p=patch.object(m,name,value);p.start();self.addCleanup(p.stop)
        started=patch.object(m,'started_at',return_value='test-container-start');started.start();self.addCleanup(started.stop)
        m.atomic_json(m.DATA/'settings.json',{'backend':'vps-psiphon','region':'PL','port':40000,'gemini_check':True})
        m.atomic_json(m.CONFIG,{'EgressRegion':'PL','TargetServerEntry':'old-secret'})
        m.atomic_json(m.STATE,{'ip':'192.0.2.1'})
        m.atomic_json(m.CACHE,{'region':'PL'})
        m.ENV_FILE.write_text("# keep\nBIND=127.0.0.1\nEGRESS_REGION=PL\nREGION_POOL='PL NL'\n")
        m.ENV_FILE.chmod(0o600)

    def test_systemd_owns_tunnel(self):
        with patch.object(m,'run',return_value='') as run:
            for action in ('stop','start','restart'):m.tunnel_action(action)
        self.assertEqual([c.args[0] for c in run.call_args_list],
                         [['systemctl',a,'vps-psiphon.service'] for a in ('stop','start','restart')])

    def test_old_settings_keep_console_backend(self):
        m.atomic_json(m.DATA/'settings.json',{'region':'PL','port':40000})
        with patch.object(m,'run',return_value='') as run:m.tunnel_action('restart')
        self.assertEqual(run.call_args.args[0],['docker','restart','vps-psiphon'])

    def test_region_change_syncs_all_files_and_backs_up(self):
        with patch.object(m,'docker_restart') as restart:m.set_region('NL',75)
        self.assertEqual(m.read_json(m.CONFIG)['EgressRegion'],'NL')
        self.assertFalse(m.read_json(m.CONFIG)['TargetServerEntry'])
        settings=m.read_json(m.DATA/'settings.json')
        self.assertEqual((settings['region'],settings['port'],settings['gemini_check']),('NL',40000,True))
        self.assertIn('EGRESS_REGION=NL\n',m.ENV_FILE.read_text())
        self.assertIn("REGION_POOL=''\n",m.ENV_FILE.read_text())
        self.assertIn('BIND=127.0.0.1',m.ENV_FILE.read_text())
        self.assertFalse(m.STATE.exists());self.assertFalse(m.CACHE.exists())
        backup=list(m.DATA.glob('region-backup-*'))[0]
        self.assertEqual(m.read_json(backup/'psiphon.config')['TargetServerEntry'],'old-secret')
        self.assertEqual(m.ENV_FILE.stat().st_mode & 0o777,0o600)
        restart.assert_called_once_with(75)

    def test_same_region_repairs_outdated_env(self):
        m.ENV_FILE.write_text('BIND=127.0.0.1\nEGRESS_REGION=SG\n')
        with patch.object(m,'docker_restart') as restart:m.set_region('PL',75)
        self.assertIn('EGRESS_REGION=PL',m.ENV_FILE.read_text())
        restart.assert_called_once_with(75)

    def test_auto_removes_region_restriction(self):
        with patch.object(m,'docker_restart'):m.set_region('',75)
        self.assertEqual(m.read_json(m.CONFIG)['EgressRegion'],'')
        self.assertIn('EGRESS_REGION=\n',m.ENV_FILE.read_text())

    def test_same_region_does_not_restart(self):
        with patch.object(m,'docker_restart') as restart:m.set_region('PL',75)
        restart.assert_not_called()

    def test_region_settings_persist_when_tunnel_is_slow(self):
        with patch.object(m,'docker_restart',side_effect=RuntimeError('not ready')):
            with self.assertRaises(RuntimeError):m.set_region('NL',75)
        self.assertEqual(m.read_json(m.DATA/'settings.json')['region'],'NL')
        self.assertIn('EGRESS_REGION=NL',m.ENV_FILE.read_text())

    def test_invalid_config_leaves_files_untouched(self):
        m.CONFIG.write_text('invalid')
        with self.assertRaises(RuntimeError):m.set_region('NL',75)
        self.assertEqual(m.read_json(m.DATA/'settings.json')['region'],'PL')
        self.assertIn('EGRESS_REGION=PL',m.ENV_FILE.read_text())

    def test_exporter_failure_still_starts_service(self):
        with patch.object(m,'tunnel_action') as action, patch.object(m,'db_path',return_value=m.DATA/'db'), patch.object(m,'run',side_effect=RuntimeError('export failed')):
            with self.assertRaises(RuntimeError):m.collect_candidates('PL')
        self.assertEqual([c.args[0] for c in action.call_args_list],['stop','start'])

    def test_exported_candidate_cache_is_private(self):
        rows=[{'server_ip':'192.0.2.5','diagnostic':'abcdefgh','encoded':'secret'}]
        with patch.object(m,'tunnel_action'), patch.object(m,'db_path',return_value=m.DATA/'db'), patch.object(m,'run',return_value=json.dumps(rows[0])):
            self.assertEqual(m.collect_candidates('PL'),rows)
        self.assertEqual(m.CACHE.stat().st_mode & 0o777,0o600)

    def test_set_region_resumes_running_monitor_after_error(self):
        with patch.object(sys,'argv',['autopin','set-region','--region','NL']), patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0)), patch.object(m,'run',return_value='') as run, patch.object(m,'set_region',side_effect=RuntimeError('not ready')):
            with self.assertRaises(RuntimeError):m.main()
        self.assertEqual([c.args[0] for c in run.call_args_list],
                         [['systemctl','stop','psiphon-autopin.service'],['systemctl','start','psiphon-autopin.service']])

    def test_set_region_does_not_start_inactive_monitor(self):
        with patch.object(sys,'argv',['autopin','set-region','--region','NL']), patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],3)), patch.object(m,'run') as run, patch.object(m,'set_region'):
            self.assertEqual(m.main(),0)
        run.assert_not_called()

    def test_invalid_region_never_stops_monitor(self):
        with patch.object(sys,'argv',['autopin','set-region','--region','NL;false']), patch.object(m.subprocess,'run') as run:
            with self.assertRaises(SystemExit):m.main()
        run.assert_not_called()

    def test_check_honors_strict_region(self):
        with patch.object(sys,'argv',['autopin','check','--strict-region']), patch.object(m,'probe',return_value=('192.0.2.1','NL')), patch.object(m,'gemini_verdict',return_value='INCONCLUSIVE'):
            self.assertEqual(m.main(),2)

    def test_search_applies_country_before_adopting_exit(self):
        calls=[]
        with patch.object(m,'clear_target',side_effect=lambda r:calls.append(('region',r))), patch.object(m,'docker_restart',side_effect=lambda w:calls.append(('restart',w))), patch.object(m,'verify_pin_current',return_value=False), patch.object(m,'adopt_current',side_effect=lambda *a:calls.append(('adopt',a[0])) or True):
            m.search('NL',75,12)
        self.assertEqual(calls,[('region','NL'),('restart',75),('adopt','NL')])

    def test_rotation_preserves_existing_transport_policy(self):
        cfg=m.read_json(m.CONFIG)
        cfg['DisableTactics']=True
        m.atomic_json(m.CONFIG,cfg)
        m.apply_candidate({'encoded':'new-target'},'PL')
        self.assertTrue(m.read_json(m.CONFIG)['DisableTactics'])
        m.clear_target('PL')
        self.assertTrue(m.read_json(m.CONFIG)['DisableTactics'])

    def test_interrupted_search_recovers_matching_healthy_target(self):
        m.atomic_json(m.CACHE,{'region':'PL','entries':[{'diagnostic':'abcdefgh','encoded':'old-secret','server_ip':'192.0.2.5','region':'PL'}]})
        with patch.object(m,'connected_id',return_value='abcdefgh'), patch.object(m,'socks_ip',return_value='192.0.2.1'), patch.object(m,'docker_restart') as restart:
            self.assertTrue(m.adopt_current('PL',False,0,False,observed=('192.0.2.1','PL','SERVING',None,'')))
        state=m.read_json(m.STATE)
        self.assertFalse(state['adopted_unpinned'])
        self.assertEqual(state['server_ip'],'192.0.2.5')
        restart.assert_not_called()

    def test_interrupted_search_does_not_verify_mismatched_target(self):
        m.atomic_json(m.CACHE,{'region':'PL','entries':[{'diagnostic':'abcdefgh','encoded':'different-secret','server_ip':'192.0.2.5','region':'PL'}]})
        with patch.object(m,'connected_id',return_value='abcdefgh'):
            self.assertFalse(m.adopt_current('PL',False,0,False,observed=('192.0.2.1','PL','SERVING',None,'')))
        self.assertEqual(m.read_json(m.STATE),{'ip':'192.0.2.1'})

    def test_interrupted_search_rejects_changing_exit(self):
        m.atomic_json(m.CACHE,{'region':'PL','entries':[{'diagnostic':'abcdefgh','encoded':'old-secret','server_ip':'192.0.2.5','region':'PL'}]})
        with patch.object(m,'connected_id',return_value='abcdefgh'), patch.object(m,'socks_ip',return_value='192.0.2.99'):
            with self.assertRaises(RuntimeError):m.adopt_current('PL',False,0,False,observed=('192.0.2.1','PL','SERVING',None,''))
        self.assertEqual(m.read_json(m.STATE),{'ip':'192.0.2.1'})

    def test_monitor_waits_for_startup_without_restart(self):
        m.atomic_json(m.STATE,{'ip':'192.0.2.1','diagnostic_id':'abcdefgh','region':'PL'})
        with patch.object(m,'wait_ready') as ready, patch.object(m,'evaluate_exit',return_value=('192.0.2.1','PL','SERVING',None,'')), patch.object(m,'connected_id',return_value='abcdefgh'), patch.object(m,'tunnel_action') as action, patch.object(m.time,'sleep',side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):m.monitor('PL',3600,75,12)
        ready.assert_called_once_with(75)
        action.assert_not_called()

    def test_monitor_retries_outage_after_30_seconds_not_one_hour(self):
        with patch.object(m,'wait_ready'), patch.object(m,'evaluate_exit',side_effect=RuntimeError('outage')), patch.object(m,'docker_restart') as restart, patch.object(m.time,'sleep',side_effect=KeyboardInterrupt) as sleep:
            with self.assertRaises(KeyboardInterrupt):m.monitor('PL',3600,75,12)
        sleep.assert_called_once_with(30)
        restart.assert_not_called()

    def test_outage_recovery_occurs_after_three_consecutive_failures(self):
        with patch.object(m,'wait_ready'), patch.object(m,'evaluate_exit',side_effect=[RuntimeError('down'),RuntimeError('down'),RuntimeError('down'),('192.0.2.1','PL','SERVING',None,'')]), patch.object(m,'docker_restart') as restart, patch.object(m.time,'sleep',side_effect=[None,None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.monitor('PL',3600,75,12)
        restart.assert_called_once_with(75)

    def test_dead_target_triggers_discovery_after_failed_restart(self):
        with patch.object(m,'wait_ready'), patch.object(m,'evaluate_exit',side_effect=RuntimeError('down')), patch.object(m,'docker_restart',side_effect=RuntimeError('dead target')), patch.object(m,'search') as search, patch.object(m.time,'sleep',side_effect=[None,None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.monitor('PL',3600,75,12)
        search.assert_called_once_with('PL',75,12,False,0,False)

    def test_unknown_classifier_after_restart_does_not_rotate(self):
        with patch.object(m,'wait_ready'), patch.object(m,'evaluate_exit',side_effect=RuntimeError('Google UNKNOWN')), patch.object(m,'docker_restart'), patch.object(m,'search') as search, patch.object(m.time,'sleep',side_effect=[None,None,KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):m.monitor('PL',3600,75,12)
        search.assert_not_called()

    def test_ready_wait_does_not_restart_existing_tunnel(self):
        with patch.object(m,'socks_ip',side_effect=[RuntimeError('starting'),'192.0.2.1']), patch.object(m.time,'sleep') as sleep, patch.object(m,'tunnel_action') as action:
            self.assertEqual(m.wait_ready(75),'192.0.2.1')
        sleep.assert_called_once_with(2)
        action.assert_not_called()


class InstallerTests(unittest.TestCase):
    def test_embedded_manager_matches_source(self):
        self.assertEqual(heredoc('PY_MANAGER'),(ROOT/'psiphon_autopin.py').read_text())

    def test_bash_and_embedded_python_syntax(self):
        subprocess.run(['bash','-n',str(ROOT/'install_psiphon_autopin.sh')],check=True)
        for marker in ('VALIDATE_VPS','VPS_ENV','VPS_CONFIG','VPS_REGION','HOST_PORT','SETTINGS'):
            compile(heredoc(marker),marker,'exec')
        subprocess.run(['bash','-n'],input=heredoc('VPS_RUN'),text=True,check=True)

    def test_generated_launcher_keeps_host_port_and_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);conf=base/'psiphon.config';env=base/'env';args=base/'args'
            conf.write_text(json.dumps({'EgressRegion':'PL','TargetServerEntry':'secret','ListenInterface':'lo','DisableTactics':False}))
            env.write_text(f'BIND=127.0.0.1\nNAME=vps-psiphon\nCONF_DIR={base}\nEGRESS_REGION=NL\nSOCKS_PORT=40000\nHTTP_PORT=40001\nIMAGE=test-image\n')
            docker=base/'docker'
            docker.write_text('#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\nif sys.argv[1]=="run":Path('+repr(str(args))+').write_text(json.dumps(sys.argv[1:]))\n')
            docker.chmod(0o755)
            chown=base/'chown';chown.write_text('#!/bin/sh\nexit 0\n');chown.chmod(0o755)
            launcher=heredoc('VPS_RUN').replace('/etc/default/@P@',str(env)).replace('@IMAGE@','test-image')
            subprocess.run(['bash'],input=launcher,text=True,check=True,env={**os.environ,'PATH':str(base)+os.pathsep+os.environ['PATH']})
            config=json.loads(conf.read_text())
            self.assertEqual((config['LocalSocksProxyPort'],config['LocalHttpProxyPort'],config['ListenInterface']),(1080,8080,'any'))
            self.assertTrue(config['DisableTactics'])
            self.assertFalse(any('INPROXY' in p for p in config['LimitTunnelProtocols']))
            self.assertEqual(config['TargetServerEntry'],'secret')
            self.assertEqual(config['EgressRegion'],'NL')
            published=json.loads(args.read_text())
            self.assertIn('127.0.0.1:40000:1080',published)
            self.assertIn('127.0.0.1:40001:8080',published)
            self.assertIn('SOCKS_PORT=1080',published)

    def test_no_public_mapping_accepted_with_docker_nat_only(self):
        helpers=INSTALLER.split('vps_mapping_ok() {',1)[1].split('verify_proxy_binding() {',1)[0]
        helpers='vps_mapping_ok() {'+helpers
        for bind,rc in [('127.0.0.1',0),('0.0.0.0',1),('::',1)]:
            mappings={'1080/tcp':[{'HostIp':bind,'HostPort':'40000'}],
                      '8080/tcp':[{'HostIp':bind,'HostPort':'40001'}]}
            script='set -o pipefail\nBACKEND=vps-psiphon;CONTAINER=vps-psiphon;SOCKS_PORT=40000;HTTP_PORT=40001\n'
            script+='docker() { printf \'%s\\n\' \''+json.dumps(mappings)+"'; }\n"
            result=subprocess.run(['bash'],input=script+helpers+'\nproxy_listeners_ready\n',text=True)
            self.assertEqual(result.returncode,rc)

    def test_migration_detects_actual_published_port(self):
        code=heredoc('HOST_PORT')
        bindings={'1080/tcp':[{'HostIp':'127.0.0.1','HostPort':'40000'}]}
        result=subprocess.run([sys.executable,'-',json.dumps(bindings),'1080'],input=code,text=True,capture_output=True,check=True)
        self.assertEqual(result.stdout.strip(),'40000')


if __name__=='__main__':unittest.main()
