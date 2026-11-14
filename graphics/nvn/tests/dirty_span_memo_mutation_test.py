#!/usr/bin/env python3
"""线程内备忘（#974 问 3）的点变异：每个变异体在 build/ 下的临时副本里各编一份，对应的单测必须红在指定的断言上；源码树不动。

  find_span 的备忘（nvn_dirty.c）  → t_dirty_span_memo.c（直接包含变异副本，只编这一个文件）
  池查找的备忘（rp_entry.c）        → t_nvn_replay.c（与 native-test-nvn_replay 同款编法，只把 rp_entry.c 换成变异副本）

放不进来的（宿主上无法确定性触发，或去掉后答案不变）：
  - find_span 记录前「扫描后再读一次代际」那道复查（seqlock 读者惯用式）：去掉它，单线程与宿主测试里答案不变；
    由 t_dirty_span_memo.c 的并发用例做压力，不在这里声称能杀。
  - find_span 里「奇数代际」的判断在命中侧与记录侧各有一道（与 g_prep_miss 同款）：只去掉其中一道答案不变，所以下面的变异体两道一起去。
  - 池备忘的区间上界 lim：池互不重叠时去掉它答案不变（只在池嵌套时才影响候选是谁）。

用法：python3 dirty_span_memo_mutation_test.py [dirty|pool]   （缺省两半都跑）
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/span-memo-mutations'
OUT.mkdir(parents=True, exist_ok=True)
CC = os.environ.get('CC', 'cc')

DIRTY = 'graphics/nvn/gfx/nvn/nvn_dirty.c'
ENTRY = 'graphics/nvn/replay/rp_entry.c'

# ---------- find_span 备忘（nvn_dirty.c）：(名字, [(旧, 新) …], 期望单测里出现的断言文字) ----------
BUMP = '    atomic_fetch_add(&g_table_epoch, 1);\n'
HIT_GUARD = 'if (!(epoch & 1)) {   // 奇数 = 有写者正在改表：不信备忘，也不记'
REC_GUARD = 'if (!(epoch & 1) && atomic_load_explicit(&g_table_epoch, memory_order_relaxed) == epoch)'
dirty_mutations = [
    ('命中第一路不比代际', [('if (w0->epoch == epoch && w0->a == a && w0->len == len)', 'if (w0->epoch && w0->a == a && w0->len == len)')],
     '登记之后，旧的「没有」作废'),
    ('命中第二路不比代际', [('if (w1->epoch == epoch && w1->a == a && w1->len == len)', 'if (w1->epoch && w1->a == a && w1->len == len)')],
     '第二路要比代际'),
    ('第一路键里不比长度', [('w0->a == a && w0->len == len) { g_span_hits++;', 'w0->a == a) { g_span_hits++;')], '同族键的答案不能串'),
    ('第二路键里不比长度', [('w1->a == a && w1->len == len) { g_span_hits++;', 'w1->a == a) { g_span_hits++;')], '同族键的答案不能串'),
    ('第一路键里不比起点', [('w0->a == a && w0->len == len) { g_span_hits++;', 'w0->len == len) { g_span_hits++;')], '同族键的答案不能串'),
    ('第二路键里不比起点', [('w1->a == a && w1->len == len) { g_span_hits++;', 'w1->len == len) { g_span_hits++;')], '同族键的答案不能串'),
    ('奇数代际也信也记（两道判断一起去）',
     [(HIT_GUARD, 'if (1) {   // 变异：奇数代际也信'),
      (REC_GUARD, 'if (atomic_load_explicit(&g_table_epoch, memory_order_relaxed) == epoch)')], '奇数代际：不信旧记录'),
    ('关闭开关被无视', [('const unsigned bits = atomic_load_explicit(&g_span_memo_bits, memory_order_relaxed);',
                         'unsigned bits = atomic_load_explicit(&g_span_memo_bits, memory_order_relaxed); if (!bits) bits = 1;')], '关着：一次也不命中'),
    ('容量不夹上限', [('log2_entries > SPAN_MEMO_LOG2 ? (unsigned)SPAN_MEMO_LOG2 : log2_entries', 'log2_entries')], '超过上限按上限'),
    ('登记收工不加代际', [('    atomic_store_explicit(&r->live, 1, memory_order_release);\n' + BUMP, '    atomic_store_explicit(&r->live, 1, memory_order_release);\n')],
     '写者「登记」收工后代际'),
    ('注销收工不加代际', [('atomic_fetch_sub(&g_live, 1); }\n' + BUMP, 'atomic_fetch_sub(&g_live, 1); }\n')], '写者「注销」收工后代际'),
    ('重置会话收工不加代际', [('atomic_store(&g_hooks_on, 0);\n' + BUMP, 'atomic_store(&g_hooks_on, 0);\n')], '写者「重置会话」收工后代际'),
    ('原地换底收工不加代际',
     [(BUMP + '    pthread_mutex_unlock(&g_slot_mu);\n    return 1;\n}\nuint64_t nvn_dirty_mapping_generation',
       '    pthread_mutex_unlock(&g_slot_mu);\n    return 1;\n}\nuint64_t nvn_dirty_mapping_generation')], '写者「原地换底」收工后代际'),
    ('登记完全不动代际', [('pthread_mutex_lock(&g_slot_mu);\n' + BUMP + '    int n = atomic_load(&g_nr);\n    int slot = -1;\n',
                           'pthread_mutex_lock(&g_slot_mu);\n    int n = atomic_load(&g_nr);\n    int slot = -1;\n'),
                          ('    atomic_store_explicit(&r->live, 1, memory_order_release);\n' + BUMP, '    atomic_store_explicit(&r->live, 1, memory_order_release);\n')],
     '登记之后，旧的「没有」作废'),
    ('注销完全不动代际', [(BUMP + '    range_t *r = NULL; int n = atomic_load(&g_nr);\n', '    range_t *r = NULL; int n = atomic_load(&g_nr);\n'),
                          ('atomic_fetch_sub(&g_live, 1); }\n' + BUMP, 'atomic_fetch_sub(&g_live, 1); }\n')],
     '注销之后，旧的命中作废'),
]

# ---------- 池查找备忘（rp_entry.c） ----------
pool_mutations = [
    ('池备忘不比代际', [('if (m->epoch != ep || addr < m->a || addr >= m->lim) continue;', 'if (!m->epoch || ep == 0 || addr < m->a || addr >= m->lim) continue;')],   # 代际不再比对（ep 从 1 起，ep == 0 恒假，只为不留未用变量告警）
     '0x200 + 0x10, 8) && rp_pool_find'),
    ('池备忘装不下也算命中',
     [('if (addr - m->a > m->n || len > m->n - (addr - m->a)) return 0;   // 候选是它但装不下：锁内二分同样判不命中，交给锁内', '/* 变异：不判装不装得下 */')],
     'pm_check(B + 0xf80, 0x100)'),
    ('池备忘给错长度', [('if (size) *size = m->n;', 'if (size) *size = m->n + 1;')], 'pm_check(B + 0x800, 0x100)'),
    ('池备忘关着也查', [('if (!on) return 0;', '/* 变异：关着也查 */')], 'pm_hits() == hz && pm_lookups() == lz'),
]

compile_flags = ['-O2', '-g', '-Wall', '-Wextra', '-Wno-unused-parameter']


def mutate(source, edits, name):
    for old, new in edits:
        if source.count(old) != 1:
            raise SystemExit('%s：变异锚点不唯一或不存在（%d 处）：%r' % (name, source.count(old), old[:70]))
        source = source.replace(old, new)
    return source


def run_dirty(name, code):
    src = OUT / ('dirty_%s.c' % name)
    src.write_text(code, encoding='utf-8')
    exe = OUT / ('dirty_%s' % name)
    subprocess.run([CC, *compile_flags, '-I' + str(ROOT / 'runtime/include'), '-I' + str(ROOT / 'graphics/nvn/gfx/nvn'), '-pthread',
                    '-DNVN_DIRTY_SPAN_MEMO_SOURCE="%s"' % src, '-o', str(exe), str(ROOT / 'graphics/nvn/tests/t_dirty_span_memo.c')],
                   check=True, cwd=ROOT)
    return subprocess.run([str(exe)], capture_output=True, text=True, cwd=ROOT, timeout=180)


pool_other = ['graphics/nvn/tests/t_nvn_replay.c', 'graphics/nvn/tests/nvn_clear_view_unused.c',
              *('graphics/nvn/replay/' + x for x in ('rp_exec.c', 'rp_copy_t2b.c', 'rp_clear_tex.c', 'rp_state.c', 'rp_res.c', 'rp_buf.c', 'rp_pass.c',
                                                      'rp_present.c', 'rp_draw.c', 'nvn_unimpl.c')),
              'graphics/nvn/gfx/nvn/nvn_tex.c', 'graphics/nvn/gfx/tex/nvn_deswizzle.c']
pool_flags = [*compile_flags, '-std=c11', '-D_DEFAULT_SOURCE', '-Werror',
              *('-I' + str(ROOT / x) for x in ('.', 'graphics/nvn/gfx/nvn', 'graphics/nvn/gfx/nvn/include', 'graphics/nvn/gfx/tex', 'graphics/nvn/replay'))]
pool_objs = []


def pool_build_others():
    for x in pool_other:   # 不变的部分只编一次，每个变异体只重编 rp_entry.c 再链接
        o = OUT / ('pool_obj_%s.o' % Path(x).stem)
        subprocess.run([CC, *pool_flags, '-c', str(ROOT / x), '-o', str(o)], check=True, cwd=ROOT)
        pool_objs.append(str(o))


def run_pool(name, code):
    src = OUT / ('pool_%s.c' % name)
    src.write_text(code, encoding='utf-8')
    obj = OUT / ('pool_%s.o' % name)
    subprocess.run([CC, *pool_flags, '-c', str(src), '-o', str(obj)], check=True, cwd=ROOT)
    exe = OUT / ('pool_%s' % name)
    subprocess.run([CC, *pool_objs, str(obj), '-lm', '-o', str(exe)], check=True, cwd=ROOT)
    return subprocess.run([str(exe), str(ROOT / 'docs/直连_Vulkan回放接线表.tsv')], capture_output=True, text=True, cwd=ROOT, timeout=180)


def expect_red(name, r, want):
    out = r.stdout + r.stderr
    if r.returncode == 0:
        raise SystemExit(name + '：变异体居然通过了（单测没拦住）')
    if want not in out:
        raise SystemExit(name + '：红在别处，期望断言含 %r\n%s' % (want, out[-1500:]))
    print('  %s：已拦住（红在「%s」）' % (name, want), flush=True)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ''
    done = 0
    if only != 'pool':
        dirty_src = (ROOT / DIRTY).read_text(encoding='utf-8')
        pos = run_dirty('positive', dirty_src)
        if pos.returncode:
            raise SystemExit('find_span 备忘：正对照没过\n' + pos.stdout + pos.stderr)
        print('find_span 备忘 正对照：', pos.stdout.strip().splitlines()[-1], flush=True)
        for i, (name, edits, want) in enumerate(dirty_mutations):
            expect_red(name, run_dirty('m%d' % i, mutate(dirty_src, edits, name)), want)
            done += 1
    if only != 'dirty':
        entry_src = (ROOT / ENTRY).read_text(encoding='utf-8')
        pool_build_others()
        ppos = run_pool('positive', entry_src)
        if ppos.returncode:
            raise SystemExit('池查找备忘：正对照没过\n' + ppos.stdout + ppos.stderr)
        print('池查找备忘 正对照：', [l for l in ppos.stdout.splitlines() if '项检查' in l][-1:], flush=True)
        for i, (name, edits, want) in enumerate(pool_mutations):
            expect_red(name, run_pool('m%d' % i, mutate(entry_src, edits, name)), want)
            done += 1
    print('PASS: 线程内备忘 %d 个变异体全部被单测拦住' % done)


main()
