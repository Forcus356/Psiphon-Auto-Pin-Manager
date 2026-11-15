"""Check fail-closed artifact verification and actual generated isolation flags."""
import json
from pathlib import Path
import re
import unittest
from test_autopin import ROOT,INSTALLER,heredoc
import test_installation as installation

class SupplyChainTests(unittest.TestCase):
    install=installation.InstallationTests.install
    def test_upstream_refs_are_fixed_and_console_never_uses_a_branch(self):
        for name in ('PIN_IMAGE','CONSOLE_BASE'):
            value=re.search(r"^"+name+r"='([^']+)'",INSTALLER,re.M).group(1)
            self.assertRegex(value,r'@sha256:[a-f0-9]{64}$')
        self.assertRegex(re.search(r"CONSOLE_COMMIT='([^']+)'",INSTALLER).group(1),r'^[a-f0-9]{40}$')
        self.assertRegex(re.search(r"CONSOLE_SHA256='([^']+)'",INSTALLER).group(1),r'^[a-f0-9]{64}$')
        for line in INSTALLER.splitlines():
            if 'docker pull ' in line:self.assertIn('"$PIN_IMAGE"',line)
        self.assertNotIn('binaries/master/',INSTALLER);self.assertNotIn('git/trees/master',INSTALLER)
    def test_bad_binary_hash_is_rejected_before_execution_or_tunnel_stop(self):
        # Corrupt the expected fixture hash only in the sandbox's installer copy.
        from unittest.mock import patch
        original=Path.read_text
        def read(path,*args,**kwargs):
            text=original(path,*args,**kwargs)
            if path==ROOT/'install_psiphon_autopin.sh':
                text=text.replace('CONSOLE_SHA256=\'faf6873ddc1dab6c00e11a090a711fb3a26cfa7dbc1717e0c3b1978dfff4c105\'',"CONSOLE_SHA256='"+'0'*64+"'")
            return text
        with patch.object(Path,'read_text',read):base,p=self.install(console=True)
        self.assertNotEqual(p.returncode,0);self.assertIn('SHA-256 mismatch',p.stderr)
        cmds=[json.loads(s) for s in (base/'commands').read_text().splitlines()]
        self.assertFalse(any(cmd[:2]==['docker','build'] for cmd in cmds));self.assertNotIn(['docker','stop','vps-psiphon'],cmds)
        self.assertFalse((base/'opt/vps-psiphon/ConsoleClient').exists())
    def test_generated_container_runs_unprivileged_without_capabilities(self):
        base,p=self.install();self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        commands=[json.loads(s) for s in (base/'commands').read_text().splitlines()]
        starts=[s for s in commands if s[:2]==['docker','run'] and '--name' in s]
        self.assertTrue(starts)
        for cmd in starts:
            self.assertEqual(cmd[cmd.index('--user')+1],'1000:1000')
            self.assertIn('--read-only',cmd);self.assertEqual(cmd[cmd.index('--cap-drop')+1],'ALL')
            self.assertIn('no-new-privileges:true',cmd)
            self.assertTrue(any('@sha256:' in arg for arg in cmd))
        for name in ('vps-psiphon.service','psiphon-autopin.service'):
            text=(base/'etc/systemd/system'/name).read_text()
            for setting in ('ProtectSystem=strict','ProtectHome=true','PrivateTmp=true','NoNewPrivileges=true','RestrictNamespaces=true','UMask=0077','CapabilityBoundingSet=','PartOf=docker.service'):
                self.assertIn(setting,text)
    def test_lan_binding_remains_explicit_and_unchanged(self):
        base,p=self.install(extra_args=('--bind','172.17.0.1'))
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(json.loads((base/'var/lib/psiphon-autopin/settings.json').read_text())['bind'],'172.17.0.1')

    def test_console_build_context_excludes_private_configuration(self):
        base,p=self.install(console=True);self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        allow=(base/'opt/vps-psiphon/.dockerignore').read_text().splitlines()
        self.assertEqual(allow,['**','!Dockerfile','!ConsoleClient'])

    def test_obsolete_go_is_refused_before_stopping_existing_service(self):
        from unittest.mock import patch
        source=installation.FAKE.replace('go version go1.26.0 linux/amd64','go version go1.20.14 linux/amd64')
        with patch.object(installation,'FAKE',source):base,p=self.install()
        self.assertNotEqual(p.returncode,0);self.assertIn('Go 1.21+ is required',p.stderr)
        commands=[json.loads(s) for s in (base/'commands').read_text().splitlines()]
        self.assertFalse(any(c[0]=='systemctl' and 'stop' in c for c in commands))
        self.assertTrue(json.loads((base/'state').read_text())['running'])
