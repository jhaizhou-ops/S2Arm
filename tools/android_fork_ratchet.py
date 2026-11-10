#!/usr/bin/env python3
"""安卓直连回放层分叉计数（只打印、不拦合入），建议见 android/AGENTS.md 第 3 节。
安卓回放层（android/native/nvn、android/native/direct）是 iOS nvn_mtl.m 的平行实现，收敛设计见
docs/设计_回放核心共用.md（D0–D9）。下面四项计数给评审看分叉是涨是降；维护方口径（#71）：共用层成形前不用硬门禁强制，所以永远退出 0。
  compat_macros  android/native/nvn/nvn_be_compat.h 的 #define（mtl_* → nvn_be_* 转接宏）
  op_cases       android/native/** 里的 `case OP_` 分支（安卓侧另写的命令解码）
  mtl_defs       android/native/** 里以 mtl_ 命名的函数定义（安卓侧新增的回放层入口）
  shared_android graphics/nvn/gfx/nvn/** 与 runtime/src/** 里的 __ANDROID__（共用文件里的平台分支）
都不计 // 注释。用法：python3 tools/android_fork_ratchet.py [--write-baseline]；比基线涨了打印「提示」并点名文件，仍退出 0。"""
import json, os, re, sys

R = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
BASELINE = os.path.join(R, 'tools', 'android_fork_baseline.json')
SRC = ('.c', '.h', '.inc', '.cpp', '.m')
OP = re.compile(r'\bcase\s+OP_')
MTL_DEF = re.compile(r'^[A-Za-z_][\w \*]*\bmtl_\w+\s*\([^;]*$')
ANDROID = re.compile(r'__ANDROID__')

def files(*roots):
    for root in roots:
        for dp, dn, fn in os.walk(os.path.join(R, root)):
            dn[:] = sorted(d for d in dn if d not in ('tests', 'third_party'))
            for f in sorted(fn):
                if f.endswith(SRC): yield os.path.relpath(os.path.join(dp, f), R)

def lines(rel):
    with open(os.path.join(R, rel), encoding='utf-8', errors='replace') as fh:
        return [l.split('//', 1)[0] for l in fh]

def count(paths, pat):
    per = {}
    for p in paths:
        n = sum(1 for l in lines(p) if pat.search(l))
        if n: per[p] = n
    return per

def measure():
    nvn = 'android/native/nvn/nvn_be_compat.h'
    andr = list(files('android/native'))
    return {
        'compat_macros': {nvn: sum(1 for l in lines(nvn) if l.startswith('#define'))} if os.path.exists(os.path.join(R, nvn)) else {},
        'op_cases': count(andr, OP),
        'mtl_defs': count(andr, MTL_DEF),
        'shared_android': count(list(files('graphics/nvn/gfx/nvn', 'runtime/src')), ANDROID),
    }

def main():
    m = measure()
    if '--write-baseline' in sys.argv:
        with open(BASELINE, 'w', encoding='utf-8') as fh:
            json.dump({k: {'total': sum(v.values()), 'files': v} for k, v in m.items()}, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write('\n')
        print('已写基线', os.path.relpath(BASELINE, R)); return 0
    base = json.load(open(BASELINE, encoding='utf-8'))
    for k, v in m.items():
        now, was = sum(v.values()), base.get(k, {}).get('total', 0)
        if now > was:
            grew = [f'{f} {n}（基线 {base[k]["files"].get(f, 0)}）' for f, n in v.items() if n > base.get(k, {}).get('files', {}).get(f, 0)]
            print(f'提示 {k}：{now} > 基线 {was}（+{now - was}）；涨在：' + '；'.join(grew) + '。不拦合入；若是安卓侧新增的回放层机制，PR 里说明为什么不能做到共用层（android/AGENTS.md 第 3 节）')
        else:
            print(f'计数 {k}：{now}（基线 {was}' + (f'，-{was - now}；可同笔改小基线：python3 tools/android_fork_ratchet.py --write-baseline' if now < was else '') + '）')
    return 0

if __name__ == '__main__':
    sys.exit(main())
