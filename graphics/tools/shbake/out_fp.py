#!/usr/bin/env python3
# 着色器包产出指纹（10-24 总指挥「对产物按内容寻址，输出不变就不算变」）：python3 graphics/tools/shbake/out_fp.py <工作目录 W> <仓库根 R> <平台> <程序号> → 打印 sha256 十六进制
#   着色器键（shader_pack.sh key_of）按工具源码 / 二进制算，偏保守：gal_xc 剥离后的二进制、翻译器闭包源码一处变就变。10-24 审计今天 main 前进 107 次、键变 16 次，
#   约一半不影响翻译输出（只改运行时的 gal_core / gal_draw、GAL 运行时辅助、ShBake 单测）。键变了照跑 ②（抽取 + 翻译 + gal_xc），再按本指纹判：
#   与现行包记下的（shaders/output.fp）相同 → 本次出的着色器包与现行逐字节相同（除去下面两处非内容字节），shader_pack.sh 退出 3，pack/stage_shaders.sh 沿用现行、只记新键。
# 指纹 = 包里来自 ② 的全部产出 + ③④（编库 / 管线归档）读到的全部输入：
#   ② 产出：work/lib 全部（MSL、离线索引、翻不了的清单）、程序表（去掉耗时列 ms）、读帧缓冲证明、社区管线状态、Ryujinx 缓存（.toc 头里的创建时间戳置零）、画幅元数据、客体键表、翻译红数与计数；
#   收集来的表（特化管线 / 首用 / 键对照）；③④ 的全部脚本；统一工具链、SDK、本机系统与芯片、影响产物的环境。
#   10-24 实测（翻译缓存里同款相邻两键，翻译器只改了运行时）：两份 ② 产出只差程序表 ms 列与 .toc 第 16–23 字节（TocHeader.Timestamp），其余逐字节相同
import hashlib, json, os, subprocess, sys

W, R, PLAT, TID = sys.argv[1:5]
h = hashlib.sha256()
def put(tag, data): h.update(tag.encode() + b'\0' + (data if isinstance(data, bytes) else data.encode()) + b'\0')
def put_file(tag, p):
    if p and os.path.isfile(p): put(tag, hashlib.sha256(open(p, 'rb').read()).digest())
    else: put(tag, b'missing')
def put_dir(tag, d, keep=lambda f: True, read=lambda p: open(p, 'rb').read()):
    if not os.path.isdir(d): put(tag, b'missing'); return
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            if keep(f): put(tag + ':' + os.path.relpath(p, d), hashlib.sha256(read(p)).digest())
def toc(p):   # Ryujinx 缓存目录表：头里 Timestamp（第 16–23 字节）是建文件的时刻，不是内容
    b = bytearray(open(p, 'rb').read())
    if p.endswith('.toc') and len(b) >= 24: b[16:24] = bytes(8)
    return bytes(b)
put('plat', PLAT)
# ② 的产出（③ 编库前 lib/ 下全是 gal_xc 出的：msl/*.metal、gal.idx、xc_failed.txt）
put_dir('lib', os.path.join(W, 'lib'))
for f in ('fbr.tsv', 'reflib_states.tsv', 'widen.idx', 'widen_pos.bin', 'guest_keys.tsv'): put_file(f, os.path.join(W, f))
pt = os.path.join(W, 'programs.tsv')
if os.path.isfile(pt):
    rows = [l.rstrip('\n').split('\t') for l in open(pt, encoding='utf-8')]
    ms = rows[0].index('ms') if rows and 'ms' in rows[0] else -1
    put('programs.tsv', '\n'.join('\t'.join(c for i, c in enumerate(r) if i != ms) for r in rows))
else: put('programs.tsv', b'missing')
put_dir('shcache', os.path.join(W, 'shcache', TID), read=toc)
b = json.load(open(os.path.join(W, 'bake.json')))   # 进 shader_pack.json 的翻译读数（耗时不进）
put('bake', json.dumps({k: b.get(k) for k in ('red', 'counts', 'stage_only', 'known_gap', 'spec_sources', 'ref_guest', 'reflib', 'spec_trimmed_tex_queries')}, sort_keys=True, ensure_ascii=False))
# 收集来的表（pack/stage_shaders.sh 经环境给）
for v in ('S2A_SPEC_PIPES', 'S2A_PSO_USE', 'S2A_PSO_KEYMAP'): put_file(v, os.environ.get(v))
# ③④ 的脚本：shbake 下非 C# 文件、出包主脚本、编库脚本与统一工具链
sb = os.path.join(R, 'graphics/tools/shbake')
for f in sorted(os.listdir(sb)):
    p = os.path.join(sb, f)
    if os.path.isfile(p) and not f.endswith(('.cs', '.csproj')): put_file('script:' + f, p)
for f in ('graphics/tools/shader_pack.sh', 'graphics/metal/tools/gal_offline.py', 'graphics/metal/tools/unity_check.py', 'tools/toolchain.env'): put_file('script:' + f, os.path.join(R, f))
# 工具链（编库 / 归档都用它）、没给目标时的缺省（SDK 大版本、本机系统与芯片）、影响产物的环境（并行度、缓存位置、远端分流不影响产物，不进）
def out(*a): return subprocess.run(list(a), capture_output=True, text=True).stdout
for sdk in ('iphoneos', 'macosx'): put('sdk:' + sdk, out('xcrun', '-sdk', sdk, 'metal', '--version') + out('xcrun', '--sdk', sdk, '--show-sdk-version'))
put('host', os.environ.get('DEVELOPER_DIR', '') + '\n' + out('sw_vers', '-productVersion') + out('sysctl', '-n', 'machdep.cpu.brand_string'))
for k in sorted(os.environ):
    if k.startswith(('S2A_PSO_', 'PSO_', 'GAL_UNITY', 'GAL_SHARD', 'GAL_LINK_', 'S2A_METAL_TT', 'S2A_DEVELOPER_DIR', 'IPHONEOS_DEPLOYMENT_TARGET', 'MACOSX_DEPLOYMENT_TARGET')) \
            and k not in ('S2A_PSO_USE', 'S2A_PSO_KEYMAP', 'S2A_PSO_J', 'S2A_PSO_REMOTE'):
        put('env:' + k, os.environ[k])
print(h.hexdigest())
