#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""停住现场自动归类（K01 / #194）：读 host.log 里的「[现场]」块，按规则表归因，给出建议归属。

用法：
  python3 tools/stall_classify.py <host.log> [--json <out.json>] [--md <out.md>] [--rules <stall_rules.tsv>]
  python3 tools/stall_classify.py <host.log>          # Markdown 写 stdout

规则（不是 AI）放在 tools/stall_rules.tsv：加一类新停住 = 加几行数据，本文件不用改。

三类判据（与规则表的 slot 列对应）：
  thread_stack  某线程调用栈里的符号（现场块内 pc / lr / #N 三类帧）
  dump_why      现场块开头的触发原因（「===== 全线程现场：<原因>（N 条线程…）」）
  log_line      该站点前后的日志行（低区账 / 托管 OOM / 声音没开播这类没有栈证据的停住）

判据层级（stack_first）：先看栈类。同一份现场里 GPU 模拟线程的栈可能完全相同（①着色器实化互等
与 ②管线作业等待就是这样），区别只在渲染线程栈上；栈类一条都不中，才看 dump_why / log_line。
未命中任何规则 = 「未知」，不硬套成已知类。
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

UNKNOWN = '未知'

# ---- 行格式（出处都写在注释里，改格式先改源码再改这里）-------------------

# runtime/src/tdump.c 的 out()：每条现场行都带「[现场] 」前缀；真机 host.log 前面还有时间戳与进程名，所以在行内找。
DUMP_PREFIX = re.compile(r'\[现场\] ?(.*)$')

# 「===== 全线程现场：<原因>（N 条线程，另写 <路径>）=====」
DUMP_HEAD = re.compile(r'=====\s*全线程现场：(?P<why>.*?)（(?P<n>\d+)\s*条线程')
DUMP_END = '现场完'

# 「线程 44/119 tid 741943「S2A.GPU」等待 优先级 47 QoS UI 用户态 5.89 s」
# 注意：tdump.c 里是 「tid %llu「%s」」——tid 与「之间没有空格；没名字时打「无名」。状态可能是「?」。
DUMP_THREAD = re.compile(
    r'线程\s+(?P<idx>\d+)/(?P<n>\d+)\s+tid\s+(?P<tid>\d+)\s*「(?P<name>[^」]*)」\s*'
    r'(?P<state>在跑|等待|停|不可中断等待|终止|\?)\s+优先级\s+(?P<pri>-?\d+)\s+QoS\s+(?P<qos>\S+)\s+用户态\s+(?P<user>[\d.]+)\s*s'
)

# 「pc RhSpinWait+0x28（S2Arm）」/「lr <redacted>+0x1c（libdispatch.dylib）」/「#3 gal_pso_job_wait+0x20（S2Arm）」
# 也有「lr 0」（无符号）：只取符号，不去猜。
DUMP_FRAME_KIND = re.compile(r'^(?P<kind>pc|lr|#(?P<idx>\d+))\s+(?P<sym>\S+?)(?:\+0x[0-9a-fA-F]+)?\s*(?:（(?P<mod>[^）]*)）)?\s*$')

# 寄存器行：「x0  …」（取证全寄存器）与「x-2 → 模块+偏移  [word word]」（归属并读指向字）——解析时跳过
DUMP_REGS = re.compile(r'^x-?\d+(\s|→)')


def _trigger_patterns():
    """哪个看门打的现场（5 个调用点，出处见每行注释）。返回 [(名字, 正则, 原因模板), …]。"""
    return (
        # runtime/src/ap_host.c：出图停住看门
        ('出图停住看门',
         re.compile(r'出图停住看门：上屏帧数停在\s+(?P<frame>\d+)\s+已\s+(?P<sec>\d+)\s+秒'),
         '出图停住看门：停在第 {frame} 帧已 {sec} 秒'),
        # tests/autoplay/autoplay.c：自动玩家停图先打现场
        ('自动玩家停图',
         re.compile(r'自动玩家：出图停在第\s+(?P<frame>\d+)\s+帧已\s+(?P<sec>\d+)\s+秒（阶段：(?P<stage>[^）]*)），先打现场'),
         '自动玩家：出图停在第 {frame} 帧已 {sec} 秒（阶段：{stage}）'),
        # tests/autoplay/autoplay.c：自动玩家没进可玩
        ('自动玩家未进可玩',
         re.compile(r'自动玩家：线程表（(?P<why>[^）]*)）'), '{why}'),
        # runtime/src/energy.c：游戏线程满核空转（满核空转现场）
        ('满核空转看门',
         re.compile(r'游戏线程满核空转：(?P<name>[^（]*?)（线程号\s+(?P<tid>\d+)）连续\s+≥\s*(?P<sec>\d+)\s+秒占\s+(?P<cores>[\d.]+)\s+核'),
         '游戏线程满核空转：{name} 占 {cores} 核（线程号 {tid}，连续 ≥ {sec} 秒）'),
        # graphics/metal/gal_core.m：GPU 栅栏卡死主动退出（退出码 86）
        ('GPU 栅栏卡死',
         re.compile(r'【红】GPU 卡死：等栅栏\s+(?P<want>\d+)\s+超过\s+(?P<sec>\d+)\s+秒'),
         'GPU 卡死：等栅栏 {want} 超过 {sec} 秒'),
    )


TRIGGERS = _trigger_patterns()

# 原因文本里的帧号：「第 N 帧」「停在 N 帧」「帧 N」「停在 N 已」
WHY_FRAME = (
    re.compile(r'第\s*(\d+)\s*帧'),
    re.compile(r'停在\s*(\d+)\s*帧'),
    re.compile(r'上屏帧数停在\s*(\d+)'),
    re.compile(r'停在\s*(\d+)\s*已'),
    re.compile(r'帧\s+(\d+)'),
)

