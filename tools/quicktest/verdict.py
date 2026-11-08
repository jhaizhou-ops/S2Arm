#!/usr/bin/env python3
"""快测单局定性：verdict.py <局目录> [<补跑局目录>]
读 runtime/run_mac.sh 写出的局目录（host.log、frames.tsv、run.out、run.rc），打一行制表符分隔：
  结论  第一个失败点  首帧(是/否)  首帧毫秒  帧数  图形模式  直连异常  崩溃  红行前3  进局
归类顺序（维护方 10-26 普查 151 款定下的口径）：崩溃 → 游戏 Break → 游戏自己退出（nnMain 返回，10-30）→ 首帧 → 直连异常，都没有就是「通过」。
  直连异常 = host.log 有「【红】直连异常（不切换，继续跑）：」行（graphics/nvn/host_adapt.m；10-26 起运行中不切换、不再写 wire/<程序号>/fail）。
  崩溃按栈顶归类，别只写「崩溃」：GPU 模拟线程异常 / 客体代码（pc 落在 main / sdk / subsdkN / rtld）/ .NET GC 堆 / C# 未处理异常 / 其余取栈 #0 函数名。
  给了补跑局目录（第一局崩了才补跑）：两局都崩记「稳定崩溃」，只崩一次记「偶发崩溃」，栈顶取第一局。
  收局崩溃：崩溃信号 / 未处理异常出现在宿主收局标志（「收局阶段」或「服务层关停」行）之后 = 局已到点、宿主在关，崩溃列记「收局」，
  不算局内崩溃、不补跑，第一个失败点记「收局崩溃：<栈顶>」（10-29 普查：bb82b5511 起 HorizonHost.Stop 空引用，每局收局都崩，原先全记成稳定崩溃）。
  「通过」只表示零配置起得来、过了首帧、局内没崩；能不能玩到可操作场景看末列「进局」：自动玩家小结 ap_summary.json
  marked = 是、其余 = 否，没有小结（自动玩家没开）= -；
  小结是收局时才写盘的：收局前崩 / 被杀就没有小结，这时按 host.log 里 MARK 当场写下的行判（「S2A 标记 MARK：帧」= 是，
  有自动玩家输出但都没有 = 否；10-29 普查：HorizonHost.Stop 收局崩溃让小结全丢，进局一列全成「-」）。
  没到 MARK 且这局视觉测试员不可用（host.log「视觉测试员不可用」：机器上没有判官密钥）= 未判——自动玩家靠视觉模型导航，仪器不在不能记「否」
  （10-29 普查 Snow Bros. 在 Air：首帧有、0 崩，Air 缺 openrouter.key，原先记成没进局）。
点触卡页（掌机档没进局是否换主机档复跑，one_game.sh 用）：verdict.py --touch-stuck <局目录>
自测：verdict.py --selftest"""
import json, os, re, sys

CRASH = re.compile(r'收到信号|致命信号|SIGSEGV|SIGBUS|SIGABRT|signal [0-9]+|CRASH 信号')
GUEST_PC = re.compile(r'CRASH 信号 [0-9]* 地址 \S* pc ((?:main|sdk|subsdk[0-9]*|rtld)\+0x[0-9a-f]+)')
BREAK = re.compile(r'Break 原因 .* 位于 [a-z0-9]*\+0x[0-9a-f]+')
EXC = re.compile(r'EXCEPTION : ([^\n]+)')   # 游戏自己打的托管异常（C# / Unity / MonoGame 类引擎退出前）
RED = re.compile(r'^.*?(?:【红】|\[RED\])')


def read(p):
    try:
        with open(p, 'rb') as f:
            return f.read().decode('utf-8', 'replace')
    except OSError:
        return ''


