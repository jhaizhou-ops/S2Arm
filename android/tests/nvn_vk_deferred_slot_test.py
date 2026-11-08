#!/usr/bin/env python3
"""Actual slot retirement plus a mutation proving the fence gate is tested."""
import shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = HERE.parent / 'native/nvn/nvn_vk_first_draw.c'
class DeferredSlotTest(unittest.TestCase):
    def test_slot_proof_and_mutant(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc)
        includes = [HERE/'vkhost', HERE/'hostvk', HERE.parent/'native', HERE.parent/'native/direct', HERE.parent/'native/nvn', ROOT/'runtime/include', ROOT/'graphics/nvn/gfx/nvn', ROOT/'graphics/nvn/gfx/nvn/include', ROOT/'graphics/nvn/gfx/tex', ROOT/'graphics/nvn/third_party/vulkan-headers/include']
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            # Mutate exactly the production failure branch: a missing proof is ignored.
            source = SOURCE.read_text()
            old = 'if (bad) {\n        FD_LOG("present defer: the previous frame has no completion proof; resources retained");'
            new = 'if (0 && bad) {\n        FD_LOG("present defer: the previous frame has no completion proof; resources retained");'
            self.assertEqual(source.count(old), 1)
            mutant = td/'nvn_vk_first_draw_mutant.c'
            mutant.write_text(source.replace(old, new))
            for name, target, expect_success in [('production', SOURCE, True), ('mutant', mutant, False)]:
                binary = td/name
                cmd = [cc, '-std=gnu11', '-ffunction-sections', '-fdata-sections'] + [f'-I{x}' for x in includes] + [f'-DFIRST_DRAW_SOURCE="{target}"', str(HERE/'nvn_vk_deferred_slot_test.c'), ('-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'), '-o', str(binary)]
                if sys.platform == 'darwin': cmd.append('-Wl,-undefined,dynamic_lookup')
                subprocess.run(cmd, check=True)
                result = subprocess.run([str(binary)], capture_output=True, text=True)
                if expect_success:
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, 'mutant escaped fence-proof assertions')
                    self.assertIn('nvn_vk_first_draw_retire_all()!=0', result.stderr)
if __name__ == '__main__': unittest.main()