# 有这几行但没有 [现场] 块也算一次停住（声音那份：输出 #N 10 秒回调 0 次）。
# 出处：compat/patches/0143-audio-true-gap.patch 的 S2AOutputDiag 读数行。
SOUND_STALL = re.compile(r'\[声\]\s*输出\s*#\d+\s*(?:10|1\d|\d+)\s*秒：回调\s+(?P<cb>\d+)\s*次')

# 能耗行里的「nx-<名> <瓦数> W（<核数> 核，…）」：④的第二个条件（同时段某 nx-* 游戏线程 ≥0.95 核）从这里取。
# 出处：runtime/src/energy.c 的「耗能前 %d 线程：」段。
ENERGY_THREAD = re.compile(r'(?P<name>nx-[\w.-]+)\s+[\d.]+\s*W（(?P<cores>[\d.]+)\s*核')
ENERGY_LINE = re.compile(r'\[能耗\]\s*近\s*[\d.]+\s*秒')

# 站点向前配日志行不设固定行数：一直看到**上一个站点之后**（第一个站点从文件头算）。
# 真实日志里「低区账 [托管 OOM]」与崩溃现场块之间隔着约 510 行退场取证（低区全列、窗口尾部逐块等），
# 固定 120 行窗口够不着证据，11 份低区耗尽崩溃全被判成「未知」——这是用 42 份完整 host.log 验收暴露的。
# 向后只看到下一个站点之前，再限 CONTEXT_AFTER 行。
CONTEXT_AFTER = 200

# 声音读数行之后多少行内还算「同时段」：能耗行是 10 秒一次的周期行，读数行与它之间隔着几十行属正常。
HOT_SCAN_LINES = 400

# 满核判定阈值：与 runtime/src/energy.c 的 s2a_spin_step 一致（0.95 核）
SPIN_CORES = 0.95

# ④ 声音只满足一半判据时的降级类（见 _downgrade_audio）
SUSPECT_AUDIO = '声音（疑似）'


# ---- 数据结构 -----------------------------------------------------------

@dataclass
class StackFrame:
    kind: str      # 'pc' | 'lr' | '#' + 序号
    sym: str
    module: str = ''

    @property
    def depth(self):
        if self.kind.startswith('#'):
            try:
                return int(self.kind[1:])
            except ValueError:
                return -1
        return -1


@dataclass
class Thread:
    idx: int
    tid: int
    name: str
    state: str
    priority: int
    qos: str
    user_s: float
    frames: list = field(default_factory=list)
    is_crasher: bool = False        # 行尾带「（本线程，发起现场）」：崩溃时就是发信号那条

    @property
    def symbols(self):
        return [f.sym for f in self.frames]


@dataclass
class Site:
    """一次停住：一个触发行 + 它的 [现场] 块 + 前后日志行。"""
    index: int
    line_no: int
    why: str = ''
    trigger: str = ''
    frame_hint: int = None
    has_dump: bool = False
    n_declared: int = 0                 # 开头行声明的线程数
    closed: bool = False                # 见到「现场完」收尾行
    block_line: int = 0                 # [现场] 块开头所在行（和触发行可能不是同一行）
    hot_thread: str = ''                # ④ 的第二个条件：同时段某 nx-* 线程 ≥0.95 核（空 = 没证据）
    threads: list = field(default_factory=list)
    context: list = field(default_factory=list)   # 站点附近的非 [现场] 行
    interleaved: list = field(default_factory=list)   # 现场块内部穿插的普通日志行（不结束块，见 parse_log）
    gap: bool = False                   # 块里连续出现普通行：剩余现场被摘掉了，普通行不再算块内容

    @property
    def truncated(self):
        """现场块没有收尾行，且声明线程多于解析到的：这份现场是摘录或被截断（不报错，只提示）。"""
        return self.has_dump and not self.closed


@dataclass
class Rule:
    kind: str
    owner: str
    slot: str
    thread: str          # thread_stack 时限定线程名：'*' 任何 / '.' 非渲染 / '@crasher' 发起现场那条 / 正则
    state: str           # 线程状态约束：'*' 不限；'在跑' / '!等待' / '在跑|等待'
    weight: int
    pattern: str
    note: str
    rx: re.Pattern = None
    thread_rx: re.Pattern = None
    state_ok: tuple = ()  # (允许的, 禁止的)


VALID_SLOTS = ('thread_stack', 'dump_why', 'log_line')
HEADER = ['kind', 'owner', 'slot', 'thread', 'state', 'weight', 'pattern', 'note']

# 崩溃发起点：tdump.c 给发起现场的那条线程行尾加「（本线程，发起现场）」
CRASHER_MARK = '发起现场'
# Metal 驱动自己中止的特征：优先比**模块列**（真实栈里驱动帧常是 `<redacted>+0xd0（AGXMetalG18P）`，
# 符号被抹掉只剩模块名），同时比符号，两者任一命中即可（与审核方给的
# AGX::DataBufferAllocator::grow / IOGPUMetalResourcePoolCreatePooledResource / pso_desc 例子一致）。
GPU_DRIVER_SYMS = re.compile(r'IOGPU|AGXMetal|AGX::|AGX_|Metal\b|Metal\)', re.I)
GPU_DRIVER_KIND = 'GPU 驱动中止'
ABORT_SYMS = re.compile(r'abort|__pthread_kill|pthread_kill')
# 块头原因里带「崩溃」「信号 6」= 崩溃现场（crash.c 直接打的现场没有触发行）
CRASH_WHY = re.compile(r'崩溃|信号\s*\d+')

# 渲染线程：判据分层的第一层（见 stall_rules.tsv 开头说明）
RENDER_THREAD = re.compile(r'S2A\.GPU(?!\.)')


# ---- 规则表 -------------------------------------------------------------

