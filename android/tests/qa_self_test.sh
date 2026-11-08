#!/usr/bin/env bash
# qa.sh 的自测（fixture）。
#
# 在临时目录造一个最小仓库，用 shim 替掉 docker / git / uname，覆盖 qa.sh 的编排逻辑
# （容器工作目录与路径约定、skip 语义与退出码、报告字段）和全部 preflight 拒绝路径。
#
# 不需要 Docker，也不需要 JDK / CMake：fixture 里的 test.sh / verify-apk.py / docker/build.sh 是桩。
# 测的是"qa.sh 有没有把正确的命令放在正确的工作目录下执行、把结果如实写进报告"，
# 不是被编排工具本身的正确性（后者由真跑 qa.sh 覆盖）。docker shim 会忠实模拟容器语义：
# -w /src 映射到 fixture 仓库根，目录不存在就直接失败——这是"路径约定写错"唯一可靠的检测点。
#
# 用法：bash android/tests/qa_self_test.sh
set -uo pipefail

android_dir=$(cd "$(dirname "$0")" && pwd)
qa=$android_dir/qa.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/qa-selftest.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

[ -f "$qa" ] || { echo "🔴 找不到 $qa" >&2; exit 2; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi
    if [ -f "$work/out.log" ]; then sed 's/^/       | /' "$work/out.log" | tail -12; fi
    return 0
}

# ---- fixture ----

# write_shims <根>：docker / git / uname 三个桩，放在 <根>/bin 下
write_shims() {
    local root=$1
    mkdir -p "$root/bin"

    # docker：只实现 qa.sh 用到的 info / image inspect / run。
    # run 的语义按容器来：-w 是容器内路径，/src 映射到 fixture 仓库根；目录不存在即失败。
    cat > "$root/bin/docker" <<'SH'
#!/usr/bin/env python3
import os, subprocess, sys

root = os.environ["QA_FIXTURE_ROOT"]
a = sys.argv[1:]

if a[:1] == ["info"]:
    sys.exit(1 if os.environ.get("QA_SHIM_NO_DAEMON") else 0)

if a[:2] == ["image", "inspect"]:
    if os.environ.get("QA_SHIM_NO_IMAGE"):
        sys.exit(1)
    print("sha256:" + "0" * 64)
    sys.exit(0)

if a[:1] == ["run"]:
    wd = cmd = None
    env, rest, i = dict(os.environ), [], 1
    while i < len(a):
        if a[i] == "-w":
            wd = a[i + 1]; i += 2; continue
        if a[i] == "-c":
            cmd = a[i + 1]; rest = a[i + 2:]; i += 2; continue
        if a[i] == "-e":
            k, _, v = a[i + 1].partition("=")
            # PATH 保留宿主机值：fixture 里没有镜像的 /opt/android-sdk，
            # 覆盖掉就找不到 python3 / bash 了。PATH 的正确性由真跑覆盖。
            if k != "PATH":
                env[k] = v
            i += 2; continue
        i += 1
    if cmd is None:
        sys.exit("fixture: docker run 缺 -c")
    if wd is None:
        sys.exit("fixture: docker run 缺 -w")
    if wd == "/src":
        host_wd = root
    elif wd.startswith("/src/"):
        host_wd = os.path.join(root, wd[len("/src/"):])
    else:
        sys.exit("fixture: 未知的容器工作目录 " + wd)
    if not os.path.isdir(host_wd):
        sys.exit("fixture: 容器工作目录不存在 " + wd)
    sys.exit(subprocess.call(["bash", "-c", cmd] + rest, cwd=host_wd, env=env))

sys.exit(0)
SH

    # git：只回答 qa.sh 用到的三种查询，固定 SHA、干净工作区。
    cat > "$root/bin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *--abbrev-ref*) echo "fixture/branch" ;;
    *rev-parse*)    echo "0123456789abcdef0123456789abcdef01234567" ;;
    *status*)       : ;;
esac
exit 0
SH

    # uname：让 preflight 的 Windows 原生 shell 分支可测。
    cat > "$root/bin/uname" <<'SH'
#!/usr/bin/env bash
echo "${QA_SHIM_UNAME:-Linux}"
SH

    chmod +x "$root/bin/docker" "$root/bin/git" "$root/bin/uname"
}

