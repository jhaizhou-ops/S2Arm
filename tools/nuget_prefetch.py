#!/usr/bin/env python3
"""离线门禁要的 NuGet 包：依赖一变就在本机联网还原一次，列出包目录交给 tools/remote.sh 同步到门禁机（11-07 启动器线）。

起因：launchers/windows/launcher/gate.sh 只做离线还原（--source <本机包缓存>，门禁不联网、可复现）。#1639 加包后，
mini 假家目录和本机 ~/.nuget/packages 都没联网还原过，门禁退出 75「OFFLINE DEPENDENCIES NOT READY」，整批列车留队。
以后改依赖（加包、升版本）同样会复现，所以把「联网补齐」放在门禁之前的同步阶段，门禁本身仍离线。

用法：python3 tools/nuget_prefetch.py <工程.csproj 或目录>…（目录 = 下面全部 .csproj，跳过 obj/ bin/）
  输出：每行一个要同步的包目录，形如 ~/.nuget/packages/<小写包名>/<版本>（remote.sh 的 sync 写法）。
  依赖指纹 = 各工程文件、同目录及上级的 Directory.*.props / Directory.Packages.props / global.json / NuGet.config 内容
           + dotnet --version；指纹没变且列出的目录都在本机缓存里 → 直接用上次的清单，不跑 dotnet。
  指纹变了或缺目录 → 先离线还原试一次，不行再联网还原（只在本机），读 obj/project.assets.json 收包。
退出码：0 成功；1 还原失败（标准错误写原因）；2 用法。
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEP_FILES = ("Directory.Build.props", "Directory.Build.targets", "Directory.Packages.props", "global.json", "NuGet.config", "nuget.config")


def cache_dir() -> Path:
    return Path(os.environ.get("NUGET_PACKAGES") or Path.home() / ".nuget/packages")


def dep_inputs(project: Path) -> list[Path]:
    files = [project]
    d = project.parent
    while True:
        files += [d / n for n in DEP_FILES if (d / n).is_file()]
        if d == ROOT or d.parent == d:
            break
        d = d.parent
    return files


def fingerprint(projects: list[Path], dotnet: str) -> str:
    h = hashlib.sha256()
    for p in sorted({f for pr in projects for f in dep_inputs(pr)}):
        h.update(os.path.relpath(p, ROOT).encode() + b"\0" + p.read_bytes() + b"\0")
    h.update(subprocess.run([dotnet, "--version"], capture_output=True, text=True).stdout.strip().encode())
    return h.hexdigest()[:16]


def packages(project: Path) -> set[str]:
    """obj/project.assets.json 里还原到的包（含传递依赖与运行时包下载项），形如 <小写名>/<版本>。"""
    assets = json.loads((project.parent / "obj/project.assets.json").read_text(encoding="utf-8"))
    out = {k.lower() for k, v in assets.get("libraries", {}).items() if v.get("type") == "package"}
    for fw in assets.get("project", {}).get("frameworks", {}).values():
        for dep in fw.get("downloadDependencies", []):
            ver = dep.get("version", "").strip("[]").split(",")[0].strip()
            if dep.get("name") and ver:
                out.add(f"{dep['name'].lower()}/{ver}")
    return out


def restore(dotnet: str, project: Path, cache: Path, env: dict) -> bool:
    offline = [dotnet, "restore", str(project), "--source", str(cache), "-p:NuGetAudit=false", "--disable-parallel"]
    if subprocess.run(offline, env=env, capture_output=True).returncode == 0:
        return True
    online = subprocess.run([dotnet, "restore", str(project), "--disable-parallel"], env=env, capture_output=True, text=True)
    if online.returncode:
        sys.stderr.write(f"【红】联网还原 {os.path.relpath(project, ROOT)} 失败：{(online.stdout + online.stderr).strip()[-400:]}\n")
    return online.returncode == 0


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write(__doc__.split("\n\n")[2] + "\n")
        return 2
    dotnet = os.environ.get("S2A_DOTNET") or shutil.which("dotnet")
    if not dotnet:
        sys.stderr.write("【红】没有 dotnet，备不了离线门禁要的 NuGet 包\n")
        return 1
    projects: list[Path] = []
    for a in argv:
        p = Path(a).resolve()
        projects += sorted(q for q in p.rglob("*.csproj") if not {"obj", "bin"} & set(q.relative_to(p).parts)) if p.is_dir() else [p]
    if not projects:
        sys.stderr.write("【红】没找到 .csproj：" + " ".join(argv) + "\n")
        return 1
    cache = cache_dir()
    run_root = Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run")
    record = run_root / "s2arm/cache/nuget_prefetch" / (fingerprint(projects, dotnet) + ".list")
    if record.is_file():
        listed = [l for l in record.read_text().splitlines() if l]
        if listed and all((cache / l).is_dir() for l in listed):
            print("\n".join("~/.nuget/packages/" + l for l in listed))
            return 0
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1", NUGET_PACKAGES=str(cache))
    found: set[str] = set()
    for p in projects:
        if not restore(dotnet, p, cache, env):
            return 1
        found |= packages(p)
    missing = sorted(l for l in found if not (cache / l).is_dir())
    if missing:
        sys.stderr.write("【红】还原后本机缓存仍缺：" + "、".join(missing[:5]) + "\n")
        return 1
    record.parent.mkdir(parents=True, exist_ok=True)
    tmp = record.with_suffix(".tmp")
    tmp.write_text("\n".join(sorted(found)) + "\n")
    tmp.replace(record)
    print("\n".join("~/.nuget/packages/" + l for l in sorted(found)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