def _parse_state(state, where):
    """state 列 → (允许的集合, 禁止的集合)。`*` = 不限；`!等待` = 不能是等待；`在跑|等待` = 两者之一。"""
    state = (state or '*').strip()
    if state == '*' or state == '':
        return (), ()
    allow, deny = set(), set()
    for part in state.split('|'):
        part = part.strip()
        if not part:
            continue
        if part.startswith('!'):
            deny.add(part[1:])
        else:
            allow.add(part)
    if allow and deny:
        raise SystemExit(f'{where} state 不能同时写允许和禁止：{state!r}')
    return tuple(allow), tuple(deny)


def _state_ok(rule, thread):
    allow, deny = rule.state_ok
    if not allow and not deny:
        return True
    if allow and thread.state not in allow:
        return False
    if deny and thread.state in deny:
        return False
    return True


def load_rules(path):
    """读规则表；格式错直接报红——悄悄跳一行规则，归类就是错的。"""
    rules, order, owners = [], [], {}
    p = Path(path)
    if not p.is_file():
        raise SystemExit(f'规则表不存在：{p}')
    with p.open(encoding='utf-8') as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            cols = line.split('\t')
            if len(cols) != len(HEADER):
                raise SystemExit(f'{p}:{n} 列数应为 {len(HEADER)}（{" ".join(HEADER)}），实际 {len(cols)}：{line!r}')
            if [c.strip() for c in cols] == HEADER:
                continue    # 表头（照抄在文件里给人看用）
            kind, owner, slot, thread, state, weight, pattern, note = (c.strip() for c in cols)
            if slot not in VALID_SLOTS:
                raise SystemExit(f'{p}:{n} slot 认不得：{slot!r}（可用：{" / ".join(VALID_SLOTS)}）')
            try:
                w = int(weight)
            except ValueError:
                raise SystemExit(f'{p}:{n} weight 不是整数：{weight!r}')
            try:
                rx = re.compile(pattern)
            except re.error as e:
                raise SystemExit(f'{p}:{n} 正则编译不过（{e}）：{pattern!r}')
            thread_rx = None
            if slot == 'thread_stack' and thread not in ('*', '.', '@crasher'):
                try:
                    thread_rx = re.compile(thread)
                except re.error as e:
                    raise SystemExit(f'{p}:{n} thread 正则编译不过（{e}）：{thread!r}')
            if slot == 'thread_stack' and thread == '@crasher' and not pattern.count('abort') and kind != 'GPU 驱动中止':
                pass    # @crasher 只用于崩溃发起点，不强制限定模式
            allow, deny = _parse_state(state, f'{p}:{n}')
            if kind not in owners:
                order.append(kind)
                owners[kind] = owner
            elif owners[kind] != owner:
                raise SystemExit(f'{p}:{n} 同一 kind「{kind}」的归属不一致：{owners[kind]!r} vs {owner!r}')
            rules.append(Rule(kind, owner, slot, thread, state, w, pattern, note, rx, thread_rx, (allow, deny)))
    if not rules:
        raise SystemExit(f'规则表是空的：{p}')
    # 「声音（疑似）」是 classify 按 ④ 的两条判据降级出来的（见 _downgrade_audio），不是规则表里的一行；
    # 归属沿用「声音」那一类，报告里不出现空归属。
    owners.setdefault(SUSPECT_AUDIO, owners.get('声音', ''))
    return rules, order, owners


# ---- 解析 ---------------------------------------------------------------

def _trigger_of(line):
    """这一行是不是现场触发行？返回 (来源, 原因文本, 帧号) 或 None。"""
    for name, rx, tmpl in TRIGGERS:
        m = rx.search(line)
        if not m:
            continue
        try:
            why = tmpl.format(**m.groupdict())
        except (KeyError, IndexError):
            why = m.group(0)
        return name, why, _frame_of(why)
    return None


# 没有触发行时，按块头原因的关键词反推是哪个看门打的现场（tdump.c 的 why 文案由调用方给）
WHY_TO_TRIGGER = (
    ('出图停住看门', re.compile(r'出图停住看门|上屏帧数停在')),
    ('自动玩家停图', re.compile(r'自动玩家')),
    ('满核空转看门', re.compile(r'满核空转')),
    ('GPU 栅栏卡死', re.compile(r'GPU 卡死')),
    ('崩溃', re.compile(r'崩溃')),
)


def _trigger_from_why(why):
    for name, rx in WHY_TO_TRIGGER:
        if why and rx.search(why):
            return name
    return ''


def _frame_of(text):
    for rx in WHY_FRAME:
        m = rx.search(text)
        if m:
            try:
                return int(m.group(1))
            except ValueError:
                continue
    return None


def _parse_thread(payload):
    m = DUMP_THREAD.search(payload)
    if not m:
        return None
    try:
        user_s = float(m.group('user'))
    except ValueError:
        user_s = 0.0
    try:
        pri = int(m.group('pri'))
    except ValueError:
        pri = -1
    return Thread(idx=int(m.group('idx')), tid=int(m.group('tid')), name=m.group('name') or '',
                  state=m.group('state'), priority=pri, qos=m.group('qos'), user_s=user_s,
                  is_crasher='发起现场' in payload)


def _parse_stack(payload):
    body = payload.strip()
    if not body or DUMP_REGS.match(body):
        return None
    m = DUMP_FRAME_KIND.match(body)
    if not m:
        return None
    return StackFrame(kind=m.group('kind'), sym=m.group('sym'), module=_module_of(body, m))


