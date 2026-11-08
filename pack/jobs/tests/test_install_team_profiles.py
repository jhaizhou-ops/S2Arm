# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Xcode 缓存缺失时，只从可用开发签名材料发现团队；不连接 Apple。"""
import datetime, hashlib, os, plistlib, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install

class ProfileTeamsTests(unittest.TestCase):
    def discover(self, *, account=True, expired=False, development=True, identity=True, malformed=False, mismatch=False):
        with tempfile.TemporaryDirectory() as home:
            folder = Path(home) / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
            folder.mkdir(parents=True); (folder / 'test.mobileprovision').touch()
            cert = b'synthetic certificate'
            profile = dict(TeamIdentifier=['ABCDE12345'], TeamName='测试团队', LocalProvision=True,
                ExpirationDate=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=-1 if expired else 2),
                ProvisionedDevices=['synthetic-device'], DeveloperCertificates=[cert],
                Entitlements={'get-task-allow': development, 'com.apple.developer.team-identifier': 'FGHIJ67890' if mismatch else 'ABCDE12345'})
            prefs = {'DVTDeveloperAccountManagerAppleIDLists': {'IDE.Identifiers.Prod': [{'identifier': 'synthetic-account'}]}} if account else {}
            def run(args, **kw):
                if args[0] == 'defaults': data = plistlib.dumps(prefs)
                elif args[1] == 'find-identity': data = ('1) ' + hashlib.sha1(cert).hexdigest().upper() + ' "Apple Development"') if identity else ''
                elif args[1] == 'cms': data = b'bad plist' if malformed else plistlib.dumps(profile)
                else: raise AssertionError(args)
                return subprocess.CompletedProcess(args, 0, data, '')
            with patch.dict(os.environ, HOME=home), patch.object(install.subprocess, 'run', side_effect=run):
                return install.xcode_teams()

    def test_account_without_old_cache_uses_matching_development_profile(self):
        self.assertEqual(self.discover(), [dict(id='ABCDE12345', name='测试团队', free=True)])

    def test_unusable_material_does_not_unlock_install(self):
        for args in [dict(account=False), dict(expired=True), dict(development=False), dict(identity=False), dict(malformed=True), dict(mismatch=True)]:
            with self.subTest(args=args): self.assertEqual(self.discover(**args), [])
