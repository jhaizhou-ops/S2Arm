#!/usr/bin/env python3
# 片元输出类型变体出包（现编回收 R2）单测：⓪ 提交的 pso_layout.json 与 nvn_pso_skey.h / nvn_pfkind.h 现导出的逐字节同；① fout_want.py 从管线键 R 行 / rt_fout.tsv 行算请求表；② S2A.Dsh DshFt.Masks（graphics/tools/direct/dsh/Ft.cs，经 dsh_cmp --fn ft_masks 调）按反射过滤（同 nvn_mtl.m pso_int_need）。
#   ① 生成器用同一份 nvn_pso_skey.h 造 R 行（pso_skey_from + pso_skey_hex，与宿主写 pso_user.tsv 同一路径），期望按画布格式手算：
#      普通遍 R32Uint@0 / RGBA8Unorm@1 / RG16Sint@2 → 无符号 1、有符号 4；合并遍 lmap {2, 0, ff}：R32Uint→位 2、R8Sint→位 0、ff 不算 → 无符号 4、有符号 1；
#      可读瓦片行（fz）、没有片元键、全是浮点画布 → 不出；同一行两遍 → 去重；rt_fout 行「键 2 0」进、坏行（非十六进制 / 列数不对）不进；目录来源只读 .tsv。
#      双源混合（nvn_pso_skey.h pso_dual_source）：RGBA8Unorm@0 开混合、目标色因子 ONE_MINUS_SRC1_COLOR(0x11) → 有符号 100（位 8）；同样因子但画布 0 没开混合、或开混合但因子是
#      ONE / ONE_MINUS_SRC_ALPHA → 不出；rt_fout 行「键 0 100」进、「0 200」（超出位 8）不进。
#   ② ft_masks（表 FOUT_WANT[键] 由本测给，键不在表里 = 空请求）：双源位 8 不按颜色过滤：颜色 [0] 时 {(0,100)} → [(0,100)]；颜色 [0, 1] 时 {(3,0), (1,2), (0,0)} → [(1,2), (3,0)]；有 main0_u 且 u_mask = 3 → (3,0) 去掉；颜色只有 [1] → [(0,2), (2,0)]；没有颜色信息 → 不过滤；表里没有这个键 → []
#   反证：dsh_cmp 没有 ft_masks 入口即红；fout_want.py 不存在即红；布局 JSON 里画布格式偏移挪 4 字节（模拟结构体改了没重导）→ ① 的请求表必须变（11-04 Windows 出包线：出库改用 Python 读提交的布局）
import atexit, collections, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '../../../..')); NVN = os.path.join(ROOT, 'graphics/nvn/gfx/nvn')
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

t = tempfile.mkdtemp(prefix='t_fout_want_'); atexit.register(shutil.rmtree, t, True)
cc = lambda src, exe: subprocess.run(['clang', '-fobjc-arc', '-I', NVN, '-I', os.path.join(NVN, 'include'), src, '-framework', 'Foundation', '-o', exe], capture_output=True, text=True)
DIRECT = os.path.join(ROOT, 'graphics/tools/direct')
r = cc(os.path.join(DIRECT, 'pso_layout_gen.m'), os.path.join(t, 'pso_layout_gen'))
if r.returncode: sys.exit(f'✗ pso_layout_gen.m 编不过：{r.stderr[-600:]}')
gen_json = subprocess.run([os.path.join(t, 'pso_layout_gen')], capture_output=True, text=True, check=True).stdout
check(gen_json == open(os.path.join(DIRECT, 'pso_layout.json'), encoding='utf-8').read(),
      '⓪ 提交的 pso_layout.json = 现编 pso_layout_gen 导出（不一致：结构体或像素格式判定改了，跑 pso_layout_gen > graphics/tools/direct/pso_layout.json 重导）')
