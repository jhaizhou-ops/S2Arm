#!/usr/bin/env python3
"""Compile and exercise the production first-draw release on a host fixture."""
import shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
class ReleaseTest(unittest.TestCase):
    def test_release(self):
        cc=shutil.which('cc')
        self.assertIsNotNone(cc, 'C compiler required for first-draw release regression')
        includes=[HERE/'vkhost', HERE/'hostvk', HERE.parent/'native', HERE.parent/'native/direct', HERE.parent/'native/nvn', ROOT/'runtime/include', ROOT/'graphics/nvn/gfx/nvn', ROOT/'graphics/nvn/gfx/nvn/include', ROOT/'graphics/nvn/gfx/tex', ROOT/'graphics/nvn/third_party/vulkan-headers/include']
        with tempfile.TemporaryDirectory() as td:
            binary=Path(td)/'release-test'
            cmd=[cc,'-std=gnu11','-ffunction-sections','-fdata-sections'] + [f'-I{x}' for x in includes] + [str(HERE/'nvn_vk_first_draw_release_test.c'),('-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'),'-o',str(binary)]
            subprocess.run(cmd,check=True)
            for directory, uuid in [(0,1),(1,0),(1,1),(2,0)]:
                with self.subTest(directory=directory, uuid=uuid):
                    result=subprocess.run([str(binary),str(directory),str(uuid)],capture_output=True,text=True)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__': unittest.main()
