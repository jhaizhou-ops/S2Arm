#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""android/ 下 README 引用的 Markdown 文件必须在仓库里。

查 Markdown 相对链接和行内代码里形如 a/b.md 的路径，按「相对 README」或「相对仓库根」找；
只查 .md：其他类型的路径可能是构建产物或运行时路径。
用法：readme_links.py [仓库根]；有悬空引用时逐条打印、退出 1。
"""
import os
import re
import subprocess
import sys

LINK = re.compile(r'!?\[[^\]]*\]\(([^)\s]+)\)')
CODE = re.compile(r'`([^`\s]+/[^`\s]*\.md)(?:#[^`\s]*)?`')


def targets(text):
    without_fences = re.sub(r'```.*?```', '', text, flags=re.DOTALL)
    for match in LINK.finditer(without_fences):
        target = match.group(1)
        if not re.match(r'[a-z][a-z0-9+.-]*:', target) and not target.startswith('#'):
            yield target.split('#', 1)[0]
    for match in CODE.finditer(without_fences):
        yield match.group(1)


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
    listed = subprocess.run(['git', '-C', root, 'ls-files', '-z', 'android'], capture_output=True, text=True, check=True).stdout
    readmes = [f for f in listed.split('\0') if re.match(r'README[^/]*\.md$', os.path.basename(f))]
    dead = checked = 0
    for readme in readmes:
        with open(os.path.join(root, readme), encoding='utf-8') as handle:
            text = handle.read()
        for target in targets(text):
            checked += 1
            candidates = (os.path.join(root, os.path.dirname(readme), target), os.path.join(root, target))
            if not any(os.path.exists(path) for path in candidates):
                print(f'悬空引用 {readme}: {target}')
                dead += 1
    print(f'android README 引用检查：期望 0 处悬空 → 真结果 {dead} 处（{len(readmes)} 份 README，{checked} 条引用）')
    return 1 if dead else 0


if __name__ == '__main__':
    sys.exit(main())