# make_fixture <目录>：最小仓库，含 qa.sh 副本与各步的桩
make_fixture() {
    local root=$1
    mkdir -p "$root/android/tests" \
             "$root/android/app/build/outputs/apk/debug" \
             "$root/android/docker" \
             "$root/fake-sdk/build-tools/36.0.0"
    cp "$qa" "$root/android/tests/qa.sh"
    printf '#!/usr/bin/env bash\necho "fixture test.sh ok"\n' > "$root/android/test.sh"
    printf 'import sys\nprint("fixture verify-apk ok: " + sys.argv[1])\n' > "$root/android/verify-apk.py"
    # APK 构建的桩：产出 APK，供后续静态校验使用（全量用例要三步都真跑）。
    cat > "$root/android/docker/build.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p android/app/build/outputs/apk/debug
printf 'apk' > android/app/build/outputs/apk/debug/app-debug.apk
echo "fixture build.sh ok"
SH
    printf 'apk' > "$root/android/app/build/outputs/apk/debug/app-debug.apk"
    printf '#!/usr/bin/env bash\necho "fixture apksigner ok"\n' > "$root/fake-sdk/build-tools/36.0.0/apksigner"
    chmod +x "$root/android/test.sh" "$root/android/docker/build.sh" \
             "$root/fake-sdk/build-tools/36.0.0/apksigner"
    write_shims "$root"
}

# run_qa <fixture 根> [参数...]：在 fixture 里跑 qa.sh，输出进 $work/out.log，返回它的退出码。
# 额外环境变量用 EXTRA_ENV 数组传（用例之间要清空）。
EXTRA_ENV=()
run_qa() {
    local fix=$1; shift
    ( cd "$fix" && env -u S2ARM_ANDROID_IMAGE -u S2ARM_ANDROID_CACHE \
        PATH="$fix/bin:$PATH" \
        QA_FIXTURE_ROOT="$fix" \
        ANDROID_HOME="$fix/fake-sdk" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        bash android/tests/qa.sh "$@" ) > "$work/out.log" 2>&1
}

# ---- 断言 ----

# step_result <report.json> <步骤名前缀>：ok / fail / -skip / (missing)
step_result() {
    python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for r in d["steps"]:
    if r["name"].startswith(sys.argv[2]):
        print(r["result"])
        break
else:
    print("(missing)")
PY
}

# report_field <report.json> <字段>：打印顶层字段值（缺失打印 (missing)，布尔转小写）
report_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get(sys.argv[2], "(missing)")
print(str(v).lower() if isinstance(v, bool) else v)
PY
}

report_ok() { report_field "$1" ok; }
report_complete() { report_field "$1" complete; }

# report_skipped <report.json>：跳过项的名字，用 | 连接；没有则打印空
report_skipped() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("|".join(d.get("skipped") or []))
PY
}

# report_shape <report.json>：一次校验 schema / git / image / apk / 步数与跳过字段，PASS 或给出原因
report_shape() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
problems = []
if d.get("schema") != "s2arm.android.qa-report.v1":
    problems.append("schema=" + str(d.get("schema")))
if len(d.get("git", {}).get("sha", "")) != 40:
    problems.append("git.sha 长度不是 40")
if d.get("image", {}).get("tag") != "s2arm-android-build:1":
    problems.append("image.tag=" + str(d.get("image", {}).get("tag")))
steps = d.get("steps", [])
if len(steps) != 3:
    problems.append("steps 数量=%d，期望 3" % len(steps))
skipped = d.get("skipped")
if not isinstance(skipped, list):
    problems.append("skipped 不是数组")
elif len(skipped) != len([r for r in steps if r.get("result") == "-skip"]):
    problems.append("skipped 与实际 -skip 步数不一致")
if d.get("steps_total") != len(steps):
    problems.append("steps_total=%s，期望 %d" % (d.get("steps_total"), len(steps)))
if d.get("steps_ran") != len(steps) - len(skipped or []):
    problems.append("steps_ran 与 steps_total - skipped 不一致")
if not isinstance(d.get("complete"), bool):
    problems.append("complete 不是布尔")
apk = d.get("apk") or {}
if len(apk.get("sha256", "")) != 64 or not apk.get("bytes"):
    problems.append("apk 元数据不全")
for r in steps:
    if not isinstance(r.get("seconds"), int):
        problems.append("步骤耗时不是整数：" + r.get("name", "?"))
print("PASS" if not problems else "；".join(problems))
PY
}

# 末行必须是「门禁 <绿|红|不完整>：跑了 N 步 / 应跑 M 步」——只看最后一行就能判断射程。
last_line() { tail -1 "$work/out.log"; }

echo "qa.sh 自测（fixture）"

