"""内置引擎 Git 快照（10-23 走查：复制丢了空目录 → .git 无效 → Git 往上认到用户主目录的仓库）：
- clone_tree 保留空目录；
- check_git：放在别的仓库里面、自己的 .git 缺 refs 目录时报错（改前会认到外层仓库）；完整快照通过。"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build import clone_tree  # noqa: E402
from core import Failure  # noqa: E402
from embedded import check_git  # noqa: E402

ENV = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def git(d, *a):
    subprocess.run(["git", "-C", str(d), *a], check=True, env=ENV, capture_output=True)


class EngineGit(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        git(self.t, "init", "-q")   # 外层仓库（模拟用户主目录是个仓库）
        self.src = self.t / "src"; (self.src / "runtime" / "rewriter").mkdir(parents=True)
        (self.src / "runtime" / "rewriter" / "a.py").write_text("x\n")
        git(self.src, "init", "-q", "--template="); git(self.src, "add", "-A"); git(self.src, "commit", "-qm", "s")
        git(self.src, "gc", "-q", "--prune=now")   # 同 bundle_engine.py：gc 后 refs/heads 为空目录

    def test_clone_keeps_empty_dirs_and_git_valid(self):
        self.assertTrue((self.src / ".git" / "refs" / "heads").is_dir())
        self.assertEqual(list((self.src / ".git" / "refs" / "heads").iterdir()), [])
        dst = self.t / "engines" / "e1"; dst.mkdir(parents=True)
        clone_tree(types.SimpleNamespace(check=lambda: None, progress=lambda *a: None), self.src, dst)
        self.assertTrue((dst / ".git" / "refs" / "heads").is_dir())
        check_git(dst)   # 不抛异常 = 认出的仓库就是自己的 .git
        out = subprocess.run(["git", "-C", str(dst), "rev-parse", "HEAD:runtime/rewriter"], capture_output=True, text=True, env=ENV)
        self.assertEqual(out.returncode, 0, out.stderr)

    def test_broken_snapshot_rejected_not_parent_repo(self):
        dst = self.t / "engines" / "e2"; dst.mkdir(parents=True)
        clone_tree(types.SimpleNamespace(check=lambda: None, progress=lambda *a: None), self.src, dst)
        for p in sorted((dst / ".git" / "refs").rglob("*"), reverse=True):
            p.rmdir() if p.is_dir() else p.unlink()
        (dst / ".git" / "refs").rmdir()   # 模拟改前：refs 目录丢了
        with self.assertRaises(Failure):
            check_git(dst)


if __name__ == "__main__":
    unittest.main()


class SnapshotIgnoresBuildOutputs(unittest.TestCase):
    """11-02 beta.3 走查：快照没带根 .gitignore，出包在副本里编出的 bin/ obj/ 被 pack/ipa.sh 的
    「git status --porcelain -- runtime ios graphics translator services compat Makefile」当成改动，玩家导出 iPhone 版死在最后一步。
    用真仓库的根 .gitignore 和 bundle_engine 的输入清单搭快照、造产物，期望那条检查看到的是空的；去掉 .gitignore 的反证要非空。"""
    ROOT = Path(__file__).resolve().parents[3]

    def snapshot(self, with_ignore):
        d = Path(tempfile.mkdtemp())
        (d / "graphics" / "widen").mkdir(parents=True); (d / "graphics" / "widen" / "a.cs").write_text("x\n")
        (d / "services" / "aot").mkdir(parents=True); (d / "services" / "aot" / "b.cs").write_text("y\n")
        if with_ignore:
            (d / ".gitignore").write_bytes((self.ROOT / ".gitignore").read_bytes())
        for a in (["init", "-q", "--template="], ["add", "--force", "--all"], ["commit", "-qm", "s"]):
            git(d, *a)
        for out in ("graphics/widen/bin/Release/x.dll", "graphics/widen/obj/project.assets.json", "services/aot/bin/y", "services/aot/obj/z"):
            (d / out).parent.mkdir(parents=True, exist_ok=True); (d / out).write_text("o\n")
        return subprocess.run(["git", "-C", str(d), "status", "--porcelain", "--", "runtime", "ios", "graphics", "translator", "services", "compat", "Makefile"],
                              env=ENV, capture_output=True, text=True, check=True).stdout

    def test_root_gitignore_is_an_engine_input(self):
        sys.path.insert(0, str(self.ROOT))
        from launchers.macos.bundle_engine import INPUTS
        self.assertIn(".gitignore", INPUTS)

    def test_build_outputs_do_not_count_as_changes(self):
        self.assertEqual(self.snapshot(True), "")
        self.assertIn("?? graphics/widen/bin/", self.snapshot(False))   # 反证：没有忽略规则就是旧的红

