#!/bin/bash
# 门禁覆盖：ios/embed.py ios/macho_dylib.py runtime/src/imgpack.c runtime/src/imgpack.h runtime/src/loader.c runtime/build.mk tests/ios_embed_test.sh
# 游戏镜像包 Frameworks/S2AImages.dylib（ios/embed.py 纯 Python 写 Mach-O；11-04 全外置后是游戏镜像的唯一形态，原「编进主程序」已删）。约 10 秒：bash tests/ios_embed_test.sh
#   不论多少模块都只有 __TEXT,__swcode / __SWDATA,__img / __TEXT,__swidx 三个节（马力欧派对 130 模块原先每模块独占节，超过 Mach-O 255 节上限）。
#   夹具：四种布局的小模块（普通 / 装载偏置 LOAD_BIAS / FAR（PATCH_OFF < 0）/ 双补丁岛 PATCH2）+ 补丁区为空的模块，外加 130 个普通模块一组；内容是确定的伪随机字节。
#   期望（按 embed.py 文件头的规格手算，不调被测实现）：每模块 x0 = [LOAD_BIAS 个 0] + 文件[0, 圆整16K(TEXT_END + 偏置) − 偏置)，
#   W = 文件[x0 末, PATCH_OFF)（FAR：[.., FILE_IMAGE_LEN)），x1 = 文件[PATCH_OFF（FAR：FILE_IMAGE_LEN）, 末) 补 0 到 16K，x2 = 文件末尾 PATCH2_LEN 字节补 0 到 16K；
#   代码块依次排进 __swcode、W 块依次排进 __img，偏移表按模块参数顺序记（偏移, 长度），全部 16K 整数倍。
#   装载器读法（runtime/src/imgpack.c，loader.c iOS 分支同一份）：Mac 小程序打开镜像包（注册签名 + 库校验），按名 / 块号查，代码块 / 可写块真映射进预留地址读回，
#     与期望逐字节相同，s2a_imgpack_same 认同；长度为 0 的块（无双岛的 x2、没有补丁点的 x1）查得到、长度 0、不报停。
#   反证（原生线审查要求）：魔数错 / 某块没按 16K 对齐 / 两块重叠的坏表，打开即报错并点名哪一块。
#   （11-02 再犯：马力欧派对 nro0 改写无补丁点、x1 长 0，偏移表打开时当缺块报停，真机 FATAL「nro0 的第 2 块长度为 0」）
#   （11-02 自犯：只测了写出的格式，装载器结构体把交替的（偏移, 长度）读成先 4 个偏移再 4 个长度，真机 FATAL「第 2 块长度为 0」）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/ios_embed.XXXXXX"); trap 'rm -rf "$T"' EXIT
command -v xcrun > /dev/null || { echo "ios_embed：没有 xcrun（要 Mac 上的 clang 编读包小程序）→ 红"; exit 1; }
exec python3 - "$H/ios/embed.py" "$T" "$H/runtime/src" <<'PY'
import os, random, struct, subprocess, sys
emb, T, SRC = sys.argv[1:4]; PG = 0x4000; r16 = lambda x: (x + PG - 1) & ~(PG - 1); bad = []
def ck(c, m):
    print(('✓ ' if c else '✗ ') + m)
    if not c: bad.append(m)
def mod(d, n, te, po, ko, sz, lb=0, fl=None, l2=0, seed=0):   # 写 <名>.fixups.tsv 表头 + <名>.patched.bin（sz 字节映像 + 双岛 l2 字节）
    h = {'TEXT_END': te, 'PATCH_OFF': po, 'KEY_PAGE_OFF': ko, 'KEY_PAGE_SIZE': PG}
    if lb: h['LOAD_BIAS'] = lb
    if fl is not None: h['FILE_IMAGE_LEN'] = fl
    if l2: h['PATCH2_OFF'] = 0x7fff0000; h['PATCH2_LEN'] = l2
    open(f'{d}/{n}.fixups.tsv', 'w').write(''.join(f'# {k} {v:#x}\n' if v >= 0 else f'# {k} -{-v:#x}\n' for k, v in h.items()))
    random.seed(seed); open(f'{d}/{n}.patched.bin', 'wb').write(bytes(random.getrandbits(8) for _ in range(sz + l2)))
    return dict(h, sz=sz, lb=lb, fl=fl, l2=l2)