def one(d):
    """单局读数：返回 dict（首帧 帧数 图形模式 直连异常 崩溃 红行 host）。"""
    h, out = read(os.path.join(d, 'host.log')), read(os.path.join(d, 'run.out'))
    r = {'host': h}
    m = re.search(r'图形模式：([^（\n]*)', h)
    r['mode'] = m.group(1).strip() if m else '-'
    r['anom'] = '是' if '【红】直连异常（不切换，继续跑）：' in h else '否'
    nf = max(read(os.path.join(d, 'frames.tsv')).count('\n') - 1, 0)
    r['nf'] = nf
    m = re.search(r'nnMain → 首帧上屏.*?\+([0-9.]+) ms', h)
    r['ff'] = '是' if (m or nf > 0) else '否'
    r['ffms'] = m.group(1) if m else '-'
    cr = '是' if (CRASH.search(h) or CRASH.search(out)) else '否'
    if cr == '否' and '收局 rc=0' not in out:
        m = re.search(r'收局 rc=([0-9]+)', out)
        if m:
            cr = 'rc=' + m.group(1)
    rc = read(os.path.join(d, 'run.rc')).strip()
    if cr == '否' and rc not in ('', '0'):
        cr = f'局rc={rc}'   # 局被杀 / 超时 / 构建失败：没有崩溃信号也不能记通过
    if cr != '否':   # 收局之后才崩：局内没崩
        shut = min((i for i in (h.find('收局阶段'), h.find('服务层关停')) if i >= 0), default=-1)
        hit = [i for i in (h.find('CRASH 信号'), h.find('Unhandled exception')) if i >= 0]
        if shut >= 0 and hit and min(hit) > shut: cr = '收局'
    # 超墙钟被杀（runtime/run_mac.sh「超墙钟 N 秒没收局」+ kill -9）且没有任何崩溃信号、出过帧：局已跑满时长、只是宿主收不了局，
    #   不算局内崩溃（11-02 一次成功线：御天之剑 HD 三局 1 局被墙钟杀，记成「偶发崩溃：局异常退出」误判）；崩溃列记「收局超时」
    if cr != '否' and not CRASH.search(h) and not CRASH.search(out) and re.search(r'超墙钟 \d+ 秒没收局', out) and nf > 0: cr = '收局超时'
    r['cr'] = cr
    reds = []
    for line in h.splitlines():
        if '【红】' in line or '[RED]' in line:
            s = RED.sub('', line, count=1)[:120]
            if s not in reds:
                reds.append(s)
    r['red'] = '  '.join(reds[:3]).replace('\t', ' ') or '-'
    s = read(os.path.join(d, 'ap_summary.json'))
    try:
        j = json.loads(s) if s else None
    except ValueError:
        j = None
    if j is None and '自动玩家' in h:   # 没有小结：按 MARK 当场写下的日志行
        j = {'marked': 'S2A 标记 MARK：帧' in h}
    r['mark'] = '-' if j is None else '是' if j.get('marked') else '未判' if '视觉测试员不可用' in h else '否'
    return r


def crash_kind(h):
    m = re.search(r'GPU 模拟线程异常退出：([A-Za-z.]*)', h)
    if m:
        return f'GPU模拟线程异常（{m.group(1)}）'
    m = GUEST_PC.search(h)
    if m:
        return f'客体代码（{m.group(1)}）'
    if 'CRASH 信号' not in h and not CRASH.search(h):
        return '局异常退出（无崩溃信号：超时 / 被杀 / 构建失败，看 run.out 末尾）'
    i = h.find('CRASH 信号')
    tail = '\n'.join(h[i:].splitlines()[:41]) if i >= 0 else ''
    if 'gc_heap' in tail:
        return 'NET GC 堆'
    if 'UnhandledException' in tail or 'FailFast' in tail:
        m = re.search(r'Unhandled exception\. ([A-Za-z.]*)', h)
        return f'C#未处理异常（{m.group(1) if m else ""}）'
    m = re.search(r'#0 ([^+（ \n]+)', tail)
    return m.group(1) if m else '未知'


def verdict(d, d2=None):
    a = one(d)
    fail, verd = '-', '通过'
    pre = '（首帧前）' if a['ff'] == '否' else ''
    brk = BREAK.search(a['host'])
    if a['cr'] not in ('否', '收局', '收局超时'):
        kind = '崩溃'
        if d2:
            kind = '稳定崩溃' if one(d2)['cr'] not in ('否', '收局', '收局超时') else '偶发崩溃'
        verd, fail = '失败', f'{kind}：{crash_kind(a["host"])}{pre}'
    elif brk:
        verd, fail = '失败', f'游戏Break{pre}：{brk.group(0)[len("Break "):]}'
    elif '收到 nnMain 返回' in a['host']:   # 游戏自己退出（10-30 原生层：忍者龟出首帧后 5 秒开场视频处 nnMain 返回、宿主优雅退出，没有红行，原先只看首帧判通过）
        ex = EXC.search(a['host'])
        verd, fail = '失败', f'游戏自己退出（nnMain 返回）{pre}' + (f'：{ex.group(1).strip()[:80]}' if ex else '')
    elif a['ff'] == '否':
        verd, fail = '失败', '首帧'
    elif a['anom'] == '是':
        verd, fail = '失败', '直连异常'
    if verd == '通过' and a['cr'] == '收局':
        fail = f'收局崩溃：{crash_kind(a["host"])}'
    if verd == '通过' and a['cr'] == '收局超时':
        fail = '收局超时：超墙钟没收局（无崩溃信号，局已跑满时长）'
    return [verd, fail, a['ff'], a['ffms'], str(a['nf']), a['mode'], a['anom'], a['cr'], a['red'], a['mark']]


