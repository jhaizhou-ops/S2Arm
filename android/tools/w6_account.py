#!/usr/bin/env python3
"""W6.0/W6.1 生产全账离线归集：只读日志与设备快照，不参与运行时采集。

输入是 `adb logcat -v threadtime` 的原始文本；可选 `--serial` 追加读取设备/包/内存/热状态
和 SurfaceFlinger 显示样本。输出 JSON + 人读摘要。缺字段保留 null 并在 `missing` 写明原因，
不把未观测值填 0，也不把 CPU 等待冒称 GPU 时间或显示帧率。

用法：
  python3 android/tools/w6_account.py --log /tmp/run.log --pid 1234 \
      --window 60 --json /tmp/w6.json
  adb logcat -v threadtime > /tmp/run.log   # 采集端自己负责时长与场景标记
"""
import argparse
import json
import re
import statistics
import subprocess
import sys
from datetime import datetime

LINE = re.compile(
    r'^(?P<mon>\d\d)-(?P<day>\d\d)\s+(?P<time>\d\d:\d\d:\d\d\.\d+)\s+'
    r'(?P<pid>\d+)\s+(?P<tid>\d+)\s+(?P<level>[VDIWEF])\s+(?P<tag>\S+)\s*:\s?(?P<msg>.*)$')

FRAME = re.compile(
    r'frame timing\(近(?P<win>\d+)帧, frame=(?P<frame>\d+)\): gap=(?P<gap>[\d.]+)ms '
    r'p50=(?P<p50>[\d.]+) p95=(?P<p95>[\d.]+) max=(?P<max>[\d.]+) \(n=(?P<n>\d+)\) '
    r'exec=(?P<exec>[\d.]+)ms present=(?P<present>[\d.]+)ms other=(?P<other>[\d.]+)ms '
    r'commands=(?P<commands>[\d.]+) fps=(?P<fps>[\d.]+)')
FRAME_THIS = re.compile(
    r'frame timing\(本帧\): gap=(?P<gap>[\d.]+)ms exec=(?P<exec>[\d.]+)ms '
    r'present=(?P<present>[\d.]+)ms other=(?P<other>[\d.]+)ms commands=(?P<commands>\d+)')
LONGFRAME = re.compile(
    r'longframe\(本帧\): frame=(?P<frame>\d+) gap=(?P<gap>[\d.]+)ms exec=(?P<exec>[\d.]+)ms'
    r'（其中 编译 \+(?P<compile_n>\d+) 次 (?P<compile_ms>[\d.]+)ms、'
    r'管线创建 \+(?P<pipe_n>\d+) 次 (?P<pipe_ms>[\d.]+)ms）\| 等待/其它 (?P<other>[\d.]+)ms')
LONGFRAME_ATTR = re.compile(
    r'longframe 归因：compile=(?P<compile>\d+) ms=(?P<compile_ms>\d+) max_ms=(?P<compile_max>\d+) '
    r'\| pipeline_create=(?P<pipe>\d+) failure=(?P<pipe_fail>\d+) ms=(?P<pipe_ms>\d+) '
    r'max_ms=(?P<pipe_max>\d+)')
GPU_FRAME = re.compile(
    r'gpu frame(?:\((?P<where>[^)]*)\))?: (?P<ms>[\d.]+) ms \((?P<detail>[^)]*)\)')
GPU_PASSES = re.compile(r'(\d+) passes?')
PRESENT_ACCOUNT = re.compile(
    r'present account: submitted=(?P<submitted>\d+) draw_completed_sync=(?P<completed>\d+) '
    r'presentation_retired=(?P<retired>\d+) pending=(?P<pending>\d+) retained=(?P<retained>\d+) '
    r'deferred_retired=(?P<deferred>\d+) \| fail\(submit=(?P<submit_fail>\d+) '
    r'present=(?P<present_fail>\d+) fence_timeout=(?P<fence_timeout>\d+) '
    r'retire_timeout=(?P<retire_timeout>\d+) acquire_timeout=(?P<acquire_timeout>\d+)\)')
