#!/usr/bin/env python3
# 直连库容器的 Vulkan 种类与指纹位单测（C# LibPack.PackFiles，graphics/tools/direct/dsh/batch/LibPack.cs，#783 合入线 11-03 答 ①；经 dsh_batch --libpack pack 调，
#   不要 xcrun，Linux / Mac 都能跑）：python3 graphics/tools/direct/tests/t_lib_pack_vk.py
#   ① 苹果库与改前逐字节相同：一组固定的 Metal 按键文件（不真编：PackFiles 不看 metallib 内容；含 _bf / _bv / _ft / _se / _b_t1 / _bg3 两样 / _bgv 两样、
#      成批合编两键的 _b 指向同一个批库 u<16>.metallib、两段字节相同只存一次）不给指纹打包，lib.idx / lib.000.pak 的 SHA-256 = 改前 main（310d46bdd）
#      同一份输入打出来的（写死在 GOLD_*；改容器格式时用 --gold 在改前的树上重算）；头部 36–47 这 12 字节全 0
#   ② Vulkan 库：三键的 _b.json（种类 1）+ _b.spv（种类 52）给指纹打包 → 记录按 (键, 种类) 升序、每段字节 = 原文件、16 字节对齐、
#      头部魔数 / 版本 1 / 链号同 Metal 口径，36–43 = 指纹（u64 小端，按十六进制解），44–47 为 0；其余字节与 Metal 库的写法一致（同一份 PackFiles）
#   ③ 反证（都退出 1、输出目录不留分片 / 索引 / 临时文件）：_b.spv 不给指纹；指纹不是 16 位小写十六进制；给了指纹又混进 Metal 段（_b.metallib）
import hashlib, os, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
GOLD_IDX = '50947b783551c32a95763d3dab5f6cdc4ccc361219475e35a5763edc3bbc0d7a'
GOLD_PAK = 'a6527eab528c3244b7917dd66ea58a3d5f58c73abdbdd7c9e58a325ceebc69a5'
CHAIN, VKFP = '0a7dae3c1e7b', '7d7ccaee95f9f398'
K1, K2, K3 = '0000000000000abc', '00000000000fedcb', 'fedcba9876543210'
fails = []


def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)


def pack(src, out, *fp): return subprocess.run([*CMD, '--libpack', 'pack', src, out, CHAIN, *fp], capture_output=True, text=True)


def write(d, files):
    os.makedirs(d)
    for n, b in files.items(): open(os.path.join(d, n), 'wb').write(b)
    return files


def metal_files():   # 固定输入：字节按名字定，跑几次都一样
    f = {f'{K1}_b.json': b'{"key": "%s_b", "stage": "ps"}' % K1.encode(), f'{K1}_b.metallib': b'metallib bytes of K1 ' * 3,
         f'{K1}_bf.metallib': b'readable-tile variant', f'{K1}_bv.metallib': b'vertex-pull variant', f'{K1}_ft.metallib': b'typed-output variants',
         f'{K1}_se.metallib': b'sampler emulation variant', f'{K2}_b.json': b'{"key": "%s_b", "fn_lib": "u0123456789abcdef"}' % K2.encode(),
         f'{K2}_b.metallib': b'per-key lib replaced by the batch lib', f'{K2}_b_t1.metallib': b'tess domain 1', f'{K2}_bg3.metallib': b'bg3 lib',
         f'{K2}_bg3.json': b'{"gs_slice": 1}', f'{K2}_bgv.metallib': b'bgv lib', f'{K2}_bgv.json': b'{"gs_v": 1}',
         f'{K3}_b.json': b'{"key": "%s_b", "fn_lib": "u0123456789abcdef"}' % K3.encode(), f'{K3}_b.metallib': b'per-key lib replaced by the batch lib',
         f'{K3}_bf.metallib': b'readable-tile variant', 'u0123456789abcdef.metallib': b'batch lib shared by K2 and K3', 'inputs.tsv': b'game\tx\n'}
    return f


def vk_files():
    return {f'{k}_b.{x}': (b'{"key": "%s_b", "bindings": []}' % k.encode() if x == 'json' else b'\x03\x02\x23\x07' + k.encode() * (i + 1))
            for i, k in enumerate((K1, K2, K3)) for x in ('json', 'spv')}


def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()


