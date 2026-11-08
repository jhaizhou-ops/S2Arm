#!/usr/bin/env python3
"""tools/metal_compile_prof.py 单测：MSL 顶层切分 / 删函数体 / 语句块切分 / 夹具段切分，
以及（本机有 metal 时）measure / sections / bisect 三条路的端到端读数与只读性。

读数期望由夹具本身定，不跑被测实现也能算：128 KB 夹具 4 段各有 kernel，bisect 的小夹具里
一个函数体占全文件九成语句，二分必须收敛到它。
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import metal_compile_prof as prof  # noqa: E402

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
fails = 0


def check(name, want, got):
    global fails
    ok = want == got
    fails += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want}，实 {got}")


SAMPLE = '''#include <metal_stdlib>
using namespace metal;

constant float kScale = 1.5f;

struct Payload {
  float4 tint;
  float weight;
};

static inline float heavy(float x) {
  float a = x;
  if (a > 0.5f) {
    a = a * 2.0f;
  } else {
    a = a - 1.0f;
  }
  return a;
}

[[clang::always_inline]] static void voidish(float x) {
  return;
}

kernel void k(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
  float a = heavy(float(gid.x));
  if (a > 1.0f) { a = a * 0.5f; }
  if (a > 2.0f) { a = a - 3.0f; }
  out.write(float4(a), gid);
}
'''


def test_scan():
    units = prof.scan_units(SAMPLE)
    kinds = [u.kind for u in units]
    check('顶层单元数', 7, len(units))
    check('函数个数', 3, kinds.count('func'))
    check('struct 归 type', 1, kinds.count('type'))
    check('预处理行', 1, kinds.count('pp'))
    names = [u.name for u in units if u.kind == 'func']
    check('函数名按出现顺序', ['heavy', 'voidish', 'k'], names)
    void_unit = [u for u in units if u.name == 'voidish'][0]
    check('void 函数识别', True, void_unit.returns_void)
    check('非 void 函数识别', False, [u for u in units if u.name == 'heavy'][0].returns_void)

    blanked = prof.blank_edit(void_unit, SAMPLE)
    check('void 函数体删成空', True, blanked[2].strip().endswith('voidish(float x) {}'))
    check('非 void 函数体删成 return {}', '{ return {}; }',
          prof.blank_edit([u for u in units if u.name == 'heavy'][0], SAMPLE)[2]
          .split('heavy(float x) ')[1].split('\n}')[0].strip())
    text = prof.apply_edits(SAMPLE, [blanked])
    check('删完仍是 3 个函数', 3, len([u for u in prof.scan_units(text) if u.kind == 'func']))
    check('删完签名还在', 'voidish', [u.name for u in prof.scan_units(text) if u.kind == 'func'][1])


def test_statements():
    body = ('  float a = x;\n'
            '  if (a > 1.0f) { a = a * 2.0f; } else { a = a - 1.0f; }\n'
            '  for (int i = 0; i < 4; i++) { a += float(i); }\n'
            '  a = a * 0.5f;\n'
            '  return a;\n')
    chunks = prof.scan_statements(body)
    check('顶层语句块数', 5, len(chunks))
    texts = [body[s:e].strip() for s, e in chunks]
    check('第 2 块是整条 if-else', True, texts[1].startswith('if (a > 1.0f)') and texts[1].endswith('}'))
    check('第 3 块是整条 for', True, texts[2].startswith('for (') and texts[2].endswith('}'))
    check('最后一块是 return', 'return a;', texts[-1])


def test_sections():
    text = ('//#region section alpha\nstatic float a() { return 1.0f; }\n//#endregion section alpha\n'
            '//#region section beta\nstatic float b() { return 2.0f; }\n//#endregion section beta\n')
    got = prof.split_sections(text)
    check('切段名', ['alpha', 'beta'], [name for name, _ in got])
    check('段内只含本段', True, 'static float b()' not in got[0][1] and 'static float a()' not in got[1][1])


def have_metal():
    try:
        proc = subprocess.run(['xcrun', '-sdk', 'iphoneos', 'metal', '--version'],
                              capture_output=True, timeout=120)
        return proc.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


BISECT_FIXTURE = '''#include <metal_stdlib>
using namespace metal;

static float small_a(float x) { return x + 1.0f; }
static float small_b(float x) { return x * 2.0f; }
static float small_c(float x) { return x - 3.0f; }
static float small_d(float x) { return x / 4.0f; }
static float small_e(float x) { return x + 5.0f; }
static float small_f(float x) { return x * 6.0f; }
static float hot(float x, device const float *src) {
  float a = x;
''' + ''.join(f'  a = a * 1.0001f + src[{i % 37}];\n' for i in range(12000)) + '''  return a;
}
kernel void k(device float *out [[buffer(0)]], device const float *src [[buffer(1)]],
              uint gid [[thread_position_in_grid]]) {
  float a = small_a(hot(float(gid), src));
  a += small_b(a) + small_c(a) + small_d(a) + small_e(a) + small_f(a);
  out[gid] = a;
}
'''


def test_generator_reproducible(tmp):
    """同参数重跑逐字节相同：别人能重造同样大小同样结构的夹具。"""
    gen = ROOT / 'tests' / 'metal_prof' / 'gen_fixtures.py'
    outputs = []
    for name in ('a.metal', 'b.metal'):
        path = os.path.join(tmp, name)
        subprocess.run([sys.executable, str(gen), '--target', '128KB', '--out', path, '-q'], check=True)
        outputs.append(hashlib.sha256(Path(path).read_bytes()).hexdigest())
    check('生成器可复现（两次逐字节相同）', True, outputs[0] == outputs[1])
    check('夹具带四种结构标记', True,
          all(f'//#region section {s}' in Path(os.path.join(tmp, 'a.metal')).read_text(encoding='utf-8')
              for s in ('deep_if', 'big_switch', 'huge_body', 'inline')))


class FakeCompiler:
    """确定的假计时：编译秒数 = 文件里分号数 × 1 毫秒。hot 的函数体占九成分号，二分必须收敛到它（期望由夹具定，不跑被测实现）"""
    def __init__(self, *args, **kwargs):
        self.calls = 0

    def time_median(self, source, reps, warmup):
        self.calls += 1
        t = Path(source).read_text(encoding='utf-8').count(';') * 1e-3
        return t, t, t, 0


def test_bisect_logic(tmp):
    """二分逻辑（不编译、不计时）：换上 FakeCompiler 跑 bisect 整条路。"""
    small = os.path.join(tmp, 'bisect_logic.metal')
    Path(small).write_text(BISECT_FIXTURE, encoding='utf-8')
    before = hashlib.sha256(Path(small).read_bytes()).hexdigest()
    log = os.path.join(tmp, 'bisect_logic.log')
    real = prof.Compiler
    prof.Compiler = FakeCompiler
    try:
        rc = prof.main(['bisect', small, '--reps', '1', '--log', log, '--min-effect', '0.05'])
    finally:
        prof.Compiler = real
    check('二分逻辑 退出码', 0, rc)
    text = Path(log).read_text(encoding='utf-8')
    check('二分逻辑 收敛到 hot', True, '最热：hot' in text)
    check('二分逻辑 语句块层给结论', True, '其中 块#' in text or '没有占主导的单块' in text
          or '没有可再删的语句块' in text)
    check('二分逻辑 日志带每轮记录（6 个候选函数至少 3 轮）', True, text.count('第 ') >= 3)
    check('二分逻辑 报出函数贡献秒数', True, '的函数体贡献' in text)
    check('二分逻辑 不改输入', before, hashlib.sha256(Path(small).read_bytes()).hexdigest())


def test_end_to_end(tmp):
    """真编译：measure / sections / bisect 走一遍，并核输入文件没被改。"""
    gen = ROOT / 'tests' / 'metal_prof' / 'gen_fixtures.py'
    fixture = os.path.join(tmp, 'fixture_128k.metal')
    subprocess.run([sys.executable, str(gen), '--target', '128KB', '--out', fixture, '-q'], check=True)
    before = hashlib.sha256(Path(fixture).read_bytes()).hexdigest()

    tsv = os.path.join(tmp, 'measure.tsv')
    proc = subprocess.run([sys.executable, str(ROOT / 'tools' / 'metal_compile_prof.py'), 'measure',
                           fixture, '--reps', '1', '--warmup', '0', '--out', tsv],
                          capture_output=True, text=True)
    check('measure 退出码', 0, proc.returncode)
    if proc.returncode == 0:
        rows = Path(tsv).read_text(encoding='utf-8').strip().splitlines()
        check('measure 表头', 'file\tbytes\tmib\tfunctions\treps\tmedian_s\tmin_s\tmax_s\ts_per_mib\tair_bytes'
              '\tcalib_s\tload1', rows[0])
        check('measure 一行读数', 2, len(rows))
        fields = rows[1].split('\t')
        check('读数里的字节数是真文件大小', str(os.path.getsize(fixture)), fields[1])
        check('函数数大于 0', True, int(fields[3]) > 0)
        check('编译秒数大于 0', True, float(fields[5]) > 0)

    stsv = os.path.join(tmp, 'sections.tsv')
    proc = subprocess.run([sys.executable, str(ROOT / 'tools' / 'metal_compile_prof.py'), 'sections',
                           fixture, '--reps', '1', '--warmup', '0', '--out', stsv],
                          capture_output=True, text=True)
    check('sections 退出码', 0, proc.returncode)
    if proc.returncode == 0:
        rows = Path(stsv).read_text(encoding='utf-8').strip().splitlines()
        check('sections 四段', 5, len(rows))
        names = [r.split('\t')[1] for r in rows[1:]]
        check('段名', ['deep_if', 'big_switch', 'huge_body', 'inline'], names)

    # 真编译只核这条路走得通、日志成形、不改输入：二分选哪一半靠单次编译计时，满负载机器上（门禁全套并发）会被噪声带偏，
    #   「收敛到 hot」这类结论由 test_bisect_logic 用确定的假计时证明（10-31 合入线：mini 全套时两条结论断言红过 5 次）
    small = os.path.join(tmp, 'bisect.metal')
    Path(small).write_text(BISECT_FIXTURE, encoding='utf-8')
    small_before = hashlib.sha256(Path(small).read_bytes()).hexdigest()
    log = os.path.join(tmp, 'bisect.log')
    proc = subprocess.run([sys.executable, str(ROOT / 'tools' / 'metal_compile_prof.py'), 'bisect',
                           small, '--reps', '1', '--log', log, '--min-effect', '0.05'],
                          capture_output=True, text=True, timeout=900)
    check('bisect 退出码', 0, proc.returncode)
    if proc.returncode == 0:
        text = Path(log).read_text(encoding='utf-8')
        check('bisect 日志有函数级二分与结论行', True, '函数级二分' in text and '结论：' in text)
    check('bisect 不改输入', small_before, hashlib.sha256(Path(small).read_bytes()).hexdigest())
    check('夹具没被工具改动', before, hashlib.sha256(Path(fixture).read_bytes()).hexdigest())


def main():
    test_scan()
    test_statements()
    test_sections()
    tmp0 = tempfile.mkdtemp(prefix='metal_prof_logic_')
    try:
        test_bisect_logic(tmp0)
    finally:
        shutil.rmtree(tmp0, ignore_errors=True)
    if not have_metal():
        print('跳过编译实测：本机 xcrun -sdk iphoneos metal --version 不通（纯解析部分已验）')
        return 1 if fails else 0
    tmp = tempfile.mkdtemp(prefix='metal_prof_test_')
    try:
        test_generator_reproducible(tmp)
        test_end_to_end(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"{'全部通过' if not fails else f'{fails} 项不通'}")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
