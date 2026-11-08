#!/usr/bin/env python3
"""Exercise the real threaded-suite launcher with a poisoned PATH Python."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name('threaded_host_suites.sh')
with tempfile.TemporaryDirectory(prefix='s2a-threaded-python-') as tmp:
    root = Path(tmp)
    suite = root / 'repo/platforms/android/tests/threaded_host_suites.sh'
    suite.parent.mkdir(parents=True)
    shutil.copyfile(source, suite)
    asset_fixture = root / 'repo/backends/vulkan/runtime/tests/asset_fixture.c'
    asset_fixture.parent.mkdir(parents=True)
    shutil.copyfile(Path(__file__).resolve().parents[2] / 'graphics/vulkan/runtime/tests/asset_fixture.c', asset_fixture)
    shutdown = root / 'repo/platforms/android/core-runtime/tests/run_shutdown_thread.sh'
    shutdown.parent.mkdir(parents=True)
    shutdown.write_text('#!/bin/sh\n[ "$#" -eq 2 ] || exit 1\nprintf "%s\\n" "$@" > "$SHUTDOWN_LOG"\n')
    # bc6a6208 起套件里 direct-tests / android-services / touch-tests 三支 bash 步骤共用 "$shared" 构建目录：
    # 沙盒只核对 python 选择与 shutdown 参数，给它们同一份空跑桩（不编、不看参数），漏桩会被当成套件失败。
    for rel in ('android/core-runtime/direct-tests/run.sh',
                'android/core-runtime/tests/run_services.sh',
                'android/core-link/runtime-tests/touch/run.sh'):
        stub = root / 'repo' / rel
        stub.parent.mkdir(parents=True, exist_ok=True)
        stub.write_text('#!/bin/sh\nexit 0\n')
    binaries = root / 'bin'
    binaries.mkdir()
    pinned = root / 'pinned python'
    pinned.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$PY_LOG"\n')
    poison = binaries / 'python3'
    poison.write_text('#!/bin/sh\necho wrong-PATH-python >&2\nexit 97\n')
    dotnet = binaries / 'dotnet'
    dotnet.write_text('''#!/bin/sh
if [ "$1" = --version ]; then echo 10.0.0; exit 0; fi
if [ "$1" = build ]; then
  # 按传入的工程名与 -c 配置产出测试 DLL（10-30 列车线：#868 在套件里加了 DirectAbi / DirectCompiler 两支 Release 编译，
  #   原假 dotnet 不论编什么都只产出 Runtime.Tests/debug，套件报「找不到构建产物」，本单测在门禁里红）
  # 两种重定向：-p:ArtifactsPath=X → X/bin/<工程>/<cfg>/<工程>.dll（runtime-tests 步在用）；
  #   -p:OutputPath=X/ → X/<工程>.dll（直连两支自测在用，避开 ArtifactsPath 搬 obj 引发的 NuGet 恢复图坍缩）
  cfg=debug; prev=; flat=
  for arg in "$@"; do case "$arg" in
    -p:OutputPath=*) out=${arg#*=}; flat=1;;
    -p:ArtifactsPath=*) out=${arg#*=};;
    *.csproj) name=$(basename "$arg" .csproj);; esac
    [ "$prev" = -c ] && cfg=$(printf %s "$arg" | tr A-Z a-z); prev=$arg; done
  if [ -n "$flat" ]; then mkdir -p "$out" && : > "$out/$name.dll"; else mkdir -p "$out/bin/$name/$cfg" && : > "$out/bin/$name/$cfg/$name.dll"; fi
fi
exit 0
''')
    for executable in (pinned, poison, dotnet):
        executable.chmod(0o755)
    log = root / 'python.log'
    shutdown_log = root / 'shutdown.log'
    env = dict(os.environ, S2A_PY=str(pinned), DOTNET=str(dotnet), PY_LOG=str(log),
               SHUTDOWN_LOG=str(shutdown_log),
               PATH=str(binaries) + os.pathsep + os.environ.get('PATH', '/usr/bin:/bin'))
    result = subprocess.run(['bash', str(suite)], env=env, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(f'threaded suite did not use S2A_PY: rc={result.returncode}\n{result.stdout}{result.stderr}')
    paths = log.read_text().splitlines()
    expected = ['counter-tests/run.py', 'audio-lifetime-tests/run.py', 'metrics-tests/run.py']
    if sys.platform.startswith('linux'):
        expected.append('tests/run_lifecycle.py')
    if len(paths) != len(expected) or any(not actual.endswith(want) for actual, want in zip(paths, expected)):
        raise SystemExit(f'threaded suite used unexpected Python inputs: {paths}')
    shutdown_args = shutdown_log.read_text().splitlines()
    if len(shutdown_args) != 2 or not shutdown_args[0].endswith('/shutdown') or shutdown_args[1] != str(dotnet):
        raise SystemExit(f'threaded suite used unexpected shutdown arguments: {shutdown_args}')
    print('threaded host suites: explicit S2A_PY used for each Python runner; PATH poison untouched')
