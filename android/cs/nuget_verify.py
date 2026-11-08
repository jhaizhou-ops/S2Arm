#!/usr/bin/env python3
"""Restore 后核对固定 NuGet 包（#1131 复审第 5 条）。

输入 project.assets.json：libraries 是还原进缓存的包，downloadDependencies
是 NativeAOT 的 runtime/host/RID pack（不进 packages.lock.json）。凡
nuget-pins.tsv 钉过的包，版本必须与固定表一致、缓存目录里
.nupkg.metadata 的 contentHash 必须与钉的 SHA-512 一致；包目录里还保留
.nupkg 字节时，重算其 SHA-512 并和下载时记录的 .nupkg.sha512 比对，防
缓存被事后改写。任何一条不符即非零退出——不猜、不跳过。
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path

PINS = Path(__file__).resolve().parent / 'nuget-pins.tsv'
REQUIRED_IDS = ('microsoft.dotnet.ilcompiler', 'microsoft.net.illink.tasks')
RID_ILC = re.compile(r'^runtime\.[^.]+\.microsoft\.dotnet\.ilcompiler$')


def load_pins(path):
    pins = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        ident, version, sha512 = line.split()
        if ident.lower() in pins:
            raise ValueError(f'固定表重复条目 {ident}')
        pins[ident.lower()] = (version, sha512)
    if not pins:
        raise ValueError(f'固定表为空：{path}')
    return pins


def restored_packages(assets_path):
    doc = json.loads(Path(assets_path).read_text())
    found = {}
    for key in doc.get('libraries', {}):
        ident, _, version = key.rpartition('/')
        if ident and version:
            found[ident.lower()] = version
    for framework in doc.get('project', {}).get('frameworks', {}).values():
        for dep in framework.get('downloadDependencies', []):
            version = dep['version'].strip('[]').split(',')[0].strip()
            found[dep['name'].lower()] = version
    return found


def verify_package(nuget_root, ident, version, sha512, errors):
    pkg_dir = nuget_root / ident / version
    if not pkg_dir.is_dir():
        errors.append(f'{ident}/{version} 不在 NuGet 缓存：{pkg_dir}')
        return
    meta = pkg_dir / '.nupkg.metadata'
    if not meta.is_file():
        errors.append(f'{ident}/{version} 缺 .nupkg.metadata')
        return
    actual = json.loads(meta.read_text()).get('contentHash')
    if actual != sha512:
        errors.append(f'{ident}/{version} contentHash 不符：缓存 {actual}，固定 {sha512}')
        return
    nupkg = pkg_dir / f'{ident}.{version}.nupkg'
    recorded = pkg_dir / f'{ident}.{version}.nupkg.sha512'
    if nupkg.is_file() and recorded.is_file():
        digest = base64.b64encode(hashlib.sha512(nupkg.read_bytes()).digest()).decode()
        if digest != recorded.read_text().strip():
            errors.append(f'{ident}/{version} .nupkg 字节与下载记录不符（缓存被改写？）')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets', required=True, type=Path, help='project.assets.json')
    ap.add_argument('--pins', type=Path, default=PINS, help='固定表')
    ap.add_argument('--nuget', type=Path,
                    default=Path(os.environ.get('NUGET_PACKAGES')
                                 or Path.home() / '.nuget/packages'),
                    help='NuGet 全局缓存根')
    args = ap.parse_args()
    pins = load_pins(args.pins)
    restored = restored_packages(args.assets)
    errors = []
    for required in REQUIRED_IDS:
        if required not in restored:
            errors.append(f'project.assets.json 未还原 {required}（不是 NativeAOT 恢复？）')
    rid_ilcs = sorted(i for i in restored if RID_ILC.match(i))
    if 'microsoft.dotnet.ilcompiler' in restored and not rid_ilcs:
        errors.append('未还原本宿主 RID 的 ILC 工具链包'
                      '（runtime.<rid>.microsoft.dotnet.ilcompiler）')
    for ident in rid_ilcs:
        if ident not in pins:
            errors.append(f'本宿主 RID 的 ILC 包未固定：{ident}（请把它的 SHA-512 钉进 nuget-pins.tsv）')
    for ident, (version, sha512) in sorted(pins.items()):
        if ident not in restored:
            continue  # RID 包按宿主取：osx-arm64 只在 macOS 还原，不强求在场
        if restored[ident] != version:
            errors.append(f'{ident} 版本不符：还原 {restored[ident]}，固定 {version}')
            continue
        verify_package(args.nuget, ident, version, sha512, errors)
    if errors:
        for e in errors:
            print(f'【红】NuGet 固定核对：{e}', file=sys.stderr)
        return 1
    checked = sum(1 for ident in pins if ident in restored)
    print(f'NuGet 固定核对通过：{checked} 个包的 contentHash 与钉值一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
