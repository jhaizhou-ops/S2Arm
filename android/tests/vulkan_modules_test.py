#!/usr/bin/env python3
"""Selection policy over real symbol-reader results; NSO parsing stays shared."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "android/tools"))
sys.path.insert(0, str(ROOT / "graphics/nvn/tools"))
from vulkan_modules import replaced_modules
import nso_syms
import make_pack


def rows(imports=(), exports=()):
    return [(n, False, 1) for n in imports] + [(n, True, 1) for n in exports]


class Selection(unittest.TestCase):
    def run_fixture(self, mapping):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in mapping:
                (root / name).touch()
            with patch.object(nso_syms, "load", side_effect=lambda p: mapping[Path(p).name]), \
                 patch.object(nso_syms, "dynsyms", side_effect=lambda data: data):
                return replaced_modules(root)

    def fixture(self):
        return {"main": rows(["vkCreateInstance", "nn_os_start"]),
                "sdk": rows(exports=["nn_os_start", "nvnBootstrapLoader"]),
                "subsdk0": rows(["vk_icdGetInstanceProcAddr"], ["vkGetInstanceProcAddr", "vkCreateInstance"]),
                "subsdk1": rows(exports=["vk_icdGetInstanceProcAddr"])}

    def test_only_loader_and_driver_excluded(self):
        self.assertEqual(self.run_fixture(self.fixture()), ["subsdk0", "subsdk1"])

    def test_nvn_and_mixed_frontends_refused(self):
        for imports in [["nvnBootstrapLoader"], ["vkCreateInstance", "nvnBootstrapLoader"], ["vkCreateInstance", "eglInitialize"]]:
            with self.subTest(imports=imports):
                fixture = self.fixture(); fixture["main"] = rows(imports)
                with self.assertRaisesRegex(ValueError, "requires Vulkan"):
                    self.run_fixture(fixture)

    def test_driver_cpu_dependency_not_silently_dropped(self):
        fixture = self.fixture()
        fixture["main"] = rows(["vkCreateInstance", "cpu_helper"])
        fixture["subsdk1"] = rows(exports=["vk_icdGetInstanceProcAddr", "cpu_helper"])
        with self.assertRaisesRegex(ValueError, "non-Vulkan imports"):
            self.run_fixture(fixture)

    def test_kept_definition_satisfies_cpu_dependency(self):
        fixture = self.fixture()
        fixture["main"] = rows(["vkCreateInstance", "cpu_helper"])
        fixture["sdk"] = rows(exports=["cpu_helper"])
        fixture["subsdk1"] = rows(exports=["vk_icdGetInstanceProcAddr", "cpu_helper"])
        self.assertEqual(self.run_fixture(fixture), ["subsdk0", "subsdk1"])

    def test_direct_imports_without_embedded_driver(self):
        self.assertEqual(self.run_fixture({"main": rows(["vkCreateInstance"]), "sdk": rows()}), [])

    def test_descriptor_is_indexed_outside_removed_code_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            # The package path also runs the real address-requirements collector.
            # Use the shared synthetic NSO/NPDM, not empty stand-ins.
            root = Path(make_pack.synthetic_root(temp)); staging = Path(temp) / 'work/modules'
            def rewrite(exefs, out):
                Path(out).mkdir(parents=True)
                for module in ['main', 'sdk', 'subsdk0', 'subsdk1']:
                    (Path(out) / (module + '.patched.bin')).write_bytes(b'fixture')
            with patch.object(make_pack, 'rewrite', side_effect=rewrite), \
                 patch.object(make_pack, 'stage_system_data', return_value=None), \
                 patch('vulkan_modules.replaced_modules', return_value=['subsdk0', 'subsdk1']):
                entries = dict(make_pack.entries_from_root(str(root), str(staging), direct_vulkan=True))
            self.assertIn('modules', entries)
            self.assertIn('direct-vulkan.txt', entries)
            self.assertTrue(Path(entries['exefs/addr_need.tsv']).is_file())
            self.assertEqual(Path(entries['direct-vulkan.txt']).read_text(),
                             'S2ARM_VULKAN_DIRECT_V1\nsubsdk0\nsubsdk1\n')
            self.assertTrue((staging / 'subsdk0.patched.bin').is_file())
            self.assertTrue((staging / 'subsdk1.patched.bin').is_file())


if __name__ == "__main__":
    unittest.main()
