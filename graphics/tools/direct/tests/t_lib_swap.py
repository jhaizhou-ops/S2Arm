#!/usr/bin/env python3
# 直连库发布核验单测（C# LibPack.Publish：CheckNames 齐全判定 + SdkCheckItems 发布目标 -sdk + 打容器 + ps_inputs.tsv / keys.tsv，graphics/tools/direct/dsh/batch/LibPack.cs，
#   经 dsh_batch --libpack <输入目录> <输出目录> <链号> <mac|ios> [--no-mac-lib] 调；11-01 出库链挪进 C#，原 lib_swap.py / ps_inputs.py 随之删除）。期望按规则手写：
#   齐全判定的反例逐条造（Mac 缺 .metal / Mac 缺 .json / iOS 缺 .json / 两边键集不同 / 空库；只出 iOS 的 --no-mac-lib：Mac 有库 / 缺 .metal / 缺 .json / 键集不同，及同一份不带开关核不过）；
#   只有 json / metal、没有 metallib 的键（编译失败）通过并报个数；按目标发布：容器里的反射全是目标平台的 -sdk、键库 / 变体库 / 批库是目标那一侧的字节；目标写错、反射平台不符 → 拒。
# 随迁移删除的旧用例：inputs.tsv 印章判「全量没走完」（整份出库在内存里核验，不再有半截目录）、目录整体替换 swap（不再有按键文件目录）。
import json, os, shutil, struct, subprocess, sys, tempfile, atexit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

REC = {'ios': 'xcrun -sdk iphoneos metal -c -mios-version-min=18.0; xcrun -sdk iphoneos metallib',
       'mac': 'xcrun -sdk macosx metal -c -mmacosx-version-min=15.0; xcrun -sdk macosx metallib'}
CHAIN = '0a7dae3c1e7b'
def put(d, name, plat):   # 按键文件：json 是带本侧编译约定的反射，其余是占位字节
    p = os.path.join(d, name)
    if name.endswith('.json'): json.dump({'chain_metal': REC[plat]}, open(p, 'w'))
    else: open(p, 'w').write(plat + name)
def lib(d, keys, exts, plat):
    os.makedirs(d)
    for k in keys:
        for e in exts: put(d, f'{k}_b.{e}', plat)
    return d
def publish(root, plat='ios', flags=()):
    return subprocess.run([*CMD, '--libpack', os.path.join(root, 'in'), os.path.join(root, 'out'), CHAIN, plat, *flags], capture_output=True, text=True)

K1, K2 = '0123456789abcdef', 'fedcba9876543210'
MAC, IOS = ('metal', 'metallib', 'json'), ('metallib', 'json')
t = tempfile.mkdtemp(prefix='t_lib_swap_'); atexit.register(shutil.rmtree, t, True)
def case(name, mac_keys=(K1, K2), mac_ext=MAC, ios_keys=(K1, K2), ios_ext=IOS, drop=None, flags=(), extra=()):
    root = os.path.join(t, name); m = lib(os.path.join(root, 'in', 'mac'), mac_keys, mac_ext, 'mac'); i = lib(os.path.join(root, 'in', 'ios'), ios_keys, ios_ext, 'ios')
    if drop: os.unlink(os.path.join(m if drop[0] == 'mac' else i, drop[1]))
    for side, f in extra: put(m if side == 'mac' else i, f, side)
    return publish(root, flags=flags)
def red(r, why): return r.returncode == 1 and why in r.stderr   # 拒，且拒的理由对（不是别的错误碰巧退出 1）