def _module_of(body, m):
    """栈帧的模块列（tdump.c 里符号后面的括号：「#3 <redacted>+0xd0（AGXMetalG18P）」）。

    真实日志里驱动帧的符号常被抹成 `<redacted>`，只剩括号里的模块名（IOGPUMetal*、
    AGXMetalG18P、Metal …）。所以模块必须单独解析出来：GPU 驱动中止判据同时比符号和模块，
    只比符号会漏（42 份完整日志里的 mhrise 中止就是这么漏的）。
    """
    if m.group('mod'):
        return m.group('mod').strip()
    # 正则的括号段没吃上（符号里有空格等少见形态）：退回取行尾最后一个全角括号。
    mt = re.search(r'（([^）]*)）\s*$', body)
    return mt.group(1).strip() if mt else ''


def parse_log(path):
    """把 host.log 切成若干次停住。返回 (sites, warnings, stats)。"""
    p = Path(path)
    if not p.is_file():
        raise SystemExit(f'host.log 不存在：{p}')

    sites = []
    warnings = []
    stats = {'lines': 0, 'dump_blocks': 0, 'reg_lines': 0}

    pending = None        # 已看到触发行、还没等到 [现场] 块：(来源, 原因, 帧号, 行号)
    since_trigger = 0     # 触发行之后扫过多少行
    cur = None            # 当前 [现场] 块
    cur_th = None
    in_dump = False
    last_site = None
    last_sound_site = None
    hot_scan_until = 0    # 到哪一行为止还在给 last_sound_site 找「某 nx-* ≥0.95 核」证据
    prev_plain = False    # 上一行是不是普通日志行（用于判断现场块里连续出现普通行 = 剩余现场被摘掉）

    def close_thread():
        nonlocal cur_th
        if cur is not None and isinstance(cur_th, Thread):
            cur.threads.append(cur_th)
        cur_th = None

    def close_dump(closed):
        nonlocal cur, in_dump, last_site
        close_thread()
        if cur is not None:
            cur.closed = closed
            last_site = cur
            # 不给打开还没有 [现场] 块的触发行配现场了：站点照旧留着（只有触发行）。
            # 真实日志里触发行与它那段现场块之间可能隔着几百行别的线程读数（04 声音那份就是），
            # 不切断的话现场块会被并进一个不相干的站点。
            drop_pending()
            on_site(cur)
        cur = None
        in_dump = False

    def make_site(src, why, frame, ln, has_dump=False):
        s = Site(index=len(sites) + 1, line_no=ln, why=why, trigger=src, frame_hint=frame, has_dump=has_dump)
        sites.append(s)
        on_site(s)
        return s

    def on_site(s):
        """新站点出现：给上一条声音读数找「某 nx-* ≥0.95 核」的窗口到此为止。"""
        nonlocal last_sound_site, hot_scan_until
        hot_scan_until = 0
        if s.trigger != '声音输出读数':
            last_sound_site = None

    def drop_pending():
        nonlocal pending
        pending = None

    def flush_pending():
        """触发行一直没等到 [现场] 块：造一个只有触发行、没有现场块的站点。"""
        nonlocal pending
        if pending is not None:
            src, why, frame, ln = pending
            make_site(src, why, frame, ln, has_dump=False)
            pending = None

    with p.open(encoding='utf-8', errors='replace') as fh:
        for ln, raw in enumerate(fh, 1):
            stats['lines'] += 1
            line = raw.rstrip('\n')
            prev_was_plain = prev_plain

            # 「现在还在一个没结束的 [现场] 块里吗」。块里穿插的普通行（声音读数行、能耗行、红行）
            # 也算块内容：这类行不能另起一个站点，否则真实日志里会凭空多出几个假停住。
            #
            # 但穿插的普通行**不是** [现场] 行——块内的取证行按 tdump.c 都带「[现场] 」前缀。
            # 所以一旦在块里读到普通行、紧接着又是一条普通行，说明块的剩余部分被摘掉了
            # （真实日志里 dump 期间别的线程照常打日志，且现场可能只写了一半）。这种情况下
            # 普通行不再算块内容，按普通日志行处理；块本身仍然开着，等到下一个块头 / 现场完 / 文件尾。
            in_block = (in_dump and cur is not None and cur.has_dump
                        and not cur.closed and not cur.gap)

            dm = DUMP_PREFIX.search(line)
            prev_plain = dm is None
            if dm:
                payload = dm.group(1)

                if DUMP_HEAD.search(payload):
                    # 上一块没收尾就开了新的：容错
                    if in_dump:
                        close_dump(False)
                    head = DUMP_HEAD.search(payload)
                    try:
                        n_dec = int(head.group('n'))
                    except ValueError:
                        n_dec = 0
                    why = head.group('why').strip()
                    if pending is not None:
                        # 触发行之后紧跟 [现场] 块：并入同一个站点（一次停住 = 触发行 + 现场块），
                        # 不要拆成「没有现场块」和「有现场块」两个站点。
                        src, p_why, p_frame, p_ln = pending
                        cur = make_site(src, why or p_why, p_frame if p_frame is not None else _frame_of(why),
                                        p_ln, has_dump=True)
                        if not cur.why:
                            cur.why = p_why
                        pending = None
                    else:
                        # 没有触发行（如崩溃现场由 crash.c 直接打）：块头的原因就是触发原因。
                        # 块头原因文案和触发行不同，这里按关键词反推是哪个看门打的。
                        cur = make_site(_trigger_from_why(why), why, _frame_of(why), ln, has_dump=True)
                    cur.n_declared = n_dec
                    cur.block_line = ln
                    since_trigger = 0
                    in_dump = True
                    cur_th = None
                    stats['dump_blocks'] += 1
                    continue

                if DUMP_END in payload:
                    # 「现场完」只认作块尾：普通日志行里也可能出现这两个字（如「渲染丢周期 0」不会，
                    # 但「…完…」会），所以只有块内的「现场完」才算收尾。
                    if in_dump:
                        close_dump(True)
                    continue

                if in_dump and cur is not None:
                    if DUMP_REGS.match(payload.strip()):
                        stats['reg_lines'] += 1
                        continue
                    th = _parse_thread(payload)
                    if th is not None:
                        close_thread()
                        cur_th = th
                        continue
                    fr = _parse_stack(payload)
                    if fr is not None:
                        if isinstance(cur_th, Thread):
                            cur_th.frames.append(fr)
                        continue
                    # 现场块里既不是线程行、也不是栈帧、也不是寄存器行：格式变了或新加了取证行。
                    # 不猜内容，但记下来——悄悄丢掉会让栈证据少一段，归类就可能错。
                    stats['unknown_lines'] = stats.get('unknown_lines', 0) + 1
                    if stats['unknown_lines'] <= 5:
                        warnings.append(f'第 {ln} 行：现场块里的行认不得（既不是线程行、栈帧，也不是寄存器行）：'
                                        f'{payload.strip()[:120]}')
                    continue
                # [现场] 前缀但不是块内容：当普通行处理（落到下面）

            if in_dump and cur is not None:
                # 现场块里穿插了一条**没有 [现场] 前缀**的普通日志行：dump 期间别的线程照常打日志。
                # 真实日志里这一行（如「[gal] 【红】上传租约…」）紧跟块头，早先版本在这里 stop 收尾，
                # 108 条线程一条都没读进来，42 份里有 8 份中招。现在：照常当普通日志行收进上下文，
                # 但**不结束块**——块只在「现场完」、下一个「全线程现场」块头、或文件结尾处结束。
                stats['interleaved_lines'] = stats.get('interleaved_lines', 0) + 1
                cur.interleaved.append(line)
                if prev_was_plain:
                    cur.gap = True
                if len(cur.interleaved) <= 3:
                    warnings.append(f'第 {ln} 行：现场块里穿插了普通日志行（照常收进上下文，不结束块）：'
                                    f'{line.strip()[:120]}')

            trig = _trigger_of(line)
            if trig is not None:
                flush_pending()
                src, why, frame = trig
                pending = (src, why, frame, ln)
                since_trigger = 0
                continue

            if pending is not None:
                since_trigger += 1
                if since_trigger > CONTEXT_AFTER:
                    flush_pending()
            # 声音读数（回调 0 次）且整份日志没有对应的现场：也算一次停住。
            # 同一段里连打多行读数只记第一次，避免一次停住被数成好几次。
            sm = SOUND_STALL.search(line)
            if sm is not None and sm.group('cb') == '0' and not in_block:
                if last_sound_site is None or ln - last_sound_site.line_no > CONTEXT_AFTER:
                    last_sound_site = make_site('声音输出读数', f'声音输出：{line.strip()[:160]}', None, ln)
                    # ④ 的第二条判据（同时段某 nx-* 线程 ≥0.95 核）来自读数行之后的能耗行，
                    # 别把 pending 清扫得太早——从这条读数重新起算。
                    hot_scan_until = ln + HOT_SCAN_LINES

            # ④ 的第二个条件：同时段某 nx-* 游戏线程 ≥0.95 核（`[能耗] … 耗能前 6 线程：nx-172 6.06 W（0.97 核…）`）。
            # issue 原文 ④ 的判据是「回调 0 次」+「同时段某 nx-* 线程 ≥0.95 核」两条；只满足第一条的归「声音（疑似）」。
            if last_sound_site is not None and ln <= hot_scan_until and ENERGY_LINE.search(line):
                for mt in ENERGY_THREAD.finditer(line):
                    try:
                        cores = float(mt.group('cores'))
                    except ValueError:
                        continue
                    if cores >= SPIN_CORES:
                        last_sound_site.hot_thread = f'{mt.group("name")} {cores:.2f} 核'
                        break

    if in_dump:
        close_dump(False)
    flush_pending()

    _attach_context(p, sites, warnings)
    return sites, warnings, stats


