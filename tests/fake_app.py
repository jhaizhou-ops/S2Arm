#!/usr/bin/env python3
# 假 App（执行器单测用）：按 tests/真机契约.md 写 host.log / frames.tsv / 解包。场景由 FAKE_SCENE 选：
#   ok（缺省）就绪 → 30 帧/秒出帧，第 MARK_AT（缺省 30）帧打 MARK，每帧分配 1000 B、不回收、不读回阻塞
#   gc     MARK 之后每 3 帧 gen0 +1、每次 GC 停顿 10 ms（gc_pause_us）         stall  出到第 40 帧后停住不出
#   crash  第 50 帧打 CRASH 后退出            nomark 不打 MARK
#   noready 不打「S2A 就绪」
#   gpuhang 第 41 帧写一行 GPU 卡死原文（FAKE_HANG_LINE 可换），之后照常出帧
#   restart MARK 后 FAKE_RESTART_AFTER（缺省 3）帧做一次进程内重启：同真 App，帧号从 1 重数、frames.tsv 重写（只剩重启后这一段）、心跳帧号归零
# FAKE_SHOT=<名>：MARK 时写 Documents/ap_<名>.png（自动玩家自存截图）
import glob, json, os, signal, sys, tarfile, time
D = os.environ['FAKE_DOCS']; sc = os.environ.get('FAKE_SCENE', 'ok'); signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
if os.environ.get('S2A_PACK_APPLY_ONLY') == '1':
    if os.environ.get('FAKE_APPLY') == 'crash': sys.exit(5)   # 起来即崩、没走到解包（10-22 链 SDK 27 没接 UIScene 的包）
    if os.environ.get('FAKE_APPLY') == 'slow': time.sleep(8)   # 解得慢但活着：不许被当成崩
    prog = os.environ.get('FAKE_APPLY') == 'progress'   # 同真 App（runtime/src/pack_apply.c）：每解一个包先记一行「进度：解开 …」，全部解完才记完成行；每包隔 3 秒
    pk = os.path.join(D, '资源包'); n = 0; nt = 0
    if os.environ.get('FAKE_APPLY') == 'vanish':   # 推送包在解包前没了、旧 App 照写 .applied（10-25 测试机2 马车8：推 4 批、记「解开 0 个包」）
        for t in glob.glob(os.path.join(pk, '.incoming', '*.tar')): os.remove(t)
    tars = sorted(glob.glob(os.path.join(pk, '.incoming', '*.tar')))
    for i, t in enumerate(tars):
        if prog:
            with open(os.path.join(D, 'unpack.log'), 'a') as f: f.write(f'10-25 00:00:00 进度：解开 {os.path.basename(t)}（{i + 1}/{len(tars)}）1 个文件 0 MB（0.0 秒）\n')
            time.sleep(3)
        with tarfile.open(t) as z: z.extractall(pk); n += len(z.getnames())
        os.remove(t); nt += 1
    sha = json.load(open(os.path.join(pk, 'manifest.json')))['index_sha256']
    import shutil; shutil.copyfile(os.path.join(pk, 'index.tsv'), os.path.join(pk, 'index.applied.tsv'))   # 同真 App（runtime/src/pack_apply.c）：已应用索引
    open(os.path.join(pk, '.applied'), 'w').write(sha)
    with open(os.path.join(D, 'unpack.log'), 'a') as f: f.write(f'10-25 00:00:00 解开 {nt} 个包 {n} 个文件 0 MB，.applied = {sha}（0.0 秒）\n')
    # 写完 .applied 还活着：linger = 3 秒后像真 App 收尾那样重开 host.log（轮换后新建、截断）；hang = 一直不退（只有 SIGTERM 能结束）。11-05 Switch Sports 冷装局 host.log 只剩 760 字节
    if os.environ.get('FAKE_APPLY') == 'linger': time.sleep(3); open(os.path.join(D, 'host.log'), 'w').write('[s2a] 收推送进程收尾\n')
    if os.environ.get('FAKE_APPLY') == 'hang':
        while True: time.sleep(1)
    sys.exit(0)
