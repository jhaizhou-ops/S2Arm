#!/usr/bin/env python3
"""Android packages consume system data prepared by refresh; fixtures contain no game data."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ANDROID = Path(__file__).resolve().parents[1]
REPO = ANDROID.parents[0]
spec = importlib.util.spec_from_file_location('android_make_pack', ANDROID / 'tools/make_pack.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


class PreparedSystemDataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'root'
        self.system = self.root / 'systemdata'
        self.system.mkdir(parents=True)
        result = subprocess.run([sys.executable, str(REPO / 'pack/sysdata_synth.py'), '--ids'],
                                capture_output=True, text=True, check=True)
        self.ids = result.stdout.split()
        self.assertTrue(self.ids)
        for sid in self.ids:
            path = self.system / sid
            path.mkdir()
            (path / 'fixture').write_text('prepared data')

    def stage(self, source=None):
        return pack.stage_system_data(str(self.root), str(self.root / 'stage'), source)

    def test_prepared_root_is_selected_without_mutation(self):
        before = (self.system / self.ids[0] / 'fixture').read_bytes()
        self.assertEqual(Path(self.stage()), self.system)
        self.assertEqual((self.system / self.ids[0] / 'fixture').read_bytes(), before)

    def test_missing_or_empty_required_directory_is_red(self):
        (self.system / self.ids[0] / 'fixture').unlink()
        with self.assertRaisesRegex(SystemExit, '缺少已准备的系统数据'):
            self.stage()
        (self.system / self.ids[0]).rmdir()
        with self.assertRaisesRegex(SystemExit, '缺少已准备的系统数据'):
            self.stage()

    def test_metadata_only_and_symlink_do_not_count_as_prepared_data(self):
        data = self.system / self.ids[0]
        (data / 'fixture').unlink()
        (data / '.DS_Store').write_bytes(b'metadata')
        with self.assertRaisesRegex(SystemExit, '缺少已准备的系统数据'):
            self.stage()
        (data / '.DS_Store').unlink()
        (data / 'link').symlink_to(self.system / self.ids[-1] / 'fixture')
        with self.assertRaisesRegex(SystemExit, '缺少已准备的系统数据'):
            self.stage()

    def test_external_source_requires_refresh(self):
        with self.assertRaisesRegex(SystemExit, '请先通过 refresh'):
            self.stage(str(self.root / 'external'))

    def test_environment_does_not_override_prepared_root(self):
        with patch.dict(os.environ, {'S2A_SYSDATA': str(self.root / 'external')}):
            self.assertEqual(Path(self.stage()), self.system)

    def test_synthetic_root_explicitly_prepares_fixtures(self):
        temp = Path(self.temp.name) / "synthetic"
        temp.mkdir()
        root = pack.synthetic_root(str(temp))
        self.assertEqual(Path(pack.stage_system_data(root, 'unused')), Path(root) / 'systemdata')


if __name__ == '__main__':
    unittest.main()