GEN = r'''#import <Foundation/Foundation.h>
#import <Metal/MTLPixelFormat.h>
@interface NvShader : NSObject { @public int stage; char key[24]; } @end
@implementation NvShader @end
#include "nvn_pso_skey.h"
#include <stdio.h>
static void rowb(const char *fs, const uint32_t cf[8], int merged, const uint8_t lm[8], int fz, uint32_t ben, uint32_t src, uint32_t dst) {
    pso_key k; memset(&k, 0, sizeof k); memcpy(k.cfmt, cf, sizeof k.cfmt); if (lm) memcpy(k.lmap, lm, 8); if (fz) k.fsfn = (const void *)1;
    k.blend_en = ben; k.blend[0].src_rgb = src; k.blend[0].dst_rgb = dst; k.blend[0].src_a = src; k.blend[0].dst_a = dst;
    NvShader *v = [NvShader new]; strcpy(v->key, "1111111111111111_b"); NvShader *f = nil;
    if (fs) { f = [NvShader new]; f->stage = 1; strcpy(f->key, fs); }
    pso_skey sk; pso_fz_desc z = {0}; pso_skey_from(&k, v, f, merged, fz ? &z : NULL, &sk);
    char h[sizeof sk * 2 + 1]; pso_skey_hex(&sk, h); printf("R\t%s\n", h);
}
static void row(const char *fs, const uint32_t cf[8], int merged, const uint8_t lm[8], int fz) { rowb(fs, cf, merged, lm, fz, 0, 0, 0); }
int main(void) {
    const uint32_t a[8] = {MTLPixelFormatR32Uint, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRG16Sint};
    const uint32_t b[8] = {MTLPixelFormatR32Uint, MTLPixelFormatR8Sint, MTLPixelFormatR32Uint}; const uint8_t lm[8] = {2, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    const uint32_t fl[8] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float};
    row("aaaaaaaaaaaaaaaa_b", a, 0, NULL, 0); row("aaaaaaaaaaaaaaaa_b", b, 1, lm, 0); row("cccccccccccccccc_b", a, 0, NULL, 1);
    row(NULL, a, 0, NULL, 0); row("dddddddddddddddd_b", fl, 0, NULL, 0); row("aaaaaaaaaaaaaaaa_b", a, 0, NULL, 0);
    rowb("ffffffffffffffff_b", fl, 0, NULL, 0, 1, 2, 0x11);     // ONE, ONE_MINUS_SRC1_COLOR on target 0 → dual
    rowb("9999999999999999_b", fl, 0, NULL, 0, 0, 2, 0x11);     // same factors, blending off → nothing
    rowb("8888888888888888_b", fl, 0, NULL, 0, 1, 2, 6);        // ONE, ONE_MINUS_SRC_ALPHA → nothing
    printf("S\taaaaaaaaaaaaaaaa_b\t1\nR\t00ff\n");
    return 0;
}
'''
open(os.path.join(t, 'gen.m'), 'w').write(GEN)
r = cc(os.path.join(t, 'gen.m'), os.path.join(t, 'gen'))
if r.returncode: sys.exit(f'✗ 生成器编不过：{r.stderr[-600:]}')
os.makedirs(os.path.join(t, 'seed'))
open(os.path.join(t, 'seed', 'pso_user.tsv'), 'w').write(subprocess.run([os.path.join(t, 'gen')], capture_output=True, text=True, check=True).stdout)
open(os.path.join(t, 'seed', 'rt_fout.tsv'), 'w').write('# 键\t无符号\t有符号\nbbbbbbbbbbbbbbbb\t2\t0\nbbbbbbbbbbbbbbbb\t2\tzz\nbbbbbbbbbbbbbbbb\t4\nbbbbbbbbbbbbbbbb\t0\t100\nbbbbbbbbbbbbbbbb\t0\t200\n')
open(os.path.join(t, 'seed', 'notes.txt'), 'w').write('eeeeeeeeeeeeeeee\t1\t0\n')   # 目录来源只读 .tsv
o = os.path.join(t, 'fout_want.tsv')
r = subprocess.run([sys.executable, os.path.join(DIRECT, 'fout_want.py'), o, os.path.join(t, 'seed'), os.path.join(t, 'missing')], capture_output=True, text=True)
rows = [l for l in open(o).read().splitlines() if not l.startswith('#')] if os.path.exists(o) else None
want = ['aaaaaaaaaaaaaaaa\t1\t4', 'aaaaaaaaaaaaaaaa\t4\t1', 'bbbbbbbbbbbbbbbb\t0\t100', 'bbbbbbbbbbbbbbbb\t2\t0', 'ffffffffffffffff\t0\t100']
check(r.returncode == 0 and rows == want, f'① 请求表 = {want}（rc {r.returncode}，实得 {rows}；{r.stdout.strip()[-120:]}）')
check('5 条请求' in r.stdout, f'① 汇总行报 5 条（{r.stdout.strip()[-120:]}）')
# 反证：工具副本配一份画布格式偏移挪了 4 字节的布局 → 请求表必须变（证明 ① 真按 JSON 布局解，不是碰巧）
import json
bad = os.path.join(t, 'bad'); os.makedirs(bad)
for f in ('fout_want.py', 'pso_layout.py'): shutil.copyfile(os.path.join(DIRECT, f), os.path.join(bad, f))
lay = json.load(open(os.path.join(DIRECT, 'pso_layout.json'), encoding='utf-8')); lay['cfmt'] += 4
json.dump(lay, open(os.path.join(bad, 'pso_layout.json'), 'w'))
ob = os.path.join(t, 'bad.tsv'); subprocess.run([sys.executable, os.path.join(bad, 'fout_want.py'), ob, os.path.join(t, 'seed')], capture_output=True, text=True)
rows_bad = [l for l in open(ob).read().splitlines() if not l.startswith('#')] if os.path.exists(ob) else None
check(rows_bad is not None and rows_bad != want, f'① 反证：布局偏移挪 4 字节 → 请求表变了（{rows_bad}）')

