#!/usr/bin/env python3
# 假 devicectl（执行器 / 调度单测用，不碰手机）：S2A_DEVICECTL="python3 tests/fake_devicectl.py"，每台设备的状态放 $FAKE_DEV/<--device>。
# 硬件 UDID 按测试机名单对应（FAKE_HW_UDID 给了就用它，模拟 devicectl 报错设备）。
# 只实现执行器用到的子命令；copy to 以目录为源 = 把目录内容合并进目标目录（与真机 10-19 实测一致）。
# 起局时以 $FAKE_APP（缺省 tests/fake_app.py）起假 App，环境 = 本进程环境 + --environment-variables。
import time, json, os, plistlib, shutil, signal, subprocess, sys, uuid, zipfile
A = sys.argv[1:]
TO = None
if '--timeout' in A:   # 执行器把 devicectl 自带的 --timeout 加在命令末尾；先摘掉，下面「最后一个参数 = 包路径 / 包名」照旧
    i = A.index('--timeout'); TO = A[i + 1]; del A[i:i + 2]
def opt(k, d=None):
    if k == '--timeout': return TO
    return A[A.index(k) + 1] if k in A else d
R = os.path.join(os.environ['FAKE_DEV'], opt('--device', 'nodev')); os.makedirs(R, exist_ok=True)   # 每台设备一个目录
HW = os.environ.get('FAKE_HW_UDID') or {'00000000-0000-0000-0000-000000000001': '00000000-0000000000000001', '00000000-0000-0000-0000-000000000002': '00000000-0000000000000002'}.get(opt('--device'), '')
def app_dir(b): return os.path.join(R, 'apps', b)
def log(s):
    with open(os.path.join(R, 'calls.log'), 'a') as f: f.write(s + '\n')
log(' '.join(A[:3]))
def hang():   # 挂死：真 devicectl 带 --timeout 时到点放弃、非 0 退出（服务端撤掉这次操作）；不带就一直挂，由外层 timeout 杀
    t = opt('--timeout'); time.sleep(float(t) if t else 3600); print('Operation timed out; abandoned', file=sys.stderr); sys.exit(1)
if A[:3] == ['device', 'info', 'displays'] and opt('--json-output'):   # 同真机 JSON（11-07 Duo 实测结构）；FAKE_DUAL_DISPLAY=1 = Duo：primary 背光关、亮着的是第二块
    one = lambda uid, primary, active: {'uniqueId': uid, 'primary': primary, 'active': active, 'name': 'LCD' if primary else 'LCD-1'}
    ds = [one('987-654-321', True, False), one('123-456-789', False, True)] if os.environ.get('FAKE_DUAL_DISPLAY') == '1' else [one('111-111-111', True, True)]
    json.dump({'result': {'displays': ds}}, open(opt('--json-output'), 'w')); sys.exit(0)