def _attach_context(path, sites, warnings):
    """给每个站点配「站点之前」的日志行（低区账 / OOM 异常这类证据可能在现场块前几百行）。

    下界 = 上一个站点之后（第一个站点从文件头算），不设固定行数——真实日志里低区账与崩溃现场块之间
    隔着约 510 行退场取证，固定 120 行窗口够不着，11 份低区耗尽崩溃全被判成「未知」。
    上界 = 下一个站点之前（向后最多 CONTEXT_AFTER 行，声音读数在触发行附近）。
    """
    if not sites:
        return
    spans = []
    for i, s in enumerate(sites):
        lo = (sites[i - 1].line_no + 1) if i else 1
        hi = min(s.line_no + CONTEXT_AFTER, sites[i + 1].line_no - 1) if i + 1 < len(sites) else s.line_no + CONTEXT_AFTER
        spans.append((max(1, lo), max(lo, hi)))
    with path.open(encoding='utf-8', errors='replace') as fh:
        cur_i = 0
        for ln, raw in enumerate(fh, 1):
            while cur_i < len(spans) and spans[cur_i][1] < ln:
                cur_i += 1
            if cur_i >= len(spans):
                break
            line = raw.rstrip('\n')
            # 现场块内穿插的普通日志行（parse_log 收进 site.interleaved 的那些）也要当上下文，
            # 否则「现场块里就夹着低区账 / 红行」的真实日志会把证据丢掉。
            for j in range(cur_i, len(spans)):
                lo, hi = spans[j]
                if lo > ln:
                    break
                if lo <= ln <= hi and not DUMP_PREFIX.search(line):
                    sites[j].context.append(line)
    for s in sites:
        s.context.extend(s.interleaved)


# ---- 归类 ---------------------------------------------------------------

