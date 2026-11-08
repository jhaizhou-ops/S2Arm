#!/usr/bin/env bash
# 门禁手动：要 Linux / WSL 加已构建的安卓 Docker 镜像跑整套 APK 构建与校验（十分钟级）；编排逻辑由 qa_self_test.sh 在 android/test.sh 门禁跑
# Android QA 门禁：一条命令跑完无设备单测 + 契约 + APK 构建 + APK 静态校验，产出一份可追溯报告。
#
# 用法：
#   bash android/tests/qa.sh                 # 全量，报告写 build/qa/
#   bash android/tests/qa.sh --out <目录>     # 换报告目录
#   bash android/tests/qa.sh --skip-apk       # 只跑无设备单测与契约（快，结果不完整 → 退出 2）
#   bash android/tests/qa.sh --skip-build     # 复用已有 APK，只重跑静态校验（结果不完整 → 退出 2）
#   bash android/tests/qa.sh --offline        # APK 构建加 --offline，不联网
#
# 为什么要求 WSL / Linux：Windows 原生 Git Bash 跑不了这套链，原因在下面 preflight 里逐条报。
# 为什么都在容器里跑：宿主机不需要 JDK 17 / CMake，工具版本由镜像钉死，报告才有可比性。
#
# 退出码：0 = 全绿且没有跳过；1 = 有步骤失败；2 = 环境不满足，或有步骤被跳过（不完整）。
# 判据与 tools/contrib_check.sh 一致：跳过不是绿——报告要自报「跑了 N 步 / 应跑 M 步」。
set -euo pipefail

android_dir=$(cd "$(dirname "$0")/.." && pwd)
repo_dir=$(cd "$android_dir/../.." && pwd)
out=$repo_dir/build/qa
skip_apk=0
skip_build=0
offline=0
image=${S2ARM_ANDROID_IMAGE:-s2arm-android-build:1}
cache=${S2ARM_ANDROID_CACHE:-s2arm-android-build-cache}

# 按标记截断，不写死行号：打印第 2 行到第一条非注释行之前（避免改注释就让 --help 输出错位）。
usage() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case $1 in
        --out) [ $# -ge 2 ] || { echo "--out 需要一个目录" >&2; exit 2; }; out=$2; shift 2 ;;
        --skip-apk) skip_apk=1; shift ;;
        --skip-build) skip_build=1; shift ;;
        --offline) offline=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "🔴 $*" >&2; exit 2; }

# ---- preflight：环境不满足就当场说清楚，不静默降级 ----

# 1. Windows 原生 shell。MSYS 会把容器内路径 /src 改写成 D:/...，并把 UNC 挂载点挂成空目录；
#    两者都会让后续步骤以看似无关的错误失败，所以直接拒绝，让人去 WSL 跑。
case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*)
        die "这是 Windows 原生 shell（$(uname -s)）。请改在 WSL 里跑：
    wsl -d <发行版> --cd <仓库根> bash android/tests/qa.sh
  Windows 原生下有两个绕不过去的问题：MSYS 会把 --workdir /src 改写成 D:/...；
  \\\\wsl.localhost\\... 这类 UNC 路径 bind mount 进去是空目录。" ;;
esac

# 2. CRLF。core.autocrlf=true 时 checkout 出来的 .sh 带 CRLF，bash 会把
#    "set -euo pipefail" 读成 "pipefail\r" 并报 invalid option name。
# 不用 GNU 专有的 grep -U：BSD grep（macOS 门禁）没有这个选项，会直接报错并静默失效。
cr=$(printf '\r')
crlf=$(find "$android_dir" -name '*.sh' -type f -exec grep -l "$cr" {} + 2>/dev/null | head -5 || true)
[ -z "$crlf" ] || die "这些脚本是 CRLF 换行，bash 跑不了：
$crlf
  修：git config core.autocrlf false && git rm --cached -r . >/dev/null && git reset --hard"

# 3. git 与 Docker。缺就报出确切命令，不自动装、不自动构建（门禁不能偷偷联网）。
command -v git > /dev/null || die "找不到 git。报告要记提交 SHA 与工作区状态，没有 git 就写不出可追溯的报告。"
command -v docker > /dev/null || die "找不到 docker。"
docker info > /dev/null 2>&1 || die "Docker daemon 没起来（Docker Desktop 没启动 / 没连上）。"
if ! docker image inspect "$image" > /dev/null 2>&1; then
    die "缺镜像 ${image}。构建：
    docker build -t $image $android_dir/docker
  （首次要联网拉 SDK 36 / NDK 29.0.14206865 / CMake 3.31.6 / Gradle 9.8.1，约 4-6 分钟；
    services.gradle.org 偶发 SSL_ERROR_SYSCALL，重跑即可命中缓存。）"
