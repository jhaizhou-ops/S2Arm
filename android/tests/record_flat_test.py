#!/usr/bin/env python3
"""批次 1 / 模块 A 的宿主合同（A1/A2/A4）：命令流拍平后记录内引用与延迟参数的自持性。

被测生产代码：`android/native/direct/record_flat.c`（拍平：A2 延迟数组入记录 + A4
记录内引用重定位）与它复用的 `bind_defer.c`。C 驱动 `record_flat_test.c` 只用记录布局
（`nvn_obj.h`）构造记录，不建 Vulkan 对象、不碰设备。

用法：
  默认              → 用工作区源码编译并运行，期望全绿。
  --source-ref REV  → 用 git REV 的源码编译同一份测试（先红后绿/撤前对照）。改动前没有拍平
                      模块（record_flat.c），因此必须报红并给出可读原因。
  --withdraw        → 行为撤回对照：把关键实现改回旧行为/关掉捕获，每条变异都必须让合同转红
                      （变异体存活 = 本测试无鉴别力 = 失败）。
"""
from pathlib import Path
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "android/native"
TEST_C = ROOT / "android/tests/record_flat_test.c"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref", help="git revision for the red/withdrawal control")
parser.add_argument("--withdraw", action="store_true", help="run behaviour-withdrawal mutations (each must turn red)")
args = parser.parse_args()

INCLUDES = [
    NATIVE / "direct", NATIVE / "nvn", NATIVE, NATIVE / "compat",
    ROOT / "graphics/nvn/gfx/nvn", ROOT / "graphics/nvn/gfx/nvn/include", ROOT / "graphics/nvn/gfx/tex",
]
CC = os.environ.get("CC", "cc")


def source(path):
    if args.source_ref:
        try:
            return subprocess.check_output(["git", "show", f"{args.source_ref}:{path}"], cwd=ROOT, text=True,
                                            stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            return None
    return (ROOT / path).read_text()


def build_and_run(td, flat_src, bind_src):
    flat = td / "record_flat.c"
    bind = td / "bind_defer.c"
    flat.write_text(flat_src)
    bind.write_text(bind_src)
    exe = td / "record_flat_test"
    cmd = [CC, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror"]
    cmd += ["-I" + str(p) for p in INCLUDES]
    cmd += [str(TEST_C), str(flat), str(bind), "-o", str(exe)]
    cp = subprocess.run(cmd, text=True, capture_output=True, timeout=120)
    if cp.returncode:
        return cp.returncode, cp.stdout + cp.stderr
    rp = subprocess.run([str(exe)], text=True, capture_output=True, timeout=60)
    return rp.returncode, rp.stdout + rp.stderr


def main():
    flat_src = source("android/native/direct/record_flat.c")
    bind_src = source("android/native/direct/bind_defer.c")
    if flat_src is None or bind_src is None:
        # 改动前源码里没有拍平模块：A2/A4 合同在旧实现上必然红（旧实现是裸 memcpy）。
        print("红：%s 里没有 android/native/direct/record_flat.c —— 命令流拍平"
              "（A2 延迟参数入记录 / A4 记录内引用重定位）尚未实现，本合同在旧源码上不成立"
              % (args.source_ref or "<working tree>"))
        return 1
    if args.withdraw:
        return withdraw(flat_src, bind_src)
    with tempfile.TemporaryDirectory(prefix="record-flat-") as d:
        rc, out = build_and_run(Path(d), flat_src, bind_src)
    if rc != 0:
        print(out, end="")
        print("红：拍平合同失败（rc=%d）" % rc)
        return 1
    print(out, end="")
    print("PASS: record flatten contracts (A2 deferred params captured at ownership transfer, "
          "A4 record-internal references relocated, unreadable guest data fails closed)")
    return 0


# 行为撤回对照：每条变异必须让合同转红，否则本测试不具鉴别力。
MUTATIONS = [
    ("no-rebase-set-rt-snapshots",
     "        if (flat_point(w, &dst_pt[i], &dst_snap[i])) return S2A_RECORD_FLAT_MEMORY;\n",
     "        (void)dst_pt;   /* mutation */\n"),
    # 真机 2026-11-07 打出的缺陷本身：追加时就把快照地址写进记录，缓冲一增长（realloc）就悬垂。
    ("attach-snapshot-address-while-growing",
     "    if (!w->owned) { *field = snap; return 0; }\n"
     "    return flat_fix_add((size_t)((const uint8_t *)field - g_buf), (size_t)((const uint8_t *)snap - g_buf));\n",
     "    *field = snap; return 0;   /* mutation: address written while the buffer still moves */\n"),
    ("no-capture-record-snapshot-bytes",
     "        memcpy(slot, ref, sizeof *slot);\n        return 0;\n",
     "        memset(slot, 0, sizeof *slot);   /* mutation */\n        return 0;\n"),
    ("keep-deferred-buffer-record",
     "    out->stage = (int32_t)((uint32_t)src->stage & ~(uint32_t)BIND_BUF_DEFER);\n"
     "    out->addr = flat_ga2ca((uint64_t)(uintptr_t)range.address);\n"
     "    out->size = (uint64_t)range.size;\n",
     "    (void)range;   /* mutation: old behaviour, replay reads guest again */\n"),
    ("keep-deferred-handles-record",
     "    for (int32_t i = 0; i < parsed.n; i++) out->h[i] = parsed.h[i];\n"
     "    out->defer = 0;\n    out->src = 0;\n",
     "    (void)parsed;   /* mutation: old behaviour, replay reads guest again */\n"),
    ("keep-bind-tex1-device-word",
     "    out->h = handle;\n    out->slot = src->slot & ~BIND_TEX1_AT;\n",
     "    (void)handle;   /* mutation: old behaviour, replay reads guest again */\n"),
]


def withdraw(flat_src, bind_src):
    failures = 0
    with tempfile.TemporaryDirectory(prefix="record-flat-withdraw-") as d:
        td = Path(d)
        for i, (name, old, new) in enumerate(MUTATIONS):
            if old not in flat_src:
                print("MISSING ANCHOR for mutation %s" % name)
                failures += 1
                continue
            mutated = flat_src.replace(old, new, 1)
            mdir = td / str(i)
            mdir.mkdir()
            rc, out = build_and_run(mdir, mutated, bind_src)
            if rc == 0:
                print("MUTANT SURVIVED: %s（合同没有鉴别力）" % name)
                print(out, end="")
                failures += 1
            else:
                print("withdraw %s: expected red ok (rc=%d)" % (name, rc))
    if failures:
        print("红：撤回对照有 %d 项未按预期转红" % failures)
        return 1
    print("PASS: %d behaviour-withdrawal mutations all turned the contract red" % len(MUTATIONS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
