#!/usr/bin/env python3
"""Exercise production session settlement and release ordering on the host."""
import shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
class AdapterReleaseOrderTest(unittest.TestCase):
    def test_release_order(self):
        cc=shutil.which('cc')
        self.assertIsNotNone(cc,'C compiler required for adapter release regression')
        includes=[HERE/'vkhost', HERE/'hostvk', HERE.parent/'native', HERE.parent/'native/direct', HERE.parent/'native/nvn', ROOT/'runtime/include', ROOT/'graphics/nvn/gfx/nvn', ROOT/'graphics/nvn/gfx/nvn/include', ROOT/'graphics/nvn/gfx/tex', ROOT/'graphics/nvn/third_party/vulkan-headers/include']
        with tempfile.TemporaryDirectory() as td:
            binary=Path(td)/'adapter-release-test'
            cmd=[cc,'-std=gnu11','-ffunction-sections','-fdata-sections']+[f'-I{x}' for x in includes]+[str(HERE/'nvn_vk_adapter_release_order_test.c'),('-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'),'-pthread','-o',str(binary)]
            if sys.platform == 'darwin': cmd.append('-Wl,-undefined,dynamic_lookup')
            modes = [[]] if sys.platform == 'darwin' else [[], ['-DS2A_PORTABLE_TIMEDLOCK']]
            for extra in modes:
                with self.subTest(shim=bool(extra) or sys.platform == 'darwin'):
                    subprocess.run(cmd + extra,check=True)
                    result=subprocess.run([str(binary)],capture_output=True,text=True)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__': unittest.main()
