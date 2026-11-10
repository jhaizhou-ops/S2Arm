# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Cleanup must unlink entries without following them into player data."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import Failure
import layout
import library


class CleanupLinkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="s2arm synthetic cleanup ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.c = SimpleNamespace(library=self.root / "library", work_root=self.root / "work")
        self.gid = "0100000000000000"
        self.c.library.mkdir()
        self.output = layout.ios_work(self.c, self.gid)   # 这款文件夹的出包工作目录 build/ios
        self.output.mkdir(parents=True)

    def payload(self, parent):
        parent.mkdir(parents=True, exist_ok=True)
        path = parent / "synthetic.txt"
        path.write_bytes(b"player data must survive")
        return path

    def test_prune_unlinks_intermediates_without_deleting_their_targets(self):
        for retain in (True, False):
            for target in (layout.path(self.c, self.gid, "saves"), self.root / "outside"):
                with self.subTest(retain_compiler=retain, target=target.name):
                    payload = self.payload(target)
                    self.output.mkdir(parents=True, exist_ok=True)   # 上一轮清理把 build/ 整个删了
                    link = self.output / "intermediate"
                    link.unlink(missing_ok=True)
                    link.symlink_to(target, target_is_directory=True)
                    library.prune_build(self.c, self.gid, retain_compiler=retain)
                    self.assertEqual(payload.read_bytes(), b"player data must survive")
                    self.assertFalse(link.is_symlink())

    def seed_root(self, root):
        (root / "ctl").mkdir(parents=True); (root / "programs/1").mkdir(parents=True); (root / "romfs").mkdir(); (root / ".stage_pkg").mkdir()
        for name in ("main.npdm", "main.fixups.tsv", "main.gates.tsv", "main.patched.bin", "icon.jpg", "romfs.s2aidx", "build.log", ".root_src", "ctl/control.nacp",
                     "programs/1/main.npdm", "programs/1/main.fixups.tsv", "programs/1/main.patched.bin", "romfs/huge.bin"):
            (root / name).write_bytes(name.encode())

    def test_container_kit_keeps_only_what_assembly_reads(self):
        root = self.root / "product"; self.seed_root(root)
        kit = library.save_container_kit(self.c, self.gid, root)
        self.assertEqual(sorted(str(p.relative_to(kit)) for p in kit.rglob("*") if p.is_file()),
                         sorted(["main.npdm", "main.fixups.tsv", "main.gates.tsv", "main.patched.bin", "icon.jpg", "romfs.s2aidx", "ctl/control.nacp",
                                 "programs/1/main.npdm", "programs/1/main.fixups.tsv", "programs/1/main.patched.bin"]))
        self.assertIsNone(library.save_container_kit(self.c, self.gid, self.root / "missing"))
        self.assertTrue((kit / "main.npdm").is_file())   # 产物根不完整时不动旧的

    def test_success_prune_removes_roots_and_unpack_but_keeps_delivery(self):
        root = self.output / "roots" / "k@pkg"; self.seed_root(root)
        image = layout.image_ios(self.c, self.gid)
        pack = image / "pack"; pack.mkdir(parents=True); (pack / "index.tsv").write_bytes(b"i"); (pack / "manifest.json").write_text("{}")
        (self.output / "logs").mkdir(); (self.output / "logs" / "refresh.log").write_text("l"); (self.output / "work").mkdir()
        unpacked = layout.build_dir(self.c, self.gid); (unpacked / "x").write_bytes(b"x")
        library.save_container_kit(self.c, self.gid, root)
        library.prune_build(self.c, self.gid)
        self.assertEqual(sorted(p.name for p in image.iterdir()), ["kit", "pack"])   # 交付件（容器件、资源包）在 image/ios，不动
        self.assertEqual(sorted(str(p.relative_to(unpacked)) for p in unpacked.rglob("*")), ["ios", "ios/logs", "ios/logs/refresh.log"])   # 解包、产物根、work 清掉，出包日志留

    def test_without_kit_prune_keeps_current_root(self):
        root = self.output / "roots" / "k@pkg"; self.seed_root(root)
        (self.output / "roots" / "k@现行").symlink_to("k@pkg")
        pack = layout.image_ios(self.c, self.gid) / "pack"; pack.mkdir(parents=True); (pack / "manifest.json").write_text("{}")   # 老玩家：有资源包没容器件
        library.prune_build(self.c, self.gid)
        self.assertTrue((self.output / "roots" / "k@pkg" / "main.npdm").is_file())

    def test_unlinks_file_and_dangling_links_without_following_them(self):
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        for target in (payload, self.root / "missing"):
            with self.subTest(target=target.name):
                link = self.output / "scratch"
                link.unlink(missing_ok=True)
                payload.write_bytes(b"player data must survive")
                link.symlink_to(target)
                library._rm(self.c, self.c.library, link)
                self.assertFalse(link.is_symlink())
                self.assertEqual(payload.read_bytes(), b"player data must survive")

    def test_refuses_a_symlink_in_an_ancestor(self):
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        link = self.output / "intermediate"
        link.symlink_to(payload.parent, target_is_directory=True)
        with self.assertRaises(Failure):
            library._rm(self.c, self.c.library, link / payload.name)
        self.assertEqual(payload.read_bytes(), b"player data must survive")

    def test_refuses_root_and_outside_entries_but_removes_ordinary_scratch(self):
        outside = self.payload(self.root / "outside")
        for path in (self.c.library, outside):
            with self.subTest(path=path.name), self.assertRaises(Failure):
                library._rm(self.c, self.c.library, path)
        scratch = self.payload(self.output / "scratch")
        library._rm(self.c, self.c.library, scratch.parent)
        self.assertFalse(scratch.parent.exists())
        self.assertEqual(outside.read_bytes(), b"player data must survive")

    @unittest.skipUnless(os.name == "nt", "Windows junction requires Windows")
    def test_junction_is_removed_without_deleting_its_target(self):
        payload = self.payload(layout.path(self.c, self.gid, "saves"))
        junction = self.output / "intermediate"
        subprocess.run(["cmd", "/c", "mklink", "/J", str(junction), str(payload.parent)],
                       check=True, capture_output=True)
        with self.assertRaises(Failure):
            library._rm(self.c, self.c.library, junction / payload.name)
        library.prune_build(self.c, self.gid)
        self.assertFalse(junction.exists())
        self.assertEqual(payload.read_bytes(), b"player data must survive")


if __name__ == "__main__":
    unittest.main()
