#!/usr/bin/env python3
"""Audit the actual unstripped diagnostic target built by Gradle."""
import argparse
import json
import pathlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path('/src'),
                    help='source tree being built (docker gate mounts /src; host gate passes its snapshot)')
parser.add_argument('--ndk-bin', type=pathlib.Path, default=None,
                    help='NDK prebuilt <host>/bin with llvm-nm/llvm-readelf; default uses the pinned NDK '
                         'parsed from docker/Dockerfile (host gate resolves via s2a_ndk_host_bin)')
args = parser.parse_args()
root = args.root
if args.ndk_bin is None:
    _packages = dict(p.split(';', 1) for p in re.search(
        r'^ARG SDK_PACKAGES="([^"]+)"$',
        (pathlib.Path(__file__).resolve().parent / 'Dockerfile').read_text(), re.M)[1].split())
    args.ndk_bin = pathlib.Path('/opt/android-sdk/ndk') / _packages['ndk'] / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
android = root / 'android'
commands = list((android / 'app/.cxx').glob('Debug/*/arm64-v8a/compile_commands.json'))
libraries = list((android / 'app/build/intermediates/cxx').glob('Debug/*/obj/arm64-v8a/libs2arm_android.so'))
if len(commands) != 1 or len(libraries) != 1:
    sys.exit(f'【红】找不到唯一的 CMake 编译清单/未剥离库: {len(commands)} / {len(libraries)}')
entries = json.loads(commands[0].read_text())
sources = []
for entry in entries:
    command = entry.get('command', '')
    if 'CMakeFiles/s2arm_android.dir/' in command:
        path = pathlib.Path(entry['file'])
        if not path.is_absolute():
            path = pathlib.Path(entry['directory']) / path
        sources.append(str(path.resolve(strict=True)))
if not sources:
    sys.exit('【红】CMake 编译清单没有 s2arm_android 源文件')
source_list = root / 'build/android-cs/static/gate-sources.txt'
source_list.write_text('\n'.join(sources) + '\n')
ndk = args.ndk_bin
report = root / 'build/android-cs/static/gate-audit.json'
cmd = [sys.executable, str(android / 'core-link/audit.py'),
       '--archive', str(root / 'build/android-cs/static/libs2a_cs.a'),
       '--library', str(libraries[0]), '--source-list', str(source_list),
       '--source-root', str(android), '--consumer-root', str(root / 'services/S2A.Services'),
       '--nm', str(ndk / 'llvm-nm'), '--readelf', str(ndk / 'llvm-readelf'),
       '--link-input-list', str(root / 'build/android-cs/static/link.txt'),
       '--android-elf', '--report', str(report)]
subprocess.run(cmd, check=True)
data = json.loads(report.read_text())
missing = set(data['missing_direct_definitions']) | set(data['unresolved_direct_symbols'])
if missing or not data['diagnostic_link_complete']:
    sys.exit('【红】core-link 缺失/未定义：' + ', '.join(sorted(missing)))
print(f"core-link 未定义/缺失直接符号：{len(missing)}；引用 {len(data['required_direct_symbols'])}")
