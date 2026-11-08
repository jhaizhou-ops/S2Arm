#!/usr/bin/env python3
# 门禁手动：要传参数：真实成功包的 shaders 目录 + 失败诊断目录，手动回归（docs/坑记录.md 着色器摘要一节）
"""真实着色器产物回归，不生成着色器、不替换编译器。

python3 tests/shader_summary_real_test.py <成功包的 shaders> <失败诊断目录>
失败诊断目录须含真实 shader_pack.json、bake.json、pso_gen.log、shader_pack.log。
只在临时目录链接或复制输入；需要 macOS 的 ARG_MAX 与现有 pack/roots.sh。
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(script, env):
    return subprocess.run(
        ["/bin/bash", "-c", script], env={**env, "LC_ALL": "C"}, text=True, capture_output=True
    )


def main():
    shaders, evidence = (Path(arg).resolve(strict=True) for arg in sys.argv[1:])
    recorded = json.loads((evidence / "shader_pack.json").read_text())
    assert recorded["pso"]["chunks"] > 0 and recorded["pso_archive_kb"] == 0
    archives = sorted(shaders.glob("gal_pso.*.bin"))
    libraries = sorted(shaders.glob("gal.*.metallib"))
    assert archives and libraries, "需要真实成功包的归档与函数库"
    original = {path: digest(path) for path in (evidence / "shader_pack.json", archives[0])}
    expected = {
        "pso_archive_kb": sum(path.stat().st_size for path in archives) // 1024,
        "metallib_kb": sum(path.stat().st_size for path in libraries) // 1024,
    }
    # 直接执行生产脚本中已有的汇总命令与收尾段，Bash 负责解释；不复制实现。
    source = (REPO / "graphics/tools/shader_pack.sh").read_text()
    report = source[source.index('PSOBAD=$PSOBAD "$PY" - "$W/bake.json"'):source.index('key_of "$ROOT" >')]
    stage_source = (REPO / "pack/stages/shaders.sh").read_text()
    stage = stage_source[stage_source.index("PARTIAL=0\n"):stage_source.index('_root_rm "$W/shaders/work"')]
    with tempfile.TemporaryDirectory(prefix="s2a-real-shaders-") as temporary:
        root = Path(temporary)
        long_dir = root
        while len(os.fsencode(long_dir)) < 760:
            long_dir /= "真实归档 path with spaces " + "x" * 100
        long_dir.mkdir(parents=True)
        (long_dir / "shcache").mkdir()
        for path in archives + libraries:
            (long_dir / path.name).symlink_to(path)
        argv_bytes = sum(len(os.fsencode(long_dir / path.name)) + 1 for path in archives)
        arg_max = os.sysconf("SC_ARG_MAX")
        assert argv_bytes > arg_max, f"真实归档数量不足以覆盖 ARG_MAX：{argv_bytes} <= {arg_max}"
        old = run('cat "$O"/gal_pso.*.bin 2>/dev/null | wc -c', {**os.environ, "O": str(long_dir)})
        assert old.returncode == 0 and int(old.stdout) == 0, old
        env = {
            **os.environ, "W": str(evidence), "O": str(long_dir), "PY": sys.executable,
            "MF": str(recorded["red"]["metal_compile"]), "TID": recorded["title"],
            "PSORED": str(recorded["red"]["pso_archive"]),
            "PSOBAD": str(recorded["red"]["pso_pipeline"]),
        }
        rebuilt = recorded["rebuilt"]
        env["SP_REBUILT"] = " ".join(str(value) for value in (
            rebuilt["msl_total"], rebuilt["msl_total"] - rebuilt["msl"], rebuilt["msl"],
            rebuilt["pso_chunks_total"], rebuilt["pso_chunks"],
        ))
        times = recorded["wall_s"]
        elapsed = 0
        env["T0"] = "0"
        for index, name in enumerate(("build_s", "extract_s", "bake_s", "metal_s", "pso_s"), 1):
            elapsed += times[name]
            env[f"T{index}"] = str(elapsed)
        script = 'set -u\nt() { echo "$*"; }\n' + report
        result = run(script, env)
        assert result.returncode == 0, result.stderr + result.stdout
        actual = json.loads((long_dir / "shader_pack.json").read_text())
        assert all(actual[name] == size > 0 for name, size in expected.items()), actual
        # 10-30 前的证据带通用链接版读数（link_dylib 与 red.link_dylib），汇总已不再出：按去掉它们后的值比
        legacy = recorded["red"].pop("link_dylib", 0)
        recorded["red_total"] -= legacy
        for name, value in recorded.items():
            if name not in (*expected, "shcache_kb", "link_dylib"):
                assert actual[name] == value, name
        print(f"PASS 真实归档 {len(archives)} 片，argv={argv_bytes} > ARG_MAX={arg_max}；旧统计 0，新统计 {expected}")

        # 实际文件系统错误：悬空链接和同名目录都不能被当成有效归档或统计为 0。
        bad = long_dir / archives[0].name
        bad.unlink()
        bad.symlink_to(root / "missing")
        (long_dir / "shader_pack.json").unlink()
        result = run(script, env)
        assert result.returncode != 0 and not (long_dir / "shader_pack.json").exists()
        bad.unlink()
        bad.mkdir()
        result = run(script, env)
        assert result.returncode != 0 and not (long_dir / "shader_pack.json").exists()
        print("PASS 归档不可读取或不是普通文件时汇总失败，不生成成功报告")
        bad.rmdir()
        for path in archives[1:]:
            (long_dir / path.name).unlink()
        result = run(script, env)
        assert result.returncode == 0, result.stderr + result.stdout
        empty = json.loads((long_dir / "shader_pack.json").read_text())
        assert empty["pso_archive_kb"] == 0 and empty["metallib_kb"] == expected["metallib_kb"]
        print("PASS 没有归档文件时如实统计 0，函数库读数不变")

        roots = root / "roots"
        roots.mkdir()
        current = roots / "game@current"
        current.mkdir()
        (roots / "game@现行").symlink_to(current.name)
        stage_env = {
            **os.environ, "S2A_ROOTS": str(roots), "S2A_ROOTS_SHARED": str(root / "shared"),
            "S2A_ROOTS_NO_BOOT": "1", "G": "game", "rc": "0", "red": "", "SCH": "",
        }
        for case in ("zero", "missing-index", "copy-failure", "early-exit", "spec-copy-failure"):
            tag = case
            working = roots / f"game@{tag}.tmp"
            (working / "shaders/work").mkdir(parents=True)
            shutil.copy2(evidence / "shader_pack.log", working / "shader_pack.log")
            report_source = shaders if case == "spec-copy-failure" else evidence
            shutil.copy2(report_source / "shader_pack.json", working / "shaders/shader_pack.json")
            for name in ("bake.json", "pso_gen.log"):
                shutil.copy2(evidence / name, working / "shaders/work" / name)
            for name in ("gal.shards", "gal.idx"):
                shutil.copy2(shaders / name, working / "shaders" / name)
            saved = roots / ".failed/game_shaders"
            if saved.exists():
                shutil.rmtree(saved)
            if case == "missing-index":
                (working / "shaders/gal.idx").unlink()
            if case == "copy-failure":
                # 让真实 cp 遇到 EISDIR，检查保存失败确实阻止 root_abort。
                (saved / "pso_gen.log").mkdir(parents=True)
                (saved / "pso_gen.log/pso_gen.log").mkdir()
            if case == "early-exit":
                shutil.rmtree(working / "shaders")
            result = run(
                f'set -u\nsource "{REPO}/pack/roots.sh"\n' + stage,
                {
                    **stage_env, "W": str(working), "TAG": tag,
                    "rc": "1" if case == "early-exit" else "0",
                    "SCH": "1" if case == "spec-copy-failure" else "",
                    "SCF": str(working / "missing-spec-combos.tsv"),
                },
            )
            assert result.returncode == 1, result.stderr + result.stdout
            assert (roots / "game@现行").resolve() == current.resolve()
            if case == "copy-failure":
                assert working.exists() and "保存着色器诊断失败" in result.stdout, result
            else:
                assert not working.exists(), result
                assert digest(saved / "shader_pack.log") == digest(evidence / "shader_pack.log")
                if case != "early-exit":
                    assert digest(saved / "shader_pack.json") == digest(report_source / "shader_pack.json")
                    for name in ("bake.json", "pso_gen.log"):
                        assert digest(saved / name) == digest(evidence / name)
            print(f"PASS 真实失败诊断 {case}：现行不变，日志保存 / 临时现场符合预期")
    assert all(digest(path) == value for path, value in original.items())
    print("PASS 原始报告与抽查归档哈希不变；未运行游戏或修改源产物")


if __name__ == "__main__":
    main()