# ---- 1. 全量：三步都真跑，退出 0 且报告 complete ----
echo "[1] 全量（三步都跑）"
fix=$work/c1; make_fixture "$fix"
run_qa "$fix" --out "$fix/build/qa"; rc=$?
rep=$fix/build/qa/report.json
[ "$rc" -eq 0 ] && ok "退出 0" || bad "退出码 ${rc}，期望 0"
[ "$(report_ok "$rep" 2>/dev/null)" = "true" ] && ok "report.ok=true" || bad "report.ok 不是 true"
[ "$(report_complete "$rep" 2>/dev/null)" = "true" ] && ok "report.complete=true" || bad "report.complete 不是 true"
[ "$(report_field "$rep" steps_ran 2>/dev/null)" = "3" ] && ok "跑了 3 步" || bad "steps_ran=$(report_field "$rep" steps_ran 2>/dev/null)"
[ "$(report_skipped "$rep" 2>/dev/null)" = "" ] && ok "skipped 为空" || bad "skipped=$(report_skipped "$rep" 2>/dev/null)"
[ "$(report_shape "$rep" 2>/dev/null)" = "PASS" ] && ok "报告字段完整" || bad "报告字段：$(report_shape "$rep" 2>/dev/null)"
grep -q '✅ 全绿' "$fix/build/qa/report.md" 2>/dev/null && ok "report.md 写全绿" || bad "report.md 没写全绿"
[ "$(last_line)" = "门禁 绿：跑了 3 步 / 应跑 3 步" ] && ok "末行报射程 3/3" || bad "末行是：$(last_line)"

# ---- 2. --skip-apk：跳过不是绿，必须退 2 且自报不完整 ----
# 这条是维护者 review 的核心要求：0 的定义是「全绿且没有缺跑」，缺跑算 2。
echo "[2] --skip-apk（跳过两步）"
fix=$work/c2; make_fixture "$fix"
run_qa "$fix" --skip-apk --out "$fix/build/qa"; rc=$?
rep=$fix/build/qa/report.json
[ "$rc" -eq 2 ] && ok "退出 2（不完整）" || bad "退出码 ${rc}，期望 2"
[ "$(report_ok "$rep" 2>/dev/null)" = "true" ] && ok "report.ok=true（没有失败）" || bad "report.ok 不是 true"
[ "$(report_complete "$rep" 2>/dev/null)" = "false" ] && ok "report.complete=false" || bad "report.complete 不是 false"
[ "$(report_skipped "$rep" 2>/dev/null)" = "APK 构建（assembleDebug + lintDebug + verify-apk + apksigner）|APK 静态校验（verify-apk + apksigner）" ] \
    && ok "skipped 列出两步" || bad "skipped=$(report_skipped "$rep" 2>/dev/null)"
grep -q '不完整' "$fix/build/qa/report.md" 2>/dev/null && ok "report.md 写不完整" || bad "report.md 没写不完整"
[ "$(last_line)" = "门禁 不完整：跑了 1 步 / 应跑 3 步" ] && ok "末行报射程 1/3" || bad "末行是：$(last_line)"

# ---- 3. --skip-build：复用已有 APK，只跳过构建一步，仍是不完整 ----
# 这条同时是"容器工作目录与路径约定"的回归测试：把 run_apk_checks 的 -w 写回
# /src/platforms/android 而仍传仓库根相对路径，shim 会因为目录解析不到而失败。
echo "[3] --skip-build（复用已有 APK）"
fix=$work/c3; make_fixture "$fix"
run_qa "$fix" --skip-build --out "$fix/build/qa"; rc=$?
rep=$fix/build/qa/report.json
[ "$rc" -eq 2 ] && ok "退出 2（少跑一步）" || bad "退出码 ${rc}，期望 2"
[ "$(step_result "$rep" 'APK 构建')" = "-skip" ] && ok "APK 构建 = -skip（不重跑构建）" || bad "APK 构建 = $(step_result "$rep" 'APK 构建')"
[ "$(step_result "$rep" 'APK 静态校验')" = "ok" ] && ok "APK 静态校验 = ok" || bad "APK 静态校验 = $(step_result "$rep" 'APK 静态校验')"
[ "$(report_skipped "$rep" 2>/dev/null)" = "APK 构建（assembleDebug + lintDebug + verify-apk + apksigner）" ] && ok "skipped 只列构建" || bad "skipped=$(report_skipped "$rep" 2>/dev/null)"
grep -q 'fixture verify-apk ok' "$fix/build/qa/logs/apk-check.log" 2>/dev/null \
    && ok "校验确实在容器里执行了 verify-apk" || bad "apk-check.log 里没有 verify-apk 输出"

