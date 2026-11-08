#!/usr/bin/env python3
# 门禁手动：只能 Linux（Linux 宿主描述符测试，macOS 上 mkdtemp 声明冲突编不过），本机跑不了，门禁 Linux 路径本轮没实跑验证
"""真实 os.c/runtime 启动 sink：Linux host 描述符测试，不代表 Android/NativeAOT 真机验收。"""
import argparse
import json
import pathlib
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--out', type=pathlib.Path, required=True)
p.add_argument('--cc', default='cc')
p.add_argument('--cflag', action='append', default=[])
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[4]
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
flags = [a.cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-pthread'] + a.cflag
for d in ['runtime/include', 'runtime/src', 'android/native', 'android/native/runtime']:
    flags += ['-I', str(root / d)]
objects = []
for source, extra in [
    ('runtime/src/os.c', ['-D__ANDROID__', '-Ddup2=log_test_dup2']),
    ('android/native/runtime/runtime.c', ['-D__ANDROID__']),
    ('runtime/src/guest_main.c', []),
    ('android/core-link/runtime-tests/session-log/session_log_test.c', []),
    ('android/native/direct/selection.c', []),
    ('android/native/direct/attempt.c', []),
    ('android/native/direct/graphics.c', []),
    ('android/native/direct/json.c', []),
    ('android/native/direct/sha256.c', []),
    ('android/native/direct/s2a_direct_abi.c', []),
]:
    obj = out / (pathlib.Path(source).stem + '.o')
    subprocess.run(flags + extra + ['-c', str(root / source), '-o', str(obj)], check=True)
    objects.append(str(obj))
exe = out / 'session-log'
subprocess.run(flags + objects + ['-o', str(exe)], check=True)
results = []
for case in ['success', 'missing-dir', 'partial-bind', 'invalid']:
    directory = out / case
    if case != 'missing-dir':
        directory.mkdir()
        (directory / 'host-old.log').write_text('previous session must survive\n')
    r = subprocess.run([str(exe), case, str(directory)], capture_output=True, text=True, timeout=10)
    files = list(directory.glob('host-37-*.log'))
    text = files[0].read_text() if files else ''
    passed = r.returncode == 0
    if case == 'success':
        markers = ['Android 会话日志', 'FIRST_CORE_WINDOW', '[s2a] NATIVE_LOG', 'C_STDERR', 'C_STDOUT',
                   'SIGNAL_RAW_WRITE', 'NATIVE_AFTER_STDERR_REPLACED']
        passed &= len(files) == 1 and all(x in text for x in markers) and '\npipe\n' not in text
    elif case == 'partial-bind':
        passed &= len(files) == 1 and 'FIRST_CORE_WINDOW' not in text
    else:
        passed &= not files
    if directory.exists():
        passed &= (directory / 'host-old.log').read_text() == 'previous session must survive\n'
    results.append(dict(case=case, passed=passed, returncode=r.returncode, stdout=r.stdout, stderr=r.stderr,
                        logs=[str(x) for x in files], log=text))
    print(case, 'PASS' if passed else 'FAIL')
(out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
if not all(x['passed'] for x in results):
    raise SystemExit(1)

# 回归负控：删除真实 runtime 对 sink 的调用，原生产行为必须被同一个消费者测试拒绝。
source = (root / 'android/native/runtime/runtime.c').read_text()
old = 'int log_error = s2a_android_session_log_start(r->services.state_dir, r->services.session_id);'
assert source.count(old) == 1
mutant = out / 'runtime-no-log.c'
mutant.write_text(source.replace(old, 'int log_error = 0;'))
obj = out / 'runtime-no-log.o'
subprocess.run(flags + ['-D__ANDROID__', '-c', str(mutant), '-o', str(obj)], check=True)
bad = out / 'no-log'
subprocess.run(flags + [str(obj) if x == str(out / 'runtime.o') else x for x in objects] + ['-o', str(bad)], check=True)
directory = out / 'negative-control'
directory.mkdir()
r = subprocess.run([str(bad), 'success', str(directory)], capture_output=True, text=True, timeout=10)
(out / 'negative-control.json').write_text(json.dumps(dict(returncode=r.returncode, stdout=r.stdout, stderr=r.stderr), indent=2) + '\n')
if r.returncode == 0:
    raise SystemExit('FAIL: omitted sink was not detected')
print('negative control PASS (omitted production sink rejected)')
