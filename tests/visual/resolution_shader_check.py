#!/usr/bin/env python3
# 门禁手动：要私有游戏数据：S2A.ShBake 从游戏着色器重烘的 spv/ 目录
"""验证真实客体代码重烘后的 SPIR-V；使用 SPIRV-Tools 与 SPIRV-Cross，不自写二进制解析。

输入为 S2A.ShBake bake 的 spv/ 目录，不能用旧缓存里直接抽出的 SPIR-V。
报告每支验证失败的文件；不把失败过滤为成功。此检查不代替实际游戏缩放截图。
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import json
from pathlib import Path
import subprocess


def validate(path: Path) -> tuple[str, str]:
    result = subprocess.run(
        ["spirv-val", "--target-env", "vulkan1.2", str(path)],
        capture_output=True, text=True, check=False,
    )
    return str(path), "" if result.returncode == 0 else result.stdout + result.stderr


def reflect(path: Path) -> dict:
    result = subprocess.run(
        ["spirv-cross", str(path), "--reflect"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spv", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--stages", default="vert,frag,comp", help="此次真实语料必须包含的阶段")
    parser.add_argument("--baseline", type=Path, help="基线 bake 输出根；按 programs.tsv 中相同客体阶段配对，仍完整报告原有失败")
    args = parser.parse_args()
    paths = sorted(args.spv.glob("*.spv"))
    if not paths:
        parser.error("目录中没有真实重烘的 SPIR-V")

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        failed = [{"path": path, "error": error} for path, error in pool.map(validate, paths) if error]

    # 各阶段取一支真实程序，核对原字段偏移保持不变，Y 数组位于末尾且仍按 std140 的 16 字节步长。
    stages = {}
    layout_errors = []
    for path in paths:
        reflection = reflect(path)
        stage = reflection["entryPoints"][0]["mode"]
        if stage in stages:
            continue
        ubos = [ubo for ubo in reflection.get("ubos", []) if ubo["binding"] == 0 and ubo["set"] == 0]
        if not ubos:
            layout_errors.append(f"{path}: 没有支持缓冲")
            continue
        ubo = ubos[0]
        members = reflection["types"][ubo["type"]]["members"]
        expected_offsets = [0, 16, 144, 160, 176, 192, 1360, 1376, 1392, 1408, 1424, 1440]
        actual_offsets = [member["offset"] for member in members]
        if actual_offsets != expected_offsets:
            layout_errors.append(f"{path}: 支持缓冲偏移 {actual_offsets}")
        for index in (5, 11):
            if index >= len(members) or members[index].get("array") != [73] or members[index].get("array_stride") != 16:
                layout_errors.append(f"{path}: 成员 {index} 不是 73 项、16 字节步长的倍率数组")
        if ubo["block_size"] != 2608:
            layout_errors.append(f"{path}: 支持缓冲大小 {ubo['block_size']} != 2608")
        stages[stage] = str(path)
        if {"vert", "frag", "comp"}.issubset(stages):
            break
    missing_stages = sorted(set(args.stages.split(",")) - set(stages))
    report = {"shaders": len(paths), "spirv_val_failures": failed, "layout_errors": layout_errors,
              "stages": stages, "missing_stages": missing_stages}
    if args.baseline:
        def programs(root: Path) -> list[dict]:
            with (root / "programs.tsv").open() as file:
                return list(csv.DictReader(file, delimiter="\t"))

        old_programs = programs(args.baseline)
        new_programs = programs(args.spv.parent)
        identities = ("idx", "origin", "status", "kind", "source", "stages(阶段:键:客体长度:指纹)")
        if len(old_programs) != len(new_programs) or any(
            any(old[key] != new[key] for key in identities) for old, new in zip(old_programs, new_programs)
        ):
            raise ValueError("基线与候选的真实程序 / 客体阶段不一致，不能用来对照")
        pairs = set()
        for old, new in zip(old_programs, new_programs):
            old_keys, new_keys = old["spv"].split(","), new["spv"].split(",")
            if len(old_keys) != len(new_keys):
                raise ValueError(f"程序 {old['idx']} 阶段数不一致")
            pairs.update(zip(old_keys, new_keys))
        old_paths = sorted({args.baseline / "spv" / (key + ".spv") for key, _ in pairs if key})
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            old_errors = dict(pool.map(validate, old_paths))
        new_errors = {entry["path"]: entry["error"] for entry in failed}
        valid_pairs, regressions, existing_failures = [], [], []
        for old_key, new_key in sorted(pairs):
            if not old_key:
                continue
            old_path, new_path = args.baseline / "spv" / (old_key + ".spv"), args.spv / (new_key + ".spv")
            old_error, new_error = old_errors[str(old_path)], new_errors.get(str(new_path), "")
            pair = {"baseline": str(old_path), "candidate": str(new_path)}
            if not old_error and not new_error:
                valid_pairs.append(pair)
            elif old_error and new_error and old_error.splitlines()[0].split(": ", 2)[-1] == new_error.splitlines()[0].split(": ", 2)[-1]:
                existing_failures.append(pair)
            elif new_error:
                regressions.append({**pair, "baseline_error": old_error, "candidate_error": new_error})
        report["baseline_comparison"] = {"valid_pairs": valid_pairs, "existing_failure_pairs": existing_failures, "regressions": regressions}
        print(f"相同客体阶段对照：两边通过 {len(valid_pairs)} 对，两边原有失败 {len(existing_failures)} 对，新增失败 {len(regressions)} 对")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"SPIR-V {len(paths)} 支，验证失败 {len(failed)}，布局错误 {len(layout_errors)}，缺少阶段 {missing_stages}")
    return int(bool(failed or layout_errors or missing_stages))


if __name__ == "__main__":
    raise SystemExit(main())