# ---- 4. 有失败时退出码取 1（优先于不完整的 2） ----
echo "[4] --skip-build 但没有 APK（失败优先）"
fix=$work/c4; make_fixture "$fix"
rm -f "$fix/android/app/build/outputs/apk/debug/app-debug.apk"
run_qa "$fix" --skip-build --out "$fix/build/qa"; rc=$?
rep=$fix/build/qa/report.json
[ "$rc" -eq 1 ] && ok "退出 1（失败优先于不完整）" || bad "退出码 ${rc}，期望 1"
[ "$(step_result "$rep" 'APK 静态校验')" = "fail" ] && ok "APK 静态校验 = fail" || bad "APK 静态校验 = $(step_result "$rep" 'APK 静态校验')"
[ "$(report_ok "$rep" 2>/dev/null)" = "false" ] && ok "report.ok=false" || bad "report.ok 不是 false"
grep -q '没有产出' "$work/out.log" && ok "日志指出缺产物" || bad "日志没说明为什么跳过"

# ---- 5. preflight：Windows 原生 shell 拒绝，退出 2 ----
echo "[5] preflight：Windows 原生 shell"
fix=$work/c5; make_fixture "$fix"
EXTRA_ENV=(QA_SHIM_UNAME=MINGW64_NT-10.0-19045)
run_qa "$fix" --skip-apk; rc=$?
EXTRA_ENV=()
[ "$rc" -eq 2 ] && ok "退出 2" || bad "退出码 ${rc}，期望 2"
grep -q 'Windows 原生 shell' "$work/out.log" && ok "报出 Windows 原生 shell" || bad "没报出原因"
grep -q 'WSL' "$work/out.log" && ok "给出 WSL 用法" || bad "没给出改在 WSL 跑的指引"

# ---- 6. preflight：CRLF 脚本拒绝，退出 2 ----
echo "[6] preflight：CRLF 脚本"
fix=$work/c6; make_fixture "$fix"
printf 'echo crlf\r\n' >> "$fix/android/test.sh"
run_qa "$fix" --skip-apk; rc=$?
[ "$rc" -eq 2 ] && ok "退出 2" || bad "退出码 ${rc}，期望 2"
grep -q 'CRLF' "$work/out.log" && ok "报出 CRLF" || bad "没报出 CRLF"

# ---- 7. preflight：Docker daemon 没起来，退出 2 ----
echo "[7] preflight：Docker daemon 没起来"
fix=$work/c7; make_fixture "$fix"
EXTRA_ENV=(QA_SHIM_NO_DAEMON=1)
run_qa "$fix" --skip-apk; rc=$?
EXTRA_ENV=()
[ "$rc" -eq 2 ] && ok "退出 2" || bad "退出码 ${rc}，期望 2"
grep -q 'Docker daemon' "$work/out.log" && ok "报出 daemon 没起来" || bad "没报出 daemon"

# ---- 8. preflight：缺镜像，报出确切的构建命令，退出 2 ----
echo "[8] preflight：缺镜像"
fix=$work/c8; make_fixture "$fix"
EXTRA_ENV=(QA_SHIM_NO_IMAGE=1)
run_qa "$fix" --skip-apk; rc=$?
EXTRA_ENV=()
[ "$rc" -eq 2 ] && ok "退出 2" || bad "退出码 ${rc}，期望 2"
grep -q '缺镜像' "$work/out.log" && ok "报出缺镜像" || bad "没报出缺镜像"
grep -q 'docker build -t' "$work/out.log" && ok "给出构建命令" || bad "没给出构建命令"

# ---- 9. --help 只打注释头，不漏实现行 ----
echo "[9] --help"
fix=$work/c9; make_fixture "$fix"
run_qa "$fix" --help; rc=$?
[ "$rc" -eq 0 ] && ok "退出 0" || bad "退出码 ${rc}，期望 0"
grep -q '^set -euo pipefail' "$work/out.log" && bad "--help 把实现行也打出来了" || ok "--help 不含实现行"
grep -q 'skip-build' "$work/out.log" && ok "--help 列出 --skip-build" || bad "--help 没列出 --skip-build"

echo
if [ "$fail" -eq 0 ]; then
    echo "qa.sh 自测：$pass 项全过"
    exit 0
fi
echo "qa.sh 自测：$pass 过 / $fail 失败"
exit 1
