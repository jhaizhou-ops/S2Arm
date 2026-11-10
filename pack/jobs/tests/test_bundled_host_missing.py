#!/usr/bin/env python3
"""发版应用的内置宿主缺失不吞成现场编（审计 P2-196）：
   发版运行时（Runtime/versions.json runtimeSchema 4）+ 引擎清单 engine.json 里没有 Binaries/S2ArmGame.app → env() 抛「请重新安装完整应用」；
   源码树（引擎目录没有 engine.json）→ 不抛、不设 S2A_BUNDLED_HOST（按需现编，反证）。期望手写。新用例单独成文件（公用大测试文件合入时互相冲突）。"""
import json
import unittest
import unittest.mock as um

import test_jobs
from core import Failure


class BundledHostMissing(unittest.TestCase):
    setUp, tearDown = test_jobs.JobsTests.setUp, test_jobs.JobsTests.tearDown

    def release_app(self):
        res = self.root / "res"; (res / "Runtime").mkdir(parents=True)
        (res / "Runtime/versions.json").write_text(json.dumps({"runtimeSchema": 4}))
        self.c.r.update(resources=str(res))
        engine = self.root / "engine"; engine.mkdir()
        return engine

    def test_manifest_without_host_is_reinstall(self):
        engine = self.release_app()
        (engine / "engine.json").write_text(json.dumps({"files": {"Binaries/Other/x": "00"}}))
        with um.patch.object(self.c, "engine", engine), self.assertRaises(Failure) as e:
            self.c.env()
        self.assertIn("重新安装完整应用", str(e.exception))

    def test_source_tree_has_no_bundled_host(self):
        engine = self.release_app()
        with um.patch.object(self.c, "engine", engine):
            env = self.c.env()
        self.assertNotIn("S2A_BUNDLED_HOST", env)


if __name__ == "__main__":
    unittest.main()
