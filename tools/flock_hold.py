#!/usr/bin/env python3
# 持锁小进程（内核文件锁 flock(2)）——仓库里唯一的进程间互斥实现：tools/devlock.sh（设备锁）与 tools/plock.sh（出包锁 / 刷新锁 / 提交锁 / 登记锁 …）都调它。
# 用法：flock_hold.py <锁文件> <持锁者 pid> take|probe [标签]   标签只为在 ps 里认出是谁的持锁进程（devlock_hold / plock_hold），不参与逻辑
# 退出码 0 = take 取到（标准输出守护进程 pid）/ probe 锁空闲；1 = 锁被占；2 = 持锁者已不在 / 监视不可用；3 = 锁文件打不开
# 非阻塞取到锁后 fork 脱离成守护进程（setsid、关掉继承来的 fd），用 kqueue NOTE_EXIT（Linux 用 pidfd / poll）盯持锁者：持锁者一退出（含 kill -9）它随即退出、内核放锁；
#   放锁 = 给它发 TERM。锁文件常驻不删（删了再建是另一个 inode，两边各锁各的）。为什么不在调用方 shell 里开 fd 持锁：flock 跟着文件描述走，
#   会被调用方起的每个子进程（sleep、后台循环、devicectl）继承，持锁者被 kill -9 后孤儿子进程还攥着锁（见 tools/devlock.sh 文件头）
#   take-any：<锁文件> 写成「a:b:c」多把，依次试、锁住第一把空闲的，标准输出「守护进程 pid<TAB>锁文件」；全被占退 1（11-04 门禁全机步数令牌：
#     一次调用试完 N 把，排队的步不必每秒起 N 次解释器）
import fcntl, os, select, sys
path, holder, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
fd = None
for cand in (path.split(':') if mode == "take-any" else [path]):
    try:
        f = os.open(cand, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as e:   # 打不开（路径是目录：旧版 mkdir 锁同名、无权限…）≠ 锁被占：单列退出码 3，调用方报红而不是一直等
        print(f'打不开锁文件 {cand}：{e}', file=sys.stderr); sys.exit(3)
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(f); continue
    fd, path = f, cand; break
if fd is None:
    sys.exit(1)
if mode == "probe":
    sys.exit(0)
r, w = os.pipe()
pid = os.fork()
if pid:
    os.close(w)
    ok = os.read(r, 1) == b"1"   # 等守护进程登记好对持锁者的监视再报取到：持锁者已死就报 2、锁随守护进程退出而放
    if ok:
        print(f"{pid}\t{path}" if mode == "take-any" else pid)
    sys.exit(0 if ok else 2)
os.close(r)
os.setsid()
nul = os.open(os.devnull, os.O_RDWR)
for i in (0, 1, 2):
    os.dup2(nul, i)
keep = sorted({fd, w})
os.closerange(3, keep[0]); os.closerange(keep[0] + 1, keep[1]); os.closerange(keep[1] + 1, 65536)   # 不攥调用方的管道（… | tail 不被拖住）
if hasattr(select, "kqueue"):
    kq = select.kqueue()
    try:
        kq.control([select.kevent(holder, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT)], 0, 0)
    except OSError:
        os._exit(2)
    os.write(w, b"1"); os.close(w)
    kq.control(None, 1, None)   # 持锁者退出即返回；放锁走 SIGTERM（缺省动作直接退出）
else:
    try:
        parent_fd = os.pidfd_open(holder)
        poll = select.poll()
        poll.register(parent_fd, select.POLLIN)
        # 已退出但尚未回收的持锁者仍能打开 pidfd；握手前检查已可读的退出状态。
        if poll.poll(0):
            os._exit(2)
    except (AttributeError, OSError):   # 持锁者已死 / API、内核或权限不支持：明确失败，不按 PID 探活兜底
        os._exit(2)
    os.write(w, b"1"); os.close(w)
    poll.poll()   # pidfd 固定打开时的进程身份，后续 PID 复用不改变监视对象
    os.close(parent_fd)
os._exit(0)
