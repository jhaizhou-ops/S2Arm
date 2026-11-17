"""前台装机先停后台自动作业（11-17 #1450：「更新 iPhone」排在降到最低优先级的「准备更新」后面等程序锁，10 分钟没等到）。
真进程：后台替身拿着 .program-<号>.lock 与 .auto-heavy.lock（D2R f0c1f644c 的自动作业串行锁）慢跑，写一份同真作业形状的任务记录
（operation / pid / pidStart / state running），收 SIGTERM 时记 cancelled 退出——同玩家在界面点取消那条路（core.cancel）。期望手写：
  ① 前台走 install.packer_phone_lock + ipa.program_locks：几秒内拿到程序锁（不等满后台的慢活），后台进程已退出、记录 cancelled
  ② 反向：不先停后台、直接排程序锁（等 3 秒）→ library_busy（原来的倒置）
  ③ 两个后台同时在（一个拿着 auto-heavy 慢跑、一个排在 auto-heavy 后面）：都被停掉、都退出，前台照常拿到锁，没有死锁
  ④ 已结束的、不是这两类的、是前台自己的任务记录：一概不碰
  ⑤ 名单与 main.AUTO_HEAVY 一致
  ⑥ 日志里有「取消正在跑的后台任务」「拿到手机锁」「拿到程序锁 <号>」
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap
import time
import unittest

from jobcase import JobCase, ROOT
import core
import install
import ipa

GID = "0100000000010000"
HOLDER = textwrap.dedent('''
    import json, os, signal, sys, time
    sys.path.insert(0, sys.argv[1])
    import filelock, core
    lib, jobs, task, op, locks = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6].split(",")
    rec = os.path.join(jobs, task + ".json")
    def write(state):
        tmp = rec + ".tmp"
        json.dump(dict(schema=1, id=task, operation=op, state=state, pid=os.getpid(), pidStart=core.pid_start(os.getpid())), open(tmp, "w")); os.replace(tmp, rec)
    def stop(*_):
        write("cancelled"); sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    write("running")
    import contextlib
    with contextlib.ExitStack() as st:
        for n in locks:
            from pathlib import Path
            st.enter_context(filelock.held(Path(lib) / ("." + n + ".lock"), wait_s=600))
        open(os.path.join(jobs, task + ".holding"), "w").close()
        time.sleep(600)
''')


class PreemptAuto(JobCase):
    def setUp(self):
        super().setUp()
        self.c.library.mkdir(parents=True, exist_ok=True)
        self.jobs = core.jobs_dir(self.c.private); self.jobs.mkdir(parents=True, exist_ok=True)
        self.c.task = "fg"
        self.procs = []
        self.addCleanup(self.kill_all)

    def kill_all(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill(); p.wait()

    def start(self, task, op, locks, wait_holding=True):
        p = subprocess.Popen([sys.executable, "-c", HOLDER, str(ROOT / "pack/jobs"), str(self.c.library), str(self.jobs), task, op, ",".join(locks)])
        self.procs.append(p)
        import threading
        threading.Thread(target=p.wait, daemon=True).start()   # 替身是本测试进程的子进程：退出后要有人收（真作业由启动器收），否则僵尸 pid 一直「活着」
        end = time.monotonic() + 20
        while time.monotonic() < end and not (self.jobs / (task + (".holding" if wait_holding else ".json"))).exists():
            time.sleep(0.05)
        self.assertTrue((self.jobs / (task + (".holding" if wait_holding else ".json"))).exists(), f"后台替身 {task} 没起来")
        return p

    def state(self, task):
        return json.loads((self.jobs / f"{task}.json").read_text())["state"]

    def test_foreground_preempts_and_gets_lock(self):
        bg = self.start("bg1", "installUpdatePrepare", [f"program-{GID}", "auto-heavy"])
        t0 = time.monotonic()
        with install.packer_phone_lock(self.c):
            with ipa.program_locks(self.c, [GID]):
                got = time.monotonic() - t0
        self.assertLess(got, 15, "前台不该等满后台的慢活")
        self.assertIsNotNone(bg.poll(), "后台已退出"); self.assertEqual(self.state("bg1"), "cancelled")
        log = (self.c.logs / "fg-decisions.log").read_text(encoding="utf-8")
        for want in ("取消正在跑的后台任务 installUpdatePrepare", "拿到手机锁", f"拿到程序锁 {GID}"):
            self.assertIn(want, log)

    def test_without_preempt_foreground_waits(self):
        self.start("bg2", "installUpdatePrepare", [f"program-{GID}"])
        import filelock
        with self.assertRaises(filelock.Busy):
            with filelock.held(self.c.library / f".program-{GID}.lock", wait_s=3):
                pass

    def test_two_auto_jobs_no_deadlock(self):
        a = self.start("bgA", "sgradeMac", ["auto-heavy", f"program-{GID}"])
        b = self.start("bgB", "installUpdatePrepare", ["auto-heavy"], wait_holding=False)   # 排在 auto-heavy 后面
        t0 = time.monotonic()
        with install.packer_phone_lock(self.c):
            with ipa.program_locks(self.c, [GID]):
                got = time.monotonic() - t0
        self.assertLess(got, 20)
        for p, t in ((a, "bgA"), (b, "bgB")):
            p.wait(timeout=10)
            self.assertEqual(self.state(t), "cancelled")

    def test_leaves_other_records_alone(self):
        other = self.start("bgX", "ipa", [f"program-{GID}x"])
        for task, rec in (("done", dict(operation="installUpdatePrepare", state="completed", pid=os.getpid())),
                          ("fg", dict(operation="installUpdatePrepare", state="running", pid=os.getpid()))):
            (self.jobs / f"{task}.json").write_text(json.dumps(dict(rec, schema=1, id=task)))
        self.assertEqual(core.preempt_jobs(self.c, install.PREEMPT_OPERATIONS, wait=2), [])
        self.assertIsNone(other.poll(), "出包作业不碰")

    def test_list_matches_main(self):
        import main
        self.assertEqual(tuple(install.PREEMPT_OPERATIONS), tuple(main.AUTO_HEAVY))


if __name__ == "__main__":
    unittest.main()