PRESENT_LIFECYCLE = re.compile(
    r'present lifecycle: submitted=(?P<submitted>\d+) draw_completed=(?P<completed>\d+) '
    r'presentation_retired=(?P<retired>\d+) pending=(?P<pending>\d+) retained=(?P<retained>\d+)')
PRESENT_SPLIT = re.compile(
    r'present 拆分(?:\(延迟\))?：等GPU画完=(?P<gpu>\d+) us \| acquire=(?P<acquire>\d+) us '
    r'\| 录blit\+提交=(?P<blit>\d+) us \| present\+vsync=(?P<vsync>\d+) us')
DRAW_TIMING = re.compile(r'draw timing\((?P<kind>[^)]*)\): avg=(?P<avg>\d+) us over (?P<n>\d+) draws')
FLUSH = re.compile(r'frame flush: avg draws=(?P<draws>\d+) wait=(?P<wait>-?\d+) us gap=(?P<gap>-?\d+) ms')
DRAW_WINDOW = re.compile(r'draw window: draws=(?P<draws>\d+) depthOnly=(?P<depth>\d+)')
PASS_WINDOW = re.compile(
    r'render pass window: hit=(?P<hit>\d+) miss=(?P<miss>\d+) create=(?P<create>[\d.]+) ms '
    r'fb=(?P<fb>[\d.]+) ms \(n=(?P<n>\d+)\)')
PROGRAM_CACHE = re.compile(
    r'program cache 跨局：disk_hits=(?P<disk_hits>\d+) disk_stores=(?P<disk_stores>\d+) '
    r'disk_failures=(?P<disk_failures>\d+) offline_hits=(?P<offline_hits>\d+) '
    r'offline_misses=(?P<offline_misses>\d+) offline_rejects=(?P<offline_rejects>\d+)')
LOCK = re.compile(r'adapter exec: lockWait=(?P<us>[\d.]+) us/笔 \(n=(?P<n>\d+)\)')
OP = re.compile(r'op=(?P<op>\d+) count=(?P<count>\d+) avg=(?P<avg>[\d.]+)us total=(?P<total>[\d.]+)ms')
ERROR = re.compile(r'\b(retained|timeout|timed out|failed|refus|lost|unavailable|不匹配|失败|保留)\b')

TIME = re.compile(r'^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)$')


def parse_ts(mon, day, hh, mm, ss, frac):
    # 日志跨月/跨年没有年份；只用于同一份日志内的相对窗口，年份填 2000 便于排序。
    micro = int((frac + '000000')[:6])
    return datetime(2000, int(mon), int(day), int(hh), int(mm), int(ss), micro).timestamp()


def pct(values, p):
    if not values:
        return None
    values = sorted(values)
    if p <= 0:
        return values[0]
    k = (len(values) * p + 99) // 100 - 1
    return values[max(0, min(len(values) - 1, k))]


def mean(values):
    return statistics.fmean(values) if values else None


def rnd(v, n=3):
    return None if v is None else round(v, n)


def parse_log(path):
    rows = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = LINE.match(line.rstrip('\n'))
            if not m:
                continue
            msg = m.group('msg')
            if msg.startswith('prev|'):
                continue  # 上一局回放，不属于本进程本窗口
            pid = int(m.group('pid'))
            ts = parse_ts(m.group('mon'), m.group('day'), *TIME.match(
                f"{m.group('mon')}-{m.group('day')} {m.group('time')}").groups()[2:])
            rows.append((ts, pid, m.group('level'), m.group('tag'), msg))
    return rows


def pick_pid(rows, wanted):
    if wanted:
        return wanted
    counts = {}
    for _, pid, level, tag, msg in rows:
        if tag == 'S2Arm' and (msg.startswith('frame timing') or msg.startswith('present')):
            counts[pid] = counts.get(pid, 0) + 1
    if not counts:
        counts = {pid: 1 for _, pid, level, tag, msg in rows if tag == 'S2Arm'}
    return max(counts, key=counts.get) if counts else None