check(case('ok').returncode == 0, '齐全：两键、Mac 三样、iOS 两样 → 通过')
check(red(case('mac_metal', drop=('mac', f'{K2}_b.metal')), '没有 _b.metal'), 'Mac 一个键缺 .metal → 不过')
check(red(case('mac_json', drop=('mac', f'{K2}_b.json')), 'Mac 库 1 个键有 _b.metallib 没有 _b.json'), 'Mac 一个键缺 .json → 不过')
check(red(case('ios_json', drop=('ios', f'{K1}_b.json')), 'iOS 库 1 个键有 _b.metallib 没有 _b.json'), 'iOS 一个键缺 .json → 不过')
check(red(case('keyset', ios_keys=(K1,)), '键集不同'), '两边键集不同 → 不过')
check(red(case('empty', mac_keys=(), ios_keys=()), '一个键都没出'), '一个键都没出 → 不过')
K3 = '1111222233334444'
r = case('orphan_json', extra=(('mac', f'{K3}_b.json'), ('mac', f'{K3}_b.metal'), ('ios', f'{K3}_b.json')))
check(r.returncode == 0 and '1 个键只有 json / metal' in r.stdout, f'两边各多一个只有 json（Mac 加 metal）的键（编译失败）→ 通过、报 1 个（实得 {r.returncode}；{(r.stdout + r.stderr).strip()[-80:]}）')
check(case('orphan_metal', extra=(('mac', f'{K3}_b.metal'),)).returncode == 0, 'Mac 多一个只有 .metal 源码的键 → 通过')
# gs_slice（11-02 双人成行 / 八方2 439bed623be839b2）：几何阶段只转发图层号、按设计只出反射 json（宿主读它、用顶点阶段的图层入口画），出成了，不算编译失败、进 keys.tsv；
#   反证：同样只有 json、反射里没有 gs_slice 的键仍是编译失败、不进 keys.tsv
def gs_case(name, gs):
    root = os.path.join(t, name); m = lib(os.path.join(root, 'in', 'mac'), (K1, K2), MAC, 'mac'); i = lib(os.path.join(root, 'in', 'ios'), (K1, K2), IOS, 'ios')
    for d, plat in ((m, 'mac'), (i, 'ios')): json.dump({'chain_metal': REC[plat], 'stage': 'gs', **({'gs_slice': {'loc': 1, 'comp': 'x'}} if gs else {})}, open(os.path.join(d, f'{K3}_b.json'), 'w'))
    r = publish(root); k = os.path.join(root, 'out', 'keys.tsv')
    return r, (open(k).read() if os.path.exists(k) else None)
r, k = gs_case('gs_slice', True)
check(r.returncode == 0 and '只有 json' not in r.stdout and k == f'{K1}\n{K3}\n{K2}\n', f'gs_slice 键两侧只有 json → 通过、不报编译失败、keys.tsv 含它（实得 {r.returncode}；{k!r}；{(r.stdout + r.stderr).strip()[-80:]}）')
r, k = gs_case('gs_plain', False)
check(r.returncode == 0 and '1 个键只有 json / metal' in r.stdout and k == f'{K1}\n{K2}\n', f'反证：没有 gs_slice 的只有 json 的键 → 仍报编译失败、不进 keys.tsv（实得 {r.returncode}；{k!r}）')
# 直通几何快路变体（11-06 金刚 kong_pt：Dsh 出了 <key>_bgs<i> / _bgc，发布这道文件名过滤没收，lib.idx 种类 64–97 为 0）：
#   两侧给 K1 加 _bgs3 / _bgc 的 metallib + json，期望（lib_pack.inc 定义手算）iOS 容器里有种类 67（64+3）、83（80+3）、96、97 各 1 段
def lib_kinds(d):
    b = open(os.path.join(d, 'lib.idx'), 'rb').read(); n, ns = struct.unpack_from('<II', b, 12)
    return [struct.unpack_from('<QBBHIQ', b, 48 + 16 * ns + 24 * i)[1] for i in range(n)]
