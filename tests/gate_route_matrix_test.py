#!/usr/bin/env python3
"""门禁路由回归：每行是独立人工指定的必要步骤，不要求输出只有这些步骤。"""
import contextlib
import importlib.util
import io
import sys
import unittest
import warnings
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gate_route', ROOT / 'tools/gate_route.py')
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)


class RouteMatrixTest(unittest.TestCase):
    def test_required_routes(self):
        # 分别覆盖作业层、抽取阶段闭包、原生执行入口、图形工具及渲染器。
        # 必选项依据实际依赖/钩子契约手写；禁选项防止宽泛匹配掩盖缺口。
        cases = [
            ('tests', 'pack/jobs/core.py', {'tests/pack_jobs_test.sh'}, {'tests/stage_keys_test.sh'}),
            ('tests', 'pack/stage_extract.sh', {'tests/stage_keys_test.sh'}, {'tests/pack_jobs_test.sh'}),
            ('tests', 'pack/stage_direct.sh', {'tests/stage_keys_test.sh'}, {'tests/pack_jobs_test.sh'}),   # 11-05 起 run_mac.sh 不在直连阶段闭包里（出包不再起局），样例换成仍是阶段输入的脚本
            ('tests', 'graphics/tools/shbake/xc_key.sh', {'tests/xc_key_test.sh'}, {'tests/pack_jobs_test.sh'}),
            ('hooks', 'pack/jobs/core.py', {'launchers/macos/gate.sh'}, {'runtime/gate.sh', 'graphics/gate.sh'}),
            ('hooks', 'services/S2A.Services/Native.cs', {'android/gate.sh', 'android/core-link/gate.sh'}, set()),
            ('hooks', 'services/S2A.Services/HidServer.cs', {'android/core-link/gate.sh'}, {'android/gate.sh'}),
            ('hooks', 'services/S2A.Services/SmDirect.cs', {'android/core-link/gate.sh'}, {'android/gate.sh'}),
            ('hooks', 'graphics/metal/cs/NxTrack.cs', {'android/core-link/gate.sh'}, {'android/gate.sh'}),
            ('hooks', 'android/cs/video/AvcH264Decoder.cs', {'android/gate.sh', 'android/core-link/gate.sh'}, set()),
            ('hooks', 'graphics/vulkan/wsi/AndroidWindow.cs', {'android/gate.sh'}, set()),
            ('hooks', 'android/verify-apk.py', {'android/gate.sh'}, set()),
            ('hooks', 'graphics/tools/direct/compiler/DirectBundle.cs', {'android/core-link/gate.sh'}, set()),
            ('hooks', 'graphics/tools/direct/dsh/Tables.cs', {'android/core-link/gate.sh'}, set()),
            ('hooks', 'translator/dmsh_xlate/Program.cs', {'android/core-link/gate.sh'}, set()),
            ('hooks', 'graphics/widen/shader/SpirvFetchScale.cs', {'android/core-link/gate.sh'}, set()),
            ('hooks', 'graphics/widen/SpirvCbufUseText.cs', {'android/core-link/gate.sh'}, set()),
            ('hooks', 'runtime/src/ap_host.c', {'runtime/gate.sh', 'graphics/gate.sh'}, {'tests/visual/gate.sh'}),
            ('hooks', 'graphics/metal/gal_core.m', {'runtime/gate.sh', 'graphics/gate.sh', 'tests/visual/gate.sh'}, {'launchers/macos/gate.sh'}),
        ]
        for mode, changed, required, excluded in cases:
            with self.subTest(mode=mode, changed=changed):
                out = io.StringIO()
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', ResourceWarning)
                    with patch.object(sys, 'argv', ['gate_route.py', mode, changed]), contextlib.redirect_stdout(out):
                        route.main()
                got = set(out.getvalue().splitlines())
                self.assertTrue(required <= got, f'{changed}: missing {required - got}; got {got}')
                self.assertFalse(excluded & got, f'{changed}: unexpected {excluded & got}')


if __name__ == '__main__':
    unittest.main()