if A[:3] == ['device', 'capture', 'screenshot']:   # 整屏截图：写一张 2868×1320 的 PNG（17 Pro Max 横屏原生分辨率）；FAKE_NO_SHOT=1 模拟截屏失败
    if os.environ.get('FAKE_NO_SHOT') == '1': print('ERROR: capture failed', file=sys.stderr); sys.exit(1)
    # Duo：不带 --display-unique-id 截的是 primary（背光关）= 全黑，这里按截屏失败处理，好让单测看得出截错屏
    if os.environ.get('FAKE_DUAL_DISPLAY') == '1' and opt('--display-unique-id') != '123-456-789': print('ERROR: captured primary display (backlight off)', file=sys.stderr); sys.exit(1)
    import struct, zlib
    w, h = 2868, 1320; raw = b''.join(b'\0' + b'\0' * w for _ in range(h))
    ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(opt('--destination'), 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
    sys.exit(0)
if A[:2] == ['list', 'devices']:   # 设备列表（tools/devices.sh 贡献者自有设备 S2A_DEVICE_OWN=1 用）：FAKE_DEVLIST = JSON 数组，每项 name / udid / identifier，可选 reality（缺省 physical）/ platform（iOS）/ paired（true）
    ds = [{'identifier': d['identifier'], 'hardwareProperties': {'udid': d['udid'], 'reality': d.get('reality', 'physical'), 'platform': d.get('platform', 'iOS')},
           'deviceProperties': {'name': d['name']}, 'connectionProperties': {'pairingState': 'paired' if d.get('paired', True) else 'unpaired'}} for d in json.loads(os.environ.get('FAKE_DEVLIST', '[]'))]
    json.dump({'result': {'devices': ds}}, open(opt('--json-output'), 'w')); sys.exit(0)
if A[:3] == ['device', 'info', 'details']: print(f'  UDID: {HW}'); sys.exit(0)
if A[:3] == ['device', 'info', 'apps']:
    b = opt('--bundle-id'); ad = os.path.join(R, 'apps')   # 不带 --bundle-id = 列机上全部 App（每个 apps/<包名>/url 一项，带 bundleIdentifier）
    bs = [b] if b else (sorted(os.listdir(ad)) if os.path.isdir(ad) else [])
    apps = [{'bundleIdentifier': x, 'url': open(os.path.join(app_dir(x), 'url')).read()} for x in bs if os.path.exists(os.path.join(app_dir(x), 'url'))]
    if os.environ.get('FAKE_APPS_GARBAGE') == '1': open(opt('--json-output'), 'w').write('<<not json>>'); sys.exit(0)   # 模拟 devicectl 吐出读不了的 JSON（审计 P1-50）
    json.dump({'result': {'apps': apps}}, open(opt('--json-output'), 'w')); sys.exit(0)
if A[:3] == ['device', 'info', 'files'] and opt('--json-output'):   # 同真机 --json-output：递归列出 relativePath / size / isDirectory（tools/dev_run.sh 推完逐文件核用）
    if os.environ.get('FAKE_LIST_FAIL_SUB') == opt('--subdirectory', ''): sys.exit(1)   # 指定子目录的清单拉不回（tools/push_pack.py 核账退回整包重推的用例）
    d = os.path.join(app_dir(opt('--domain-identifier')), opt('--subdirectory', ''))
    fs = []
    for dp, dn, fn in os.walk(d):
        for n in sorted(dn + fn):
            p = os.path.join(dp, n); rel = os.path.relpath(p, d)
            fs.append({'relativePath': rel, 'name': rel, 'metadata': {'size': os.path.getsize(p)}, 'resources': {'isDirectory': os.path.isdir(p)}})
    json.dump({'result': {'files': fs}}, open(opt('--json-output'), 'w')); sys.exit(0 if os.path.isdir(d) else 1)
if A[:3] == ['device', 'info', 'files']:   # 只列一层：每行「名字  属性」
    d = os.path.join(app_dir(opt('--domain-identifier')), opt('--subdirectory', ''))
    for n in sorted(os.listdir(d)) if os.path.isdir(d) else []: print(f'{n}   Writable, Readable')
    sys.exit(0)
if A[:3] == ['device', 'install', 'app']:
    z = zipfile.ZipFile(A[-1]); pl = [n for n in z.namelist() if n.endswith('.app/Info.plist')][0]
    b = plistlib.loads(z.read(pl))['CFBundleIdentifier']; os.makedirs(os.path.join(app_dir(b), 'Documents'), exist_ok=True)
    open(os.path.join(app_dir(b), 'url'), 'w').write(f'file:///fake/{uuid.uuid4().hex[:8]}/')   # 每次安装路径都变（与真机一致）
    with open(os.path.join(R, 'installs.log'), 'a') as f: f.write(b + '\n')
    sys.exit(0)
if A[:3] == ['device', 'uninstall', 'app']: shutil.rmtree(app_dir(A[-1]), ignore_errors=True); sys.exit(0)
if A[:2] == ['device', 'copy']:
    if A[2] == 'from' and int(os.environ.get('FAKE_HANG_FROM', '0')) > 0:   # 前 N 次 copy from 挂死（模拟 xctrace 异常退出后设备通道挂住，10-20 测试机1）
        cf = os.path.join(R, 'hang_count'); n = int(open(cf).read()) if os.path.exists(cf) else 0; open(cf, 'w').write(str(n + 1))
        if n < int(os.environ['FAKE_HANG_FROM']): hang()
    if A[2] == 'from' and os.environ.get('FAKE_HANG_AFTER_LAUNCH') == '1' and os.path.exists(os.path.join(R, 'launched')): hang()   # 起局后文件服务挂死（10-21 测试机1 马车8 局形态）
    if A[2] == 'from' and opt('--source') == os.environ.get('FAKE_HANG_SRC'):   # 拉某文件第 FAKE_HANG_SRC_N 次挂死（模拟起局后轮询时通道挂住，10-20 测试机2 拉 host.log 171 秒）
        cf = os.path.join(R, 'hang_src_count'); n = int(open(cf).read()) if os.path.exists(cf) else 0; open(cf, 'w').write(str(n + 1))
        if n + 1 == int(os.environ.get('FAKE_HANG_SRC_N', '1')): hang()
    if A[2] == 'to' and int(os.environ.get('FAKE_FAIL_TO', '0')) > 0:   # 前 N 次 copy to 失败（模拟推回机上偶发失败，11-02 测试机1 桥「推回失败，下一轮重推」）
        cf = os.path.join(R, 'fail_to_count'); n = int(open(cf).read()) if os.path.exists(cf) else 0; open(cf, 'w').write(str(n + 1))
        if n < int(os.environ['FAKE_FAIL_TO']): print('ERROR: copy failed', file=sys.stderr); sys.exit(1)
    b = opt('--domain-identifier'); root = app_dir(b)
    if not os.path.isdir(root): print('app not installed', file=sys.stderr); sys.exit(1)
    src, dst = opt('--source'), opt('--destination')
    if A[2] == 'to':
        d = os.path.join(root, dst)
        # FAKE_ENOSPC=<子串>：推往含该子串的目标时按机上空间满报错退出（报错原文照 10-29 测试机1 cp.log：openat(2) 返回 POSIX 28）
        if os.environ.get('FAKE_ENOSPC') and os.environ['FAKE_ENOSPC'] in dst:
            print(f'ERROR: The operation couldn\u2019t be completed. Failed to open {dst} for writing, openat(2) returned POSIX error code 28 (parentParam = 5) (NSPOSIXErrorDomain error 28 (0x1C))', file=sys.stderr); sys.exit(1)
        if os.path.isdir(src):
            shutil.copytree(src, d, dirs_exist_ok=True)
            # FAKE_DROP=<文件名>：推目录时前 FAKE_DROP_N 次（缺省 1）悄悄漏掉这个文件、照样返回 0（10-26 八方2：推存档 cpto 成功、机上少了 MJSaveData1）
            if os.environ.get('FAKE_DROP'):
                cf = os.path.join(R, 'drop_count'); n = int(open(cf).read()) if os.path.exists(cf) else 0
                if n < int(os.environ.get('FAKE_DROP_N', '1')):
                    open(cf, 'w').write(str(n + 1))
                    for dp, _, fn in os.walk(d):
                        if os.environ['FAKE_DROP'] in fn: os.remove(os.path.join(dp, os.environ['FAKE_DROP']))
        else: os.makedirs(os.path.dirname(d), exist_ok=True); shutil.copyfile(src, d)
        if int(os.environ.get('FAKE_HANG_TO', '0')) > 0:   # 前 N 次 copy to 拷完不退出（10-20 测试机2：18 字节 app.id 写完后 devicectl 挂 14.5 分钟）
            cf = os.path.join(R, 'hang_to_count'); n = int(open(cf).read()) if os.path.exists(cf) else 0; open(cf, 'w').write(str(n + 1))
            if n < int(os.environ['FAKE_HANG_TO']): time.sleep(3600)
        sys.exit(0)
    s = os.path.join(root, src)
    if os.path.isdir(s): shutil.copytree(s, dst, dirs_exist_ok=True); sys.exit(0)   # 拉整个目录（同真 devicectl：11-06 测试机1 实拉 Documents/wire/<程序号>/shaders 整目录）
    if not os.path.isfile(s): print(f'no such file {src}', file=sys.stderr); sys.exit(1)
    # 拉取不新鲜（11-06 性能线 A：Duo 上 live 副本 30 秒没更新，判红前重读也没拿到新内容）：从第一次拉 host.log 起第 FAKE_STALE_FROM_S 秒开始、持续 FAKE_STALE_S 秒，
    #   拉 host.log / frames.tsv 返回时段开头那一刻的快照（rc=0）；FAKE_STALE_MODE=fail 改为直接失败（rc=1）
    if os.environ.get('FAKE_STALE_S') and (src.endswith('host.log') or src.endswith('frames.tsv')):
        t0f = os.path.join(R, 'stale_t0')
        if not os.path.exists(t0f): open(t0f, 'w').write(str(time.time()))
        el = time.time() - float(open(t0f).read()); a0 = float(os.environ.get('FAKE_STALE_FROM_S', '0'))
        if a0 <= el < a0 + float(os.environ['FAKE_STALE_S']):
            if os.environ.get('FAKE_STALE_MODE') == 'fail': print('fake: copy timed out', file=sys.stderr); sys.exit(1)
            snap = os.path.join(R, 'stale_' + os.path.basename(src))
            if not os.path.exists(snap): shutil.copyfile(s, snap)
            shutil.copyfile(snap, dst); sys.exit(0)
    if src.endswith('frames.tsv') and os.environ.get('FAKE_LAG_FRAMES'):   # live 副本滞后（10-27 R13 坑 2）：拉回的 frames.tsv 只到第 N 帧，设备上其实还在涨
        keep = int(os.environ['FAKE_LAG_FRAMES'])
        with open(s, encoding='utf-8', errors='replace') as f: lines = f.read().splitlines(True)
        with open(dst, 'w', encoding='utf-8') as f: f.write(''.join(lines[:keep + 1]))
        sys.exit(0)
    shutil.copyfile(s, dst)
    # 拉取记录（事件信号）：执行器每轮轮询拉一次 host.log；假 App 按「拉了几次、什么时候拉的」推进，不靠固定 sleep 竞速（gpuslow，10-23 负载下偶发红）
    if src.endswith('host.log'):
        with open(os.path.join(root, 'pulls.log'), 'a') as f: f.write(f'{time.time()}\n')
    sys.exit(0)
if A[:3] == ['device', 'process', 'launch']:
    if opt('--environment-variables') is not None and not json.loads(opt('--environment-variables')):   # 真 devicectl 拒收空对象（10-22 实测）
        print('Error: Unable to decode environment variables. Please pass only strings for keys and data.', file=sys.stderr); sys.exit(64)
    b = A[-1]; root = app_dir(b); pf = os.path.join(R, 'app.pid')
    if '--terminate-existing' in A and os.path.exists(pf):
        try: os.kill(int(open(pf).read()), signal.SIGTERM)
        except (OSError, ValueError): pass
    env = dict(os.environ); env.update(json.loads(opt('--environment-variables', '{}'))); env['FAKE_DOCS'] = os.path.join(root, 'Documents')
    app = os.environ.get('FAKE_APP', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fake_app.py'))
    con = '--console' in A
    p = subprocess.Popen([sys.executable, app], env=env, stdout=subprocess.PIPE if con else subprocess.DEVNULL, stderr=open(os.path.join(R, 'app.err'), 'a'), start_new_session=True)
    open(pf, 'w').write(str(p.pid))
    with open(os.path.join(R, 'launches.log'), 'a') as f: f.write(opt('--environment-variables', '{}') + '\n')
    if env.get('S2A_PACK_APPLY_ONLY') != '1': open(os.path.join(R, 'launched'), 'w').write('1')
    lg = os.environ.get('FAKE_LINGER', '').split(None, 1)   # 起局这一刻 FAKE_LINGER 的进程才出现（之前被开局清残留结束过也重新算活）
    if len(lg) == 2 and env.get('S2A_PACK_APPLY_ONLY') != '1':
        open(os.path.join(R, 'linger_on'), 'w').write(lg[0]); kf = os.path.join(R, 'killed.txt')
        if os.path.exists(kf): open(kf, 'w').write(''.join(l for l in open(kf) if l.strip() != lg[0]))
    if con:   # 真 devicectl：提示行 + App 的 stdout（pty，行尾 \r\n）；收到 SIGTERM 转给 App，App 退了写 --json-output（带 terminationResult）再退
        def fin(*_):
            try: os.kill(p.pid, signal.SIGTERM)
            except OSError: pass
        signal.signal(signal.SIGTERM, fin)
        print(f'Launched application with {b} bundle identifier.\r\nWaiting for the application to terminate...\r', flush=True)
        for l in p.stdout: sys.stdout.write(l.decode('utf-8', 'replace')); sys.stdout.flush()
        rc = p.wait(); print(f'The app terminated with the exit code {rc}.\r', flush=True)
        if opt('--json-output'): json.dump({'result': {'process': {'processIdentifier': p.pid}, 'terminationResult': {'exitCode': rc, 'wasCoreDumpCreated': False}}}, open(opt('--json-output'), 'w'))
        sys.exit(0)
    if opt('--json-output'): json.dump({'result': {'process': {'processIdentifier': p.pid}}}, open(opt('--json-output'), 'w'))
    sys.exit(0)
if A[:3] == ['device', 'info', 'processes']:   # 夹具 <设备目录>/processes.txt：一行「pid 路径」（模拟机上残留的旧 App 进程）+ 本假设备起的、还活着的假 App；真机进程表从不为空，带一行 launchd
    pf = os.path.join(R, 'processes.txt'); print('1 /sbin/launchd')
    if os.path.exists(pf): print(open(pf).read(), end='')
    lg = os.environ.get('FAKE_LINGER', '').split(None, 1)   # FAKE_LINGER="pid 路径"：起局后多一个收局后还活着的进程（11-07 ab_pre3d2），被结束（killed.txt）才消失
    kf = os.path.join(R, 'killed.txt')
    if len(lg) == 2 and os.path.exists(os.path.join(R, 'linger_on')) and lg[0] not in (open(kf).read().split() if os.path.exists(kf) else []): print(f'{lg[0]} {lg[1]}')
    ap = os.path.join(R, 'app.pid')
    try:
        if os.path.exists(ap): os.kill(int(open(ap).read()), 0); print(f'{open(ap).read().strip()} /private/var/containers/Bundle/Application/FAKE/S2Arm.app/S2Arm')
    except (OSError, ValueError): pass
    sys.exit(0)
def drop(pid):   # 进程结束：从夹具进程表里去掉；FAKE_LINGER 的进程记进 killed.txt
    with open(os.path.join(R, 'killed.txt'), 'a') as f: f.write(f'{pid}\n')
    pf = os.path.join(R, 'processes.txt')
    if os.path.exists(pf): open(pf + '.n', 'w').write(''.join(l for l in open(pf) if l.split()[:1] != [str(pid)])); os.replace(pf + '.n', pf)
if A[:3] == ['device', 'process', 'signal']:   # 只记 SIGKILL 并结束（夹具进程）
    with open(os.path.join(R, 'signaled.log'), 'a') as f: f.write(f"{opt('--pid')} {opt('--signal')}\n")
    if str(opt('--pid')) not in os.environ.get('FAKE_KILL_STUCK', '').split(): drop(opt('--pid'))   # FAKE_KILL_STUCK：SIGKILL 也停不掉
    sys.exit(0)
if A[:3] == ['device', 'process', 'terminate']:
    with open(os.path.join(R, 'terminated.log'), 'a') as f: f.write(str(opt('--pid')) + '\n')
    if str(opt('--pid')) not in os.environ.get('FAKE_TERM_STUCK', '').split(): drop(opt('--pid'))   # FAKE_TERM_STUCK：terminate 回成功但进程还在（10-20 测试机2）
    pf = os.path.join(R, 'app.pid')   # 只杀本假设备起的假 App：夹具里的 pid 是编的，别误杀本机同号进程
    try:
        if os.path.exists(pf) and open(pf).read().strip() == str(opt('--pid')): os.kill(int(opt('--pid')), signal.SIGTERM)
    except (OSError, ValueError, TypeError): pass
    sys.exit(0)
print('fake_devicectl: 未实现 ' + ' '.join(A), file=sys.stderr); sys.exit(2)