def expect(d, n, h):   # 按规格算四块的期望字节
    b = open(f'{d}/{n}.patched.bin', 'rb').read(); sz, lb, l2, te, po = h['sz'], h['lb'], h['l2'], h['TEXT_END'], h['PATCH_OFF']
    a = r16(te + lb) - lb; pad = lambda x, ln: x + b'\0' * (ln - len(x))
    x0 = pad(b'\0' * lb + b[0:a], lb + a)
    if po < 0: w, x1 = b[a:h['fl']], pad(b[h['fl']:sz], r16(sz) - h['fl'])
    else: w, x1 = b[a:po], pad(b[po:sz], r16(sz - po))
    x2 = pad(b[sz:sz + l2], r16(l2)) if l2 else b''
    return [x0, w, x1, x2]
def macho(path):   # 64 位 Mach-O → {(段, 节): (文件偏移, 长度)}
    m = open(path, 'rb').read(); ncmd = struct.unpack_from('<I', m, 16)[0]; o = 32; out = {}
    for _ in range(ncmd):
        cmd, sz = struct.unpack_from('<II', m, o)
        if cmd == 0x19:
            nsect = struct.unpack_from('<I', m, o + 64)[0]
            for i in range(nsect):
                s = o + 72 + 80 * i; sect, seg = m[s:s + 16].rstrip(b'\0').decode(), m[s + 16:s + 32].rstrip(b'\0').decode()
                size, off = struct.unpack_from('<Q', m, s + 40)[0], struct.unpack_from('<I', m, s + 48)[0]
                out[(seg, sect)] = (off, size)
        o += sz
    return m, out
