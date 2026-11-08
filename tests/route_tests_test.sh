#!/bin/bash
# 本地受影响单测运行器：真实 tools/route_tests.sh + gate_route.py + safe_killpg.sh，
# 临时 git 仓、合成测试；固定期望不调用被测实现生成。无游戏/远端/下载。
set -u
H=$(cd "$(dirname "$0")/.." && pwd) || exit 1
python3 - "$H" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
checks = 0

def check(condition, label, detail=''):
    global checks
    if not condition:
        raise AssertionError(f'{label}\n{detail}')
    checks += 1
    print(f'通 {checks}：{label}', flush=True)

with tempfile.TemporaryDirectory(prefix='s2a-route-test-') as temporary:
    repo = Path(temporary) / 'repo with spaces'
    repo.mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.STDOUT)
    def write(name, text):
        p = repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    git('init', '-q')
    for name in ('route_tests.sh', 'gate_route.py', 'safe_killpg.sh'):
        (repo / 'tools').mkdir(exist_ok=True)
        shutil.copyfile(root / 'tools' / name, repo / 'tools' / name)
    write('tools/gate_route.tsv', '# 合成仓不需要钩子\n')
    write('.gitignore', 'events\npids\n*.log\n')
    write('tests/a_green_test.sh', 'echo green >> events\nexit 0\n')
    write('tests/b_red_test.sh', 'echo red >> events\nexit 7\n')
    # 长寿夹具：( sleep 90 && … ) 只在自然寿命走完时写 natural.log（被信号杀掉不写），回收判据认这件事、不按墙钟
    write('tests/c_slow_test.sh', '''
( sleep 90 && echo natural >> natural.log ) & child=$!
printf '%s %s\\n' "$BASHPID" "$child" > pids
trap 'wait "$child" 2>/dev/null; exit 143' TERM
wait "$child"
''')
    write('tests/d_last_test.sh', 'echo last >> events\nexit 0\n')
    write('tools/input file.py', 'pass\n')
    write('tests/e_dependency_test.sh', '# 门禁覆盖：tools/input*\necho dep >> events\n')
    git('add', '.')
    git('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'base')
    git('branch', 'baseline')
    # timeout 若被误调用就留证；真实实现必须完全不依赖该外部命令。
    fakebin = Path(temporary) / 'bin'
    fakebin.mkdir()
    forbidden = fakebin / 'timeout'
    forbidden.write_text('#!/bin/sh\necho forbidden-timeout >> "' + str(repo / 'events') + '"\nexit 99\n')
    forbidden.chmod(0o755)
    env = os.environ.copy()
    env['PATH'] = str(fakebin) + os.pathsep + env['PATH']
    def run(*args):
        out = subprocess.run(['bash', 'tools/route_tests.sh', '--base', 'baseline', *args],
                             cwd=repo, env=env, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=25)
        return out.returncode, out.stdout
    def modify(name):
        with (repo / name).open('a') as f:
            f.write('\n# changed\n')
    def reset():
        git('reset', '--hard', '-q', 'baseline')
        for name in ('events', 'pids', 'natural.log', 'tests/f_new_test.sh'):
            (repo / name).unlink(missing_ok=True)
    def live(pid):
        q = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
        return bool(q.stdout.strip()) and not q.stdout.strip().startswith('Z')
    def gone(pids):
        # 按事件判，不设墙钟期限（负载下 5 秒期限会误红）：被收回的进程只会消失；没被收回的，sleep 90 走完自然寿命先写 natural.log
        while any(live(p) for p in pids):
            if (repo / 'natural.log').exists():
                return False
            time.sleep(0.02)
        return not (repo / 'natural.log').exists()
    def timed_out():
        # --timeout 只收整数秒、从起监督进程就计时（tools/route_tests.sh 132/154 行），负载下超时可能先于夹具写下 pids（孙进程还没起，场景没被检验）。
        # 只认夹具起好后才超时的那一次；没起好的一次也已被整组 KILL，丢弃重跑，最多 5 次
        for _ in range(5):
            rc, out = run('--timeout', '1')
            if (repo / 'pids').exists():
                return rc, out, [int(p) for p in (repo / 'pids').read_text().split()]
        raise AssertionError('5 次超时都先于夹具起好孙进程，③ 未被检验\n' + out)

    rc, out = run()
    check(rc == 0 and out.strip() == '改动集为空，未跑任何单测', '④ 空集退出 0、不回退全跑', out)
    modify('tests/a_green_test.sh')
    modify('tests/b_red_test.sh')
    index = repo / '.git/index'
    before = index.read_bytes()
    rc, out = run('--dry-run')
    check(rc == 0 and out.splitlines() == ['tests/a_green_test.sh', 'tests/b_red_test.sh'], '① 精确清单', out)
    check(not (repo / 'events').exists(), '⑤ dry-run 无执行副作用')
    check(index.read_bytes() == before, 'dry-run 不改真实 index')
    reset()
    modify('tests/a_green_test.sh')
    rc, out = run()
    check(rc == 0 and '跑了 1 个 / 应跑 1 个，绿 1 红 0' in out and (repo / 'events').read_text() == 'green\n', '单绿退出 0、结果与计数正确', out)
    reset()
    for name in ('a_green', 'b_red', 'd_last'):
        modify(f'tests/{name}_test.sh')
    rc, out = run()
    check(rc == 1 and 'tests/b_red_test.sh' in out and 'rc=7' in out
          and '跑了 2 个 / 应跑 3 个，绿 1 红 1' in out
          and (repo / 'events').read_text() == 'green\nred\n', '② 红例点名，默认停止、少跑仍红', out)
    (repo / 'events').unlink()
    rc, out = run('--keep-going')
    check(rc == 1 and '跑了 3 个 / 应跑 3 个，绿 2 红 1' in out
          and (repo / 'events').read_text() == 'green\nred\nlast\n', 'keep-going 红后继续', out)
    reset()
    modify('tests/c_slow_test.sh')
    rc, out, pids = timed_out()
    check(rc == 1 and '超时，rc=124' in out and '跑了 1 个 / 应跑 1 个，绿 0 红 1' in out,
          '③ 超时明确判红，不伪装成测试成功', out)
    # 「未等待自然寿命」= 运行器返回时夹具还没走完自然寿命（natural.log 不在），不再用「10 秒内返回」
    check(not (repo / 'natural.log').exists() and gone(pids), '③ 子/孙进程无活动残留，未等待自然寿命 90 秒', out)
    reset()
    write('tests/c_slow_test.sh', '''
trap '' TERM
( sleep 90 && echo natural >> natural.log ) & child=$!
printf '%s %s\\n' "$BASHPID" "$child" > pids
wait "$child"
''')
    rc, out, pids = timed_out()
    check(rc == 1 and '超时，rc=124' in out and not (repo / 'natural.log').exists() and gone(pids),
          '拒绝 TERM 的子/孙进程仍经 helper KILL 有界收回', out)
    reset()
    write('tests/f_new_test.sh', 'echo new >> events\n')
    before = index.read_bytes()
    rc, out = run('--dry-run')
    check(rc == 0 and out.strip() == 'tests/f_new_test.sh' and index.read_bytes() == before,
          '未跟踪新单测进入原路由，真实 index 不变', out)
    rc, out = run()
    check(rc == 0 and (repo / 'events').read_text() == 'new\n', '未跟踪新单测实际执行', out)
    reset()
    modify('tests/a_green_test.sh')
    git('add', 'tests/a_green_test.sh')
    modify('tests/b_red_test.sh')
    modify('tools/input file.py')
    before = index.read_bytes()
    rc, out = run('--dry-run')
    check(rc == 0 and out.splitlines() == ['tests/a_green_test.sh', 'tests/b_red_test.sh', 'tests/e_dependency_test.sh']
          and index.read_bytes() == before, '暂存+未暂存+含空格路径改动，保留真实 index', out)
    # MM cancellation: staged content and worktree differ, even when the latter
    # equals HEAD. Both diff paths belong to the change set independently.
    reset()
    path = repo / 'tests/a_green_test.sh'
    original = path.read_text()
    modify('tests/a_green_test.sh')
    git('add', 'tests/a_green_test.sh')
    path.write_text(original)
    check(git('status', '--porcelain=v1').decode().strip() == 'MM tests/a_green_test.sh',
          '抵消夹具确实同时存在暂存与未暂存差异')
    before = index.read_bytes()
    rc, out = run('--dry-run')
    check(rc == 0 and out.splitlines() == ['tests/a_green_test.sh'] and index.read_bytes() == before,
          'MM 抵消不丢改动，且真实 index 字节不变', out)
    rc, out = run()
    check(rc == 0 and (repo / 'events').read_text() == 'green\n', 'MM 抵消仍实际运行所选单测', out)
    reset()
    modify('tools/input file.py')
    git('add', '.')
    git('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'change')
    rc, out = run('--dry-run')
    check(rc == 0 and 'tests/e_dependency_test.sh' in out, 'base...HEAD 已提交差异也进路由', out)
    reset()
    for args in (('--timeout', '0'), ('--timeout', '-1'), ('--timeout', '1.5'), ('--timeout', '09'),
                 ('--timeout', '99999999999999999999'), ('--timeout',), ('--base',), ('--base', 'missing-ref'), ('--unknown',)):
        rc, out = run(*args)
        check(rc == 2, f'参数/基线错误退出 2：{args}', out)
    # 路由器失败不当成空清单；不能碰任何真实单测。
    write('tools/gate_route.py', 'raise SystemExit(9)\n')
    rc, out = run()
    check(rc == 2 and not (repo / 'events').exists(), '路由器失败为环境错误，不报空集绿', out)
    reset()
    write('tests/f_new_test.sh', '''
( sleep 90 && echo natural >> natural.log ) &
echo "$!" > pids
exit 0
''')
    rc, out = run()
    check(rc == 0 and gone([int((repo / 'pids').read_text())]), '正常结束亦清理同组遗留后台进程', out)
    reset()
    modify('tests/c_slow_test.sh')
    logfile = Path(temporary) / 'interrupt.log'
    with logfile.open('w') as log:
        proc = subprocess.Popen(['bash', 'tools/route_tests.sh', '--base', 'baseline'], cwd=repo,
                                env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not (repo / 'pids').exists() and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            check((repo / 'pids').exists(), '中断夹具确实已启动')
            pids = [int(p) for p in (repo / 'pids').read_text().split()]
            proc.send_signal(signal.SIGTERM)
            rc = proc.wait(timeout=10)
            check(rc == 143 and gone(pids), '中断返回 143、同组子孙被回收', logfile.read_text())
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)
    reset()
    # Native cat/pipe boundary: fill stdout without draining it, then observe
    # cat as this exact Popen runner's direct child before signalling the runner.
    # No cat replacement, process-group guesses or signals to unrelated PIDs.
    write('tests/f_new_test.sh', 'python3 -c \'print("x" * 262144)\'\n')
    proc = subprocess.Popen(['bash', 'tools/route_tests.sh', '--base', 'baseline'], cwd=repo,
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        cat_seen = False
        deadline = time.monotonic() + 10
        while proc.poll() is None and time.monotonic() < deadline:
            rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
            for row in rows.splitlines():
                fields = row.split(None, 2)
                if len(fields) == 3 and fields[1] == str(proc.pid) and Path(fields[2]).name == 'cat':
                    cat_seen = True
                    break
            if cat_seen:
                break
            time.sleep(0.02)
        check(cat_seen, '末项日志正在由原生 cat 输出，测试组已回收')
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=10)
        check(proc.returncode == 143 and '跑了 1 个 / 应跑 1 个，绿 1 红 0' not in out,
              '末项 cat 输出期间 TERM 返回 143，不输出全绿结论', out[-400:] + err)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.communicate(timeout=10)
    check(not (repo / 'events').exists(), '所有流程未调用 GNU timeout 桩')
print(f'route_tests 单测全过：{checks} 项')
PY
