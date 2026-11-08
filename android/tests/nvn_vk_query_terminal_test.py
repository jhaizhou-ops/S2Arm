#!/usr/bin/env python3
"""Production query ownership and pending-writeback terminal safety."""
import shutil, subprocess, tempfile, unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
class QueryTerminalTest(unittest.TestCase):
    def test_pending_is_retained(self):
        cc=shutil.which('cc'); self.assertIsNotNone(cc,'C compiler required')
        inc=[HERE/'query_edges/stub',HERE/'vkhost',ROOT/'graphics/nvn/third_party/vulkan-headers/include',HERE.parent/'native/direct',HERE.parent/'native/nvn',ROOT/'graphics/nvn/gfx/nvn',ROOT/'graphics/nvn/gfx/nvn/include',ROOT/'graphics/nvn/gfx']
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/'query-terminal'; cmd=[cc,'-std=gnu11','-O1','-Wall','-Wextra','-Werror','-Wno-missing-field-initializers','-Wno-unused-parameter']+[f'-I{x}' for x in inc]+[str(HERE/'nvn_vk_query_edges_test.c'),'-o',str(exe)]
            subprocess.run(cmd,check=True)
            for case in ('terminal_pending','terminal_timestamp','terminal_flags'):
                with self.subTest(case=case):
                    run=subprocess.run([str(exe),case],capture_output=True,text=True)
                    self.assertEqual(run.returncode,0,run.stdout+run.stderr)
if __name__=='__main__': unittest.main()
