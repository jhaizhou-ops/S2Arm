# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包空间按实测（11-07）：实测记账口径、预算三档依据、拦截文案、「仍然继续」放行。全为合成文件，期望值手算。"""
import collections
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from jobcase import JobCase, ROOT
from core import Context, Failure
import library

sys.path.insert(0, str(ROOT))
from pack.contracts.validate import validate, ContractError

MIB = 1 << 20
GID = "01007EF00011E000"
DU = collections.namedtuple("du", "total used free")


def write(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(size))   # 随机内容：不让文件系统压缩 / 稀疏，1 MiB 就占 1 MiB 块
    return path


class SpaceMeasured(JobCase):
    def setUp(self):
        super().setUp()
        env = patch.dict(os.environ, {"S2A_DUAL": "1"})   # 直连缺省开（Context 建时固定）；实测账按直连与否分
        env.start(); self.addCleanup(env.stop)

    def context(self, operation="ipa", **extra):
        self.sequence += 1
        return Context(self.request | dict(taskId=f"space-{self.sequence}", operation=operation, gameId=GID) | extra)

    def game(self, size, gid=GID, name="塞尔达传说 旷野之息"):
        pkg = dict(titleId=gid, baseId=gid, type="base", version=0, path="sources/x.nsp", sha256=gid.lower() * 4, size=size, guestIsa="aarch64")
        return dict(id=gid, name=name, packages=[pkg])

    def ledger(self, *rows):
        # time gameId target direct inputBytes footprintBytes name
        with (self.c.library / library.SPACE_LEDGER).open("a", encoding="utf-8") as f:
            for r in rows:
                f.write("\t".join(map(str, r)) + "\n")

    def budget(self, c, game, free=45 * 10**9):
        with patch("shutil.disk_usage", return_value=DU(0, 0, free)), patch.dict(os.environ, {"S2A_DUAL": "1"}):
            return library.space_budget(c, game)["volumes"][0]

    # —— 实测记账口径 ——
    def test_disk_bytes_counts_hardlink_once_skips_symlink_and_other_volume(self):
        root = self.root / "measure"
        a = write(root / "a.bin", MIB)
        base = library.disk_bytes([root], root.stat().st_dev)
        self.assertGreaterEqual(base, MIB); self.assertLess(base, MIB + 64 * 1024)   # 1 MiB 文件 + 目录元数据（APFS 目录 0 块）
        (root / "sub").mkdir()
        os.link(a, root / "sub" / "a-link.bin")
        (root / "a-sym.bin").symlink_to(a)
        sub = library.disk_bytes([root], root.stat().st_dev) - base   # 硬链接 + 软链：数据不重复算，只多一个子目录的元数据
        self.assertLess(sub, 64 * 1024)
        write(root / "b.bin", MIB)
        self.assertEqual(library.disk_bytes([root], root.stat().st_dev) - base - sub, MIB)   # 新增一份真数据 = 正好 1 MiB
        self.assertEqual(library.disk_bytes([root, root / "sub", a], root.stat().st_dev), base + sub + MIB)   # 根互相包含也只算一次
        self.assertEqual(library.disk_bytes([root], root.stat().st_dev + 1), 0)   # 别的卷上的不算

    def test_record_measures_library_dirs_before_prune(self):
        # 打 iPhone 包成功后的自动清理（prune_build）先记一行：要清掉的中间产物也算进去（量的是峰值，不是清完剩下的）
        c = self.context("ipa")
        game = self.game(10 * 10**9)
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=[game]))
        extract = write(self.c.library / "cache" / GID / "extract" / "romfs.bin", MIB)
        write(self.c.library / "iPhone" / GID / "junk.tmp", 2 * MIB)   # 成功后会被清掉的中间产物
        (self.c.library / "iPhone" / GID / "roots" / "r@1").mkdir(parents=True)
        os.link(extract, self.c.library / "iPhone" / GID / "roots" / "r@1" / "romfs.bin")   # 产物根硬链解包：不重复算
        write(self.c.library / "runtime-cache" / GID / "play.bin", MIB)   # 玩的时候才长的运行时缓存：不算
        write(self.c.library / "iPhone" / "0100000000000001" / "other.bin", MIB)   # 别款：不算
        library.prune_build(c, GID)
        self.assertFalse((self.c.library / "iPhone" / GID / "junk.tmp").exists())   # 清理照常
        rows = library._space_rows(self.c.library)
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r["gameId"], r["target"], r["direct"], r["inputBytes"], r["name"]), (GID, "ipa", "1", str(10 * 10**9), "塞尔达传说 旷野之息"))
        fp = int(r["footprintBytes"])
        self.assertGreaterEqual(fp, 3 * MIB); self.assertLess(fp, 3 * MIB + 64 * 1024)   # 1 MiB 解包（硬链接那份不重算）+ 2 MiB 中间产物
        self.assertTrue((self.c.library / library.SPACE_LEDGER).read_text(encoding="utf-8").startswith("# time\tgameId"))

    # —— 预算三档依据 ——
    def test_rule_when_no_measurement(self):
        v = self.budget(self.context("ipa"), self.game(16 * 10**9))
        rule = 16 * 10**9 * 2 + (10 << 30) + int(4.0e9 * 16e9 / 10.7e9)   # 旷野之息约 16 GB：经验门槛 48.7 GB
        self.assertEqual((v["basis"], v["needBytes"], v["enough"]), ("rule", rule, False))

    def test_same_game_measurement_scaled_with_margin(self):
        c = self.context("ipa")
        self.ledger(("2026-11-06T10:00:00", GID, "ipa", "1", 16 * 10**9, 30 * 10**9, "旧"),
                    ("2026-11-07T10:00:00", GID, "ipa", "1", 16 * 10**9, 20 * 10**9, "旷野之息"),   # 同款最后一行为准
                    ("2026-11-07T11:00:00", GID, "mac", "1", 16 * 10**9, 90 * 10**9, "旷野之息"),   # 目标不同：不用
                    ("2026-11-07T12:00:00", GID, "ipa", "0", 16 * 10**9, 90 * 10**9, "旷野之息"))   # 直连与否不同：不用
        v = self.budget(c, self.game(16 * 10**9))
        self.assertEqual((v["basis"], v["source"], v["measuredBytes"], v["existingBytes"], v["needBytes"], v["enough"]),
                         ("measured", "same", 20 * 10**9, 0, 22 * 10**9, True))
        self.assertIn("本款上次实测", v["note"])
        # 选的包变大（多了更新）：按输入大小等比换算 20 × 24/16 = 30 GB
        v = self.budget(c, self.game(24 * 10**9))
        self.assertEqual((v["measuredBytes"], v["needBytes"]), (30 * 10**9, 33 * 10**9))
        # 本款已在盘上的（上次失败留下的解包）从需要里扣掉
        write(self.c.library / "cache" / GID / "extract" / "x.bin", MIB)
        v = self.budget(c, self.game(16 * 10**9))
        self.assertGreaterEqual(v["existingBytes"], MIB)
        self.assertEqual(v["needBytes"], 22 * 10**9 - v["existingBytes"])

    def test_band_measurement_from_other_game(self):
        c = self.context("ipa")
        self.ledger(("2026-11-07T09:00:00", "0100000000000AAA", "ipa", "1", 12 * 10**9, 18 * 10**9, "同档款"),   # 11.2 GiB：8–16 档
                    ("2026-11-07T10:00:00", "0100000000000BBB", "ipa", "1", 40 * 10**9, 40 * 10**9, "大款"))     # 37 GiB：32–64 档，不用
        v = self.budget(c, self.game(10 * 10**9))   # 9.3 GiB：8–16 档
        self.assertEqual((v["basis"], v["source"], v["sourceGameId"], v["measuredBytes"], v["needBytes"]),
                         ("measured", "band", "0100000000000AAA", 15 * 10**9, int(15e9 * 1.1)))
        self.assertIn("8–16 GB", v["note"]); self.assertIn("《同档款》", v["note"])
        v = self.budget(c, self.game(1 * 10**9))   # 0.93 GiB：<2 档没有实测 → 经验规则
        self.assertEqual(v["basis"], "rule")

    # —— 拦截文案含依据 ——
    def test_rejection_names_need_basis_and_free(self):
        game = self.game(16 * 10**9)
        cases = (((), "依据：经验规则估算", "要 49 GB"),
                 ((("2026-11-07T10:00:00", GID, "ipa", "1", 16 * 10**9, 50 * 10**9, "旷野之息"),), "依据：这款游戏上次在这个游戏库实测整套约 50 GB、加 1 成余量", "要 55 GB"),
                 ((("2026-11-07T10:00:00", "0100000000000AAA", "ipa", "1", 12 * 10**9, 39 * 10**9, "同档款"),), "依据：同大小档别的游戏实测按比例换算整套约 52 GB", "要 57 GB"))
        for rows, basis, need in cases:
            with self.subTest(basis=basis):
                (self.c.library / library.SPACE_LEDGER).unlink(missing_ok=True)
                self.ledger(*rows)
                with patch("shutil.disk_usage", return_value=DU(0, 0, 45 * 10**9)), patch.dict(os.environ, {"S2A_DUAL": "1"}):
                    with self.assertRaises(Failure) as e:
                        library.check_pack_space(self.context("ipa"), game)
                text = str(e.exception)
                self.assertEqual(e.exception.code, "disk_full")
                self.assertIn(basis, text); self.assertIn(need, text); self.assertIn("只剩 45 GB", text); self.assertIn("「仍然继续」", text)

    # —— 「仍然继续」——
    def test_space_override_passes_with_warning(self):
        c = self.context("ipa", spaceOverride=True)
        with patch("shutil.disk_usage", return_value=DU(0, 0, 45 * 10**9)), patch.dict(os.environ, {"S2A_DUAL": "1"}):
            budget = library.check_pack_space(c, self.game(16 * 10**9))
        self.assertTrue(budget["override"]); self.assertFalse(budget["volumes"][0]["enough"])
        [d] = c.job["diagnostics"]
        self.assertEqual((d["code"], d["severity"]), ("disk_full", "warning"))
        self.assertIn("已按你的选择仍然继续", d["summary"])
        self.assertTrue(json.loads(c.jobpath.read_text())["space"]["override"])
        # 空间够时带了也不发警告、不标 override
        c = self.context("ipa", spaceOverride=True)
        with patch("shutil.disk_usage", return_value=DU(0, 0, 100 * 10**9)), patch.dict(os.environ, {"S2A_DUAL": "1"}):
            budget = library.check_pack_space(c, self.game(16 * 10**9))
        self.assertNotIn("override", budget); self.assertEqual(c.job["diagnostics"], [])

    def test_space_override_request_contract(self):
        self.context("build", spaceOverride=True); self.context("ipa", spaceOverride=False)
        for op, value in (("catalog", True), ("ipa", "true"), ("build", 1), ("launch", True)):
            with self.subTest(op=op, value=value), self.assertRaises(Failure):
                self.context(op, spaceOverride=value)
        base = dict(schema=1, contract="s2a.job-request.v1", privateRoot="/p", library="/l", libraryId="x", gameId=GID)
        validate("request", base | dict(operation="build", spaceOverride=True))
        validate("request", base | dict(operation="ipa", spaceOverride=False))
        for bad in (dict(operation="catalog", spaceOverride=True), dict(operation="ipa", spaceOverride="true")):
            with self.subTest(bad=bad), self.assertRaises(ContractError):
                validate("request", base | bad)


if __name__ == "__main__":
    unittest.main()