TOUCH_FAIL = re.compile(r'自动玩家结论：[^\n]*点触没反应 (\d+) 次')
TOUCH_TEXT = re.compile(r'[「“"『][^」”"』]{0,40}(?:点触|點觸|触摸|觸控|タッチ|[Tt]ouch|[Tt]ap)')


def touch_stuck(d):
    """点触卡页（10-30 总指挥 S 级 ①：掌机档没进局时是否该换主机档再跑一局）：
    自动玩家结论行「点触没反应 N 次」N ≥ 2，或视觉测试员答过点触、理由里引了屏上要点触的原文（「请点触」“Touch the screen” 这类带引号的字样）。
    返回原因串，不是点触卡页返回空串"""
    h = read(os.path.join(d, 'host.log'))
    m = TOUCH_FAIL.search(h)
    if m and int(m.group(1)) >= 2: return f'点触没反应 {m.group(1)} 次'
    vd = os.path.join(d, 'vision')
    for n in sorted(os.listdir(vd)) if os.path.isdir(vd) else []:
        if not n.endswith('.json'): continue
        try: a = json.loads(read(os.path.join(vd, n)) or '{}')
        except ValueError: continue
        if any(str(k).startswith('TOUCH') for k in a.get('keys') or []) and TOUCH_TEXT.search(str(a.get('why', ''))):
            return f'屏上要点触（vision/{n}）'
    return ''


