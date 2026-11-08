#!/usr/bin/env python3
"""Fixture tests for cs/nuget_verify.py (#1131 review item 5).

Builds a fake NuGet cache: each package dir carries a .nupkg, its
.nupkg.sha512 sidecar (base64 sha512 of the fake bytes) and a
.nupkg.metadata whose contentHash equals the pin-table value. The pin
table and project.assets.json are also fixtures — nothing touches the
real cache.
"""
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERIFY = HERE / 'nuget_verify.py'

PINS = {
    'microsoft.dotnet.ilcompiler': ('10.0.14', 'pin-sha-ilc=='),
    'microsoft.net.illink.tasks': ('10.0.14', 'pin-sha-illink=='),
    'microsoft.netcore.app.runtime.nativeaot.linux-bionic-arm64': ('10.0.14', 'pin-sha-rt=='),
    'runtime.osx-arm64.microsoft.dotnet.ilcompiler': ('10.0.14', 'pin-sha-osx=='),
}


class NugetVerifyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='s2a-nuget-verify-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.nuget = self.base / 'nuget'
        pins_path = self.base / 'pins.tsv'
        pins_path.write_text('\n'.join(f'{i}\t{v}\t{s}' for i, (v, s) in PINS.items()))
        self.pins = pins_path
        self.assets = self.base / 'assets.json'

    def make_pkg(self, ident, version, sha512, nupkg_bytes=b'fake-nupkg'):
        d = self.nuget / ident / version
        d.mkdir(parents=True)
        (d / '.nupkg.metadata').write_text(json.dumps({'contentHash': sha512}))
        (d / f'{ident}.{version}.nupkg').write_bytes(nupkg_bytes)
        digest = base64.b64encode(hashlib.sha512(nupkg_bytes).digest()).decode()
        (d / f'{ident}.{version}.nupkg.sha512').write_text(digest)
        return d

    def write_assets(self, libraries=(), download_deps=()):
        doc = {
            'libraries': {f'{i}/{v}': {} for i, v in libraries},
            'project': {'frameworks': {'net10.0': {
                'downloadDependencies': [{'name': n, 'version': f'[{v}, {v}]'}
                                         for n, v in download_deps]}}},
        }
        self.assets.write_text(json.dumps(doc))
        return self.assets

    def run_verify(self, assets=None):
        return subprocess.run(
            [sys.executable, str(VERIFY), '--assets', str(assets or self.assets),
             '--pins', str(self.pins), '--nuget', str(self.nuget)],
            capture_output=True, text=True)

    def populate(self, ids=('microsoft.dotnet.ilcompiler', 'microsoft.net.illink.tasks')):
        for ident in ids:
            version, sha = PINS[ident]
            self.make_pkg(ident, version, sha)

    def test_all_match_passes(self):
        self.populate(PINS.keys())
        self.write_assets(
            libraries=[(i, v) for i, (v, _) in PINS.items()],
            download_deps=[('microsoft.netcore.app.runtime.nativeaot.linux-bionic-arm64', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('固定核对通过', r.stdout)

    def test_content_hash_mismatch_is_red(self):
        self.populate()
        d = self.nuget / 'microsoft.dotnet.ilcompiler' / '10.0.14'
        (d / '.nupkg.metadata').write_text(json.dumps({'contentHash': 'tampered=='}))
        self.write_assets(libraries=[('Microsoft.DotNet.ILCompiler', '10.0.14'),
                                     ('Microsoft.NET.ILLink.Tasks', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('contentHash 不符', r.stderr)

    def test_restored_version_drift_is_red(self):
        self.populate()
        self.write_assets(libraries=[('Microsoft.DotNet.ILCompiler', '10.1.0'),
                                     ('Microsoft.NET.ILLink.Tasks', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('版本不符', r.stderr)

    def test_missing_package_dir_is_red(self):
        self.populate(('microsoft.net.illink.tasks',))
        self.write_assets(libraries=[('Microsoft.DotNet.ILCompiler', '10.0.14'),
                                     ('Microsoft.NET.ILLink.Tasks', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('不在 NuGet 缓存', r.stderr)

    def test_non_nativeaot_assets_are_red(self):
        self.populate()
        self.write_assets(libraries=[('Some.Other.Package', '1.0.0')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('未还原 microsoft.dotnet.ilcompiler', r.stderr)

    def test_tampered_nupkg_bytes_are_red(self):
        self.populate()
        d = self.nuget / 'microsoft.dotnet.ilcompiler' / '10.0.14'
        (d / 'microsoft.dotnet.ilcompiler.10.0.14.nupkg').write_bytes(b'evil')
        self.write_assets(libraries=[('Microsoft.DotNet.ILCompiler', '10.0.14'),
                                     ('Microsoft.NET.ILLink.Tasks', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('.nupkg 字节与下载记录不符', r.stderr)

    def test_absent_host_rid_ilcompiler_is_red(self):
        self.populate()
        self.write_assets(libraries=[('Microsoft.DotNet.ILCompiler', '10.0.14'),
                                     ('Microsoft.NET.ILLink.Tasks', '10.0.14'),
                                     ('Some.Other.Package', '9.9.9')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('本宿主 RID', r.stderr)

    def test_restored_but_unpinned_rid_is_red(self):
        self.populate()
        self.write_assets(
            libraries=[('Microsoft.DotNet.ILCompiler', '10.0.14'),
                       ('Microsoft.NET.ILLink.Tasks', '10.0.14')],
            download_deps=[('runtime.linux-x64.microsoft.dotnet.ilcompiler', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn('未固定', r.stderr)

    def test_pinned_linux_x64_rid_passes(self):
        self.populate()
        self.make_pkg('runtime.linux-x64.microsoft.dotnet.ilcompiler', '10.0.14', 'pin-sha-x64==')
        self.pins.write_text(self.pins.read_text()
                             + '\nruntime.linux-x64.microsoft.dotnet.ilcompiler\t10.0.14\tpin-sha-x64==')
        self.write_assets(
            libraries=[('Microsoft.DotNet.ILCompiler', '10.0.14'),
                       ('Microsoft.NET.ILLink.Tasks', '10.0.14')],
            download_deps=[('runtime.linux-x64.microsoft.dotnet.ilcompiler', '10.0.14')])
        r = self.run_verify()
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
