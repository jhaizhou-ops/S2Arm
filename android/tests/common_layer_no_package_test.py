#!/usr/bin/env python3
"""通用层零专用配置（#1357）：android/native、native、gfx 的源码里不得出现
具体游戏包名 `org.s2arm.game.t`。落盘目录必须由 Java 侧按当前应用传入，native 只拼文件名。

测试夹具 / 文档里的包名不在本检查范围（那些是契约样例，不是运行时代码）。
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIRS = ("android/native", "runtime", "ios", "graphics", "translator")
SUFFIXES = {".c", ".h", ".cc", ".cpp", ".cxx", ".inc", ".s", ".m", ".mm"}
NEEDLE = "org.s2arm.game.t"


def main():
    hits = []
    for name in DIRS:
        for path in sorted((ROOT / name).rglob("*")):
            if path.suffix.lower() not in SUFFIXES or not path.is_file():
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if NEEDLE in line:
                    hits.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
    if hits:
        print("【红】通用层源码出现具体游戏包名 " + NEEDLE + "：")
        print("\n".join(hits))
        return 1
    print("通用层源码无具体游戏包名（检查 %s）" % ", ".join(DIRS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
