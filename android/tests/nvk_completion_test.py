#!/usr/bin/env python3
"""D 接口（完成 token）宿主合同 runner：编译并运行 nvk_completion_test.c。

被测实现是生产 nvn_vk_completion.{h,c}（5 态完成事实、批次持有/放行、GPU 完成后退休回调、换代/Stop）。
测试用假完成源直接推进事实：不建 Vulkan device、不碰真队列、无锁无等待。

--source-ref <git rev> 用同一份测试去编译旧版本的 nvn_vk_completion.{h,c}，做“改前必须红”的撤回对照：
  - 旧版本没有这两个文件（接口尚未交付）→ 红：D 完成 token 接口不存在；
  - 旧版本文件在但合同不完整 → 编译或断言失败 → 红。
--withdraw 行为撤回对照：把关键实现改回旧行为（闸不拦在途/CPU 交接可先于 GPU/完成回调不触发/
未知完成可放行），每条变异都必须让合同转红；变异体存活 = 本测试没有鉴别力 = 失败。
默认（不带参数）编译工作树实现，期望绿。
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MODULE_C = "android/native/nvn/nvn_vk_completion.c"
MODULE_H = "android/native/nvn/nvn_vk_completion.h"
TEST_C = "android/tests/nvk_completion_test.c"


def git_show(rev: str, path: str) -> str:
    return subprocess.check_output(["git", "show", f"{rev}:{path}"], cwd=ROOT, text=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-ref", help="git revision for the red/withdrawal control")
    parser.add_argument("--withdraw", action="store_true", help="run behaviour-withdrawal mutations (each must turn red)")
    args = parser.parse_args()

    cc = os.environ.get("CC") or shutil.which("cc")
    if not cc:
        print("红: 宿主合同需要 C 编译器（cc）", file=sys.stderr)
        return 1

    if args.withdraw:
        return withdraw(cc)

    with tempfile.TemporaryDirectory(prefix="s2a-nvk-completion-") as td:
        tmp = Path(td)
        sources = [ROOT / MODULE_C]
        includes = [ROOT / "android/native/nvn"]
        if args.source_ref:
            try:
                old_c = git_show(args.source_ref, MODULE_C)
                old_h = git_show(args.source_ref, MODULE_H)
            except subprocess.CalledProcessError:
                print(f"RED（先红后绿负对照）: {args.source_ref} 里没有 {MODULE_C}/{MODULE_H}——"
                      "D 完成 token 接口尚未交付，5 态事实/持有放行/回调合同无法满足")
                return 1
            (tmp / "nvn_vk_completion.c").write_text(old_c)
            (tmp / "nvn_vk_completion.h").write_text(old_h)
            sources = [tmp / "nvn_vk_completion.c"]
            includes = [tmp] + includes

        binary = tmp / "nvk-completion-test"
        cmd = [cc, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter"]
        cmd += [f"-I{path}" for path in includes]
        cmd += [str(ROOT / TEST_C)] + [str(path) for path in sources] + ["-o", str(binary)]
        build = subprocess.run(cmd, capture_output=True, text=True)
        if build.returncode:
            print(build.stdout + build.stderr)
            print(f"RED: 编译失败（source-ref={args.source_ref or 'worktree'}）")
            return 1
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        print(run.stdout.strip())
        if run.stderr.strip():
            print(run.stderr.strip())
        if run.returncode:
            print(f"RED: 宿主合同断言失败（source-ref={args.source_ref or 'worktree'}）")
            return 1
        print(f"GREEN: 宿主合同通过（source-ref={args.source_ref or 'worktree'}）")
        return 0


# 行为撤回对照：每条变异把关键机制改回旧行为，合同必须转红。
MUTATIONS = [
    ("release-before-gate",
     "    if (fact == NVK_COMPLETE_UNKNOWN) return 0;\n    return fact >= gate;",
     "    return fact >= gate - 1;   /* mutation: in-flight reaches the gate */"),
    ("cpu-handoff-before-gpu-done",
     "    if (b->fact != NVK_COMPLETE_GPU_DONE) {\n"
     "        // CPU 交接完成必须晚于 GPU 完成：未提交/在途时声称交接完成是乱序，准确拒绝。",
     "    if (0) {\n        /* mutation: out-of-order handoff accepted */"),
    ("drop-gpu-done-callbacks",
     "        fn(l, b->token, opaque);",
     "        (void)fn; (void)opaque;   /* mutation: completion callbacks dropped */"),
    ("release-on-unknown",
     "    if (b->fact == NVK_COMPLETE_UNKNOWN) {\n        // 未知完成：不推进、不放行，引用保留。",
     "    if (0) {\n        /* mutation: unknown completion may be released */"),
]


def withdraw(cc: str) -> int:
    module_c = ROOT / MODULE_C
    worktree = module_c.read_text()
    include = ROOT / "android/native/nvn"
    failures = 0
    for name, old, new in MUTATIONS:
        if old not in worktree:
            print(f"MISSING ANCHOR for mutation {name}")
            failures += 1
            continue
        with tempfile.TemporaryDirectory(prefix="s2a-nvk-completion-withdraw-") as td:
            tmp = Path(td)
            src = tmp / "nvn_vk_completion.c"
            src.write_text(worktree.replace(old, new, 1))
            binary = tmp / "t"
            cmd = [cc, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                   f"-I{tmp}", f"-I{include}", str(ROOT / TEST_C), str(src), "-o", str(binary)]
            build = subprocess.run(cmd, capture_output=True, text=True)
            if build.returncode:
                print(f"withdraw {name}: MUTANT DID NOT COMPILE (not evidence of coverage)")
                print(build.stdout + build.stderr)
                failures += 1
                continue
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode == 0:
                print(f"MUTANT SURVIVED: {name}（合同没有鉴别力）")
                print(run.stdout)
                failures += 1
            else:
                print(f"withdraw {name}: expected red ok (rc={run.returncode})")
    if failures:
        print(f"红：撤回对照有 {failures} 项未按预期转红")
        return 1
    print(f"PASS: {len(MUTATIONS)} behaviour-withdrawal mutations all turned the contract red")
    return 0


if __name__ == "__main__":
    sys.exit(main())