r = case('gs_fast', extra=tuple((side, f'{K1}_{v}') for side in ('mac', 'ios') for v in ('bgs3.metallib', 'bgs3.json', 'bgc.metallib', 'bgc.json')))
kd = lib_kinds(os.path.join(t, 'gs_fast', 'out', 'b-' + CHAIN)) if r.returncode == 0 else []
check(r.returncode == 0 and all(kd.count(k) == 1 for k in (67, 83, 96, 97)), f'直通几何快路变体 _bgs3 / _bgc 进 iOS 容器：种类 67、83、96、97 各 1 段（实得 {r.returncode}；{sorted(set(k for k in kd if k >= 64))}）')
# 只出 iOS（--no-mac-lib）：Mac 那边每键 .metal / .json 两样、没有库
NM = ('--no-mac-lib',); MAC2 = ('metal', 'json')
check(case('nm_ok', mac_ext=MAC2, flags=NM).returncode == 0, '只出 iOS：Mac 两样（无库）、iOS 两样 → 通过')
check(red(case('nm_plain', mac_ext=MAC2), '键集不同'), '同一份不带 --no-mac-lib 核（Mac 没有库）→ 不过')
check(red(case('nm_maclib', flags=NM), 'Mac 库里却有 _b.metallib'), '只出 iOS 却有 Mac _b.metallib → 不过')
check(red(case('nm_metal', mac_ext=MAC2, flags=NM, drop=('mac', f'{K2}_b.metal')), 'Mac 侧没有 _b.metal'), '只出 iOS：Mac 一个键缺 .metal → 不过')
check(red(case('nm_json', mac_ext=MAC2, flags=NM, drop=('mac', f'{K1}_b.json')), '有 _b.metal 没有 _b.json'), '只出 iOS：Mac 一个键缺 .json → 不过')
check(case('nm_ioslib', mac_ext=MAC2, flags=NM, drop=('ios', f'{K1}_b.metallib')).returncode == 0, '只出 iOS：iOS 一个键只有 json、缺 .metallib（编译失败）→ 同孤立键，通过')
for nm, fs in (('nm_orphan_both', (('mac', f'{K3}_b.json'), ('ios', f'{K3}_b.json'))), ('nm_orphan_mac', (('mac', f'{K3}_b.json'),))):   # 10-26 八方2 13980 json / 13979 metal 整份被拒
    r = case(nm, mac_ext=MAC2, flags=NM, extra=fs)
    check(r.returncode == 0 and '1 个键只有 json / metal' in r.stdout, f'只出 iOS：{nm} 多一个 Mac 侧只有 json 的键（MSL 编失败）→ 通过、报 1 个（实得 {r.returncode}；{(r.stdout + r.stderr).strip()[-80:]}）')
r = case('nm_orphan_lib', mac_ext=MAC2, flags=NM, extra=(('mac', f'{K3}_b.json'), ('ios', f'{K3}_b.json'), ('ios', f'{K3}_b.metallib')))
check(red(r, 'Mac 侧没有 _b.metal'), '只出 iOS：Mac 侧只有 json、iOS 却出成了 metallib → 不过')
check(red(case('nm_keyset', mac_ext=MAC2, ios_keys=(K1,), flags=NM), '键集不同'), '只出 iOS：两边键集不同 → 不过')

# 发布目标（#897 wwmogu：--target mac 的包发布了 iOS 库）：两侧带各自的 -sdk 反射，按目标打容器、核 -sdk
U = 'u00112233445566aa'
def plat_lib(d, plat, src=False):
    os.makedirs(d)
    for k in (K1, K2):
        open(os.path.join(d, f'{k}_b.metallib'), 'w').write(plat + k)
        json.dump({'chain_metal': REC[plat], 'fn_lib': U, 'stage': 'ps'}, open(os.path.join(d, f'{k}_b.json'), 'w'))
        if src: open(os.path.join(d, f'{k}_b.metal'), 'w').write('struct main0_in { float4 a [[user(locn2)]]; float4 b [[user(locn0)]]; };' if k == K1 else 'msl')
    json.dump({'chain_metal': REC[plat]}, open(os.path.join(d, f'{K1}_bg0.json'), 'w'))
    open(os.path.join(d, f'{K1}_bv.metallib'), 'w').write(plat + 'bv')
    open(os.path.join(d, f'{U}.metallib'), 'w').write(plat + 'batch')
    return d
def pub(name, plat, mac_plat='mac'):
    root = os.path.join(t, name); plat_lib(os.path.join(root, 'in', 'mac'), mac_plat, src=True); plat_lib(os.path.join(root, 'in', 'ios'), 'ios')
    return publish(root, plat), os.path.join(root, 'out')
def segs(out):   # 自己按格式解析容器（宿主读法 graphics/nvn/lib_pack.inc 文件头）→ [(键, 种类, 字节)]
    d = os.path.join(out, f'b-{CHAIN}'); idx = open(os.path.join(d, 'lib.idx'), 'rb').read()
    n, ns = struct.unpack_from('<II', idx, 12); paks = [open(os.path.join(d, f'lib.{s:03d}.pak'), 'rb').read() for s in range(ns)]
    return [(f'{k:016x}', kd, paks[sh][off:off + ln]) for k, kd, sh, _, ln, off in (struct.unpack_from('<QBBHIQ', idx, 48 + 16 * ns + 24 * i) for i in range(n))]