fi

mkdir -p "$out/logs"
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git_sha=$(git -C "$repo_dir" rev-parse HEAD)
git_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
if [ -n "$(git -C "$repo_dir" status --porcelain)" ]; then git_dirty=true; else git_dirty=false; fi
image_id=$(docker image inspect "$image" --format '{{.Id}}')

# 每个步骤往 steps.tsv 追加一行：名字 / 结果 / 秒数 / 日志文件。报告由它生成。
steps=$out/steps.tsv
: > "$steps"

# run_step <名字> <日志名> <命令...>
# 失败不中断：后面的步骤仍要跑，报告里逐条给结果（门禁要一次看全，不是撞到第一个红就停）。
run_step() {
    local name=$1 log_name=$2; shift 2
    local log=$out/logs/$log_name
    local t0 t1 rc
    echo "▶ $name"
    t0=$(date +%s)
    if "$@" > "$log" 2>&1; then rc=ok; else rc=fail; fi
    t1=$(date +%s)
    printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$((t1 - t0))" "logs/$log_name" >> "$steps"
    if [ "$rc" = ok ]; then echo "  ✅ ${name}（$((t1 - t0))s）"; else echo "  🔴 ${name}（$((t1 - t0))s）→ $out/logs/$log_name"; fi
    return 0
}

# 容器里跑 test.sh。CMake 由 sdkmanager 装在 $ANDROID_HOME/cmake/<ver>/bin，镜像没有放进 PATH，
# 而 test.sh 除了 cmake 还要调 ctest，所以两个都得在 PATH 上。以非 root 跑：GameInstallTest 用
# File.canWrite() 断言"对象库只读"，root 对只读文件也返回 true，会假红。
run_host_tests() {
    docker run --rm --user "$(id -u):$(id -g)" \
        -v "$repo_dir:/src" -w /src \
        -e HOME=/tmp \
        -e PATH=/opt/android-sdk/cmake/3.31.6/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        --entrypoint bash "$image" -c 'bash android/test.sh'
}

run_apk() {
    if [ "$offline" = 1 ]; then
        S2ARM_ANDROID_IMAGE=$image S2ARM_ANDROID_CACHE=$cache bash "$android_dir/docker/build.sh" --offline :app:assembleDebug
    else
        S2ARM_ANDROID_IMAGE=$image S2ARM_ANDROID_CACHE=$cache bash "$android_dir/docker/build.sh"
    fi
}

# APK 静态校验：ABI / 16 KB 对齐 / 许可证 / 签名。用镜像里的工具，跟构建同版本。
# 工作目录固定为 /src（仓库根），路径一律相对仓库根，与宿主机侧的 [ -f ] 判定同一套约定。
# 曾经写成 -w /src/platforms/android 又传仓库根相对路径，容器里会去找
# /src/platforms/android/platforms/android/app/...，必然 "No such file or directory"。
run_apk_checks() {
    local apk=$1
    docker run --rm --user "$(id -u):$(id -g)" \
        -v "$repo_dir:/src" -w /src \
        --entrypoint bash "$image" -c '
            set -euo pipefail
            apk=$1
            [ -f "$apk" ] || { echo "容器里看不到 APK：${apk}（cwd=$(pwd)）" >&2; exit 1; }
            python3 android/verify-apk.py "$apk"
            "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs "$apk" | head -3
        ' _ "$apk"
}

run_step "无设备单测 + 契约（test.sh）" "test.log" run_host_tests

apk_rel=android/app/build/outputs/apk/debug/app-debug.apk
# 步骤名只在这里定义一次：run_step、-skip、fail 三种行共用，避免报告里同一步骤出现两个名字。
apk_build_name="APK 构建（assembleDebug + lintDebug + verify-apk + apksigner）"
apk_check_name="APK 静态校验（verify-apk + apksigner）"
if [ "$skip_apk" = 1 ]; then
    printf '%s\t-skip\t0\t-\n' "$apk_build_name" >> "$steps"
    printf '%s\t-skip\t0\t-\n' "$apk_check_name" >> "$steps"
else
    if [ "$skip_build" = 1 ]; then
        # 构建慢（约 1 分钟，首次还要下 .NET SDK），只改校验逻辑时没必要重跑。
        printf '%s\t-skip\t0\t-\n' "$apk_build_name" >> "$steps"
        echo "  ⏭️  跳过 APK 构建（--skip-build），复用已有产物"
    else
        run_step "$apk_build_name" "apk.log" run_apk
    fi
    if [ -f "$repo_dir/$apk_rel" ]; then
        run_step "$apk_check_name" "apk-check.log" run_apk_checks "$apk_rel"
    else
        printf '%s\tfail\t0\t-\n' "$apk_check_name" >> "$steps"
        echo "  🔴 没有产出 ${apk_rel}，跳过静态校验" >&2
    fi