def parse(d):
    idx = open(os.path.join(d, 'lib.idx'), 'rb').read()
    magic, ver, n, ns, z, chain = struct.unpack_from('<8sIIII12s', idx, 0)
    sizes = [struct.unpack_from('<QQ', idx, 48 + 16 * s)[0] for s in range(ns)]
    recs = [struct.unpack_from('<QBBHIQ', idx, 48 + 16 * ns + 24 * i) for i in range(n)]
    return idx, magic, ver, chain, sizes, recs


with tempfile.TemporaryDirectory() as t:
    src = os.path.join(t, 'metal'); write(src, metal_files()); out = os.path.join(t, 'b-metal')
    r = pack(src, out)
    if sys.argv[1:] == ['--gold']:
        print(f"GOLD_IDX = '{sha(os.path.join(out, 'lib.idx'))}'\nGOLD_PAK = '{sha(os.path.join(out, 'lib.000.pak'))}'" if r.returncode == 0 else r.stdout + r.stderr); sys.exit(r.returncode)
    print('① 苹果库与改前逐字节相同')
    check(r.returncode == 0 and sorted(os.listdir(out)) == ['lib.000.pak', 'lib.idx'], f'不给指纹打包退出 0、只出 lib.000.pak / lib.idx（{(r.stdout + r.stderr).strip()[-120:]}）')
    if r.returncode == 0:
        idx = parse(out)[0]
        check(sha(os.path.join(out, 'lib.idx')) == GOLD_IDX, f'lib.idx 与改前 main 同一份输入逐字节相同（SHA-256 {sha(os.path.join(out, "lib.idx"))[:16]}…）')
        check(sha(os.path.join(out, 'lib.000.pak')) == GOLD_PAK, f'lib.000.pak 与改前 main 逐字节相同（SHA-256 {sha(os.path.join(out, "lib.000.pak"))[:16]}…）')
        check(idx[36:48] == bytes(12), f'头部 36–47 全 0（实 {idx[36:48].hex()}）')

    print('② Vulkan 库')
    vsrc = os.path.join(t, 'vk'); vf = write(vsrc, vk_files()); vout = os.path.join(t, 'b-vk')
    r = pack(vsrc, vout, VKFP)
    check(r.returncode == 0 and sorted(os.listdir(vout)) == ['lib.000.pak', 'lib.idx'], f'给指纹打包退出 0、只出 lib.000.pak / lib.idx（{(r.stdout + r.stderr).strip()[-120:]}）')
    if r.returncode == 0:
        idx, magic, ver, chain, sizes, recs = parse(vout)
        want = [(int(k, 16), kind, f'{k}_b.{x}') for k in (K1, K2, K3) for kind, x in ((1, 'json'), (52, 'spv'))]
        check([(x[0], x[1]) for x in recs] == [(w[0], w[1]) for w in want], f'记录 6 段、按 (键, 种类) 升序、_b.json 种类 1 / _b.spv 种类 52（{[(hex(x[0]), x[1]) for x in recs]}）')
        pak = open(os.path.join(vout, 'lib.000.pak'), 'rb').read()
        check(all(pak[x[5]:x[5] + x[4]] == vf[w[2]] for x, w in zip(recs, want)) and all(x[5] % 16 == 0 for x in recs), '每段字节 = 原文件、起点 16 字节对齐')
        check(magic == b'S2ALIB\0\0' and ver == 1 and chain == CHAIN.encode(), f'头：魔数 / 版本 1 / 链号同 Metal 口径（{magic} {ver} {chain}）')
        check(struct.unpack_from('<Q', idx, 36)[0] == int(VKFP, 16) and idx[44:48] == bytes(4), f'头部 36–43 = 指纹（u64 小端 {idx[36:44].hex()} = {VKFP}）、44–47 为 0')

    print('③ 反证')
    def bad(name, src, *fp):
        o = os.path.join(t, 'bad-' + name); r = pack(src, o, *fp)
        left = sorted(os.listdir(o)) if os.path.isdir(o) else []
        check(r.returncode == 1 and left == [], f'{name} → 退出 1、输出目录不留东西（rc={r.returncode}，留 {left}；{(r.stdout + r.stderr).strip()[-100:]}）')
    bad('_b.spv 不给指纹', vsrc)
    bad('指纹不是 16 位小写十六进制', vsrc, '7D7CCAEE95F9F398')
    mix = os.path.join(t, 'mix'); write(mix, {**vk_files(), f'{K1}_b.metallib': b'metal'})
    bad('给了指纹又混进 Metal 段', mix, VKFP)

print('直连库容器 Vulkan 种类：' + ('全过' if not fails else f'{len(fails)} 项不过'))
sys.exit(1 if fails else 0)
