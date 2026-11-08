#!/usr/bin/env python3
"""MARK 后「改出帧状态」的段（逻辑速度同局 A/B 及其重测，tests/autoplay/autoplay.c s2a_ap_seg_open(…, 1)）：段内 60 帧开关来回切、摇杆被按住量位移，
帧率 / 卡顿 / 帧节拍判据一律不看（11-04 普查提前收局之后照常窗口从最后一段结束起算；满屏补丁线把同一口径补到帧节拍、帧率格、卡顿读数）。
自动玩家日志：「自动玩家：MARK 后段开始「<名>」（#<号>，改出帧状态，帧 <F>）」/「自动玩家：MARK 后段结束「<名>」（#<号>，帧 <F>）」
  spans(host.log 文本) → [(起帧, 止帧)]；开了没结束（局在段内收了）→ 止帧 = 无穷；旧日志没有帧号 → 该段不收（判据退回旧口径）
  strip(host.log 文本) → 去掉每段「开始」行到「结束」行之间（含两行）的文本（帧节拍这类按行取的读数用）
  keep(帧号, 段表) → 这一帧算不算进判据（所有段外 = True）
进程内重启（玩家在设置里切 60 帧走的就是它）：frames.tsv 每个会话重写（graphics/nvn/host_adapt.m ft_open O_TRUNC、graphics/metal/cs/NxFrames.cs FileMode.Create），
  只剩最后一段、帧号从 1 起；host.log 从头累积，MARK / 段行的帧号是重启前那段的。按 frames.tsv 取窗一律走 frames_mark（同统一账本 tools/device_ledger.py「重启后段」）
  last_session(host.log 文本) → (最后一次重启之后的文本, 重启过没有)；重启位置 = 提示行，没有提示行（Mac 路径不打）取心跳帧号变小那行
  frames_mark(host.log 文本) → (frames.tsv 取窗起帧, 段表)：没重启 = MARK 帧；重启过 = 重启后那段的 MARK，那段没 MARK → 1（起点行之后整段）；都没 MARK → None"""
import re

START = re.compile(r'自动玩家：MARK 后段开始「[^」]*」（#(\d+)，改出帧状态，帧 (\d+)）')
END = re.compile(r'自动玩家：MARK 后段结束「[^」]*」（#(\d+)，帧 (\d+)）')
MARK = re.compile(r'S2A 标记 MARK：帧 (\d+)')
RESTART = 'iOS 重启：provider 已就绪'   # runtime/src/session.c 每次进程内重启打（同 tools/device_ledger.py RESTART_LINE）
HB = re.compile(r'\[心跳\] 帧 (\d+)')


def spans(hl):
    hl = hl or ''; ends = {m.group(1): int(m.group(2)) for m in END.finditer(hl)}
    return [(int(m.group(2)), ends.get(m.group(1), float('inf'))) for m in START.finditer(hl)]


def strip(hl):
    hl = hl or ''; out, inside = [], set()
    for line in hl.splitlines(keepends=True):
        a = START.search(line)
        if a: inside.add(a.group(1)); continue
        b = END.search(line)
        if b and b.group(1) in inside: inside.discard(b.group(1)); continue
        if not inside: out.append(line)
    return ''.join(out)


def keep(frame, sp):
    return not any(a <= frame <= b for a, b in (sp or ()))


def last_session(hl):
    lines = (hl or '').splitlines(keepends=True); cut, last = None, None
    for i, line in enumerate(lines):
        if RESTART in line: cut, last = i, None; continue
        m = HB.search(line)
        if m:
            f = int(m.group(1))
            if last is not None and f < last: cut = i
            last = f
    return (''.join(lines[cut:]), True) if cut is not None else (hl or '', False)


def frames_mark(hl):
    cur, restarted = last_session(hl); m = MARK.search(cur)
    if m: return int(m.group(1)), spans(cur)
    return (1 if restarted and MARK.search(hl or '') else None), spans(cur)   # 1：frames.tsv 首行是起点行（frame 1、wall_us 0，tests/真机契约.md §3），从它之后取整段
