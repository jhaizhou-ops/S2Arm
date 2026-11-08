"""可选手动验证：用真实库的标准布局链接视图调用生产 CLI。"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
header = repo / "graphics/nvn/gfx/nvn/dmsh_chain.h"
host = next(line.split('"')[1] for line in header.read_text().splitlines()
            if line.startswith("#define DMSH_CHAIN "))
root = os.environ.get("S2A_GAME_DATA") or os.environ.get("S2A_IN")
direct = Path(root) / "shaders/direct" if root else None
libraries = sorted(p for p in direct.glob("b-*") if p.is_dir() and (p / "lib.idx").is_file()) if direct else []
defaults = [next((p for p in libraries if p.name == "b-" + host), None),
            next((p for p in libraries if p.name != "b-" + host), None)]
names = ("S2A_CHAIN_MATCH_LIB", "S2A_CHAIN_MISMATCH_LIB")
inputs = [Path(value).expanduser() if (value := os.environ.get(name)) else default
          for name, default in zip(names, defaults)]
missing = [name for name, path in zip(names, inputs)
           if path is None or not path.is_dir() or not (path / "lib.idx").is_file()]
if missing:
    sys.exit("【红】mac_chain_test 缺少真实库或 lib.idx：" + "、".join(missing)
             + "；请设置上述变量，或提供含同链和异链库的 S2A_GAME_DATA / S2A_IN 产物根")
matched, mismatched = (path.resolve(strict=True) for path in inputs)
assert matched.is_dir() and matched.name == "b-" + host, "同链输入须为真实当前链库"
assert mismatched.is_dir() and mismatched.name.startswith("b-") and mismatched != matched
other = mismatched.name[2:]
assert other != host, "异链输入不能是当前链"
files = [header] + [p for library in (matched, mismatched) for p in library.iterdir()
                    if p.is_file() and (p.name in ("lib.idx", "inputs.tsv") or p.suffix == ".json")]
assert (matched / "lib.idx").is_file() and (mismatched / "lib.idx").is_file(), "须提供真实打包库"
before = {p: hashlib.sha256(p.read_bytes()).digest() for p in files}
env = {k: v for k, v in os.environ.items()
       if k not in ("S2A_ALLOW_CHAIN_MISMATCH", "DM_MSL_DIR", "S2A_GAME_DATA")}


def run(root, override=None):
    actual = env.copy()
    if override is not None:
        actual["S2A_ALLOW_CHAIN_MISMATCH"] = override
    return subprocess.run([sys.executable, "-B", str(repo / "tools/mac_chain_check.py"), str(root)],
                          env=actual, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix="s2arm-chain-") as temp:
    roots = []
    for name, library in (("match", matched), ("mismatch", mismatched)):
        root = Path(temp) / name
        direct = root / "shaders/direct"
        direct.mkdir(parents=True)
        (direct / library.name).symlink_to(library, target_is_directory=True)
        roots.append(root)
    same, different = roots
    result = run(same)
    assert result.returncode == 0 and not result.stderr, result.stderr
    print("✓ 同链真实库链接视图放行")
    for override in (None, "0", "true", "2"):
        result = run(different, override)
        assert result.returncode != 0, result
        assert result.stderr.count("【红】") == 1 and host in result.stderr and other in result.stderr
    print("✓ 异链拒绝，非 1 的放行值仍拒绝，诊断含两侧链号")
    result = run(different, "1")
    assert result.returncode == 0 and "显式放行" in result.stderr, result.stderr
    print("✓ S2A_ALLOW_CHAIN_MISMATCH=1 显式放行")
    # 同链和旧链同时存在时，运行时选择同链，不被归档旧链误拦。
    (same / "shaders/direct" / mismatched.name).symlink_to(mismatched, target_is_directory=True)
    assert run(same).returncode == 0
    print("✓ 同链与旧链并存放行")
    assert run(repo).returncode == 0
    print("✓ 无 NVN 库目录放行（不冒充库内容验证）")
    # 实际旧库放在同链目录名下仍须拒绝，不伪造或修改索引头。
    (different / "shaders/direct" / mismatched.name).unlink()
    (different / "shaders/direct" / matched.name).symlink_to(mismatched, target_is_directory=True)
    assert run(different).returncode != 0
    assert run(different, "1").returncode == 0
    print("✓ 目录名与真实索引链不符仍拒绝，显式开关可放行")
    output = Path(temp) / "run"
    actual = env | {"S2A_IN": str(different), "S2A_PY": sys.executable}
    result = subprocess.run(["bash", str(repo / "runtime/run_mac.sh"), "chain-check", str(output), "1"],
                            env=actual, capture_output=True, text=True)
    assert result.returncode != 0 and "【红】" in result.stderr, result
    assert not output.exists(), "拒绝之前已写局目录"
    print("✓ 正式 Mac 入口在写局目录 / 准备存档前拒绝")
    actual["S2A_IN"] = str(same)
    actual["S2A_GAME_DATA"] = str(different)
    result = subprocess.run(["bash", str(repo / "runtime/run_mac.sh"), "chain-check", str(output), "1"],
                            env=actual, capture_output=True, text=True)
    assert result.returncode != 0 and "【红】" in result.stderr and not output.exists(), result
    print("✓ 正式入口按 S2A_GAME_DATA 优先的实际资源根核对")
assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in before.items())
print(f"✓ {len(files)} 份真实身份文件及源码头 SHA-256 未变；未启动游戏")