def _thread_matches(rule, thread):
    """这条 thread_stack 规则是否在该线程上算数（名字 + 状态两条约束）。"""
    if not _state_ok(rule, thread):
        return False
    if rule.thread == '*':
        return True
    if rule.thread == '.':
        return not RENDER_THREAD.search(thread.name)
    if rule.thread == '@crasher':
        return thread.is_crasher
    return bool(rule.thread_rx and rule.thread_rx.search(thread.name))


def _stack_hits(site, rules, render_only):
    """在（渲染线程 / 非渲染线程）栈上找特征。返回命中列表。"""
    hits = []
    for t in site.threads:
        if not t.frames:
            continue
        is_render = bool(RENDER_THREAD.search(t.name))
        if render_only is not None and is_render != render_only:
            continue
        symbols = ' '.join(t.symbols)
        for r in rules:
            if r.slot != 'thread_stack' or not _thread_matches(r, t):
                continue
            if r.rx.search(symbols):
                hits.append({'kind': r.kind, 'slot': r.slot, 'pattern': r.pattern, 'note': r.note,
                             'weight': r.weight, 'thread': t.name, 'evidence': f'{t.name}（{t.state}）'})
    return hits


def _line_hits(site, rules):
    """dump_why / log_line 两层的命中。"""
    hits = []
    for slot in ('dump_why', 'log_line'):
        sub = [r for r in rules if r.slot == slot]
        if not sub:
            continue
        texts = [site.why] if slot == 'dump_why' else site.context
        for r in sub:
            for text in texts:
                if r.rx.search(text):
                    hits.append({'kind': r.kind, 'slot': slot, 'pattern': r.pattern, 'note': r.note,
                                 'weight': r.weight, 'thread': '', 'evidence': text.strip()[:200]})
                    break
    return hits


def _winner(hits, order):
    score = {}
    for h in hits:
        score[h['kind']] = score.get(h['kind'], 0) + h['weight']
    best = max(score.items(), key=lambda kv: (kv[1], -order.index(kv[0])))[0]
    top = [k for k, v in score.items() if v == score[best]]
    return best, top


def _is_crash_site(site):
    """这份现场是不是崩溃现场：**只看触发来源**（块头原因里的「崩溃 / 信号 N」反推出来的 `崩溃`）。

    不能看「有没有线程标了（本线程，发起现场）」——**停住看门现场里也有这一行**：
    触发抓现场的那条线程（xc3 里是 `ap_main`）同样带这个标记。拿它当崩溃判据的话，
    停住看门现场会全部走进「只看发起线程、其它线程不投票」那一层，着色器实化互等 / 管线作业等待
    会整批落进「未知」（42 份完整日志里约 20 个 xc3 站点就是这么错的）。
    """
    return site.trigger == '崩溃' or bool(CRASH_WHY.search(site.why or ''))


def _crasher_verdict(site, rules, order):
    """第 0 层：崩溃现场**只看发起现场的那条线程**，返回 (kind, hits, note)，不给别的线程投票。

    真实日志里的两个误判都出在「崩溃站点还按别的线程投票」：
      · acnh 我方断言 abort（pso_desc.cold.1）被常驻空闲的 AudioRendererManager.Worker 投成「声音」；
      · mhrise SIGSEGV 在 nxgal_prog_load_binary 被别的线程的实化栈投成「着色器实化互等」。
    """
    crasher = next((t for t in site.threads if t.is_crasher), None)
    if crasher is None or not crasher.frames:
        return None
    top3 = ' ← '.join(f.sym for f in sorted(crasher.frames, key=lambda f: f.depth)[:3]) or '（没有栈帧）'
    syms = ' '.join(crasher.symbols)
    mods = ' '.join(f.module for f in crasher.frames if f.module)

    # ① 自己的栈命中某类规则 → 归那类（只在这一条线程上投票）
    hits = []
    for r in rules:
        if r.slot != 'thread_stack' or not _thread_matches(r, crasher):
            continue
        if r.rx.search(syms):
            hits.append({'kind': r.kind, 'slot': r.slot, 'pattern': r.pattern, 'note': r.note,
                         'weight': r.weight, 'thread': crasher.name, 'evidence': f'{crasher.name}（{crasher.state}）'})
    if hits:
        best, top = _winner(hits, order)
        note = f'崩溃现场只按发起现场线程「{crasher.name}」判（栈顶前 3 帧：{top3}）'
        if len(top) > 1:
            note += f'；并列：{" / ".join(top)}（票数相同，按规则表顺序取 {best}）'
        return best, hits, note

    # ② Metal 驱动自己中止：栈顶 abort/pthread_kill + 帧的模块列（或符号）是 IOGPU / AGXMetal* / Metal
    if ABORT_SYMS.search(syms) and GPU_DRIVER_SYMS.search(f'{mods} {syms}'):
        hits = [{'kind': GPU_DRIVER_KIND, 'slot': 'thread_stack', 'pattern': 'abort + 模块 IOGPU|AGXMetal|Metal',
                 'note': '发起现场线程栈顶是 abort / pthread_kill，帧的模块列 / 符号里有 Metal 驱动',
                 'weight': 10, 'thread': crasher.name, 'evidence': f'{crasher.name}：{top3}'}]
        return GPU_DRIVER_KIND, hits, f'崩溃发起点：{crasher.name} 栈顶 abort，模块/符号是 Metal 驱动（{top3}）'

    # ③ 其余 → 未知，并写清发起现场线程名与栈顶前 3 帧（审核方要的就是这个）。
    #    栈顶是 abort / __pthread_kill 的，是**我方**自己的失败断言或别的线程发的信号：
    #    这时回到日志行找直接证据（低区账 / 红行），再不行留未知——不因为没认出调用点就放弃。
    return None, None, f'崩溃发起点：{crasher.name}（{crasher.state}）栈顶前 3 帧 {top3}；其它线程不投票'