def device_snapshot(serial, package):
    def sh(*args):
        try:
            return subprocess.run(['adb', '-s', serial, *args], capture_output=True, text=True,
                                  timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ''
    props = {}
    for key in ('ro.product.model', 'ro.product.device', 'ro.build.version.release',
                'ro.soc.manufacturer', 'ro.soc.model', 'ro.hardware.vulkan'):
        props[key] = sh('shell', 'getprop', key) or None
    apk_hash = sh('shell', 'sha256sum', sh('shell', 'pm', 'path', package).replace('package:', '')).split()
    mem = sh('shell', 'dumpsys', 'meminfo', package)
    total_pss = re.search(r'TOTAL PSS:\s+(\d+)', mem)
    thermal = sh('shell', 'dumpsys', 'thermalservice')
    status = re.search(r'mStatus=(\d+)', thermal)
    battery = sh('shell', 'dumpsys', 'battery')
    return {
        'props': props,
        'package': package,
        'apkSha256': apk_hash[0] if apk_hash else None,
        'totalPssKb': int(total_pss.group(1)) if total_pss else None,
        'thermalStatus': int(status.group(1)) if status else None,
        'charging': 'AC powered: true' in battery or 'USB powered: true' in battery,
    }


def _sf_hist(line):
    hist = {}
    for m in re.finditer(r'(\d+)ms=(\d+)', line):
        hist[int(m.group(1))] = int(m.group(2))
    return hist


def _sf_pct(hist, total, p):
    if total <= 0 or not hist:
        return None
    target = (total * p + 99) // 100
    cum = 0
    for ms in sorted(hist):
        cum += hist[ms]
        if cum >= target:
            return ms
    return max(hist)


def _sf_layers(text):
    """per-layer totalFrames/dropped/averageFPS/present2present 直方图。"""
    layers = {}
    sections = re.split(r'(?m)^layerName = ', text)
    for sec in sections[1:]:
        lines = sec.splitlines()
        name = lines[0].strip() if lines else ''
        total = re.search(r'(?m)^totalFrames = (\d+)', sec)
        fps = re.search(r'(?m)^averageFPS = ([\d.]+)', sec)
        dropped = re.search(r'(?m)^droppedFrames = (\d+)', sec)
        h = re.search(r'present2present histogram is as below:\n([^\n]+)', sec)
        if not total or not h:
            continue
        layers[name] = {'total': int(total.group(1)), 'hist': _sf_hist(h.group(1)),
                        'fps': float(fps.group(1)) if fps else None,
                        'dropped': int(dropped.group(1)) if dropped else None}
    return layers


def _pick_sf_layer(layers, package):
    preferred = [n for n in layers if 's2arm' in n or (package and package in n)]
    if not preferred:
        return None
    return max(preferred, key=lambda n: layers[n]['total'])


def parse_sf_timestats(text, package):
    """解析单次 SurfaceFlinger --timestats -dump 的 per-layer 直方图。

    这是 SF 自己的聚合窗，不是逐帧原始事件；桶宽 1 ms，p50/p95/p99 取桶上界。
    没有目标 layer 或 totalFrames=0 时返回 unavailable，不用 app present 代替。
    """
    layers = _sf_layers(text)
    name = _pick_sf_layer(layers, package)
    if name is None:
        return {'source': 'sf-timestats', 'available': False, 'reason': 'SF timestats 没有目标 layer'}
    layer = layers[name]
    start = re.search(r'statsStart = (\d+)', text)
    end = re.search(r'statsEnd = (\d+)', text)
    window = None
    if start and end:
        try:
            window = max(0, int(end.group(1)) - int(start.group(1)))
        except ValueError:
            window = None
    return _sf_result(name, layer['total'], layer['total'], layer['hist'], layer['fps'],
                      layer['dropped'], window, 'sf-timestats-histogram')


def _sf_result(name, total, frames, hist, fps, dropped, window, source):
    if total <= 0 or not hist:
        return {'source': source, 'available': False, 'reason': '目标 layer 帧数为 0', 'layer': name}
    slow = sum(c for ms, c in hist.items() if ms > 25)
    return {'source': source, 'available': True, 'layer': name, 'windowSeconds': window,
            'frames': frames, 'fps': rnd(fps, 2) if fps else None, 'droppedFrames': dropped,
            'p50Ms': _sf_pct(hist, total, 50), 'p95Ms': _sf_pct(hist, total, 95),
            'p99Ms': _sf_pct(hist, total, 99),
            'maxMs': max(ms for ms, c in hist.items() if c > 0) if any(hist.values()) else None,
            'slow25MsRatio': rnd(slow / total, 4), 'bucketMs': 1}


def parse_sf_delta(before_text, after_text, package, seconds):
    """两次 dump 相减，得到与 logcat 同窗的显示账。

    `--timestats -clear` 后立刻取 before，采集结束取 after；只减目标 layer 的桶计数，
    避免把 clear 之前/其它窗口的帧算进来。layer 名变化/计数倒退则 unavailable。
    """
    before = _sf_layers(before_text)
    after = _sf_layers(after_text)
    name = _pick_sf_layer(after, package)
    if name is None:
        return {'source': 'sf-timestats-delta', 'available': False,
                'reason': 'after dump 没有目标 layer'}
    base = before.get(name)
    if base is None:
        # clear 后第一次 dump 可能还没建出目标 layer（只有 legacy/其它层）；
        # 若两次 statsStart 相同，说明还是同一次 clear 后的统计会话，目标层基线按 0 处理。
        bstart = re.search(r'statsStart = (\d+)', before_text)
        astart = re.search(r'statsStart = (\d+)', after_text)
        same_session = bstart and astart and bstart.group(1) == astart.group(1)
        before_has_target = any('s2arm' in n or (package and package in n) for n in before)
        if before_has_target or not same_session:
            return {'source': 'sf-timestats-delta', 'available': False,
                    'reason': '目标 layer 在 before/after 中不一致'}
        base = {'total': 0, 'hist': {}, 'dropped': 0}
    total = after[name]['total'] - base['total']
    hist = {ms: c - base['hist'].get(ms, 0) for ms, c in after[name]['hist'].items()}
    hist = {ms: c for ms, c in hist.items() if c > 0}
    dropped = None
    if after[name]['dropped'] is not None and base['dropped'] is not None:
        dropped = max(0, after[name]['dropped'] - base['dropped'])
    if total <= 0:
        return {'source': 'sf-timestats-delta', 'available': False, 'reason': '两次 dump 之间没有新帧',
                'layer': name}
    fps = total / seconds if seconds and seconds > 0 else None
    return _sf_result(name, total, total, hist, fps, dropped, seconds, 'sf-timestats-delta')

def surfaceflinger(serial, package):
    """显示样本：优先 SF timestats per-layer 直方图；再退回 --latency；都取不到标 unavailable。"""
    def sh(*args):
        try:
            return subprocess.run(['adb', '-s', serial, 'shell', *args], capture_output=True,
                                  text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            return ''
    sh('dumpsys', 'SurfaceFlinger', '--timestats', '-enable')
    dumped = sh('dumpsys', 'SurfaceFlinger', '--timestats', '-dump')
    parsed = parse_sf_timestats(dumped, package)
    if parsed.get('available'):
        return parsed
    layers = [l for l in sh('dumpsys', 'SurfaceFlinger', '--list').splitlines() if 's2arm' in l]
    if not layers:
        parsed['latencyReason'] = '没有 SurfaceFlinger 图层'
        return parsed
    name = re.sub(r'^RequestedLayerState\{', '', layers[0]).split('}')[0]
    raw = sh('dumpsys', 'SurfaceFlinger', '--latency', name)
    rows = []
    for line in raw.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 3:
            continue
        try:
            actual, ready = int(parts[1]), int(parts[2])
        except ValueError:
            continue
        if actual > 0 and ready > 0:
            rows.append((actual - ready) / 1e6)
    if not rows:
        parsed['latencyReason'] = 'SF --latency 没有有效帧（图层名或权限）'
        parsed['layer'] = name
        return parsed
    return {'source': 'sf-latency', 'available': True, 'layer': name, 'frames': len(rows),
            'fps': rnd(1000.0 / mean(rows), 2), 'p50Ms': rnd(pct(rows, 50)),
            'p95Ms': rnd(pct(rows, 95)), 'p99Ms': rnd(pct(rows, 99)), 'maxMs': rnd(max(rows)),
            'slow25MsRatio': rnd(sum(1 for v in rows if v > 25) / len(rows), 4)}

def analyze(rows, pid, args):
    samples = [(ts, level, msg) for ts, p, level, tag, msg in rows if p == pid and tag == 'S2Arm']
    if not samples:
        raise SystemExit(f'没有 PID {pid} 的 S2Arm 样本')
    samples.sort(key=lambda x: x[0])
    t0, t1 = samples[0][0], samples[-1][0]
    if args.since:
        t0 = max(t0, parse_ts(*re.match(r'(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)', args.since).groups()))
    if args.until:
        t1 = min(t1, parse_ts(*re.match(r'(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)', args.until).groups()))
    if args.window and (t1 - t0) > args.window:
        t1 = t0 + args.window
    win = [(ts, level, msg) for ts, level, msg in samples if t0 <= ts <= t1]
    # 同一窗口里出现多个 S2Arm 进程的帧/呈现行 = 中途重启/被外部替换；不能把两段拼成 60s。
    frame_pids = sorted({p for ts, p, level, tag, msg in rows
                         if tag == 'S2Arm' and t0 <= ts <= t1
                         and (msg.startswith('frame timing') or msg.startswith('present account')
                              or msg.startswith('nvn_vk backend ready')
                              or msg.startswith('Game startup accepted'))})
    other_pids = [p for p in frame_pids if p != pid]

    out = {
        'provenance': {
            'pid': pid, 'start': t0, 'end': t1, 'durationSeconds': rnd(t1 - t0, 1),
            's2armLines': len(win), 'source': args.log,
        },
        'appFrame': {}, 'longFrame': {}, 'gpu': {}, 'present': {}, 'presentSplit': {},
        'cpuPath': {}, 'workload': {}, 'errors': [], 'missing': [], 'checks': {},
    }
    app, longf, gpu, pres, split = [], [], [], [], []
    draw, flush, dwin, pwin, prog, lock, ops = [], [], [], [], [], [], []
    errs = {}
    for ts, level, msg in win:
        if m := FRAME.search(msg):
            app.append({k: float(m.group(k)) for k in ('gap', 'p50', 'p95', 'max', 'exec', 'present',
                                                       'other', 'commands', 'fps')} |
                       {'frames': int(m.group('n')), 'frame': int(m.group('frame'))})
        elif m := LONGFRAME.search(msg):
            longf.append({k: float(m.group(k)) for k in ('gap', 'exec', 'compile_ms', 'pipe_ms', 'other')} |
                         {'compileN': int(m.group('compile_n')), 'pipeN': int(m.group('pipe_n'))})
        elif m := GPU_FRAME.search(msg):
            pm = GPU_PASSES.search(m.group('detail'))
            gpu.append({'ms': float(m.group('ms')), 'passes': int(pm.group(1)) if pm else 0,
                        'where': m.group('where')})
        elif m := PRESENT_ACCOUNT.search(msg):
            pres.append({k: int(m.group(k)) for k in ('submitted', 'completed', 'retired', 'pending',
                                                      'retained', 'deferred', 'submit_fail', 'present_fail',
                                                      'fence_timeout', 'retire_timeout', 'acquire_timeout')})
        elif m := PRESENT_LIFECYCLE.search(msg):
            pres.append({k: int(m.group(k)) for k in ('submitted', 'completed', 'retired', 'pending',
                                                      'retained')})
        elif m := PRESENT_SPLIT.search(msg):
            split.append({k: int(m.group(k)) for k in ('gpu', 'acquire', 'blit', 'vsync')})
        elif m := DRAW_TIMING.search(msg):
            draw.append({'kind': m.group('kind'), 'avgUs': int(m.group('avg')), 'n': int(m.group('n'))})
        elif m := FLUSH.search(msg):
            flush.append({k: int(m.group(k)) for k in ('draws', 'wait', 'gap')})
        elif m := DRAW_WINDOW.search(msg):
            dwin.append({'draws': int(m.group('draws')), 'depthOnly': int(m.group('depth'))})
        elif m := PASS_WINDOW.search(msg):
            pwin.append({k: float(m.group(k)) for k in ('hit', 'miss', 'create', 'fb', 'n')})
        elif m := PROGRAM_CACHE.search(msg):
            prog.append({k: int(m.group(k)) for k in ('disk_hits', 'disk_stores', 'disk_failures',
                                                      'offline_hits', 'offline_misses', 'offline_rejects')})
        elif m := LOCK.search(msg):
            lock.append({'us': float(m.group('us')), 'n': int(m.group('n'))})
        elif m := OP.search(msg):
            ops.append({'op': int(m.group('op')), 'count': int(m.group('count')),
                        'avgUs': float(m.group('avg')), 'totalMs': float(m.group('total'))})
        if level == 'E' or (level == 'W' and ERROR.search(msg)):
            key = re.sub(r'\d+', '#', msg)[:180]
            errs[key] = errs.get(key, 0) + 1

    def agg(rows_, key):
        vals = [r[key] for r in rows_]
        return {'n': len(vals), 'median': rnd(mean(vals)) if not vals else rnd(statistics.median(vals)),
                'p95': rnd(pct(vals, 95)), 'max': rnd(max(vals))} if vals else None

    if app:
        out['appFrame'] = {
            'source': 'app frame timing(16-frame window)',
            'windows': len(app), 'frames': sum(a['frames'] for a in app),
            'gapMs': agg(app, 'gap'), 'p50Ms': agg(app, 'p50'), 'p95Ms': agg(app, 'p95'),
            'maxMs': agg(app, 'max'), 'fps': agg(app, 'fps'),
            'execMs': agg(app, 'exec'), 'presentMs': agg(app, 'present'), 'otherMs': agg(app, 'other'),
            'commands': agg(app, 'commands'),
        }
    else:
        out['missing'].append('appFrame: 没有 frame timing 行（正常模式或启动早期）')

    if longf:
        out['longFrame'] = {
            'count': len(longf), 'gapMsMax': max(x['gap'] for x in longf),
            'execMsMedian': rnd(statistics.median(x['exec'] for x in longf)),
            'compileCount': sum(x['compileN'] for x in longf),
            'compileMs': rnd(sum(x['compile_ms'] for x in longf)),
            'pipelineCount': sum(x['pipeN'] for x in longf),
            'pipelineMs': rnd(sum(x['pipe_ms'] for x in longf)),
        }

    if gpu:
        out['gpu'] = {
            'valid': len(gpu), 'invalid': None, 'source': 'VkQueryPool TIMESTAMP',
            'msMedian': rnd(statistics.median(x['ms'] for x in gpu)),
            'msMax': rnd(max(x['ms'] for x in gpu)),
            'passesMedian': rnd(statistics.median(x['passes'] for x in gpu)),
            'readAfter': sorted({x['where'] or 'present' for x in gpu}),
        }
    else:
        out['gpu'] = {'valid': 0, 'invalid': None}
        out['missing'].append('gpu: 没有 gpu frame 行（debug.s2a.gpu_time 未开或时间戳不可用）；'
                              '不用 CPU 等待代替 GPU 时间')

    if pres:
        last = pres[-1]
        first = pres[0]
        inv = last.get('submitted', 0) - last.get('retired', 0) - last.get('pending', 0)
        out['present'] = {
            'source': 'present account' if 'deferred' in last else 'present lifecycle (destroy)',
            'samples': len(pres), 'last': last,
            'delta': {k: last[k] - first[k] for k in last},
            'invariantSubmittedMinusRetiredMinusPending': inv,
        }
        out['checks']['present_states_consistent'] = inv >= 0
        out['checks']['present_retained_zero'] = last.get('retained', 0) == 0
        out['checks']['present_pending_bounded'] = last.get('pending', 0) <= 8
    else:
        out['missing'].append('present: 没有 present account/present lifecycle 行；'
                              '未观察到的退休状态不填 0')

    if split:
        out['presentSplit'] = {
            'samples': len(split),
            'gpuWaitUsMedian': rnd(statistics.median(x['gpu'] for x in split)),
            'acquireUsMedian': rnd(statistics.median(x['acquire'] for x in split)),
            'blitSubmitUsMedian': rnd(statistics.median(x['blit'] for x in split)),
            'presentVsyncUsMedian': rnd(statistics.median(x['vsync'] for x in split)),
        }

    if draw:
        out['cpuPath']['drawTiming'] = [
            {'kind': k, 'n': sum(d['n'] for d in draw if d['kind'] == k),
             'avgUsMedian': rnd(statistics.median(d['avgUs'] for d in draw if d['kind'] == k))}
            for k in sorted({d['kind'] for d in draw})]
    if lock:
        out['cpuPath']['lockWaitUsPerDraw'] = agg(lock, 'us')
    if prog:
        out['cpuPath']['programCache'] = prog[-1]
    if ops:
        out['cpuPath']['topOps'] = sorted(ops, key=lambda o: o['totalMs'], reverse=True)[:8]
    if flush:
        out['cpuPath']['flush'] = {'samples': len(flush), 'drawsMedian': rnd(statistics.median(x['draws'] for x in flush)),
                                   'waitUsMedian': rnd(statistics.median(x['wait'] for x in flush))}
    if dwin:
        out['workload']['drawsPerWindow'] = rnd(statistics.median(x['draws'] for x in dwin))
        out['workload']['depthOnlyPerWindow'] = rnd(statistics.median(x['depthOnly'] for x in dwin))
    if pwin:
        out['workload']['pass'] = {
            'hit': sum(int(x['hit']) for x in pwin), 'miss': sum(int(x['miss']) for x in pwin),
            'createMs': rnd(sum(x['create'] for x in pwin)), 'fbMs': rnd(sum(x['fb'] for x in pwin)),
        }
    out['errors'] = [{'message': k, 'count': v} for k, v in sorted(errs.items(), key=lambda kv: -kv[1])[:20]]

    out['checks']['window_ge_60s'] = (t1 - t0) >= 60.0
    out['checks']['pid_consistent'] = not other_pids
    out['provenance']['s2armPids'] = frame_pids
    if other_pids:
        out['missing'].append(
            'pid: 同窗出现多个 S2Arm 进程 ' + ','.join(map(str, other_pids)) +
            '（中途重启/被外部替换），不能拼成连续窗口')
    if args.sf_before and args.sf_after:
        try:
            out['display'] = parse_sf_delta(open(args.sf_before, encoding='utf-8', errors='replace').read(),
                                            open(args.sf_after, encoding='utf-8', errors='replace').read(),
                                            args.package, args.seconds)
        except OSError as error:
            out['display'] = {'source': 'sf-timestats-delta', 'available': False,
                              'reason': f'读取 SF dump 失败: {error}'}
    elif args.serial and args.package:
        out['device'] = device_snapshot(args.serial, args.package)
        out['display'] = surfaceflinger(args.serial, args.package)
    else:
        out['display'] = {'source': 'sf', 'available': False, 'reason': '未提供 --serial；不使用 app 帧时冒充显示'}
        out['missing'].append('display: 未采集 SurfaceFlinger/FrameTimeline')
    out['checks']['display_available'] = bool(out.get('display', {}).get('available'))
    if not out['checks']['display_available']:
        out['missing'].append('display: SurfaceFlinger 目标 layer 不可用，不能把 app 帧时当显示账')
    if not out['checks']['window_ge_60s']:
        out['missing'].append(f'window: 只有 {t1 - t0:.1f}s，不足 60s')
    return out


def summary(a):
    p = a['provenance']
    print(f"PID {p['pid']} 窗口 {p['durationSeconds']}s（{p['s2armLines']} 行）")
    disp = a.get('display', {})
    if disp.get('available'):
        print(f"显示 SF: {disp['frames']} 帧 {disp['fps']} fps p95={disp['p95Ms']}ms "
              f">25ms={disp['slow25MsRatio']:.1%}")
    else:
        print(f"显示: unavailable（{disp.get('reason')}）")
    if a.get('appFrame'):
        f = a['appFrame']
        print(f"app 帧: {f['windows']} 窗 {f['frames']} 帧 gap p50={f['gapMs']['median']}ms "
              f"fps 中位={f['fps']['median']} exec={f['execMs']['median']}ms present={f['presentMs']['median']}ms")
    if a.get('gpu', {}).get('valid'):
        g = a['gpu']
        print(f"GPU: {g['valid']} 帧 中位 {g['msMedian']}ms 最大 {g['msMax']}ms（完成后读）")
    else:
        print('GPU: unavailable')
    if a.get('present'):
        last = a['present']['last']
        d = a['present'].get('delta', {})
        # last 是会话累计；窗口读数用 delta，避免把开跑前的 present 算进 60 秒。
        print(f"present(窗口增量): submitted={d.get('submitted')} retired={d.get('retired')} "
              f"retained={d.get('retained')}（会话累计 submitted={last.get('submitted')} "
              f"retired={last.get('retired')} pending={last.get('pending')} retained={last.get('retained')}）")
    if a.get('longFrame'):
        l = a['longFrame']
        print(f"长帧: {l['count']} 帧 编译 {l['compileCount']} 次 {l['compileMs']}ms "
              f"管线 {l['pipelineCount']} 次 {l['pipelineMs']}ms")
    for k, v in a['checks'].items():
        print(f"check {k}: {'ok' if v else 'FAIL'}")
    for m in a['missing']:
        print(f"missing: {m}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--log', required=True)
    ap.add_argument('--pid', type=int)
    ap.add_argument('--window', type=int, default=60, help='分析前 N 秒（0 = 全段）')
    ap.add_argument('--since', help='MM-DD HH:MM:SS.mmm')
    ap.add_argument('--until', help='MM-DD HH:MM:SS.mmm')
    ap.add_argument('--serial')
    ap.add_argument('--sf-before', help='采集开始时的 SurfaceFlinger --timestats -dump')
    ap.add_argument('--sf-after', help='采集结束时的 SurfaceFlinger --timestats -dump')
    ap.add_argument('--seconds', type=float, default=0, help='log/SF 同窗秒数（delta 模式）')
    ap.add_argument('--package', default='org.s2arm.game.t01001b300b9be000')
    ap.add_argument('--json')
    ap.add_argument('--strict', action='store_true',
                    help='任一 check 失败或缺少 60s 窗口/GPU/present 时以非 0 退出')
    args = ap.parse_args()
    rows = parse_log(args.log)
    pid = pick_pid(rows, args.pid)
    if pid is None:
        raise SystemExit('日志里没有 S2Arm 样本')
    account = analyze(rows, pid, args)
    summary(account)
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump(account, f, ensure_ascii=False, indent=1)
            f.write('\n')
        print(f'JSON -> {args.json}')
    if args.strict:
        required = [v for v in account['checks'].values() if not v]
        if required or not account.get('gpu', {}).get('valid') or not account.get('present'):
            print('strict: W6 全账不完整或 check 失败', file=sys.stderr)
            return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
