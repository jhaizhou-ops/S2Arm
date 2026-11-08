#!/usr/bin/env python3
"""壳输入闭包（pack/shell/closure.py）单测：临时 git 仓库、真读文件，期望按规则手写。
① mark 后只读 a.c → observed 恰好 [src/a.c]（git 命令读的 .gitignore 不算：observed 不调 git）
② 表登记目录 src → a.c 被覆盖、check 退 0；再读表外的 docs/x.md → check 退 1、点名 docs/x.md
③ 「外」登记的文件被读 → 不算漏
④ 全量重读（模拟 git status：读遍全部文件）→ 打黄、退 0（核不了不判）
⑤ suggest：目录里被读 ≥ 80% → 收成目录一行；不足 → 逐个文件
"""
import os, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "pack/shell/closure.py"


class Closure(unittest.TestCase):
    def setUp(self):
        self.r = Path(tempfile.mkdtemp())
        files = {"src/a.c": "a", "src/b.c": "b", "src/c.h": "c", "src/d.c": "d", "src/e.c": "e", "docs/x.md": "x", "docs/y.md": "y", "Makefile": "m",
                 ".gitignore": "*.o\n", ".gitattributes": "* -text\n", "pack/stage_inputs/shell.tsv": "入\tsrc\n入\tMakefile\n外\tdocs/y.md\n"}
        for p, b in files.items():
            (self.r / p).parent.mkdir(parents=True, exist_ok=True); (self.r / p).write_text(b)
        subprocess.run(["git", "-C", str(self.r), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(self.r), "add", "-A"], check=True)

    def run_tool(self, *a):
        return subprocess.run([sys.executable, str(TOOL), *a, str(self.r)], capture_output=True, text=True)

    def read(self, *ps):
        for p in ps: (self.r / p).read_bytes()

    def test_closure(self):
        self.assertEqual(self.run_tool("mark").returncode, 0)
        self.read("src/a.c")
        self.assertEqual(self.run_tool("observed").stdout.split(), ["src/a.c"])                     # ①
        self.assertEqual(self.run_tool("check").returncode, 0)                                     # ②
        self.read("docs/y.md"); self.assertEqual(self.run_tool("check").returncode, 0)             # ③
        self.read("docs/x.md"); r = self.run_tool("check")
        self.assertEqual(r.returncode, 1); self.assertIn("docs/x.md", r.stderr)                    # ②
        self.read(*[str(p.relative_to(self.r)) for p in self.r.rglob("*") if p.is_file() and ".git" not in p.parts])
        r = self.run_tool("check"); self.assertEqual(r.returncode, 0); self.assertIn("核不了", r.stderr)   # ④

    def test_git_status_after_mark_reads_nothing(self):
        # 11-07：刚 git add 的仓库条目全是 racily clean（文件与索引同一秒写）；mark 后跑全树 git status（出壳子进程设 core.trustctime=false）
        #   原先会重读这些文件、被闭包当成「出壳读到」；mark 先刷索引后 → 一个都不读
        self.assertEqual(self.run_tool("mark").returncode, 0)
        subprocess.run(["git", "-c", "core.trustctime=false", "-C", str(self.r), "status", "--porcelain"], capture_output=True, check=True)
        self.assertEqual(self.run_tool("observed").stdout, "")

    def test_git_attribute_rules_not_counted(self):
        # 11-07：git 自己读的 .gitattributes 不算出壳读入（同 .gitignore），否则出壳被判「读到表外文件」删壳
        self.assertEqual(self.run_tool("mark").returncode, 0)
        self.read(".gitattributes", "src/a.c")
        r = self.run_tool("check")
        self.assertEqual(r.returncode, 0, r.stderr); self.assertNotIn(".gitattributes", r.stderr)

    def test_suggest(self):
        self.run_tool("mark"); self.read("src/a.c", "src/b.c", "src/c.h", "src/d.c", "docs/x.md")
        rows = self.run_tool("suggest").stdout.split("\n")
        self.assertIn("入\tsrc", rows)          # 4/5 = 80%
        self.assertIn("入\tdocs/x.md", rows)    # 1/2 < 80%
        self.assertNotIn("入\tdocs", rows)



class MakeArgs(unittest.TestCase):
    """pack/shell_build.sh 开了 set -u：交给 make 的参数里引用的变量必须先在脚本里赋过值。
    11-07 c445f1bd5 把「S2A_SHELLUI=$SHELLUI IOS_BUNDLE=…」写成「S2A_SHELLUI=$SHELLUIIOS_BUNDLE=…」，一跑就 unbound variable 退出、出不了壳，
    门禁里没有任何用例走到这一行（真机验收才撞到）。这里静态核：make 行引用的每个变量，在它之前都有赋值（或来自 tools/cores.sh 的 S2A_JOBS）。"""
    def test_make_lines_only_use_assigned_vars(self):
        import re
        lines = (ROOT / "pack/shell_build.sh").read_text().splitlines()
        assigned, bad, seen_make = {"S2A_JOBS"}, [], 0
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("#"):
                continue
            if '"$MK"' in line:
                seen_make += 1
                for v in re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", line):
                    if v not in assigned:
                        bad.append(f"第 {n} 行 ${v}")
            for v in re.findall(r"(?:^|[\s;({])([A-Za-z_][A-Za-z0-9_]*)=", line):
                assigned.add(v)
        self.assertGreater(seen_make, 0, "shell_build.sh 里找不到 make 行")
        self.assertEqual(bad, [], "make 行引用了没赋过值的变量（set -u 下直接退出）")

if __name__ == "__main__":
    unittest.main()