def classify(site, rules, order):
    """给一次停住归类：返回 (kind, 命中列表, 备注)。

    分层（与 stall_rules.tsv 开头写的一致，用真实全量日志验收后确定的顺序）：

      0. 崩溃发起点：**只看发起现场的那条线程**（「（本线程，发起现场）」）。它的栈命中某类规则 → 归那类；
         栈顶 abort / __pthread_kill 且帧的模块列 / 符号是 IOGPU / AGXMetal* / Metal → GPU 驱动中止；
         其余 → 未知（备注写线程名 + 栈顶前 3 帧）。**崩溃站点不再按别的线程投票**。
      1. 低区账：站点前有「低区账 [托管 OOM]」「低区账 [崩溃时]」+ OutOfMemoryException —— 低区耗尽。
         这三行是直接证据，优先于任何线程栈投票（真实日志里被空闲后台 GC 线程抢成「内存回收」）。
      2. 渲染线程 S2A.GPU 的栈（主判据）。①与②的 GPU.Emu 栈完全相同，区别只在渲染线程上。
      3. 其它线程的栈（受 state 约束：服务线程只在「在跑」时算票，空闲 BGC / 空闲音频线程不算）。
      4. dump_why / log_line。
    """
    # 第 0 层：崩溃发起点（只看那一条线程）
    crash_note = ''
    if _is_crash_site(site):
        verdict = _crasher_verdict(site, rules, order)
        if isinstance(verdict, tuple):
            kind, hits, note = verdict
            if kind is not None:
                return kind, hits, note
            crash_note = note
        # 崩溃站点**不再按别的线程投票**（空闲音频线程会把我们自己的 abort 投成「声音」）。

    # 第 1 层：低区账优先（三行同时出现在站点上下文里才算直接证据）
    lines = _line_hits(site, rules)
    lowva = [h for h in lines if h['kind'] == '低区地址耗尽']
    has_oom_tag = any('托管 OOM' in h['evidence'] for h in lowva)
    has_oom_exc = any('OutOfMemoryException' in h['evidence'] for h in lowva)
    if has_oom_tag and has_oom_exc:
        note = '低区账 [托管 OOM] + OutOfMemoryException 同时出现，低区耗尽直接证据，优先于线程栈投票'
        return '低区地址耗尽', lowva, note

    if crash_note:
        # 崩溃站点的栈证据只有发起现场那条线程，且它栈顶的调用点没认出归属 →
        # 回日志行找直接证据（「现场完」之前打的那几行）。仍然不拿别的线程栈投票。
        logs = [h for h in lines if h['slot'] == 'log_line']
        if logs:
            best, top = _winner(logs, order)
            note = f'{crash_note}；发起线程栈没认出归属，按站点前的日志行判（{best}）'
            if len(top) > 1:
                note += f'；并列：{" / ".join(top)}（票数相同，按规则表顺序取 {best}）'
            return best, logs, note
        return UNKNOWN, [], crash_note

    # 第 2 层：渲染线程栈
    render = _stack_hits(site, rules, render_only=True)
    if render:
        best, top = _winner(render, order)
        hits = render + _stack_hits(site, rules, render_only=False) + lines
        note = ''
        if len(top) > 1:
            note = f'渲染线程栈并列：{" / ".join(top)}（票数相同，按规则表顺序取 {best}）'
        return best, hits, note

    # 第 3 层：其它线程栈
    other = _stack_hits(site, rules, render_only=False)
    if other:
        best, top = _winner(other, order)
        hits = other + lines
        note = f'渲染线程栈没有命中，按其它线程栈判（{best}）'
        if len(top) > 1:
            note += f'；并列：{" / ".join(top)}（票数相同，按规则表顺序取 {best}）'
        return best, hits, note

    # 第 4 层：日志行
    if lines:
        best, top = _winner(lines, order)
        note = '没有栈证据，按 ' + ' / '.join(sorted({h['slot'] for h in lines})) + ' 判'
        if len(top) > 1:
            note += f'；并列：{" / ".join(top)}（票数相同，按规则表顺序取 {best}）'
        best, note = _downgrade_audio(site, best, note)
        return best, lines, note

    return UNKNOWN, [], '没有任何规则命中'


def _downgrade_audio(site, kind, note):
    """④ 声音的判据是两条：回调 0 次 + 同时段某 nx-* 线程 ≥0.95 核（issue 原文）。
    只满足第一条、拿不到第二条证据的，降为「声音（疑似）」，并在备注里写清缺哪条——
    不把「有声音问题但可能不是同一个根因」的现场冒充成 ④。"""
    if kind != '声音':
        return kind, note
    if site.hot_thread:
        return kind, (note + f'；④两条判据都满足（回调 0 次 + {site.hot_thread}）')
    return SUSPECT_AUDIO, (note + '；④只满足「回调 0 次」，「同时段某 nx-* 线程 ≥0.95 核」这一条在日志里没有证据，降为疑似')


def key_frames(site, hits):
    """关键栈帧：优先渲染线程上命中的那条，取它最深的几帧。"""
    syms = [h['pattern'] for h in hits if h['slot'] == 'thread_stack']
    # 关键帧要落在「真正在等的那条线程」上：排序键 = (命中帧数, 是渲染线程, 命中列表里点名的线程)
    # ①与②的 GPU.Emu 栈相同，两边都会命中实化符号，所以「是不是渲染线程」必须优先于命中帧数
    # （否则 ② 会把关键帧给到 GPU.Emu，而真正的判据在渲染线程的 gal_pso_job_wait 上）。
    scored = []
    for t in site.threads:
        if not t.frames:
            continue
        n = sum(1 for f in t.frames if any(re.search(p, f.sym) for p in syms))
        if n == 0:
            continue
        scored.append(((1 if RENDER_THREAD.search(t.name) else 0, n), t))
    if not scored:
        return [], None
    t = max(scored, key=lambda kv: kv[0])[1]
    out = [f'线程「{t.name}」（tid {t.tid}，{t.state}，用户态 {t.user_s:.2f} s）']
    for f in sorted(t.frames, key=lambda f: f.depth)[:6]:
        out.append(f'{f.kind} {f.sym}' + (f'（{f.module}）' if f.module else ''))
    return out, t


