#!/usr/bin/env python3
# 编译时盘写满不能当成「这一支编不过、其余照出」（#265）：dsh_batch --metal-compile 走真实的 Metal.Init + Compile（graphics/tools/direct/dsh/batch/Build.cs），
#   PATH 前面放假 xcrun 注入编译器输出。期望按 Build.cs 的分类规则手写：
#   ① 编译器报 No space left on device → 整次停（退出 2，原话带 No space left on device，出包作业据此报 disk_full）
#   ② 普通语法错 → 只记这一支编不过（退出 1），不整次停
#   ③ 编译器报 LLVM ERROR: Error opening（11-09 外部报告：中文用户名路径，metallib 用 ANSI 代码页开文件失败）→ 整次停（退出 2），不逐支记编不过
#   ④ 全败熔断：70 支全编不过、一支没编成 → 第 64 支编不过时整次停（退出 2、编译器调用 128 次 = 64 支 × 两次），原先 70 支全记编不过退 0 出空库
#   ⑤ 先编成一支、之后 70 支编不过 → 不熔断（退出 1、70 failed）：逐支编不过是翻译缺陷，照旧只记
#   ⑥ Windows 路径改写（Metal.WinRelative，--win-relative）：带空格 / 非 ASCII 的路径参数改成相对工作区（含 -xxx=<路径>），纯 ASCII 不动；不在工作区下的报停
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

FAKE = '''#!/bin/sh
case " $* " in
  *" --version "*) echo "Apple metal version 32023.999 (fake)"; exit 0;;
  *" --show-sdk-version "*) echo 99.0; exit 0;;
  *" --show-sdk-build-version "*) echo FAKE1; exit 0;;
esac
echo "$FAKE_ERR" >&2; exit 1
'''
def run(err):
    with tempfile.TemporaryDirectory() as t:
        b = os.path.join(t, 'bin'); os.makedirs(b); x = os.path.join(b, 'xcrun'); open(x, 'w').write(FAKE); os.chmod(x, 0o755)
        src = os.path.join(t, 'k1.metal'); open(src, 'w').write('kernel void k() {}\n')
        w = os.path.join(t, 'work'); os.makedirs(w)
        env = dict(os.environ, PATH=b + os.pathsep + os.environ['PATH'], FAKE_ERR=err, S2A_METAL_PCH='0')
        return subprocess.run([*CMD, '--metal-compile', w, src], capture_output=True, text=True, env=env)

r = run("error: unable to open output file '/x/k1.air': 'No space left on device'")
check(r.returncode == 2 and 'No space left on device' in r.stdout, f'① 盘写满 → 整次停、原话带 No space left on device（实得 {r.returncode}：{r.stdout.strip()[:160]}{r.stderr.strip()[:200]}）')
r = run("k1.metal:1:15: error: expected expression")
check(r.returncode == 1 and 'expected expression' in r.stdout, f'② 普通语法错 → 只记这一支编不过（实得 {r.returncode}：{r.stdout.strip()[:160]}）')
FAKE2 = '''#!/bin/bash
case " $* " in
  *" --version "*) echo "Apple metal version 32023.999 (fake)"; exit 0;;
  *" --show-sdk-version "*) echo 99.0; exit 0;;
  *" --show-sdk-build-version "*) echo FAKE1; exit 0;;
esac
out=; prev=; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
case " $* " in *" metallib "*) printf lib > "$out"; exit 0;; esac
echo compile >> "$FAKE_LOG"
case " $* " in *"/ok"*".metal "*) printf air > "$out"; exit 0;; esac
echo "k.metal:1:1: error: expected expression" >&2; exit 1
'''
def many(names):
    with tempfile.TemporaryDirectory() as t:
        b = os.path.join(t, 'bin'); os.makedirs(b); x = os.path.join(b, 'xcrun'); open(x, 'w').write(FAKE2); os.chmod(x, 0o755)
        srcs = []
        for n in names:
            s = os.path.join(t, n + '.metal'); open(s, 'w').write(f'kernel void {n}() {{}}\n'); srcs.append(s)
        w = os.path.join(t, 'work'); os.makedirs(w); log = os.path.join(t, 'calls')
        env = dict(os.environ, PATH=b + os.pathsep + os.environ['PATH'], FAKE_LOG=log, S2A_METAL_PCH='0')
        r = subprocess.run([*CMD, '--metal-compile', w, *srcs], capture_output=True, text=True, env=env)
        return r, (len(open(log).read().split()) if os.path.exists(log) else 0)

r = run("LLVM ERROR: Error opening 'C:\\Users\\测试\\k1.air': 在多字节的目标代码页中，没有此 Unicode 字符可以映射到的字符。")
check(r.returncode == 2 and '编译器打不开文件' in r.stdout, f'③ 打不开文件 → 整次停（实得 {r.returncode}：{r.stdout.strip()[:160]}）')
r, calls = many([f'bad{i}' for i in range(70)])
check(r.returncode == 2 and '连续 64 支编不过' in r.stdout and calls == 128, f'④ 70 支全编不过 → 第 64 支整次停、编译调用 128 次（实得 {r.returncode}、{calls} 次：{r.stdout.strip()[:160]}）')
r, calls = many(['ok0'] + [f'bad{i}' for i in range(70)])
check(r.returncode == 1 and 'mac 0 reused, 1 compiled, 70 failed' in r.stdout, f'⑤ 先编成一支再连败 70 支 → 不熔断、70 failed（实得 {r.returncode}：{r.stdout.strip()[-120:]}）')
with tempfile.TemporaryDirectory() as t:
    cwd = os.path.join(t, '萧小五11', 'j', 'r2px'); os.makedirs(cwd)
    a = [os.path.join(cwd, 'ios-0f', 'k.metal'), '-o', os.path.join(cwd, 'ios-0f', 'k.air'), '-fmodules-cache-path=' + os.path.join(cwd, 'pch-ios', 'mcache'), '-w', '/opt/ascii/x.h']
    r = subprocess.run([*CMD, '--win-relative', cwd, *a], capture_output=True, text=True)
    want = [os.path.join('ios-0f', 'k.metal'), '-o', os.path.join('ios-0f', 'k.air'), '-fmodules-cache-path=' + os.path.join('pch-ios', 'mcache'), '-w', '/opt/ascii/x.h']
    check(r.returncode == 0 and r.stdout.split('\n')[:-1] == want, f'⑥ 非 ASCII 路径改成相对工作区、纯 ASCII 不动（实得 {r.returncode}：{r.stdout.split(chr(10))[:6]}）')
    r = subprocess.run([*CMD, '--win-relative', cwd, os.path.join(t, '别处', 'k.metal')], capture_output=True, text=True)
    check(r.returncode == 2 and '非 ASCII' in r.stdout, f'⑥ 不在工作区下的非 ASCII 路径 → 报停（实得 {r.returncode}：{r.stdout.strip()[:120]}）')
print(f't_metal_nospace：{"全符" if not fails else f"{len(fails)} 例不符"}')
sys.exit(1 if fails else 0)
