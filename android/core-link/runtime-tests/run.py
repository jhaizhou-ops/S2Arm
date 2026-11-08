#!/usr/bin/env python3
# 门禁手动：只能 Linux（-D_GNU_SOURCE 下 mkdtemp 等 glibc 声明，macOS 编不过），本机跑不了，门禁 Linux 路径本轮没实跑验证
"""Host 组合层测试；合成端点不证明原生 guest 或 GPU 已运行。"""
import argparse
import json
import pathlib
import subprocess

p = argparse.ArgumentParser()
p.add_argument("--out", type=pathlib.Path, required=True)
p.add_argument("--cc", default="cc")
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[3]
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
runtime = root / "android/native/runtime/runtime.c"
test = pathlib.Path(__file__).with_name("runtime_test.c")
guest = root / "runtime/src/guest_main.c"
base = [a.cc, "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror", "-pthread"]
for d in ["runtime/include", "runtime/src", "android/native", "android/native/runtime"]:
    base += ["-I", str(root / d)]
direct = [root / "android/native/direct" / name for name in
          ("selection.c", "attempt.c", "graphics.c", "json.c", "sha256.c", "s2a_direct_abi.c")]
exe = out / "runtime_test"
subprocess.run(base + [str(test), str(runtime), str(guest)] + [str(p) for p in direct] + ["-o", str(exe)], check=True)
cases = ["invalid", "long-path", "window", "selfcheck", "signals", "writers-init", "track-prepare", "vm-prepare", "unresolved", "stack", "identity", "sdk-missing",
         "service-fail", "false-ready", "service-session", "service-size", "service-version",
         "service-error", "stop-load", "stop-services", "vk-prepare", "ready", "args", "source-ready", "source-no-npdm", "source-relative-npdm",
         "v2-invalid", "v2-generic", "v2-direct", "v2-direct-manual", "v2-leftover",
         "v2-frontend-missing", "v2-manual-direct-no-descriptor", "v2-bad-descriptor", "v2-manual-bad-descriptor",
         "v2-title-mismatch", "v2-manual-title-mismatch", "v2-closure-stale", "v2-closure-same"]
results = []
for case in cases:
    r = subprocess.run([str(exe), case], capture_output=True, text=True, timeout=10)
    results.append(dict(case=case, returncode=r.returncode, stdout=r.stdout, stderr=r.stderr))
    print(f"{case}: {'PASS' if r.returncode == 0 else 'FAIL'}")
# 没有桩的构建：弱符号为空，行为与没有这段校正时相同。
nostub = out / "runtime_test_nostub"
subprocess.run(base + ["-DS2A_TEST_NO_CLOSURE_STUB"] + [str(test), str(runtime), str(guest)] + [str(p) for p in direct] + ["-o", str(nostub)], check=True)
r = subprocess.run([str(nostub), "v2-closure-nostub"], capture_output=True, text=True, timeout=10)
results.append(dict(case="v2-closure-nostub", returncode=r.returncode, stdout=r.stdout, stderr=r.stderr))
print(f"v2-closure-nostub: {'PASS' if r.returncode == 0 else 'FAIL'}")
# 期望值手写：过期时 stderr 必须有这行【红】，其余两例不能有。
RED = "【红】graphics descriptor closure ryujinx-2026.10-dsh1 is not this engine's compiler (s2a-dc1-engine-new)"
for item in results:
    if item["case"] == "v2-closure-stale" and RED not in item["stderr"]:
        item["returncode"] = 1
        print("v2-closure-stale: FAIL (no red line in stderr)")
    if item["case"] in ("v2-closure-same", "v2-closure-nostub") and "【红】graphics descriptor closure" in item["stderr"]:
        item["returncode"] = 1
        print(f"{item['case']}: FAIL (unexpected red line)")
(out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
if any(r["returncode"] for r in results):
    raise SystemExit(1)

# 真实消费者必须抓到“Init 返回就继续”的回归；负控只变异生产准入条件。
mutant = out / "runtime-missing-ready-check.c"
old = "services.state != S2A_SERVICES_READY || services.error)"
source = runtime.read_text()
assert source.count(old) == 1
mutant.write_text(source.replace(old, "services.error)"))
bad = out / "runtime-missing-ready-check"
subprocess.run(base + [str(test), str(mutant), str(guest)] + [str(p) for p in direct] + ["-o", str(bad)], check=True)
r = subprocess.run([str(bad), "false-ready"], capture_output=True, text=True, timeout=10)
(out / "negative-control.json").write_text(json.dumps(dict(
    mutation="omit services Ready admission", returncode=r.returncode,
    stdout=r.stdout, stderr=r.stderr), ensure_ascii=False, indent=2) + "\n")
if r.returncode == 0:
    raise SystemExit("FAIL: false-ready negative control did not reject the mutant")
print(f"negative control: PASS (mutant rejected, exit {r.returncode})")

# 负控：校正时不丢离线库，v2-closure-stale 必须变红。
old = "descriptor.profile_count = 0;"
assert source.count(old) == 1
mutant = out / "runtime-keep-stale-library.c"
mutant.write_text(source.replace(old, ""))
bad = out / "runtime-keep-stale-library"
subprocess.run(base + [str(test), str(mutant), str(guest)] + [str(p) for p in direct] + ["-o", str(bad)], check=True)
r = subprocess.run([str(bad), "v2-closure-stale"], capture_output=True, text=True, timeout=10)
if r.returncode == 0:
    raise SystemExit("FAIL: stale-library negative control did not reject the mutant")
print(f"negative control: PASS (stale library kept is rejected, exit {r.returncode})")
