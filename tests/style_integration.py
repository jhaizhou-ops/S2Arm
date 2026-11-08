#!/usr/bin/env python3
# 门禁手动：要联网装的工具：build/style-venv 由 make style-setup 联网安装；按 docs/standards/style.md 门禁不调用，手动 bash tools/style_verify.sh
"""Exercise actual formatters and index checks using existing repository source."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import style  # noqa: E402


def execute(args, env=None, source=None, expected=0):
    result = subprocess.run(args, cwd=ROOT, env=env, input=source, capture_output=True)
    if result.returncode != expected:
        raise AssertionError(
            f"{' '.join(map(str, args))}: expected {expected}, got {result.returncode}\n"
            + result.stdout.decode("utf-8")
            + result.stderr.decode("utf-8")
        )
    return result.stdout


def main():
    style.check_tools()
    sources = [
        "runtime/src/logcon.c",
        "ios/app.m",
        "services/S2A.Services/Red.cs",
        "tools/game_fps.py",
        "tools/cost_log.sh",
    ]
    for path in sources:
        original = (ROOT / path).read_bytes()
        formatted = style.format_source(path, original)
        if not formatted or style.format_source(path, formatted) != formatted:
            raise AssertionError(f"formatter is not idempotent: {path}")
        if (ROOT / path).read_bytes() != original:
            raise AssertionError(f"formatter changed the source during read-only check: {path}")
    print("Actual C, Objective-C, C#, Python and Shell formatters: idempotent, sources unchanged")

    with tempfile.TemporaryDirectory(prefix="s2arm-style-index-") as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        tree = execute(["git", "write-tree"]).decode().strip()
        execute(["git", "read-tree", tree], env)
        original_path = "tools/game_fps.py"
        destination = "tools/style integration source.py"
        original = execute(["git", "show", f":{original_path}"])
        oid = execute(["git", "hash-object", "-w", "--stdin"], source=original).decode().strip()
        execute(["git", "update-index", "--add", "--cacheinfo", "100644", oid, destination], env)
        command = [sys.executable, "tools/style.py", "check", "--staged", "--files", destination]
        expected = int(style.format_source(destination, original) != original)
        output = execute(command, env, expected=expected).decode()
        if "style check: 1 selected files" not in output:
            raise AssertionError("new staged source must be checked even without a working file")

        execute(["git", "update-index", "--force-remove", original_path], env)
        execute(command, env)
        print("Real Git index: spaces, absent working file and rename baseline verified")

        execute([sys.executable, "tools/check_log_schema.py", "--staged"], env, expected=1)
        execute(["git", "update-index", "--add", "--cacheinfo", "100644", oid, original_path], env)
        execute(["git", "update-index", "--force-remove", destination], env)
        print("Staged event references detect a removed source despite its working copy")

        execute(["git", "update-index", "--force-remove", "docs/standards/style.md"], env)
        result = subprocess.run(
            [sys.executable, "tools/style.py", "lint", "--staged", "--files", "README.md"],
            cwd=ROOT,
            env=env,
            capture_output=True,
        )
        if result.returncode != 1 or b"MDLINK" not in result.stderr:
            raise AssertionError("staged Markdown links must use the index, not working files")
        print("Staged Markdown target deletion detected while working target still exists")
    print("Engineering standards integration checks passed")


if __name__ == "__main__":
    main()