# 读包小程序：s2a_imgpack_open → find → map（代码块 R|X、W 块 R|W 进预留地址）→ 读回写文件 → same 认同；打不开时打印原因退出 3
READER = r'''#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include "imgpack.h"
int main(int c, char **v) {
    s2a_imgpack *p; char why[512] = ""; int rc = s2a_imgpack_open(v[2], &p, why, sizeof why);
    if (rc) { fprintf(stderr, "打不开（%d）：%s\n", rc, why); return 3; }
    for (int i = 3; i < c; i++) for (int k = 0; k < 4; k++) {
        uint64_t off, len; char f[700]; snprintf(f, sizeof f, "%s/%s.%d.bin", v[1], v[i], k); FILE *o = fopen(f, "wb");
        if (!s2a_imgpack_find(p, v[i], k, &off, &len)) { fprintf(stderr, "找不到 %s 第 %d 块\n", v[i], k); return 4; }
        if (len) {
            void *at = mmap(NULL, len, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); int e = 0;
            if (s2a_imgpack_map(p, at, off, len, k != S2A_IMG_W, &e)) { fprintf(stderr, "映射 %s 第 %d 块失败 errno=%d\n", v[i], k, e); return 5; }
            if (!s2a_imgpack_same(p, at, off, len)) { fprintf(stderr, "same 不认 %s 第 %d 块\n", v[i], k); return 6; }
            fwrite(at, 1, len, o);
        }
        fclose(o);
    }
    return 0;
}
'''
def run(name, mods):
    d = f'{T}/{name}'; os.makedirs(d); hs = {n: mod(d, n, **kw) for n, kw in mods}
    lib = f'{d}/S2AImages.dylib'
    r = subprocess.run(['python3', emb, d, lib, *[n for n, _ in mods]], capture_output=True, text=True)
    if r.returncode: ck(False, f'{name}：embed.py 退出 {r.returncode}：{r.stderr[-300:]}'); return
    m, secs = macho(lib)
    ck(set(secs) == {('__TEXT', '__swcode'), ('__SWDATA', '__img'), ('__TEXT', '__swidx')}, f'{name}：{len(mods)} 个模块 → 节 {sorted(secs)}（不随模块数增长）')
    io, iz = secs[('__TEXT', '__swidx')]; ix = m[io:io + iz]
    ck(ix[:8] == b'S2AEMB01' and struct.unpack_from('<II', ix, 8) == (len(mods), 88) and iz >= 16 + 88 * len(mods), f'{name}：偏移表魔数 / 项数 {len(mods)} / 项长 88')
    co, _ = secs[('__TEXT', '__swcode')]; wo, _ = secs[('__SWDATA', '__img')]; ends = [0, 0]; ok = 0
    for i, (n, _) in enumerate(mods):
        e = ix[16 + 88 * i:16 + 88 * (i + 1)]; nm = e[:24].rstrip(b'\0').decode(); pairs = [struct.unpack_from('<QQ', e, 24 + 16 * k) for k in range(4)]
        want = expect(d, n, hs[n]); good = nm == n
        for k, (off, ln) in enumerate(pairs):
            sec = 1 if k == 1 else 0
            if ln == 0: good &= want[k] == b''; continue
            good &= off % PG == 0 and ln % PG == 0 and off == ends[sec] and ln == len(want[k])
            base = wo if k == 1 else co; good &= m[base + off:base + off + ln] == want[k]; ends[sec] = off + ln
        ok += good
    ck(ok == len(mods), f'{name}：各模块四块与规格逐字节相同、16K 对齐、依次排开 {ok}/{len(mods)}')
    open(f'{d}/r.c', 'w').write(READER)
    bl = subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-std=gnu11', f'-I{SRC}', f'{d}/r.c', f'{SRC}/imgpack.c', '-o', f'{d}/r'], capture_output=True, text=True)
    if bl.returncode: ck(False, f'{name}：Mac 读包程序编不过：{bl.stderr[-300:]}'); return
    rr = subprocess.run([f'{d}/r', d, lib, *[n for n, _ in mods]], capture_output=True, text=True)
    good = rr.returncode == 0 and all(open(f'{d}/{n}.{k}.bin', 'rb').read() == expect(d, n, hs[n])[k] for n, _ in mods for k in range(4))
    ck(good, f'{name}：装载器 imgpack 映射读回各模块四块与期望逐字节相同（退出 {rr.returncode}{("：" + rr.stderr.strip()[-160:]) if rr.stderr.strip() else ""}）')
    if name != '四种布局': return
    # 反证：坏表必须报错并点名哪一块（imgpack.c 打开时的魔数 / 16K 对齐 / 依次排开三条检查；格式检查在注册签名之前）
    def bad(tag, edit, want):
        b = bytearray(m); edit(b); open(f'{d}/bad.dylib', 'wb').write(bytes(b))
        x = subprocess.run([f'{d}/r', d, f'{d}/bad.dylib', 'main'], capture_output=True, text=True)
        ck(x.returncode == 3 and want in x.stderr, f'反证 {tag}：打开即报错且点名（退出 {x.returncode}：{x.stderr.strip()[-120:]}）')
    def setoff(b, mi, k, f):   # 第 mi 项第 k 块的偏移
        at = io + 16 + 88 * mi + 24 + 16 * k; struct.pack_into('<Q', b, at, f(struct.unpack_from('<Q', b, at)[0]))
    bad('魔数错', lambda b: b.__setitem__(slice(io, io + 8), b'S2AEMB00'), '魔数')
    bad('块未按 16K 对齐', lambda b: setoff(b, 0, 2, lambda o: o + 0x1000), 'main 第 2 块')
    bad('两块重叠', lambda b: setoff(b, 1, 0, lambda o: 0), 'lbias 第 0 块')
run('四种布局', [('main', dict(te=0x5000, po=0x10000, ko=0x8000, sz=0x11234, seed=1)),
                 ('lbias', dict(te=0x5000, po=0xF000, ko=0x7000, sz=0xF800, lb=0x1000, seed=2)),
                 ('far', dict(te=0x5000, po=-0x8000, ko=0x8000, sz=0xE345, fl=0xC000, seed=3)),
                 ('isle', dict(te=0x5000, po=0x10000, ko=0x8000, sz=0x10400, l2=0x1800, seed=4)),
                 ('nopatch', dict(te=0x5000, po=0x10000, ko=0x8000, sz=0x10000, seed=5))])   # 补丁区为空（改写没有补丁点，马力欧派对 nro0）：x1 长 0
run('130 个模块', [(f'nro{i}', dict(te=0x1000, po=0x8000, ko=0x4000, sz=0x8100, seed=100 + i)) for i in range(130)])
print('ios_embed：' + ('全过' if not bad else f'{len(bad)} 项不过')); sys.exit(1 if bad else 0)
PY
