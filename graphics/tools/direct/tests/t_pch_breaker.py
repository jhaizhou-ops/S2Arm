#!/usr/bin/env python3
# 预编头熔断（graphics/tools/direct/dsh/batch/Build.cs Metal.PchTrip = 8）：dsh_batch --metal-compile 走真实的 Init（建预编头）+ Compile，PATH 前面放假 xcrun。
#   期望按规则手写：① 带 -include-pch 一律编不过、去掉能编成 → 前 8 支各编两次、第 8 支后熔断，剩 4 支各编一次：编译调用 20 次、12 compiled / 8 retried、提示一次
#   ② 带预编头能编成 → 编译调用 12 次、0 retried、没有熔断提示
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

FAKE = '''#!/bin/bash
case " $* " in
  *" --version "*) echo "Apple metal version 32023.999 (fake)"; exit 0;;
  *" --show-sdk-version "*) echo 99.0; exit 0;;
  *" --show-sdk-build-version "*) echo FAKE1; exit 0;;
esac
out=; prev=; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
case " $* " in
  *" metal-header "*) : > "$out"; exit 0;;
  *" metallib "*) printf lib > "$out"; exit 0;;
esac
echo compile >> "$FAKE_LOG"
case " $* " in *" -include-pch "*) [ "$PCH_BREAKS" = 1 ] && { echo "error: PCH was compiled with module cache path 'A', but the path is currently 'B'" >&2; exit 1; };; esac
printf air > "$out"; exit 0
'''
def run(breaks):
    with tempfile.TemporaryDirectory() as t:
        b = os.path.join(t, 'bin'); os.makedirs(b); x = os.path.join(b, 'xcrun'); open(x, 'w').write(FAKE); os.chmod(x, 0o755)
        srcs = []
        for i in range(12):
            s = os.path.join(t, f'k{i}.metal'); open(s, 'w').write(f'kernel void k{i}() {{}}\n'); srcs.append(s)
        w = os.path.join(t, 'work'); os.makedirs(w); log = os.path.join(t, 'calls')
        env = dict(os.environ, PATH=b + os.pathsep + os.environ['PATH'], FAKE_LOG=log, PCH_BREAKS='1' if breaks else '0')
        r = subprocess.run([*CMD, '--metal-compile', w, *srcs], capture_output=True, text=True, env=env)
        calls = len(open(log).read().split()) if os.path.exists(log) else 0
        return r, calls

r, calls = run(True)
check(r.returncode == 0 and calls == 20 and 'mac 0 reused, 12 compiled, 0 failed, 8 retried' in r.stdout and r.stdout.count('不再带预编头') == 1,
      f'① 预编头整体用不了：编译调用 20 次、12 compiled / 8 retried、熔断提示一次（实得 rc {r.returncode}、{calls} 次：{r.stdout.strip()[-200:]}）')
r, calls = run(False)
check(r.returncode == 0 and calls == 12 and 'mac 0 reused, 12 compiled, 0 failed;' in r.stdout and '不再带预编头' not in r.stdout,
      f'② 预编头可用：编译调用 12 次、0 retried、不熔断（实得 rc {r.returncode}、{calls} 次：{r.stdout.strip()[-200:]}）')
print(f't_pch_breaker：{"全符" if not fails else f"{len(fails)} 例不符"}')
sys.exit(1 if fails else 0)
