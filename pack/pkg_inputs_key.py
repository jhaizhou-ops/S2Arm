#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""进包输入的内容键（pack/ipa_key.sh ipa_pkg_key 调；审计 P1-54）。

包里每样东西都要由包键覆盖，否则同一提交、同一产物根里换了它，ipa.sh 仍报「现行已是包」、装上旧包。
已由别处覆盖、这里不再读的：romfs / aoc（pack/resource_input_key.py 首尾抽样，与抽取 / 直连同一份）、
shaders/（着色器 / 直连库阶段键）、改写模块（改写阶段键）。其余一律按全内容：

  标准输入：资源包源清单（ipa_key.sh ipa_pkg_srcs，一行「包内路径=源路径」，与 pack.py 打包的是同一份）
  --file <名>=<路径>：包外进 App 的文件（随包表、图标、宽屏自动表）；路径不在记 none（不在也是一种输入）

→ 16 位十六进制。读不了就失败（不拿缺项的键当命中）。
"""
import hashlib
import os
import sys

COVERED = ('romfs', 'aoc')   # 资源抽样键已覆盖
COVERED_PREFIX = ('shaders/',)   # 着色器 / 直连库阶段键已覆盖


def content_keyed(dest):
    """资源包源清单里这一项（包内路径 / 前缀，如 systemdata、romfs.s2aidx）按全内容进包键 → True。
    pack.py / verify.py 对这类文件不按「大小 + 修改时间」沿用上一版的克隆与核对（审计 #1534 P1-54）：键按内容变了，包里也必须按内容换；
    它们合计几十 MB（11-05 马车8 产物根：系统数据 711 个 22.6 MB，另几个各不到 1 MB），每次按内容核的成本可忽略。romfs / aoc / shaders/ 不在此列（几 GB 到十几 GB，键另有来源）"""
    return not (dest in COVERED or dest.startswith(COVERED_PREFIX))


def feed(h, label, path):
    h.update(label.encode() + b'\0')
    if not os.path.lexists(path):
        h.update(b'none\0'); return
    if os.path.isdir(path):
        for dp, dn, fn in os.walk(path):
            dn.sort()
            for f in sorted(fn):
                p = os.path.join(dp, f)
                h.update(os.path.relpath(p, path).encode() + b'\0')
                file_digest(h, p)
        h.update(b'end\0'); return
    file_digest(h, path)


def file_digest(h, path):
    d = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): d.update(b)
    h.update(d.digest())


def main():
    h = hashlib.sha256(b's2arm-pkg-inputs-v1\0')
    for ln in sys.stdin.read().splitlines():
        if not ln: continue
        dest, _, src = ln.partition('=')
        if not content_keyed(dest): continue
        feed(h, 'src:' + dest, src)
    a = sys.argv[1:]
    while a:
        if a[0] != '--file' or len(a) < 2 or '=' not in a[1]: sys.exit('用法：pkg_inputs_key.py [--file <名>=<路径>]… < 源清单')
        name, _, path = a[1].partition('='); feed(h, 'file:' + name, path); a = a[2:]
    print(h.hexdigest()[:16])


if __name__ == '__main__':
    main()
