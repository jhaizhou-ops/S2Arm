#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Final APK identity: SDK-created synthetic manifests; no game, signing or device.

The Gradle checks below are source contracts, not Gradle execution evidence.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ANDROID = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ANDROID / 'tools'))
import game_apk


class AppIdTest(unittest.TestCase):
    def test_default_and_debug_suffix_contract(self):
        title = '0100000000ABCDEF'
        for suffix in ('', '.w2'):
            game_apk.validate_apk_package(title, 'org.s2arm.game.t0100000000abcdef' + suffix, True)
        game_apk.validate_apk_package(title, 'org.s2arm.game.t0100000000abcdef', False)
        for suffix in ('.test_2.extra', '.foo', '.w2.extra', '.W2', '.', '..w2', '.2w', '.w-2', '.w2/', '.w2;echo', '.w2\n'):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                game_apk.validate_apk_package(title, 'org.s2arm.game.t0100000000abcdef' + suffix, True)
        with self.assertRaises(ValueError):
            game_apk.validate_apk_package(title, 'org.s2arm.game.t0100000000abcdef.w2', False)

    def test_gradle_suffix_is_explicit_debug_only_before_signing(self):
        source = (ANDROID / 'app/build.gradle').read_text()
        self.assertIn("project.findProperty('s2arm.testAppIdSuffix')", source)
        self.assertIn('buildTypes { debug { if (testAppIdSuffix != null) applicationIdSuffix testAppIdSuffix } }', source)
        self.assertLess(source.index("throw new GradleException('s2arm.testAppIdSuffix is debug-only"),
                        source.index('if (releaseRequested && !releaseKeystore.isFile())'))
        self.assertIn("if (releaseRequested)\n        throw new GradleException('s2arm.testAppIdSuffix is debug-only", source)
        self.assertIn("testAppIdSuffix != '.w2'", source)
        self.assertIn('gradle.taskGraph.whenReady { graph ->', source)
        self.assertIn("graph.allTasks.any { it.project == project && it.name.toLowerCase(Locale.ROOT).contains('release') }", source)

    def test_real_sdk_manifest_identity(self):
        sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
        if not sdk:
            self.skipTest('real SDK required; no manifest execution evidence')
        aapt = Path(sdk) / 'build-tools/36.0.0/aapt2'
        framework = Path(sdk) / 'platforms/android-36/android.jar'
        self.assertTrue(aapt.is_file()); self.assertTrue(framework.is_file())
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for suffix, debug in (('', False), ('', True), ('.w2', True)):
                with self.subTest(suffix=suffix, debug=debug):
                    name = 'org.s2arm.game.t0100000000abcdef' + suffix
                    (root / 'AndroidManifest.xml').write_text(
                        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                        f'package="{name}" android:versionCode="7" android:versionName="1">'
                        '<uses-sdk android:minSdkVersion="29" android:targetSdkVersion="36"/>'
                        f'<application android:debuggable="{str(debug).lower()}"/></manifest>')
                    apk = root / 'identity.apk'
                    subprocess.run([str(aapt), 'link', '-I', str(framework), '--manifest',
                                    str(root / 'AndroidManifest.xml'), '-o', str(apk)], check=True,
                                   capture_output=True, text=True)
                    self.assertEqual(game_apk.apk_identity(apk), (name, 7, debug))
                    game_apk.validate_apk_package('0100000000ABCDEF', name, debug)

    def test_badging_error_and_ambiguous_identity_fail_closed(self):
        with patch.object(game_apk.os.path, 'isfile', return_value=True), \
             patch.object(game_apk.shutil, 'which', return_value='/test/aapt2'):
            for output, rc in [("package: name='x.y' versionCode='1'\n" * 2, 0), ('', 0), ('', 1)]:
                with self.subTest(output=output, rc=rc), patch.object(game_apk.subprocess, 'run',
                        return_value=subprocess.CompletedProcess([], rc, output, 'bad manifest')):
                    with self.assertRaises(ValueError):
                        game_apk.apk_identity('synthetic.apk')


if __name__ == '__main__':
    unittest.main()
