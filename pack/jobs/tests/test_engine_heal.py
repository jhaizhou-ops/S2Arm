# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#304：已装的内置引擎副本被外部改过（玩家机上宿主 S2ArmGame.app 的 Info.plist 大小和清单对不上，出包一直报 runtime_invalid）→
用前复核、对不上就从 App 包重解；App 包本身坏了才让玩家重装。期望按规则手写，夹具是合成的引擎包（含自成一库的 Git 快照）。"""
import hashlib
import json
import os
import subprocess
from pathlib import Path

from jobcase import JobCase

import embedded
from core import Context, Failure

PLIST = "Binaries/S2ArmGame.app/Contents/Info.plist"
EXE = "Binaries/S2ArmGame.app/Contents/MacOS/s2arm-host"


class EngineHealTests(JobCase):
    def setUp(self):
        super().setUp()
        self.bundle = self.root / "App.app/Contents/Resources/Engine"
        source = [(rel, b"") for rel in ("runtime/include/s2a_native.h", "runtime/rewriter/rewriter.c", "services/nxaot.sh", "pack/nx_unpack/nx_unpack.csproj",
                                         "graphics/tools/shader_pack.sh", "tools/safe_killpg.sh")]   # core.require_source 认的源码件（空文件即可）
        for rel, body in ((PLIST, b"<plist>original</plist>"), (EXE, b"\x7fhost"), ("pack/jobs/x.py", b"print(1)\n"), *source):
            (self.bundle / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.bundle / rel).write_bytes(body)
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        for args in (["init", "-q", "--template="], ["add", "pack"], ["commit", "-qm", "fixture"]):
            subprocess.run(["git", "-C", str(self.bundle), *args], env=env, check=True, stdout=subprocess.DEVNULL)
        files = {p.relative_to(self.bundle).as_posix(): [p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()]
                 for p in self.bundle.rglob("*") if p.is_file() and not p.is_symlink()}
        (self.bundle / "engine.json").write_text(json.dumps(dict(schema=1, id="e" * 64, files=files)))

    def context(self):
        self.sequence += 1
        return Context(dict(self.request, taskId=f"heal-{self.sequence}", operation="build", engineBundle=str(self.bundle)))

    def installed(self):
        c = self.context(); embedded.install(c)
        return c

    def test_size_changed_copy_is_reinstalled_on_next_job(self):
        c = self.installed()
        (c.engine / PLIST).write_bytes(b"<plist>rewritten by something else</plist>")   # 玩家机上的现象：大小变了
        c2 = self.installed()
        self.assertEqual((c2.engine / PLIST).read_bytes(), b"<plist>original</plist>")
        self.assertEqual(list(c2.engine.parent.glob("*.broken")), [])   # 坏副本挪开后删掉

    def test_same_size_rewrite_is_caught_by_artifact_digest(self):
        c = self.installed()
        (c.engine / PLIST).write_bytes(b"<plist>ORIGINAL</plist>")   # 同样大小、内容变了：快速复核看不出，用到产物时按摘要核
        self.assertEqual(embedded.artifact(c, "S2ArmGame.app"), c.engine / "Binaries/S2ArmGame.app")
        self.assertEqual((c.engine / PLIST).read_bytes(), b"<plist>original</plist>")

    def test_negative_control_copy_untouched_keeps_identity(self):
        c = self.installed()
        stamp = (c.engine / ".installed.json").stat().st_ino
        c2 = self.installed()
        self.assertEqual((c2.engine / ".installed.json").stat().st_ino, stamp)   # 副本没坏：不重解

    def test_git_use_in_installed_copy_is_not_damage(self):
        """出包流水线在已装副本里跑 git（commit 会改 .git/index、COMMIT_EDITMSG 等，它们也在清单里）：复核不能把它当成被改过、不重解"""
        c = self.installed()
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        (c.engine / "pack/jobs/stage.txt").write_text("stage\n")
        for args in (["add", "pack/jobs/stage.txt"], ["commit", "-qm", "a stage key commit with a long message"]):
            subprocess.run(["git", "-C", str(c.engine), *args], env=env, check=True, stdout=subprocess.DEVNULL)
        changed = [k for k, v in json.loads((c.engine / "engine.json").read_text())["files"].items()
                   if k.startswith(".git/") and (not (c.engine / k).is_file() or (c.engine / k).stat().st_size != v[0])]
        self.assertTrue(changed, "夹具要真的改到清单里的 .git 文件")   # 负对照的前提：确实有 .git 清单项变了
        stamp = (c.engine / ".installed.json").stat().st_ino
        c2 = self.installed()
        self.assertEqual((c2.engine / ".installed.json").stat().st_ino, stamp)   # 没重解
        self.assertTrue((c2.engine / "pack/jobs/stage.txt").is_file())

    def test_concurrent_jobs_install_same_copy_without_moving_each_other(self):
        """启动时几个作业同时初始化同一份副本（preflight + setup + catalog）：都成功、只留一份、没有作业把别人的挪走；随后同一份副本连用两次也不重解"""
        import concurrent.futures, sys
        script = (
            "import sys, json; sys.path.insert(0, sys.argv[1]); from core import Context; import embedded\n"
            "c = Context(json.loads(sys.argv[2])); embedded.install(c); embedded.artifact(c, 'S2ArmGame.app'); print('OK', c.engine)\n")
        def job(n):
            self.sequence += 1
            request = dict(self.request, taskId=f"race-{n}", operation="preflight", engineBundle=str(self.bundle))
            return subprocess.run([sys.executable, "-B", "-c", script, str(Path(embedded.__file__).parent), json.dumps(request)],
                                  capture_output=True, text=True, timeout=120)
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(job, range(4)))
        for r in results:
            self.assertEqual(r.returncode, 0, r.stdout[-800:] + r.stderr[-1500:])
        engine = embedded.engines_root(self.context()) / ("e" * 64)
        self.assertEqual(sorted(p.name for p in engine.parent.iterdir() if p.is_dir()), ["e" * 64])   # 没留 .partial / .broken
        stamp = (engine / ".installed.json").stat().st_ino
        for _ in range(2):   # 同一份副本连用两次（连出两次包的前半段）
            c = self.installed(); embedded.artifact(c, "S2ArmGame.app")
        self.assertEqual((engine / ".installed.json").stat().st_ino, stamp)

    def test_artifact_relocates_when_copy_vanished_mid_job(self):
        """本作业在用的副本被收走了（并发建库时发生过）：artifact 重新定位，不当成「没有内置产物」返回 None"""
        c = self.installed()
        os.rename(c.engine, c.engine.with_name("moved-away"))
        got = embedded.artifact(c, "S2ArmGame.app")
        self.assertIsNotNone(got)
        self.assertTrue((got / "Contents/Info.plist").is_file())

    def test_broken_app_bundle_asks_for_reinstall(self):
        c = self.installed()
        (c.engine / PLIST).write_bytes(b"x")
        (self.bundle / PLIST).write_bytes(b"also broken")   # App 包本身也坏了：重解没用
        with self.assertRaises(Failure) as e:
            self.installed()
        self.assertEqual(e.exception.code, "engine_incomplete")
        self.assertIn("重新安装完整的 S2Arm", str(e.exception))


class SharedHostHealTests(JobCase):
    """新布局的公共宿主 hosts/mac/<摘要>/S2ArmGame.app：已有的一份被改过（文件大小变了 / 少了文件）就从内置宿主重放，没变不动"""

    def setUp(self):
        super().setUp()
        self.app = self.root / "src/S2ArmGame.app"
        for rel, body in (("Contents/Info.plist", b"<plist/>"), ("Contents/MacOS/s2arm-host", b"\x7fhost"), ("Contents/MacOS/libs2a_vaguard.dylib", b"guard")):
            (self.app / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.app / rel).write_bytes(body)

    def test_changed_copy_is_replaced_untouched_copy_kept(self):
        import host_update
        sha = host_update.install_host(self.c, self.app)
        copy = host_update.layout.hosts_mac(self.c) / sha / "S2ArmGame.app"
        ino = (copy / "Contents/Info.plist").stat().st_ino
        self.assertEqual(host_update.install_host(self.c, self.app), sha)
        self.assertEqual((copy / "Contents/Info.plist").stat().st_ino, ino)   # 负对照：没变不重放
        (copy / "Contents/Info.plist").write_bytes(b"<plist>changed outside</plist>")
        (copy / "Contents/MacOS/libs2a_vaguard.dylib").unlink()
        self.assertEqual(host_update.install_host(self.c, self.app), sha)
        self.assertEqual((copy / "Contents/Info.plist").read_bytes(), b"<plist/>")
        self.assertTrue((copy / "Contents/MacOS/libs2a_vaguard.dylib").is_file())