fi

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 报告：机器可读 JSON + 人读 Markdown。失败项带日志路径与最后几行，不用再去翻文件。
# 判据：ok = 没有失败；complete = 没有跳过。退出码 0 要求两者同时成立，
# 否则「只跑了一半」会被 CI 当成全绿——这正是 contrib_check.sh 的 0 定义。
if python3 - "$out" "$steps" "$git_sha" "$git_branch" "$git_dirty" "$image" "$image_id" \
         "$started_at" "$finished_at" "$repo_dir" "$apk_rel" <<'PY'
import hashlib, json, os, sys

out, steps_file, sha, branch, dirty, image, image_id, started, finished, repo, apk_rel = sys.argv[1:12]
rows = []
with open(steps_file, encoding="utf-8") as f:
    for line in f:
        name, result, seconds, log = line.rstrip("\n").split("\t")
        row = {"name": name, "result": result, "seconds": int(seconds)}
        if log != "-":
            row["log"] = log
            path = os.path.join(out, log)
            if os.path.exists(path):
                with open(path, encoding="utf-8", errors="replace") as lf:
                    tail = [l.rstrip("\n") for l in lf.readlines()[-12:]]
                row["tail"] = tail
        rows.append(row)

apk_path = os.path.join(repo, apk_rel)
apk = None
if os.path.exists(apk_path):
    h = hashlib.sha256()
    with open(apk_path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    apk = {"path": apk_rel, "bytes": os.path.getsize(apk_path), "sha256": h.hexdigest()}

# -skip 是"本次没跑"：既不算失败，也不能算绿。ok 只表示没有失败，complete 表示一步没少。
ok = all(r["result"] != "fail" for r in rows)
skipped = [r["name"] for r in rows if r["result"] == "-skip"]
complete = not skipped
ran = len(rows) - len(skipped)
total = len(rows)

if not ok:
    verdict = "🔴 有失败"
elif not complete:
    verdict = "🟡 不完整：跳过 " + "、".join(skipped)
else:
    verdict = "✅ 全绿"

report = {
    "schema": "s2arm.android.qa-report.v1",
    "ok": ok,
    "complete": complete,
    "skipped": skipped,
    "steps_ran": ran,
    "steps_total": total,
    "started_at": started,
    "finished_at": finished,
    "git": {"sha": sha, "branch": branch, "dirty": dirty == "true"},
    "image": {"tag": image, "id": image_id},
    "apk": apk,
    "steps": rows,
}
with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
    f.write("\n")

lines = [
    "# Android QA 报告",
    "",
    f"- 结果：{verdict}",
    f"- 步数：跑了 {ran} 步 / 应跑 {total} 步",
    f"- 提交：`{sha[:12]}`（{branch}）{' · 工作区有未提交改动' if dirty == 'true' else ''}",
    f"- 镜像：`{image}` · `{image_id[:19]}`",
    f"- 时间：{started} → {finished}",
    "",
    "| 步骤 | 结果 | 耗时 |",
    "|---|---|---|",
]
for r in rows:
    icon = {"ok": "✅", "fail": "🔴", "-skip": "⏭️"}.get(r["result"], r["result"])
    lines.append(f"| {r['name']} | {icon} | {r['seconds']}s |")
if apk:
    lines += ["", f"APK：`{apk['path']}` · {apk['bytes']} 字节 · sha256 `{apk['sha256'][:16]}…`"]
for r in rows:
    if r["result"] == "fail" and r.get("tail"):
        lines += ["", f"## 失败：{r['name']}", "", f"日志：`{r['log']}`", "", "```"]
        lines += r["tail"] + ["```"]
with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines[:13]))
sys.exit(0 if ok and complete else (1 if not ok else 2))
PY
then rc=0; else rc=$?; fi

echo
echo "报告：$out/report.md  /  $out/report.json"

# 末行固定报射程（对齐 tools/gate.sh 的「跑了 N 步 / 应跑 N 步」）：
# 只看最后一行也能判断这次结果是不是覆盖了全部步骤。
total=$(wc -l < "$steps" | tr -d ' ')
skipped_n=$(awk -F'\t' '$2 == "-skip"' "$steps" | wc -l | tr -d ' ')
ran=$((total - skipped_n))
case $rc in
    0) verdict=绿 ;;
    1) verdict=红 ;;
    *) verdict=不完整 ;;
esac
echo "门禁 ${verdict}：跑了 $ran 步 / 应跑 $total 步"
exit $rc
