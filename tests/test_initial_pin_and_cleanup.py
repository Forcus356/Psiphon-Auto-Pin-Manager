"""First-pin regression and dependency receipts. Never invokes host package removal."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_autopin import m,ROOT,heredoc
import test_installation

spec=importlib.util.spec_from_file_location('autopin_system_test',ROOT/'autopin_system.py')
system=importlib.util.module_from_spec(spec);spec.loader.exec_module(system)

class InitialPinTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);base=Path(tmp.name)
        for key,value in {'BASE':base/'app','DATA':base/'data','STATE':base/'data/state.json','CONFIG':base/'config/psiphon.config','CACHE':base/'data/cache.json','POLICY':{'tunnel_pool':1,'interval':300,'wait':20},'INSTANCE':1}.items():
            p=patch.object(m,key,value);p.start();self.addCleanup(p.stop)
        m.BASE.mkdir();m.atomic_json(m.CONFIG,{'EgressRegion':'NL','TargetServerEntry':'','keep':'transport'})
        m.atomic_json(m.STATE,{'region':'NL','ip':'192.0.2.1','diagnostic_id':'abcdefgh','adopted_unpinned':True,'speed_kib_s':1000})
        self.row={'server_ip':'192.0.2.50','diagnostic':'abcdefgh','encoded':'PRIVATE_ENTRY','region':'NL'}
        self.running=True;self.actions=[]
        def lifecycle(action):self.actions.append(action);self.running=action!='stop'
        def exporter(args,**kwargs):
            self.assertFalse(self.running,'Exporter opened a live datastore')
            return json.dumps(self.row)
        patches=[patch.object(m,'tunnel_action',side_effect=lifecycle),patch.object(m,'run',side_effect=exporter),
            patch.object(m,'db_path',return_value=base/'db'),patch.object(m,'connected_id',return_value='abcdefgh'),
            patch.object(m,'socks_ip',return_value='192.0.2.1'),patch.object(m,'started_at',side_effect=['old','new']),
            patch.object(m,'wait_ready',return_value='192.0.2.1'),patch.object(m,'evaluate_exit',return_value=('192.0.2.1','NL','INCONCLUSIVE',1000,'')),patch.object(m.time,'sleep')]
        for p in patches:p.start();self.addCleanup(p.stop)
    def test_first_adoption_without_cache_produces_verified_pin(self):
        self.assertFalse(m.CACHE.exists())
        self.assertTrue(m.adopt_current('NL',True,1,False,observed=('192.0.2.1','NL','INCONCLUSIVE',1000,'')))
        state=m.read_json(m.STATE)
        self.assertFalse(state['adopted_unpinned']);self.assertFalse(state['pin_prepared'])
        self.assertEqual(state['server_ip'],'192.0.2.50');self.assertEqual(state['gemini'],'INCONCLUSIVE')
        self.assertEqual(m.read_json(m.CONFIG)['TargetServerEntry'],'PRIVATE_ENTRY')
        self.assertEqual(self.actions,['stop','start']);self.assertEqual(m.CACHE.stat().st_mode&0o777,0o600)
    def test_old_unpinned_install_can_pin_on_next_monitor_check(self):
        with patch.object(m,'auto_pin_current',return_value=True) as pin,patch.object(m.time,'sleep',side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,20,2)
        pin.assert_called_once_with('NL',False,0,False,20)
    def test_export_failure_starts_tunnel_and_defers_retry(self):
        with patch.object(m,'run',side_effect=RuntimeError('export unavailable')):
            self.assertFalse(m.auto_pin_current('NL'))
            self.assertFalse(m.auto_pin_current('NL'))
        self.assertEqual(self.actions,['stop','start']);self.assertTrue(self.running)
        self.assertFalse(m.read_json(m.CONFIG)['TargetServerEntry']);self.assertTrue(m.read_json(m.STATE)['adopted_unpinned'])
    def test_id_mismatch_rolls_back_without_claiming_pin(self):
        with patch.object(m,'connected_id',side_effect=['abcdefgh','different']),patch.object(m,'docker_restart') as restore:
            self.assertFalse(m.auto_pin_current('NL'))
        restore.assert_called_once_with(20)
        self.assertFalse(m.read_json(m.CONFIG)['TargetServerEntry']);self.assertTrue(m.read_json(m.STATE)['adopted_unpinned'])
    def test_policy_refusal_rolls_back(self):
        with patch.object(m,'evaluate_exit',return_value=('192.0.2.1','RU','REFUSED',1000,'Google=RU')),patch.object(m,'docker_restart'):
            self.assertFalse(m.auto_pin_current('NL'))
        self.assertTrue(m.read_json(m.STATE)['adopted_unpinned'])
    def test_nonunique_candidate_is_not_pinned(self):
        with patch.object(m,'candidate_for_connected_server',return_value=None):self.assertFalse(m.auto_pin_current('NL'))
        self.assertEqual(self.actions,['stop','start']);self.assertFalse(m.read_json(m.CONFIG)['TargetServerEntry'])
    def test_verified_target_and_multitunnel_do_not_reconnect(self):
        m.POLICY['tunnel_pool']=3;self.assertFalse(m.auto_pin_current('NL'))
        m.POLICY['tunnel_pool']=1;m.change_config({'TargetServerEntry':'already-pinned'})
        self.assertFalse(m.auto_pin_current('NL'));self.assertEqual(self.actions,[])
    def test_manual_prepare_adoption_remains_non_disruptive(self):
        self.assertTrue(m.adopt_current('NL',False,0,False,observed=('192.0.2.1','NL','DISABLED',1000,''),auto_pin=False))
        self.assertEqual(self.actions,[]);self.assertFalse(m.read_json(m.CONFIG)['TargetServerEntry'])
    def test_rollback_outage_is_reported_to_controller(self):
        with patch.object(m,'evaluate_exit',side_effect=RuntimeError('probe down')),patch.object(m,'docker_restart',side_effect=RuntimeError('restore down')):
            with self.assertRaisesRegex(RuntimeError,'rollback'):m.auto_pin_current('NL')
        self.assertTrue(m.read_json(m.STATE)['adopted_unpinned'])

class DependencyTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        p=patch.object(system,'ROOT',Path(tmp.name));p.start();self.addCleanup(p.stop)
    def receipt(self,component,packages):system.save_ledger({'version':1,'components':{component:{'owned':True,'preexisting':False,'packages':packages}}})
    def test_embedded_receipt_helper_matches_source(self):self.assertEqual(heredoc('PY_SYSTEM'),(ROOT/'autopin_system.py').read_text())
    def test_install_records_only_new_go_packages(self):
        before={'curl','gcc'};after=before|{'golang-go','golang-src','golang-1.26-go','golang-1.26-src','g++'}
        with patch.object(system,'inventory',side_effect=[before,after]),patch.object(system.shutil,'which',return_value=None),patch.object(system.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            self.assertEqual(system.install('go',['golang-go']),0)
        receipt=system.load_ledger()['components']['go'];self.assertTrue(receipt['owned']);self.assertNotIn('g++',receipt['packages'])
        self.assertEqual(system.ledger_path().stat().st_mode&0o777,0o600)
    def test_preexisting_go_is_not_claimed(self):
        with patch.object(system,'inventory',return_value={'golang-go'}),patch.object(system.shutil,'which',return_value='/usr/bin/go'),patch.object(system.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            system.install('go',['golang-go'])
        self.assertFalse(system.load_ledger()['components']['go']['owned'])
    def test_existing_runtime_is_kept_while_new_docker_is_owned(self):
        with patch.object(system,'inventory',side_effect=[{'runc'},{'runc','docker.io','containerd'}]),patch.object(system.shutil,'which',return_value=None),patch.object(system.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            system.install('docker',['docker.io'])
        self.assertEqual(system.load_ledger()['components']['docker']['packages'],['containerd','docker.io'])
    def test_reinstall_preserves_ownership_receipt(self):
        self.receipt('go',['golang-go'])
        with patch.object(system,'inventory',return_value={'golang-go'}),patch.object(system.shutil,'which',return_value='/usr/bin/go'),patch.object(system.subprocess,'run',return_value=subprocess.CompletedProcess([],0)):
            system.install('go',['golang-go'])
        self.assertTrue(system.load_ledger()['components']['go']['owned'])
    def test_unknown_or_preexisting_dependencies_are_retained(self):
        with patch.object(system,'inventory',return_value={'docker.io','golang-go'}),patch.object(system.subprocess,'run') as apt:
            result=system.cleanup_dependencies(True)
        apt.assert_not_called();self.assertIn('retained',result['docker']);self.assertIn('retained',result['go'])
    def test_other_instance_keeps_all_dependencies(self):
        self.receipt('go',['golang-go']);(system.ROOT/'opt/psiphon-autopin-2').mkdir(parents=True)
        with patch.object(system,'inventory') as inventory:result=system.cleanup_dependencies(True)
        inventory.assert_not_called();self.assertEqual(result['instances'],[2])
    def test_other_docker_container_blocks_docker_removal(self):
        self.receipt('docker',['docker.io'])
        with patch.object(system,'inventory',return_value={'docker.io'}),patch.object(system.shutil,'which',return_value='/usr/bin/docker'),patch.object(system.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='external-container\n',stderr='')) as commands:
            result=system.cleanup_dependencies(True)
        self.assertIn('retained',result['docker']);self.assertEqual(commands.call_count,1)
    def test_unowned_reverse_dependency_blocks_apt_removal(self):
        self.receipt('go',['golang-go'])
        with patch.object(system,'inventory',return_value={'golang-go','external-app'}),patch.object(system.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='Purg golang-go\nRemv external-app\n',stderr='')) as commands:
            result=system.cleanup_dependencies(True)
        self.assertIn('retained',result['go']);self.assertEqual(commands.call_count,1)
    def test_only_owned_packages_are_removed_without_autoremove(self):
        self.receipt('go',['golang-go','golang-src'])
        def fake(args,**kwargs):
            if '-s' in args:return subprocess.CompletedProcess(args,0,stdout='Purg golang-go\nPurg golang-src\n',stderr='')
            self.assertEqual(args,['apt-get','-y','purge','--','golang-go','golang-src'])
            self.assertNotIn('autoremove',args);return subprocess.CompletedProcess(args,0)
        with patch.object(system,'inventory',side_effect=[{'golang-go','golang-src','python3'},{'python3'}]),patch.object(system.subprocess,'run',side_effect=fake):
            result=system.cleanup_dependencies(True)
        self.assertEqual(result['go']['removed'],['golang-go','golang-src'])
    def test_tampered_receipt_cannot_remove_ssh(self):
        system.save_ledger({'version':1,'components':{'go':{'owned':True,'packages':['openssh-server']}}})
        with patch.object(system.subprocess,'run') as commands:
            with self.assertRaises(ValueError):system.cleanup_dependencies(True)
        commands.assert_not_called()
    def test_shared_lock_excludes_another_process(self):
        code="import fcntl,sys;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)"
        with system.locked():
            path=system.system_dir()/'dependencies.lock'
            blocked=subprocess.run([sys.executable,'-c',code,str(path)],capture_output=True,text=True)
            self.assertNotEqual(blocked.returncode,0)
        released=subprocess.run([sys.executable,'-c',code,str(path)],capture_output=True,text=True)
        self.assertEqual(released.returncode,0,released.stderr)
    def test_plain_last_uninstall_relinquishes_ownership(self):
        self.receipt('go',['golang-go'])
        with patch.object(system.subprocess,'run') as commands:system.cleanup_dependencies(False)
        commands.assert_not_called();self.assertEqual(system.load_ledger()['components'],{})
    def test_cli_flag_reaches_uninstall_and_rejects_other_commands(self):
        with patch.object(sys,'argv',['autopin','uninstall','--purge-deps']),patch.object(m,'uninstall') as uninstall:
            self.assertEqual(m.main(),0)
        uninstall.assert_called_once_with(True)
        with patch.object(sys,'argv',['autopin','check','--purge-deps']),patch.object(m,'uninstall') as uninstall:
            with self.assertRaises(SystemExit):m.main()
        uninstall.assert_not_called()

class DependencyInstallerIntegrationTests(unittest.TestCase):
    install=test_installation.InstallationTests.install
    def scenario(self,mode,other_instance=False):
        base,p=self.install(fresh=True,dependency_mode=mode)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        if other_instance:(base/'opt/psiphon-autopin-2').mkdir()
        p=subprocess.run([sys.executable,str(base/'opt/psiphon-autopin/psiphon_autopin.py'),'uninstall','--purge-deps'],text=True,capture_output=True,timeout=20,
            env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)})
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertFalse((base/'opt/psiphon-autopin').exists())
        self.assertFalse((base/'var/lib/psiphon-autopin').exists())
        return base,json.loads((base/'state').read_text())
    def test_failed_package_removal_returns_failure_and_keeps_receipt(self):
        base,p=self.install(fresh=True,dependency_mode='both_missing')
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        state=json.loads((base/'state').read_text());state['purge_fail']=True;(base/'state').write_text(json.dumps(state))
        p=subprocess.run([sys.executable,str(base/'opt/psiphon-autopin/psiphon_autopin.py'),'uninstall','--purge-deps'],text=True,capture_output=True,timeout=20,
            env={**os.environ,'PATH':str(base/'bin')+os.pathsep+os.environ['PATH'],'AUTOPIN_TEST_ROOT':str(base)})
        self.assertNotEqual(p.returncode,0)
        self.assertFalse((base/'opt/psiphon-autopin').exists())
        self.assertTrue((base/'bin/docker').exists());self.assertTrue((base/'bin/go').exists())
        ledger=json.loads((base/'var/lib/psiphon-autopin-system/dependencies.json').read_text())
        self.assertTrue(ledger['components']['go']['owned']);self.assertIn('could not be removed',p.stdout)
    def test_fresh_installer_receipts_drive_full_cleanup(self):
        base,state=self.scenario('both_missing')
        self.assertFalse((base/'bin/docker').exists());self.assertFalse((base/'bin/go').exists())
        self.assertNotIn('docker.io',state['packages']);self.assertNotIn('golang-go',state['packages'])
    def test_preexisting_docker_and_go_survive_full_cleanup(self):
        base,state=self.scenario('preexisting')
        self.assertTrue((base/'bin/docker').exists());self.assertTrue((base/'bin/go').exists())
    def test_only_new_go_is_removed_when_docker_preexists(self):
        base,state=self.scenario('go_missing')
        self.assertTrue((base/'bin/docker').exists());self.assertFalse((base/'bin/go').exists())
    def test_only_new_docker_is_removed_when_go_preexists(self):
        base,state=self.scenario('docker_missing')
        self.assertFalse((base/'bin/docker').exists());self.assertTrue((base/'bin/go').exists())
    def test_full_cleanup_keeps_dependencies_for_another_instance(self):
        base,state=self.scenario('both_missing',other_instance=True)
        self.assertTrue((base/'bin/docker').exists());self.assertTrue((base/'bin/go').exists())
        self.assertTrue((base/'opt/psiphon-autopin-2').exists())

if __name__=='__main__':unittest.main()