# ② ft_masks：C# DshFt.Masks(反射, 请求)；FOUT_WANT 由本测给（键不在表里 → 空请求）
sys.path.insert(0, HERE); import dshfn
FOUT_WANT = {'k': [[3, 0], [1, 2], [0, 0]], 'd': [[0, 0x100]]}
def fm(key, refl):
    r = dshfn.batch([('ft_masks', [refl, FOUT_WANT.get(key, [])])])[0]
    if 'ok' not in r: sys.exit(f'✗ dsh_cmp ft_masks 失败：{r}')
    return [tuple(x) for x in r['ok']]
check(fm('k', {'raster': {'colors': [0, 1]}}) == [(0, 0x100), (1, 2), (3, 0)], f'② 颜色 [0, 1] → 请求 [(1,2), (3,0)] + 静态双源 (0,100)（{fm("k", {"raster": {"colors": [0, 1]}})}）')
check(fm('k', {'raster': {'colors': [0, 1]}, 'entry_u': 'main0_u', 'u_mask': 3}) == [(0, 0x100), (1, 2)], '② u_mask = 3 时 (3,0) 由 main0_u 担 → [(0,100), (1,2)]')
check(fm('x', {'raster': {'colors': [0, 1]}}) == [(0, 0x100)], f'② 双源静态判：表里没有的键、只写颜色 0 与 1 → [(0,100)]（WWZ 两支修前无变体）（{fm("x", {"raster": {"colors": [0, 1]}})}）')
check(fm('x', {'raster': {'colors': [0, 1, 2]}}) == [] and fm('x', {'raster': {'colors': [1]}}) == [] and fm('x', {}) == [], '② 反证：写 0/1/2（多目标）、只写 1、没有颜色信息 → 不加双源')
check(fm('k', {'raster': {'colors': [1]}}) == [(0, 2), (2, 0)], f'② 只写 color(1) → [(0,2), (2,0)]（{fm("k", {"raster": {"colors": [1]}})}）')
check(fm('k', {}) == [(1, 2), (3, 0)], '② 没有颜色信息 → 不过滤')
check(fm('x', {'raster': {'colors': [0]}}) == [], '② 表里没有的键 → []')
check(fm('d', {'raster': {'colors': [0]}}) == [(0, 0x100)], f'② 双源位 8 不按颜色过滤 → [(0,100)]（{fm("d", {"raster": {"colors": [0]}})}）')

print(f't_fout_want：{"全符" if not fails else f"{len(fails)} 例不符"}（布局 JSON 1 份；请求表 5 条 + 反证 1 / 生成器 10 行 + rt_fout 5 行；过滤 8 例）')
sys.exit(1 if fails else 0)