def sdks(sg): return {json.loads(b).get('chain_metal', '').split()[2] for _, kd, b in sg if kd in (1, 32)}
r, out = pub('pub_ios', 'ios')
sg = segs(out) if r.returncode == 0 else []
check(r.returncode == 0 and sdks(sg) == {'iphoneos'} and [b for _, kd, b in sg if kd == 0] == [b'iosbatch'] * 2,
      f'目标 iOS：容器里反射全 iphoneos、两键种类 0 是 iOS 批库（实得 {r.returncode}、{sdks(sg)}；{(r.stdout + r.stderr).strip()[-120:]}）')
r, out = pub('pub_mac', 'mac')
sg = segs(out) if r.returncode == 0 else []
check(r.returncode == 0 and sdks(sg) == {'macosx'}, f'目标 mac：容器里反射全部是 macosx（实得 {r.returncode}、{sdks(sg)}；{r.stderr.strip()[:120]}）')
check([b for _, kd, b in sg if kd in (0, 3)] == [b'macbatch', b'macbv', b'macbatch'], '目标 mac：键库（经 fn_lib 取批库 u<批>）、变体库（_bv）都是 Mac 那份')
check(sorted({kd for _, kd, _ in sg}) == [0, 1, 3, 32], f'目标 mac：容器只有库与反射（种类 0 / 1 / 3 / 32），不带 _b.metal 源码（{sorted({kd for _, kd, _ in sg})}）')
keys = open(os.path.join(out, 'keys.tsv')).read() if os.path.exists(os.path.join(out, 'keys.tsv')) else None
psi = open(os.path.join(out, 'ps_inputs.tsv')).read().splitlines()[1:] if os.path.exists(os.path.join(out, 'ps_inputs.tsv')) else None
check(keys == f'{K1}\n{K2}\n' and psi == [f'{K1}\t0,2', f'{K2}\t'], f'keys.tsv = 两键；ps_inputs.tsv 从 Mac 侧 MSL 读 user(locn)：K1 0,2、K2 空（{keys!r}，{psi}）')
r, _ = pub('pub_mac_bad', 'mac', mac_plat='ios')
check(red(r, '-sdk macosx'), f'反证：Mac 侧反射是 iphoneos（修前把 iOS 库原样发布的样子）却发布 mac → 拒（实得 {r.returncode}）')
r, _ = pub('pub_typo', 'macos')
check(red(r, '只认 ios / mac'), '目标写成 macos（只认 ios / mac）→ 拒')

# 编不过的一句（Build.cs Metal.CompilerWhy，出库清单 / 普查「直连编不过」列读它；11-02 究极4 315 支原文被 xcrun 命令行挤掉）：真 xcrun 编一支坏 MSL，stderr 喂 --compiler-why
#   期望：只留编译器的 error 行、去掉临时目录路径（以「bad.metal:行:列: error:」开头），不含命令行；没有 error 行的输入回空（调用方退回整串）
bad = os.path.join(t, 'sub', 'bad.metal'); os.makedirs(os.path.dirname(bad)); open(bad, 'w').write('kernel void main0() { int x = ; }\n')
ce = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', bad, '-o', os.path.join(t, 'bad.air')], capture_output=True, text=True)
w = subprocess.run([*CMD, '--compiler-why'], input=ce.stderr, capture_output=True, text=True)
check(ce.returncode != 0 and w.returncode == 0 and w.stdout.startswith('bad.metal:1:') and ' error: ' in w.stdout and '/' not in w.stdout.split(' error: ')[0] and 'xcrun' not in w.stdout,
      f'坏 MSL 的编不过原因 = 编译器 error 行、去路径（实得 rc {w.returncode}：{w.stdout[:120]!r}）')
w = subprocess.run([*CMD, '--compiler-why'], input='warning: x\n', capture_output=True, text=True)
check(w.returncode == 0 and w.stdout == '', f'没有 error 行 → 空（调用方用整串）（实得 {w.stdout!r}）')
print(f't_lib_swap：{"全符" if not fails else f"{len(fails)} 例不符"}')
sys.exit(1 if fails else 0)