if os.environ.get('S2A_COLD_START') == '1': open(os.path.join(D, 'cold_start.txt'), 'w').write('清首启缓存\n')
H = open(os.path.join(D, 'host.log'), 'a', buffering=1)
# 图形模式（同 runtime/src/gfxmode.c 的文件部分）：程序号取资源包 shaders/shcache/<程序号>；旧的 wire/<程序号>/fail 起局删掉、不作依据（10-26），按包判直连
_sc = os.path.join(D, '资源包', 'shaders', 'shcache'); _tid = (sorted(os.listdir(_sc)) or [''])[0].upper() if os.path.isdir(_sc) else ''
if _tid:
    _wf = os.path.join(D, 'wire', _tid, 'fail')
    if os.path.exists(_wf): os.remove(_wf); H.write('[s2a] 图形模式：删掉旧的直连失败标记 %s（运行中不再切换，模式只按包和 S2A_GFX 定）\n' % _wf)
    H.write('[s2a] 图形模式：直连（依据 包里带本翻译链的直连库（假）；程序号 %s）\n' % _tid)
class Tee:
    def __init__(s, f): s.f = f
    def write(s, x):
        s.f.write(x)
        for l in x.splitlines():
            if not l.startswith('[gal]'): sys.stdout.write(l + '\r\n')
        sys.stdout.flush()
