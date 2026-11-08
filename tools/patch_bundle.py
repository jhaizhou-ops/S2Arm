#!/usr/bin/env python3
"""补丁库随启动器发版（补丁包部署方案 v2，满屏补丁线 11-04；jhz：每款补丁随启动器下发、真机验过才开）。
  patch_bundle.py <补丁库目录> <输出目录>
补丁库 = <程序号 16 位>/patch.tsv（本机补丁库，不进仓库）。只收文件头（第一个「[段]」之前）有 verified_builds（空格分隔的 32 位构建号）的补丁——
真机验收过至少一个构建号；出包时 pack/stage_rewrite.sh 再按本包构建号核一次（pack/ipa_key.sh ipa_patch_ship），对不上的构建不随包。
输出：<输出目录>/<程序号>/patch.tsv + INDEX.tsv（程序号 / 已验构建号 / sha256），INDEX.tsv 总会写（空库也写表头：启动器按它在不在判有没有补丁库）。
程序号目录名与文件头 program 不一致、verified_builds 里有不是 32 位十六进制的 → 报红退出 1（不悄悄收坏补丁）。
标准输出最后一行：「补丁库：收 N 款，跳过 M 款（没验过）」"""
import hashlib, os, re, shutil, sys

HEX32 = re.compile(r'^[0-9a-fA-F]{32}$')


def header(path):
    h = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\r\n')
            if line.startswith('['): break
            if not line or line.startswith('#') or '\t' not in line: continue
            k, v = line.split('\t', 1); h[k] = v.split('#', 1)[0].strip()
    return h


def bundle(src, dst):
    """→ (收的程序号列表, 跳过的程序号列表)；坏补丁抛 ValueError"""
    if os.path.isdir(dst): shutil.rmtree(dst)
    os.makedirs(dst)
    took, skipped, rows = [], [], []
    for pid in sorted(os.listdir(src)):
        p = os.path.join(src, pid, 'patch.tsv')
        if not (re.fullmatch(r'[0-9A-Fa-f]{16}', pid) and os.path.isfile(p)): continue
        h = header(p)
        vb = h.get('verified_builds', '').split()
        if not vb: skipped.append(pid.upper()); continue
        if h.get('program', '').upper() != pid.upper(): raise ValueError(f'{p}：文件头 program「{h.get("program", "")}」与目录名 {pid} 不一致')
        bad = [b for b in vb if not HEX32.match(b)]
        if bad: raise ValueError(f'{p}：verified_builds 里有不是 32 位构建号的「{" ".join(bad)}」')
        os.makedirs(os.path.join(dst, pid.upper()))
        shutil.copyfile(p, os.path.join(dst, pid.upper(), 'patch.tsv'))
        rows.append((pid.upper(), ' '.join(b.lower() for b in vb), hashlib.sha256(open(p, 'rb').read()).hexdigest()))
        took.append(pid.upper())
    with open(os.path.join(dst, 'INDEX.tsv'), 'w', encoding='utf-8') as f:
        f.write('程序号\t已验构建号\tsha256\n')
        for r in rows: f.write('\t'.join(r) + '\n')
    return took, skipped


if __name__ == '__main__':
    if len(sys.argv) != 3: print(__doc__.strip().splitlines()[0]); sys.exit(2)
    try: t, s = bundle(sys.argv[1], sys.argv[2])
    except ValueError as e: print(f'【红】{e}'); sys.exit(1)
    print(f'补丁库：收 {len(t)} 款，跳过 {len(s)} 款（没验过）')
