#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Real JVM/JNI contract; not an Android Activity or device startup test."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ANDROID = Path(__file__).resolve().parents[1]
JAVA = ANDROID / 'app/src/main/java/org/s2arm/android'

class DebugEnvironmentTest(unittest.TestCase):
    def test_production_startup_wiring(self):
        activity = (JAVA/'MainActivity.java').read_text()
        cold = activity[activity.index('    @Override public void onCreate'):activity.index('    private String loadRuntime')]
        self.assertLess(cold.index('configureDebugEnvironment(entries)'), cold.index('NativeBridge.createGame()'))
        self.assertIn('if (BuildConfig.DEBUG && getIntent() != null && getIntent().hasExtra(DebugEnvironment.EXTRA))', cold)
        hot = activity[activity.index('    @Override protected void onNewIntent'):]
        self.assertNotIn('configureDebugEnvironment(', hot)
        bridge = (ANDROID/'runtime/bridge.cpp').read_text()
        for entry, first_effect in [('create', 's2a_redirect_stderr_once();'),
                                    ('createGame', 'std::lock_guard<std::mutex> lock(g_game_create_lock);'),
                                    ('registerHost', 's2a_redirect_stderr_once();')]:
            body = bridge.split('Java_org_s2arm_android_NativeBridge_' + entry + '(')[1].split('extern "C"')[0]
            self.assertLess(body.index('if (!g_debug_environment.seal()) return 0;'), body.index(first_effect))
        self.assertIn('buildFeatures { buildConfig true }', (ANDROID/'app/build.gradle').read_text())
        self.assertIn('$<$<CONFIG:Debug>:S2A_ANDROID_DEBUG_ENV=1>', (ANDROID/'CMakeLists.txt').read_text())

    def test_wsi_qa_capability_gate(self):
        # The same native helper is called by the Android bridge. Even a forged environment
        # must be inert in release or with the debug property gate closed.
        source = r"""
#include "wsi_qa.h"
int main() {
    if (s2a_wsi_qa_disable_maintenance(false, "1") != 0) return 1;
    if (s2a_wsi_qa_disable_maintenance(true, nullptr) != 0) return 2;
    if (s2a_wsi_qa_disable_maintenance(true, "0") != 0) return 3;
#ifdef S2A_ANDROID_DEBUG_ENV
    if (s2a_wsi_qa_disable_maintenance(true, "1") != 1) return 4;
    if (s2a_wsi_qa_disable_maintenance(true, "bad") != -EINVAL) return 5;
#else
    if (s2a_wsi_qa_disable_maintenance(true, "1") != 0) return 6;
    if (s2a_wsi_qa_disable_maintenance(true, "bad") != 0) return 7;
#endif
    return 0;
}
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'qa.cpp').write_text(source)
            for debug in (False, True):
                cmd = [os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                       '-I'+str(ANDROID/'native'), str(root/'qa.cpp'), '-o', str(root/'qa')]
                if debug: cmd += ['-DS2A_ANDROID_DEBUG_ENV=1']
                subprocess.run(cmd, check=True)
                subprocess.run([str(root/'qa')], check=True)
        bridge = (ANDROID/'runtime/bridge.cpp').read_text()
        self.assertIn('s2a_wsi_qa_disable_maintenance(s2a_debug_entries_open()', bridge)
        self.assertIn('S2A_QA_NO_PRESENT_FENCE', bridge)
        surface = (ANDROID.parent.parent/'graphics/vulkan/wsi/AndroidVulkanSurface.cs').read_text()
        renderer = (ANDROID.parent.parent/'compat/tree/src/Ryujinx.Graphics.Vulkan/VulkanRenderer.cs').read_text()
        self.assertIn('_renderer.S2AForceNoSwapchainMaintenance = qaNoPresentFence == 1;', surface)
        self.assertIn('S2ASurfaceMaintenanceEnabled(WindowFactory != null,', renderer)
        self.assertIn('S2AForceNoSwapchainMaintenance));', renderer)

    def test_jvm_jni_debug_and_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            home = Path(os.environ.get('JAVA_HOME') or Path(shutil.which('javac')).resolve().parents[1])
            for debug in (True, False):
                mode = out / str(debug)
                mode.mkdir()
                (mode / 'BuildConfig.java').write_text('package org.s2arm.android; final class BuildConfig { static final boolean DEBUG = ' + str(debug).lower() + '; }')
                subprocess.run(['javac', '-d', str(mode), str(mode/'BuildConfig.java'), str(JAVA/'DebugEnvironment.java'), str(ANDROID/'tests/DebugEnvironmentTest.java')], check=True)
                source = (ANDROID/'runtime/bridge.cpp').read_text()
                onload = source[source.index('extern "C" int JNI_OnLoad'):]
                (mode/'onload.inc').write_text(onload)
                lib = mode / ('libdebugenv.dylib' if os.uname().sysname == 'Darwin' else 'libdebugenv.so')
                command = [os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC', '-pthread', '-I'+str(home/'include'), '-I'+str(home/'include'/('darwin' if os.uname().sysname == 'Darwin' else 'linux')), '-I'+str(ANDROID/'native'), '-I'+str(mode), str(ANDROID/'tests/debug_environment_jni.cpp'), '-o', str(lib)]
                if debug:
                    command += ['-DS2A_ANDROID_DEBUG_ENV=1']
                subprocess.run(command, check=True)
                for scenario in ('valid', 'invalid', 'sealed', 'raw', 'failure', 'concurrent', 'bounds'):
                    subprocess.run(['java', '-cp', str(mode), 'org.s2arm.android.DebugEnvironmentTest', str(lib), str(debug).lower(), scenario], check=True)

if __name__ == '__main__':
    unittest.main()
