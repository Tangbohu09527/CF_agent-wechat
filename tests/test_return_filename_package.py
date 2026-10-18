"""Offline guards for the fixed two-file release packager, not a Linux build."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('filename_package',ROOT/'scripts/package-return-filename.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ReleasePackageTests(unittest.TestCase):
    def test_only_two_fixed_files_and_digest_base(self):
        text=module.dockerfile('a'*40)
        self.assertEqual(text.splitlines()[0],'FROM '+module.BASE_IMAGE)
        self.assertRegex(module.BASE_IMAGE,r'@sha256:[0-9a-f]{64}$')
        self.assertEqual([line for line in text.splitlines() if line.startswith('COPY ')],[
            'COPY --chown=0:0 --chmod=0755 agent-server /opt/agent-server/agent-server',
            'COPY --chown=0:0 --chmod=0755 paste-file /opt/tools/paste-file'])
        self.assertFalse(any(line.startswith(('RUN ','ENTRYPOINT ','CMD ','ENV ','VOLUME ','USER ')) for line in text.splitlines()))

    def test_untrusted_revision_cannot_inject_dockerfile(self):
        for revision in ['', 'latest', 'a'*39, 'a'*41, 'a'*40+'\nRUN false', 'G'*40]:
            with self.assertRaises(ValueError):module.dockerfile(revision)

    def test_runtime_configuration_comparison_keeps_security_fields(self):
        original={'Config':{'Image':'parent','Labels':{'x':'old'},'Entrypoint':['/entrypoint.sh'],'User':'wechat','Env':['MODE=fixed'],'Volumes':{'/data':{}},'Healthcheck':{'Test':['CMD','curl','localhost/health']}}}
        modified={'Config':dict(original['Config'],Image='new',Labels={'x':'new'})}
        self.assertEqual(module.runtime_config(original),module.runtime_config(modified))
        for field,value in [('Entrypoint',['/other']),('User','root'),('Env',[]),('Volumes',{}),('Healthcheck',{})]:
            changed={'Config':dict(original['Config'])};changed['Config'][field]=value
            self.assertNotEqual(module.runtime_config(original),module.runtime_config(changed),field)

    def test_release_abi_and_source_identity_are_explicit(self):
        text=(ROOT/'scripts/package-return-filename.py').read_text(encoding='utf-8')
        for guard in ["rustc 1.93.0 ","os_release.get('VERSION_ID')=='\"22.04\"'","<=(2,35)","--version-info", "changed|untracked==set(transformed)","Cargo dependency lock drift", "base binary/helper identity mismatch"]:
            self.assertIn(guard,text)
        self.assertIn('64938f4656f8507e3487afb622db9e14b1b3e439950cd46e6c2a9b5047630a89',text)

    def test_isolated_probe_never_starts_wechat_or_server(self):
        text=(ROOT/'scripts/package-return-filename.py').read_text(encoding='utf-8')
        self.assertIn("'--network','none','--read-only','--entrypoint','/bin/sh'",text)
        self.assertIn('--verify /opt/agent-server/agent-server',text)
        self.assertIn('--list /opt/agent-server/agent-server',text)
        self.assertIn('live_wechat_started=False',text)
        self.assertIn('service_health_verified=False',text)
        self.assertNotIn("'--privileged'",text)
        self.assertNotIn("'--volume'",text)

    def test_ci_builds_locked_release_on_compatible_os(self):
        text=(ROOT/'.github/workflows/return-filename-candidate.yml').read_text(encoding='utf-8')
        release=text[text.index('  release-overlay:'):]
        self.assertIn('runs-on: ubuntu-22.04',release)
        self.assertIn('cargo build --release --locked',release)
        self.assertIn('timeout-minutes: 40',release)
        self.assertIn(module.UPSTREAM,release)
        self.assertNotIn('docker push',release)

if __name__=='__main__':unittest.main()