# ---- 输出 ---------------------------------------------------------------

def summarize(sites, results, owners):
    order, agg = [], {}
    for site, (kind, _h, _r) in zip(sites, results):
        if kind not in agg:
            agg[kind] = {'count': 0, 'first_frame': None, 'first_index': None, 'owner': owners.get(kind, '')}
            order.append(kind)
        a = agg[kind]
        a['count'] += 1
        if a['first_index'] is None:
            a['first_index'] = site.index
        f = site.frame_hint
        if f is not None and (a['first_frame'] is None or f < a['first_frame']):
            a['first_frame'] = f
    return order, agg


def to_json(sites, results, meta):
    order, agg = summarize(sites, results, meta['owners'])
    items = []
    for site, (kind, hits, reason) in zip(sites, results):
        kf, _ = key_frames(site, hits)
        items.append({
            'index': site.index, 'line': site.line_no, 'has_dump': site.has_dump,
            'trigger': site.trigger, 'why': site.why, 'kind': kind, 'frame': site.frame_hint,
            'threads': len(site.threads), 'key_frames': kf, 'reason': reason,
            'hits': [{k: h[k] for k in ('kind', 'slot', 'pattern', 'weight', 'note')} for h in hits],
        })
    return {
        'tool': 'stall_classify', 'issue': '#194 / K01',
        'source': dict(meta['stats'], sites=len(items), rules=len(meta['rules']), input=meta['input']),
        'summary': {k: agg[k] for k in order},
        'stalls': items,
        'warnings': meta['warnings'],
    }


def to_md(sites, results, meta):
    order, agg = summarize(sites, results, meta['owners'])
    out = ['# 停住现场归类报告\n',
           f'- 输入：`{meta["input"]}`（{meta["stats"]["lines"]} 行，{meta["stats"]["dump_blocks"]} 个 `[现场]` 块，'
           f'跳过 {meta["stats"]["reg_lines"]} 行寄存器；规则 {len(meta["rules"])} 条）',
           f'- 停住站点：**{len(sites)} 次**；规则表：`{meta["rules_path"]}`\n']
    out.append('## 每类次数\n')
    if not sites:
        out.append('没有停住（既没有触发行，也没有现场块）：**0 次**。\n')
    else:
        out += ['| 归类 | 建议归属 | 次数 | 首次站点 | 首次帧号 |', '|---|---|---|---|---|']
        for kind in order:
            a = agg[kind]
            ff = a['first_frame'] if a['first_frame'] is not None else '—'
            out.append(f'| {kind} | {a["owner"]} | {a["count"]} | 第 {a["first_index"]} 次 | {ff} |')
        out.append('')
    out.append('## 逐站点\n')
    for site, (kind, hits, reason) in zip(sites, results):
        out.append(f'### 第 {site.index} 次：**{kind}**（建议归属：{meta["owners"].get(kind, "")}）\n')
        out.append(f'- 位置：第 {site.line_no} 行；触发来源：`{site.trigger or "—"}`')
        out.append(f'- 触发原因：{site.why or "—"}')
        out.append(f'- 首次帧号：{site.frame_hint if site.frame_hint is not None else "—"}')
        out.append('- 现场：' + (f'有 `[现场]` 块，{len(site.threads)} 条线程' if site.has_dump else '**没有** `[现场]` 块（按日志行判）'))
        if reason:
            out.append(f'- 备注：{reason}')
        if hits:
            out.append('- 命中特征：')
            for h in hits:
                out.append(f'  - `{h["slot"]}` / `{h["pattern"]}`（{h["note"]}，权重 {h["weight"]}）')
        kf, _ = key_frames(site, hits)
        if kf:
            out.append('- 关键栈帧：')
            out.append(f'  - {kf[0]}')
            for k in kf[1:]:
                out.append(f'    - `{k}`')
        out.append('')
    if meta['warnings']:
        out.append('## 警告\n')
        for w in meta['warnings']:
            out.append(f'- {w}')
        out.append('')
    return '\n'.join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog='stall_classify.py',
        description='停住现场自动归类：解析 host.log 的 [现场] 块，按规则表归因并给出建议归属（K01 / #194）')
    ap.add_argument('host_log', help='host.log 路径')
    ap.add_argument('--json', dest='json_out', help='另写 JSON 结果到该路径')
    ap.add_argument('--md', dest='md_out', help='另写 Markdown 到该路径（缺省写 stdout）')
    ap.add_argument('--rules', default=str(Path(__file__).with_name('stall_rules.tsv')),
                    help='规则表路径（缺省与本文件同目录的 stall_rules.tsv）')
    a = ap.parse_args(argv)

    rules, order, owners = load_rules(a.rules)
    sites, warnings, stats = parse_log(a.host_log)
    results = [classify(s, rules, order) for s in sites]
    meta = {'input': a.host_log, 'rules': rules, 'owners': owners, 'warnings': warnings,
            'stats': stats, 'rules_path': a.rules}

    md = to_md(sites, results, meta)
    if a.md_out:
        Path(a.md_out).write_text(md + '\n', encoding='utf-8')
    else:
        sys.stdout.write(md + '\n')
    if a.json_out:
        Path(a.json_out).write_text(json.dumps(to_json(sites, results, meta), ensure_ascii=False, indent=2) + '\n',
                                    encoding='utf-8')
    for w in warnings:
        print(f'【警告】{w}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
