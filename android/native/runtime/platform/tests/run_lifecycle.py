#!/usr/bin/env python3
"""Linux ARM64 lifecycle ordering/failure tests, not a guest quiescence proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[5]
PLATFORM = ROOT / "android/native/runtime/platform"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--baseline-root", type=Path,
                        help="目录内放基线的 runtime/src/lifecycle.c 与 android/native/runtime/platform/lifecycle_android.{c,h}：单线程日志须与它逐行一致")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    records = []
    source = ROOT / "runtime/src/lifecycle.c"
    helper = PLATFORM / "lifecycle_android.c"
    fixture = PLATFORM / "tests/lifecycle.c"

    def command(argv, name, expect=0):
        start = time.monotonic()
        result = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=15)
        elapsed = time.monotonic() - start
        output = result.stdout + result.stderr
        (out / (name + ".log")).write_text(output)
        records.append({"name": name, "command": list(map(str, argv)),
                        "exit": result.returncode, "seconds": elapsed})
        assert result.returncode == expect, (name, result.returncode, expect, output)
        return output, elapsed

    def build(path, name, helper=helper):
        binary = out / name
        command([os.environ.get("CC", "cc"), "-D_GNU_SOURCE", "-D__ANDROID__", "-DS2A_UNIT_TEST",
                 "-ffunction-sections", "-fdata-sections", "-fvisibility=hidden",
                 "-Wall", "-Wextra", "-Werror", "-I" + str(ROOT),
                 "-I" + str(ROOT / "runtime/src"), "-I" + str(ROOT / "runtime/include"),
                 path, helper, fixture, "-pthread", "-ldl", "-Wl,--gc-sections",
                 "-Wl,--wrap=pthread_create,--wrap=pipe2", "-o", binary], "build-" + name)
        return binary

    binary = build(source, "lifecycle")
    symbols, _ = command(["nm", "-D", binary], "dynamic-symbols")
    assert "S2A_CancelWaits" not in symbols  # Exactly the static archive visibility boundary.
    def marks(log):
        return [line for line in log.splitlines() if line and not line.startswith("[")]
    for mode in ("normal", "signal"):
        # 单线程（基线）：地址余量在取消之前、不限时，没有原生进度行与黄
        log, _ = command([binary, mode], mode)
        assert marks(log)[:8] == ["unfreeze", "vk-drain", "vm-low", "cancel", "park", "writers", "cs-shutdown", "cleanup-result"], log
        assert log.count("cs-shutdown") == 1 and "优雅退出完成" in log and "收局进度" not in log and "【黄】" not in log, log
        # 拆线程：地址余量在服务层 Cleanup / 结果确认之后，带读 maps 用时
        log, _ = command([binary, mode + "-threaded"], mode + "-threaded")
        assert marks(log)[:8] == ["unfreeze", "vk-drain", "cancel", "park", "writers", "cs-shutdown", "cleanup-result", "vm-low"], log
        assert "优雅退出完成" in log and "读 maps 用时" in log, log
    # 拆线程读 maps 卡住（mmap_lock 竞争）：收局照常完成，只打一行黄
    log, elapsed = command([binary, "maps-stuck-threaded"], "maps-stuck-threaded")
    assert "优雅退出完成" in log and "【黄】地址余量 [收局]" in log and elapsed < 1.3, log
    assert log.index("cs-shutdown") < log.index("vm-low"), log
    # 单线程读 maps 卡住：与基线相同（在取消之前卡住，1.5 s 兜底结束）
    log, _ = command([binary, "maps-stuck"], "maps-stuck", 124)
    assert "cancel" not in marks(log) and "【黄】" not in log, log
    log, _ = command([binary, "vk-unconfigured"], "vk-unconfigured")
    assert "vk-drain" not in log and "优雅退出完成" in log, log
    # 收局只问“停车通道装过没有”：installed=0（从未安装）→ 跳过停稳等待并照常收局；
    # installed=1（含“装过但处理器被覆盖”）→ 仍走停稳等待（见上面 writers-fail 期望 125）。
    log, _ = command([binary, "writers-never-installed"], "writers-never-installed")
    assert "writers\n" not in log and "优雅退出完成" in log and "从未安装" in log, log
    for mode in ("inflight", "writers-fail", "watchdog-fail", "vk-drain-fail"):
        log, _ = command([binary, mode], mode, 125)
        assert "cs-shutdown" not in log and "优雅退出完成" not in log
    log, _ = command([binary, "vk-drain-fail"], "vk-drain-fail-order", 125)
    assert "vk-drain\n" in log and not any(s in log for s in ("cancel\n", "park\n", "writers\n")), log
    log, _ = command([binary, "cleanup-fail"], "cleanup-fail", 125)
    assert "cs-shutdown\ncleanup-result\n" in log and "优雅退出完成" not in log
    for mode in ("hang", "full-stderr", "hang-threaded", "full-stderr-threaded"):
        log, elapsed = command([binary, mode], mode, 124)
        assert "优雅退出完成" not in log and 1.3 < elapsed < 3.0
        # 兜底结束进程前有一行明确标识（stderr 管道满时写不进也不阻塞，照常 124）
        assert ("原生兜底" in log) == mode.startswith("hang"), log
        progress = [line for line in log.splitlines() if "收局进度 +" in line and "（原生）" in line]
        if mode == "hang-threaded":
            # 收局进度（原生诊断，拆线程）：兜底结束进程前每 250 ms 一行，带收局线程的内核态与 guest 写者快照
            assert len(progress) >= 4, log
            assert all("收局线程 tid" in line and "系统调用" in line and "guest 写者：" in line for line in progress), log
        elif mode == "hang":
            assert not progress, log   # 单线程保持基线：没有进度线程
    for mode in ("term-thread-fail", "term-pipe-fail"):
        command([binary, mode], mode)

    # 真实 host 日志是普通文件：O_NONBLOCK 不能防止存储阻塞。只阻塞标识写入，最终兜底仍须独立退出。
    def blocked_file(helper_source, name):
        target = out / name
        cmd = next(r["command"][:] for r in records if r["name"] == ("build-baseline-lifecycle" if name.startswith("baseline-") else "build-lifecycle"))
        if str(helper) in cmd: cmd[cmd.index(str(helper))] = str(helper_source)
        cmd[cmd.index("-o") + 1] = str(target)
        cmd += [str(PLATFORM / "tests/watchdog_write.c"), "-Wl,--wrap=write"]
        command(cmd, "build-" + name)
        for mode in ("hang", "hang-threaded"):
            start = time.monotonic()
            with (out / (name + "-" + mode + ".stderr")).open("w") as log:
                result = subprocess.run([str(target), mode], stdout=subprocess.PIPE, stderr=log, text=True, timeout=3)
            elapsed = time.monotonic() - start
            records.append({"name": name + "-" + mode, "exit": result.returncode, "seconds": elapsed, "stdout": result.stdout})
            assert result.returncode == 124 and 1.3 < elapsed < 1.9, (name, mode, elapsed, result.stdout)
        return target
    blocked_file(helper, "blocked-file")

    original = source.read_text()
    # Mutants are emitted outside the source tree and preserve the production header path.
    absolute = original.replace('"../../android/native/runtime/platform/lifecycle_android.h"',
                                '"' + str(PLATFORM / "lifecycle_android.h") + '"')
    mutants = {
        "optional-cancel": ("    S2A_CancelWaits();",
                            '    { void (*cancel)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "S2A_CancelWaits"); if (cancel) cancel(); }', 93),
        "skip-writers": ("int error = tracking_installed ? android_shutdown_writers_begin() : 0;", "int error = 0;", 92),
    }
    for name, (before, after, failure) in mutants.items():
        assert absolute.count(before) == 1, name
        path = out / (name + ".c")
        mutant_source = absolute.replace(before, after)
        if name == "skip-writers":
            # Removing the only call must fail at the runtime ownership assertion,
            # not at -Werror for the now-unused private production helper.
            mutant_source = mutant_source.replace("static int android_shutdown_writers_begin(void)",
                "static __attribute__((unused)) int android_shutdown_writers_begin(void)")
        path.write_text(mutant_source)
        mutant = build(path, name)
        log, _ = command([mutant, "normal"], "reject-" + name, failure)
        assert "cs-shutdown" not in log and "优雅退出完成" not in log
    # 负控：拆线程也把地址余量留在收局前段（S2A_CancelWaits 之前）→ 读 maps 卡住时取消请求发不出去，1.5 s 兜底结束（124）
    before = '    if (!s2a_android_shutdown_threaded()) { void s2a_vm_low(const char *); s2a_vm_low("收局"); }\n'
    assert absolute.count(before) == 1
    path = out / "vm-low-before-cancel.c"
    path.write_text(absolute.replace(before, '    { void s2a_vm_low(const char *); s2a_vm_low("收局"); }\n'))
    mutant = build(path, "vm-low-before-cancel")
    log, _ = command([mutant, "maps-stuck-threaded"], "reject-vm-low-before-cancel", 124)
    assert "cancel" not in marks(log) and "cs-shutdown" not in log and "优雅退出完成" not in log, log
    # 单线程与基线逐行一致（数字归一：用时）
    if args.baseline_root:
        import re
        base_source = args.baseline_root / "runtime/src/lifecycle.c"
        base_helper = args.baseline_root / "android/native/runtime/platform/lifecycle_android.c"
        base_header = args.baseline_root / "android/native/runtime/platform/lifecycle_android.h"
        staged = out / "baseline"
        (staged / "runtime/src").mkdir(parents=True, exist_ok=True)
        (staged / "platform").mkdir(parents=True, exist_ok=True)
        (staged / "platform/lifecycle_android.h").write_text(base_header.read_text())
        (staged / "platform/lifecycle_android.c").write_text(base_helper.read_text())
        (staged / "runtime/src/lifecycle.c").write_text(base_source.read_text().replace(
            '"../../android/native/runtime/platform/lifecycle_android.h"', '"' + str(staged / "platform/lifecycle_android.h") + '"'))
        baseline = build(staged / "runtime/src/lifecycle.c", "baseline-lifecycle", staged / "platform/lifecycle_android.c")
        blocked_file(staged / "platform/lifecycle_android.c", "baseline-blocked-file")
        normalize = lambda text: re.sub(r"[0-9]+\.[0-9]+ 秒", "N 秒", text)
        for mode, expect in (("normal", 0), ("signal", 0), ("inflight", 125), ("writers-fail", 125), ("cleanup-fail", 125), ("maps-stuck", 124)):
            ours, _ = command([binary, mode], "false-" + mode, expect)
            theirs, _ = command([baseline, mode], "baseline-" + mode, expect)
            if expect == 124:
                # 唯一的差别：兜底结束进程前的标识行
                marker = [line for line in ours.splitlines() if "原生兜底" in line]
                assert len(marker) == 1, ours
                ours = "\n".join(line for line in ours.splitlines() if "原生兜底" not in line) + ("\n" if ours.endswith("\n") else "")
            assert normalize(ours) == normalize(theirs), (mode, ours, theirs)
    receipt = {"scope": "lifecycle order and error propagation only; fixture writers are not production quiescence",
               "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in (source, helper, fixture, PLATFORM / "lifecycle_android.h")},
               "records": records}
    (out / "results.json").write_text(json.dumps(receipt, indent=2))
    print("PASS: lifecycle failure/order cases, threaded shutdown progress + bounded maps read after StopGpu, single-thread baseline order, and three rejected mutants" + ("; single-thread logs equal the baseline" if args.baseline_root else ""))


if __name__ == "__main__":
    main()