def selftest():
    import tempfile
    def mk(host='', out='收局 rc=0\n', frames=0, rc=None, summary=None):
        d = tempfile.mkdtemp()
        if summary is not None:
            open(os.path.join(d, 'ap_summary.json'), 'w').write(summary)
        if rc is not None:
            open(os.path.join(d, 'run.rc'), 'w').write(rc)
        open(os.path.join(d, 'host.log'), 'w').write(host)
        open(os.path.join(d, 'run.out'), 'w').write(out)
        if frames:
            open(os.path.join(d, 'frames.tsv'), 'w').write('帧\n' + '1\n' * frames)
        return d
    ok = '图形模式：通用（缺省）\n[t] nnMain → 首帧上屏 +812.5 ms\n'
    cases = [
        (mk(ok, frames=50), None, ['通过', '-', '是', '812.5', '50', '通用']),
        (mk('CRASH 信号 11 地址 0x0 pc main+0x20cb4c\n'), mk('CRASH 信号 11 地址 0x0 pc main+0x20cb4c\n'), ['失败', '稳定崩溃：客体代码（main+0x20cb4c）（首帧前）']),
        (mk('CRASH 信号 6 地址 0x0 pc 0x1\n#0 abort+12\n'), mk(ok, frames=5), ['失败', '偶发崩溃：abort（首帧前）']),
        (mk(ok + 'Break 原因 0 载荷 0x7 位于 main+0x1234\n', frames=3), None, ['失败', '游戏Break：原因 0 载荷 0x7 位于 main+0x1234']),
        (mk('图形模式：通用\n【红】NVN 缺函数 X\n【红】NVN 缺函数 X\n'), None, ['失败', '首帧']),
        (mk(ok + '[s2a] 【红】直连异常（不切换，继续跑）：GPU 命令缓冲报错：x\n', frames=9), None, ['失败', '直连异常']),
        (mk(ok, out='收局 rc=3\n', frames=9), None, ['失败', '崩溃：局异常退出（无崩溃信号：超时 / 被杀 / 构建失败，看 run.out 末尾）']),
        # 超墙钟被杀、无崩溃信号、出过帧 → 局内没崩、通过并标收局超时（11-02 御天之剑 HD）；没出过帧照旧算异常退出
        (mk(ok, out='Killed: 9\n🔴 t：超墙钟 630 秒没收局\n', frames=9, rc='1'), None, ['通过', '收局超时：超墙钟没收局（无崩溃信号，局已跑满时长）', '是', '812.5', '9', '通用', '否', '收局超时']),
        (mk(ok, out='Terminated: 15\n', frames=9, rc='143'), None, ['失败', '崩溃：局异常退出（无崩溃信号：超时 / 被杀 / 构建失败，看 run.out 末尾）', '是', '812.5', '9', '通用', '否', '局rc=143']),
        # 收局崩溃（10-29 普查 HorizonHost.Stop 空引用）：收局标志之后才崩 → 局内没崩、通过；收局标志之前崩照旧算崩溃
        (mk(ok + '[s2a] 收局阶段 取消服务等待：累计 1 ms\nS2A 服务层关停：到时（S2A_RUN_S）\nUnhandled exception. System.NullReferenceException: x\n'
            '[s2a] 【红】CRASH 信号 6 地址 0x0 pc __pthread_kill+0x8（宿主）\n#0 __pthread_kill+8\n#9 S2A_Runtime_UnhandledException+0x40\n', out='收局 rc=134\n', frames=9),
         None, ['通过', '收局崩溃：C#未处理异常（System.NullReferenceException）', '是', '812.5', '9', '通用', '否', '收局']),
        (mk(ok + 'CRASH 信号 11 地址 0x0 pc main+0x10\n[s2a] 收局阶段 取消服务等待：累计 1 ms\n', out='收局 rc=139\n', frames=9),
         None, ['失败', '崩溃：客体代码（main+0x10）']),
        # 游戏自己退出（10-30 忍者龟）：出过首帧、没有崩溃红行，nnMain 返回 → 失败并带上游戏打的异常
        (mk(ok + '[s2a] 收到 nnMain 返回：优雅退出\nEXCEPTION : InvalidOperationException - Cannot call Present when a render target is active.\n', frames=224), None,
         ['失败', '游戏自己退出（nnMain 返回）：InvalidOperationException - Cannot call Present when a render target is active.']),
    ]
    marks = [(mk(ok, frames=9, summary='{"marked": true, "mark_frame": 4842}'), '是'),
             (mk(ok, frames=9, summary='{"marked": false}'), '否'), (mk(ok, frames=9), '-'),
             (mk(ok + '自动玩家：视觉测试员不可用（没有 x/openrouter.key）\n', frames=9, summary='{"marked": false}'), '未判'),
             (mk(ok + '自动玩家：视觉测试员不可用（没有 x/openrouter.key）\n', frames=9, summary='{"marked": true}'), '是'),
             (mk(ok + 'S2A 标记 MARK：帧 900\n自动玩家：导航 → 局内段（依据：模型说可操控 + 读数到场景量级）\n', frames=9), '是'),   # 没小结：按当场日志
             (mk(ok + '自动玩家：导航 → 按 A（第 112 下）\n', frames=9), '否')]
    bad = 0
    for d, want in marks:
        got = verdict(d)[9]
        if got != want:
            bad += 1
            print(f'🔴 进局 期望 {want} → 真结果 {got}')
    for d, d2, want in cases:
        got = verdict(d, d2)
        if got[:len(want)] != want:
            bad += 1
            print(f'🔴 期望 {want} → 真结果 {got[:len(want)]}')
    red = verdict(cases[4][0])[8]
    if red != 'NVN 缺函数 X':
        bad += 1
        print(f'🔴 红行去重 期望「NVN 缺函数 X」→ 真结果「{red}」')
    print(f'verdict 自测：{len(cases) + len(marks) + 1} 例，红 {bad}')
    return 1 if bad else 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        sys.exit(selftest())
    if len(sys.argv) == 3 and sys.argv[1] == '--touch-stuck':   # 点触卡页：打原因、退出 0；不是退出 1
        why = touch_stuck(sys.argv[2]); why and print(why); sys.exit(0 if why else 1)
    if len(sys.argv) not in (2, 3):
        print(__doc__.strip().splitlines()[0]); sys.exit(2)
    print('\t'.join(verdict(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else None)))
