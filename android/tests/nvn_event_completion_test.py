#!/usr/bin/env python3
"""P0-4: GPU 侧事件信号（OP_SIGNAL_EVENT，不含 NVN_EV_WAIT）写 guest 值之前必须有完成证明。

宿主回归：直接编译生产 mtl_vk_adapter.c（事件完成闸门就在它的回放入口）+ 生产
nvn_vk_exec_owner.c；回放层与帧队列完成证明用强符号替身（同 vk_record.c 的信号写值语义、
同 nvn_vk_first_draw_pass_break 的完成证明契约）。用例见同目录 nvn_event_completion_test.c。
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


class EventCompletionTest(unittest.TestCase):
    def test_event_completion(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc, 'C compiler required for event completion regression')
        includes = [
            HERE / 'hostvk', HERE / 'vkhost', HERE.parent / 'native', HERE.parent / 'native/direct',
            HERE.parent / 'native/nvn', ROOT / 'runtime/include', ROOT / 'graphics/nvn/gfx/nvn',
            ROOT / 'graphics/nvn/gfx/nvn/include', ROOT / 'graphics/nvn/gfx/tex',
            ROOT / 'graphics/nvn/third_party/vulkan-headers/include',
        ]
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td) / 'event-completion-test'
            cmd = ([cc, '-std=gnu11', '-ffunction-sections', '-fdata-sections'] +
                   [f'-I{x}' for x in includes] +
                   [str(HERE / 'nvn_event_completion_test.c'),
                    str(HERE.parent / 'native/nvn/nvn_vk_exec_owner.c'),
                    ('-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'),
                    '-pthread', '-o', str(binary)])
            if sys.platform == 'darwin':
                cmd.append('-Wl,-undefined,dynamic_lookup')
            modes = [[]] if sys.platform == 'darwin' else [[], ['-DS2A_PORTABLE_TIMEDLOCK']]
            for extra in modes:
                with self.subTest(shim=bool(extra) or sys.platform == 'darwin'):
                    subprocess.run(cmd + extra, check=True)
                    result = subprocess.run([str(binary)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