if os.environ.get('S2A_LOG_CONSOLE') == '1': H = Tee(H)
F = open(os.path.join(D, os.environ.get('S2A_FRAMES_TSV', 'frames.tsv')), 'w', buffering=1)
if sc != 'noready': H.write('S2A 就绪\n[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n')   # 渲染器按游戏请求的交换间隔打（帧率能耗线 0107）
if os.environ.get('FAKE_UNFOCUS') == '1': H.write('[s2a] [心跳] 帧 0，热状态 0（0 正常 1 一般 2 严重 3 危急），进程实占 100 MB，前台失焦，持续执行档 0\n')
H.write(f"[s2a] [电] 电量 {os.environ.get('FAKE_BATT', '80%，充电中')}\n"); F.write('frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tgc_pause_us\n')
mark = int(os.environ.get('MARK_AT', '30')); gc0 = 0; fr = 0
while True:
    fr += 1
    if sc == 'gpuhang' and fr == 41:   # Metal / IOGPU 报命令缓冲卡死（11-07 测试机2）：写一行原文后照常出帧——执行器不认签名就会把这局收成 done
        H.write(os.environ.get('FAKE_HANG_LINE', '[gal] Metal 命令缓冲出错：Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)') + '\n'); H.flush()
    if sc == 'apquit' and fr > 40:   # 自动玩家没进可玩、自己收局：优雅退出后不再出帧
        if fr == 41: H.write('收到 自动玩家结束：优雅退出\n'); fr += 1
        time.sleep(1); continue
    if sc == 'gpuslow' and fr == 41:   # 加载帧 GPU 慢：停住不出帧、宿主每秒打「GPU 慢…继续等」，之后照常出帧
        # 停多久按执行器的轮询事件定，不按墙钟（10-23 负载 13–17 时偶发红：固定 12 秒的慢段可能整段落在两轮轮询之间，执行器走不到「再等」分支）：
        #   执行器的停顿时长从它「看到最后一帧」那一轮算起（不早于停顿后第一次拉取 p1）：等到一次不早于 p1 + S2A_STALL_S + 1 秒的拉取（那一轮必判到停顿、
        #   同时看到 GPU 慢 → 打「再等」），再等下一次拉取（说明那一轮的判定已打完），才恢复出帧。
        #   上限 FAKE_GPUSLOW_MAX（缺省 25 秒，小于执行器 GPU 慢宽限 30 秒）兜底，不无限停
        pl = os.path.join(os.path.dirname(D), 'pulls.log'); t0 = time.time(); stl = float(os.environ.get('S2A_STALL_S', '10')) + 1.0
        p1 = ready = None; k = 0
        while time.time() - t0 < float(os.environ.get('FAKE_GPUSLOW_MAX', '25')):
            k += 1; H.write(f'[gal] 【红】GPU 慢：等栅栏 99 已 {k} 秒（帧 40），系统回执没报错，继续等\n')
            ts = [float(x) for x in open(pl).read().split()] if os.path.exists(pl) else []
            if p1 is None: p1 = next((t for t in ts if t > t0), None)
            if p1 is not None and ready is None: ready = next((t for t in ts if t >= p1 + stl), None)
            if ready is not None and any(t > ready for t in ts): break
            time.sleep(1)
    if sc == 'stall' and fr > 40:
        if fr == 41: H.write('[gal] 【红】GPU 卡死：假卡死\n'); fr += 1; globals()['_st0'] = time.time()
        # Duo 现场（11-06）：心跳迟到时别的线程照常写行（FAKE_STALL_CHATTER），停 FAKE_STALL_RESUME_S 秒后恢复出帧
        if os.environ.get('FAKE_STALL_CHATTER'): H.write('[s2a] 写跟踪计数：别的线程照常写行\n')
        if os.environ.get('FAKE_STALL_RESUME_S') and time.time() - _st0 >= float(os.environ['FAKE_STALL_RESUME_S']): sc = 'normal'; continue
        # 同真宿主：心跳挂在主线程定时器上（ios/app.m），出帧停了心跳照打、帧号停在 40（真机 10 秒一行，这里 1 秒一行省时间）
        if not os.environ.get('FAKE_STALL_NO_HB'): H.write('[s2a] [心跳] 帧 40，热状态 0（0 正常 1 一般 2 严重 3 危急），进程实占 100 MB，前台\n')
        time.sleep(1); continue
    if sc == 'gc' and fr > mark and (fr - mark) % 3 == 0: gc0 += 1   # MARK 后每 3 帧回收一次：执行器窗口按整秒计、最短只有几帧（10-20 夜门禁并行时窗口 9→14 帧，碰不到原来第 20 帧那次回收，偶发判绿）
    # gpuslow：最后一帧（40）写进 frames.tsv 之前先打第一行「GPU 慢」——执行器一看到帧停在 40，host.log 里必已有它（10-23 负载下：写完第 40 帧后假 App
    #   被饿住几秒才打第一行，执行器判「停帧、没有 GPU 慢」红；执行器每轮先拉 host.log 后拉 frames.tsv，判停顿至少隔一轮）
    if sc == 'gpuslow' and fr == 40: H.write('[gal] 【红】GPU 慢：等栅栏 99 已 0 秒（帧 40），系统回执没报错，继续等\n')
    F.write(f'{fr}\t33333\t1000\t{gc0}\t0\t0\t0\t{10000 if sc == "gc" and fr > mark and (fr - mark) % 3 == 0 else 0}\n')   # gc 场景每次回收停 10 ms（> 30 帧停顿上限 8.3 ms = 帧预算 25%，10-23）
    if fr % int(os.environ.get('FAKE_HB_EVERY', '10')) == 0: H.write(f'[s2a] [心跳] 帧 {fr}，热状态 0（0 正常 1 一般 2 严重 3 危急），进程实占 100 MB，前台，持续执行档 0\n')   # 真 App 10 秒一行，这里每 10 帧一行（FAKE_HB_EVERY 改间隔：构造「心跳不再前进」）
    if fr == mark and sc != 'nomark' and not globals().get('_rs'):   # restart：同现场，重启后不再打 MARK（否则账本按重启后的 MARK 取窗，用例随时序时好时坏）
        H.write(f'S2A 标记 MARK：帧 {fr}\n')
        if os.environ.get('FAKE_SHOT'): open(os.path.join(D, 'ap_' + os.environ['FAKE_SHOT'] + '.png'), 'wb').write(b'PNGDATA')
    if sc == 'crash' and fr == 50: H.write('CRASH 假崩溃\n'); sys.exit(1)
    if sc == 'restart' and not globals().get('_rs') and fr == mark + int(os.environ.get('FAKE_RESTART_AFTER', '3')):   # 进程内重启（11-04 Windows 出包线外置局：切 60 帧代按「立刻重启」后帧号归零）
        _rs = 1; H.write('[s2a] iOS 重启：provider 已就绪，guest 首启前时钟/线程/GPU hold 已建立\n'); fr = 0
        F.close(); F = open(os.path.join(D, os.environ.get('S2A_FRAMES_TSV', 'frames.tsv')), 'w', buffering=1); F.write('frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tgc_pause_us\n')
    time.sleep(1 / 30)
