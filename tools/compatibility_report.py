#!/usr/bin/env python3
"""从固定提交生成同源兼容性 Markdown / 能力卡 JSON，不运行游戏或读取资源。

--format json 输出 s2a.capability-card.v1；build_model 是唯一状态模型，
render_model 只消费该模型。releaseDefaults 仅是出包发布政策，不能替代
features 的平台/比例验证；packageDigest 恒为 null。FPS 表只查询 Git 树，
不打开载荷。使用者不得据此声称当前包或新设备已经实测。
"""
import argparse
import csv
import datetime
import json
import re
import subprocess
import sys
from urllib.parse import quote
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from caps_policy import SIGNALS, SIGNAL_IMPL, signal_hashes   # 强信号口径与失效键只在 caps_policy 一处
import reglist   # 按款登记表读写层（10-30）

FPS = 'docs/名单_60帧.tsv'   # 下面四个登记表常量都是逻辑路径：tools/reglist.py name_of 映射到按款目录 docs/<表名>/<程序号>.tsv（10-30）
CAP = 'docs/名单_60帧能力覆盖.tsv'
ASPECT = 'docs/名单_满屏比例.tsv'
VERIFIED = 'graphics/widen/tables/verified.tsv'
CENSUS = 'docs/研究/直连泛化普查.md'
LDN = 'docs/方案_联机LDN.md'
STRONG = 'docs/名单_能力强信号.tsv'   # 强信号登记（jhz 10-29 07:0x 全能力出包「默认开、强信号才关」，tools/caps_policy.py）
DIRECT = 'docs/名单_直连实测.tsv'   # 普查直连实测（tools/census/census.py direct_reg 写）：direct 键的启用 / 验证来源
INPUT = 'docs/名单_输入能力.tsv'   # 可选：旧提交或无记录时不改变能力卡
SOURCES = (FPS, CAP, ASPECT, VERIFIED, CENSUS, LDN, STRONG, DIRECT, INPUT)
HEADERS = {
    INPUT: ['程序号','构建号','项','静态','局内','依据局','日期'],
    FPS: ['程序号','构建号','款','日期','帧率','整机W','满屏','包','依据局','能力来源','备注','逻辑速度','逻辑速度局'],
    CAP: ['程序号','构建号','款','L1交换间隔','L1依据','L2引擎限帧','L2依据','L3时间步','L3依据','未达标原因'],
    ASPECT: ['程序号','构建号','款','档位','平台','结论','日期','读数','依据'],
    VERIFIED: ['程序号','构建号','款','平台','登记日期','依据'],
    STRONG: ['程序号','构建号','能力','内容哈希','信号','依据','日期'],
    DIRECT: ['程序号','构建号','款','平台','直连能跑','进局','依据','日期'],
}
PLATFORMS = {'Mac','iPhone','iPad','Duo','Duo 内屏','Duo 外屏 + 折叠','Android','iOS','macOS'}
TID = re.compile(r'[0-9A-F]{16}')
BID = re.compile(r'[0-9a-f]{32}')


def table(text, path, locations=()):
    expected = HEADERS[path]
    header = False
    for line, raw in enumerate(text.splitlines(),1):
        file, number = locations[line - 1] if line <= len(locations) and locations[line - 1][0] else (path, line)
        if not raw.strip(): continue
        if raw.startswith('#'):
            if path == VERIFIED and raw.lstrip('# ').split('\t') == expected: header=True
            continue
        cells = next(csv.reader([raw],delimiter='\t',quoting=csv.QUOTE_NONE))
        if not header:
            if cells != expected: raise ValueError(f'{file}:{number}: 表头不匹配')
            header=True;continue
        if len(cells)!=len(expected):raise ValueError(f'{file}:{number}: 列数不匹配')
        row=dict(zip(expected,cells))
        if not TID.fullmatch(row['程序号']) or not BID.fullmatch(row['构建号']):
            raise ValueError(f'{file}:{number}: 程序号/构建号格式错误')
        for field in ('日期','登记日期'):
            if field in row:
                try:
                    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}',row[field]):raise ValueError()
                    datetime.date.fromisoformat(row[field])
                except ValueError:raise ValueError(f'{file}:{number}: 日期无效') from None
        yield line,row
    if not header:raise ValueError(f'{path}: 缺少表头')


def registered_numbers(value, label, path, line):
    parts=value.split('/')
    numbers=[]
    for part in parts:
        match=re.fullmatch(r'\s*(\d+(?:\.\d+)?)%?\s*(?:（[^（）]*）|\([^()]*\))?\s*',part)
        if not match:raise ValueError(f'{path}:{line}: {label}登记数值格式错误')
        numbers.append(float(match.group(1)))
    if len(numbers)<2:raise ValueError(f'{path}:{line}: {label}不足两局')
    return numbers


LAYERS = ('L1交换间隔', 'L2引擎限帧', 'L3时间步')
LAYER_RE = re.compile(r'(已具备|部分|缺|不需要|未知)(（[^（）]+）)?')
PLATFORM_MAP = {'Mac': 'macos', 'iPhone': 'ios', 'Duo': 'ios',
                'Duo 内屏': 'ios', 'Duo 外屏 + 折叠': 'ios'}
FEATURES = ('direct', 'fullscreen', 'fps60', 'online', 'controller', 'rumble', 'gyro', 'quickMenu')
FPS_PATH = re.compile(r'runtime/fps/[0-9a-f]{16}\.tsv')


def collect(sources, revision):
    """原兼容表的唯一来源解析层；保留登记事实，不在渲染器里判定。"""
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('需要完整提交 SHA')
    if any(p not in sources for p in SOURCES if p != INPUT):
        raise ValueError('缺少固定来源文件')
    games = {}

    def record(tid, bid, name=''):
        key = (tid, bid)
        if key not in games:
            games[key] = {'name': tid, 'rows': []}
        if re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,47}', name):
            old = games[key]['name']
            games[key]['name'] = min(name, old) if old != tid else name
        return games[key]

    for path in (FPS, CAP, ASPECT, VERIFIED, STRONG, DIRECT, INPUT):
        if path == INPUT and not sources.get(path):
            continue
        locations = (sources.get('__loc__') or {}).get(path, ()) if path == INPUT else ()
        for line, row in table(sources[path], path, locations):
            g = record(row['程序号'], row['构建号'], row.get('款', ''))
            if path == FPS:
                if not all(row[k].strip() for k in ('帧率', '整机W', '满屏', '包', '依据局')):
                    raise ValueError(f'{path}:{line}: 达标登记缺依据')
                frames = registered_numbers(row['帧率'], '帧率', path, line)
                watts = registered_numbers(row['整机W'], '功耗', path, line)
                full = registered_numbers(row['满屏'], '满屏', path, line)
                if not (len(frames) == len(watts) == len(full)) or any(v < 59.5 for v in frames) or any(v <= 0 or v > 4.8 for v in watts) or any(v < 99 or v > 100 for v in full):
                    raise ValueError(f'{path}:{line}: 数值不满足60帧登记合同')
                speed = row.get('逻辑速度', '未验')
                if speed not in {'绿', '红', '判不出', '未验'}:
                    raise ValueError(f'{path}:{line}: 逻辑速度枚举无效')
                if speed == '绿' and not row.get('逻辑速度局', '').strip():
                    speed = '未验'
                facts = {'speed': speed, 'native60': row['能力来源'].startswith('游戏原生 60 帧'),
                         'date': row['日期'], 'rate': ' / '.join(format(v, 'g') for v in frames) + ' 帧'}
            elif path == ASPECT:
                if row['结论'] not in {'过', '不过', '未验'}:
                    raise ValueError(f'{path}:{line}: 未知结论')
                if row['平台'] not in PLATFORM_MAP or not re.fullmatch(r'(\d+(\.\d+)?(:\d+(\.\d+)?)?|窗口)', row['档位']):
                    raise ValueError(f'{path}:{line}: 未知平台或比例')
                facts = {'platform': PLATFORM_MAP[row['平台']], 'platformLabel': row['平台'],
                         'ratio': row['档位'], 'verdict': row['结论'], 'date': row['日期']}
            elif path == CAP:
                layers = {}
                for field in LAYERS:
                    match = LAYER_RE.fullmatch(row[field])
                    if not match:
                        raise ValueError(f'{path}:{line}: 能力枚举无效')
                    # 注释通过来源定位引用，不把任意自由文字复制到清单正文。
                    layers[field] = (match[1], match[2] or '')
                facts = {'layers': layers, 'reason': row['未达标原因']}
            elif path == INPUT:
                file, number = locations[line - 1] if line <= len(locations) and locations[line - 1][0] else (path, line)
                if row['项'] not in {'controller', 'rumble', 'gyro'} or row['静态'] not in {'引用', '未见', '未知'} or row['局内'] not in {'调用', '未调用', '未测'}:
                    raise ValueError(f'{file}:{number}: 输入能力项 / 静态 / 局内枚举无效')
                if not row['依据局'].strip():
                    raise ValueError(f'{file}:{number}: 输入能力缺依据局')
                facts = {'feature': row['项'], 'static': row['静态'], 'dynamic': row['局内'], 'date': row['日期']}
            elif path == DIRECT:
                if row['平台'] not in PLATFORM_MAP or row['直连能跑'] not in {'是', '否'} or row['进局'] not in {'是', '否'}:
                    raise ValueError(f'{path}:{line}: 未知平台或直连能跑 / 进局枚举无效')
                facts = {'platform': PLATFORM_MAP[row['平台']], 'platformLabel': row['平台'], 'runs': row['直连能跑'], 'entered': row['进局'], 'date': row['日期']}
            elif path == STRONG:
                if row['能力'] not in SIGNALS or row['信号'] not in SIGNALS[row['能力']]:
                    raise ValueError(f'{path}:{line}: 能力 / 信号不在强信号口径里')
                if not re.fullmatch(r'[0-9a-f]{16}', row['内容哈希']):
                    raise ValueError(f'{path}:{line}: 内容哈希要 16 位十六进制（caps_policy.py signal-hash）')
                facts = {'cap': row['能力'], 'signal': row['信号'], 'date': row['日期'], 'hash': row['内容哈希']}
                cur = (sources.get('__signal_hashes__') or {}).get(row['能力'])
                if cur and cur != row['内容哈希']: facts['stale'] = True   # 实现已改：强信号照旧生效、标待重新实测（出包 caps_policy.strong 同判，10-30）
            elif path == VERIFIED:
                if row['平台'] not in ('apple', 'android'):
                    raise ValueError(f'{path}:{line}: 平台要 apple / android（F7 #1574 平台列）')
                facts = {'date': row['登记日期'], 'vplatform': row['平台']}
            else:
                facts = {'date': row['登记日期']}
            src = (sources.get('__loc__') or {}).get(path)   # 按款登记表：合并文本第 line 行 → 按款文件与文件内行号（证据定位指真文件）
            f, fl = src[line - 1] if src and line <= len(src) and src[line - 1][0] else (path, line)
            g['rows'].append({'path': path, 'line': line, 'file': f, 'fline': fl, 'facts': facts})
    # 旧普查/LDN仅提供身份与来源，绝不成为八键验证依据。
    for path in (CENSUS, LDN):
        for line, raw in enumerate(sources[path].splitlines(), 1):
            if path == CENSUS:
                cells = [c.strip() for c in raw.strip().strip('|').split('|')]
                ids = [cells[1]] if raw.startswith('|') and len(cells) > 1 and TID.fullmatch(cells[1]) else []
            else:
                ids = re.findall(r'(?<![0-9A-F])[0-9A-F]{16}(?![0-9A-F])', raw)
            for tid in dict.fromkeys(ids):
                keys = [k for k in games if k[0] == tid]
                if not keys:
                    record(tid, None)
                    keys = [(tid, None)]
                for key in keys:
                    games[key]['rows'].append({'path': path, 'line': line, 'facts': {}})
    return games


def verification(values, positive, negative):
    states = set(values)
    if len(states) > 1:
        return 'conflicting'
    if states == {positive}:
        return 'verified'
    if states == {negative}:
        return 'failed'
    return 'unverified'


def finish_feature(feature):
    """三轴到展示的唯一规则；不在 Markdown / UI 再判。"""
    support, enabled, verified = (feature[k] for k in ('support', 'enabled', 'verification'))
    if verified == 'conflicting' or (support == 'unsupported' and (enabled == 'on' or verified == 'verified')):
        feature['verification'] = 'conflicting'
        feature['reason'] = '未验：证据冲突'
        display = feature['reason']
    elif support == 'unsupported':
        display = '不支持：' + feature['reason']
    elif enabled == 'off':
        display = '未开启'
    elif enabled == 'unknown':
        display = '未验：缺启用记录'
    elif verified == 'verified':
        display = '已开已验（仅登记平台 / 比例范围；非当前包实测）'
    elif verified == 'failed':
        display = '已开；' + feature['reason']
    else:
        display = '已开未验；' + feature['reason']
    feature['display'] = display
    return feature


def evidence_text(value, limit=80):
    """源表文字进展示（启动器 / 清单直接给玩家看，如「能耗超线：整机 W 中位 4.92(6) > 4.8」）。
    白名单字符：读数要用的数字、小数点、括号、比较号、时刻冒号都放行；路径 / 键值（/、=）不放行，整段换占位，
    避免本机路径、令牌随清单公开。超长截断。"""
    text = value.strip()
    if not re.fullmatch(r'[\w ，。；：、（）·%+\-!?！？.()<>:]*', text):
        return '内容见来源列（未复制非展示字段）'
    return text if len(text) <= limit else text[:limit - 1] + '…'


def release_defaults(rows, platform, bid, paths, evidence_ids):
    """发布取值政策（jhz 10-29 07:0x 全能力出包「默认开、强信号才关」，口径第 7 节）：两门控键缺省 1，只有强信号写 0。
    强信号：docs/名单_能力强信号/ 本款本构建本键一行，或 fps60 有逻辑速度红登记；「判不出」「没跑到」、满屏比例「不过」（宽屏没生效）都不是。
    能力卡只见仓内登记；「静态无来源」要看产物根，出包时由 tools/caps_policy.py 再判（同一份强信号口径）。不借此推广 verification。
    """
    fps_rows = [r for r in rows if r['path'] == FPS and platform == 'ios']
    cap_rows = [r for r in rows if r['path'] == CAP]
    wide_rows = [r for r in rows if r['path'] == ASPECT]
    vt = 'apple' if platform in ('ios', 'macos') else platform   # 苹果两平台同一实现域（verified 列值 apple）；安卓只认安卓登记行（F7 #1574：apple 行不放行安卓）
    wide_on = [r for r in rows if r['path'] == VERIFIED and r['facts'].get('vplatform') == vt]
    strong = {cap: [r for r in rows if r['path'] == STRONG and r['facts']['cap'] == cap] for cap in ('fps60', 'widen')}
    path = f'runtime/fps/{bid[:16]}.tsv' if bid else None
    def ids(records):
        return [f'{r.get("file", r["path"])}:{r.get("fline", r["line"])}' for r in records]
    speeds = {r['facts']['speed'] for r in fps_rows}
    state = verification(speeds, '绿', '红')
    # 所有覆盖行都一致才采用原生例外，重复矛盾不选最乐观值。
    native = bool(cap_rows) and all(all(r['facts']['layers'][k][0] == '不需要'
                  for k in LAYERS[:2]) for r in cap_rows) and path is not None and path not in paths
    sig = lambda rs: '强信号' + ('（过时·待重新实测）' if any(r['facts'].get('stale') for r in rs) else '') + '：' + '、'.join(sorted({r['facts']['signal'] for r in rs}))   # 过时的照旧关，读数标出来（10-30 (B)）
    if '红' in speeds:
        # #717 6467095707：实测失败优先于原生能力推断；红与绿并存也按红（逻辑速度红是强信号）
        fps_value, fps_reason = 0, '强信号：逻辑速度红'
    elif strong['fps60']:
        fps_value, fps_reason = 0, sig(strong['fps60'])
    else:
        fps_value = 1
        fps_reason = ('逻辑速度绿（仅 iOS 登记范围）' if state == 'verified' else '游戏原生 60 帧' if native else '默认开：无强信号；未验：缺逻辑速度判定')
        reasons = sorted({r['facts']['reason'].strip() for r in cap_rows if r['facts']['reason'].strip() not in ('', '—')})
        if state != 'verified' and not native and reasons:   # 能力覆盖表「未达标原因」只作文案（如能耗超线读数），不作状态
            fps_reason = '默认开：无强信号；未达标：' + '；'.join(evidence_text(reason) for reason in reasons)
    outcomes = {r['facts']['verdict'] for r in wide_rows}
    if strong['widen']:
        wide_value, wide_reason = 0, sig(strong['widen'])
    else:
        wide_value = 1
        wide_reason = ('已有满屏通过登记且无失败登记（发布策略；不推广平台 / 比例）' if wide_on and '过' in outcomes and '不过' not in outcomes else
                       '默认开：无强信号；满屏比例有不过登记（宽屏没生效，不是强信号）' if '不过' in outcomes else '默认开：无强信号；未验：缺满屏读数')
    fps_refs = ids(fps_rows + cap_rows + strong['fps60'])
    if path and 'tree:' + path in evidence_ids:
        fps_refs.append('tree:' + path)
    return {'fps60': {'value': fps_value, 'reason': fps_reason, 'evidenceRefs': fps_refs},
            'fullscreen': {'value': wide_value, 'reason': wide_reason,
                           'evidenceRefs': ids(wide_on + wide_rows + strong['widen'])}}


def build_model(sources, revision, fps_tables=None, requested_scopes=()):
    """仓内登记投影；packageDigest 永远 null，不代表当前产物运行验证。"""
    games = collect(sources, revision)
    requested_scopes = tuple(requested_scopes)
    paths = set(sources.get('__fps_tables__', ()) if fps_tables is None else fps_tables)
    if any(not isinstance(p, str) or not FPS_PATH.fullmatch(p) for p in paths):
        raise ValueError('帧率表树路径无效')
    for platform, ratio in requested_scopes:
        if platform not in {None, 'ios', 'macos'} or (ratio is not None and not re.fullmatch(r'(\d+(\.\d+)?(:\d+(\.\d+)?)?|窗口)', ratio)):
            raise ValueError('请求范围无效')
    cards = []
    for (tid, bid), game in sorted(games.items(), key=lambda item: (item[0][0], item[0][1] or '')):
        rows = game['rows']
        scopes = {(r['facts']['platform'], r['facts']['ratio']) for r in rows if r['path'] == ASPECT}
        if any(r['path'] == FPS for r in rows):
            scopes.add(('ios', None))
        scopes.update((r['facts']['platform'], None) for r in rows if r['path'] == DIRECT)
        if not scopes:
            scopes.add((None, None))
        scopes.update(requested_scopes)
        for platform, ratio in sorted(scopes, key=lambda s: (s[0] or '', s[1] or '')):
            identity = {'programId': tid, 'buildId': bid, 'targetPlatform': platform, 'packageDigest': None}
            card = {'identity': identity, 'scope': {'ratio': ratio}, 'name': game['name'],
                    'features': {}, 'fpsLayers': {k: [] for k in LAYERS}, 'evidence': [], 'history': []}
            refs = {}
            for row in rows:
                path, facts = row['path'], row['facts']
                scope = dict(identity, buildId=(None if path in (CENSUS, LDN) else bid),
                             targetPlatform=('ios' if path == FPS else facts.get('platform')), ratio=facts.get('ratio'))
                rid = f'{row.get("file", path)}:{row.get("fline", row["line"])}'
                refs[rid] = row
                card['evidence'].append({'id': rid, 'kind': ('capabilityRegister' if path == CAP else 'validatedRegister' if path in (FPS, ASPECT, DIRECT) else 'sourceText'),
                    'locator': {'revision': revision, 'path': row.get('file', path), 'line': row.get('fline', row['line'])}, 'scope': scope})
                if path == CAP:
                    for field, (status, annotation) in facts['layers'].items():
                        item = {'status': status, 'display': '未验：能力状态未知' if status == '未知' else status, 'evidenceRefs': [rid]}
                        card['fpsLayers'][field].append(item)
                        if annotation:
                            # 注释仅接受短展示文字；路径/控制符等只保留列定位，不透传原值。
                            card['evidence'].append({'id': rid + ':' + field, 'kind': 'sourceText',
                                'locator': {'revision': revision, 'path': row.get('file', path), 'line': row.get('fline', row['line']), 'column': field},
                                'scope': scope, 'annotation': evidence_text(annotation)})
            for key in FEATURES:
                card['features'][key] = {'support': 'unknown', 'enabled': 'unknown', 'verification': 'unverified',
                    'reason': '未验：缺启用记录', 'evidenceRefs': {'support': [], 'enabled': [], 'verification': []}}
            fps = card['features']['fps60']
            fps_rows = [(rid, r['facts']) for rid, r in refs.items() if r['path'] == FPS and platform == 'ios']
            native = [rid for rid, facts in fps_rows if facts['native60']]
            path = f'runtime/fps/{bid[:16]}.tsv' if bid else None
            fps['enabled'] = ('on' if native or path in paths else 'off') if bid else 'unknown'
            fps['support'] = 'supported' if native else 'unknown'
            fps['verification'] = verification([f['speed'] for _, f in fps_rows], '绿', '红')
            fps['reason'] = {'verified': '游戏原生 60 帧，无需帧率表' if native else '仅引用逻辑速度绿登记',
                             'failed': '验证失败：逻辑速度变快', 'unverified': '未验：缺逻辑速度判定',
                             'conflicting': '未验：证据冲突'}[fps['verification']]
            fps['evidenceRefs']['verification'] = [rid for rid, _ in fps_rows]
            fps['evidenceRefs']['support'] = native
            fps['evidenceRefs']['enabled'] = list(native)
            if path:
                eid = 'tree:' + path
                card['evidence'].append({'id': eid, 'kind': 'sourceText', 'locator': {'revision': revision, 'path': path},
                    'scope': dict(identity, targetPlatform=None, ratio=None), 'exists': path in paths})
                if not native:
                    fps['evidenceRefs']['enabled'].append(eid)
            # 直连（发布口径缺省只出直连）：普查直连实测有本平台行 = 这局走的是直连（启用）；直连能跑 是 / 否 = 验证过 / 失败。只认本平台，Mac 实测不代 iOS
            direct = card['features']['direct']
            drows = [(rid, r['facts']) for rid, r in refs.items() if r['path'] == DIRECT and r['facts']['platform'] == platform]
            if drows:
                direct['enabled'] = 'on'; direct['evidenceRefs']['enabled'] = [rid for rid, _ in drows]
                direct['verification'] = verification([f['runs'] for _, f in drows], '是', '否')
                direct['evidenceRefs']['verification'] = [rid for rid, _ in drows]
                direct['support'] = 'supported' if direct['verification'] == 'verified' else 'unknown'
                if direct['support'] == 'supported': direct['evidenceRefs']['support'] = [rid for rid, _ in drows]
                direct['reason'] = {'verified': '仅引用本平台普查直连实测（不崩，进局或出图 ≥ 1000 帧无致命红行）', 'failed': '验证失败：普查直连局崩溃或卡在致命红行',
                                    'unverified': '未验：缺直连实测', 'conflicting': '未验：证据冲突'}[direct['verification']]
            full = card['features']['fullscreen']
            full['evidenceRefs']['enabled'] = [rid for rid, r in refs.items() if r['path'] == VERIFIED]
            full['enabled'] = ('on' if full['evidenceRefs']['enabled'] else 'off') if bid else 'unknown'
            aspect_rows = [(rid, r['facts']) for rid, r in refs.items() if r['path'] == ASPECT and
                           r['facts']['platform'] == platform and r['facts']['ratio'] == ratio]
            full['verification'] = verification([f['verdict'] for _, f in aspect_rows], '过', '不过')
            full['reason'] = {'verified': '仅引用本平台本比例登记', 'failed': '验证失败：满屏比例不过',
                              'unverified': '未验：缺该比例满屏读数', 'conflicting': '未验：证据冲突'}[full['verification']]
            full['evidenceRefs']['verification'] = [rid for rid, _ in aspect_rows]
            # 全能力出包（jhz 10-29 07:0x）：fps60 / fullscreen 缺省 supported；只有强信号（docs/名单_能力强信号/、逻辑速度红）才 unsupported + 关。
            #   能力卡只见仓内登记，「静态无来源」要看产物根，由出包 tools/caps_policy.py 判，这里不推
            for key, cap in (('fps60', 'fps60'), ('fullscreen', 'widen')):
                feat = card['features'][key]
                hits = [rid for rid, r in refs.items() if r['path'] == STRONG and r['facts']['cap'] == cap]
                red = key == 'fps60' and feat['verification'] == 'failed'
                feat['support'] = 'unsupported' if hits or red else 'supported'
                feat['evidenceRefs']['support'] = hits + (feat['evidenceRefs']['verification'] if red else [])
                if bid and (hits or red): feat['enabled'] = 'off'   # 启用轴照旧按启用记录（能力卡看不到产物根，不冒称开）；强信号才强制关
                if hits and feat['verification'] != 'conflicting':
                    feat['reason'] = '强信号' + ('（过时·待重新实测）' if any(refs[h]['facts'].get('stale') for h in hits) else '') + '：' + '、'.join(sorted({refs[h]['facts']['signal'] for h in hits}))
            for key, label in (('controller', '手柄'), ('rumble', '震动'), ('gyro', '陀螺仪')):
                entries = [(rid, r['facts']) for rid, r in refs.items() if r['path'] == INPUT and r['facts']['feature'] == key]
                if not entries:
                    continue
                feature = card['features'][key]
                positive = [rid for rid, f in entries if f['static'] == '引用' or f['dynamic'] == '调用']
                feature['support'] = 'supported' if positive else 'unknown'
                feature['evidenceRefs']['support'] = positive
                reasons = []
                if any(f['static'] == '引用' for _, f in entries):
                    reasons.append('游戏声明引用' + label)
                if any(f['dynamic'] == '调用' for _, f in entries):
                    reasons.append('局内调用' + label + '（次数未登记）')
                    if any(f['static'] == '未见' for _, f in entries):
                        reasons.append('证据冲突：静态完整未见与局内调用并存')
                if not positive:
                    reasons.append('支持未知：未见引用或调用不等于不支持')
                # 表中没有平台 / 当前包启用记录，调用也不等于设备体感验证。
                feature['reason'] = '；'.join(reasons + ['设备体感未验'])
            for key, feature in card['features'].items():
                finish_feature(feature)
                if key in ('controller', 'rumble', 'gyro') and feature['reason'] != '未验：缺启用记录':
                    feature['display'] += '；' + feature['reason']
            # 历史事实作为同一模型的一部分保留；渲染不再次解释源表。
            for rid, row in refs.items():
                facts = row['facts']
                if row['path'] == FPS and platform == 'ios':
                    label = {'verified': '60帧达标登记（逻辑速度绿；仅来源登记范围）',
                             'failed': '验证失败：逻辑速度变快', 'unverified': fps['reason'],
                             'conflicting': '未验：证据冲突'}[fps['verification']]
                    if facts['speed'] == '判不出' and fps['verification'] == 'unverified':
                        label += '；未验：逻辑速度判不出'
                    text = label + ' / ' + facts['rate'] + ' / ' + facts['date'] + '；机型未记载'
                elif row['path'] == ASPECT:
                    text = facts['platformLabel'] + ' / ' + facts['ratio'] + '：' + facts['verdict'] + '（' + facts['date'] + '）'
                elif row['path'] == VERIFIED:
                    text = '宽屏启用登记（' + facts['date'] + '；未验：缺逐比例验证）'
                else:
                    continue
                card['history'].append({'text': text, 'evidenceRefs': [rid]})
            card['releaseDefaults'] = release_defaults(rows, platform, bid, paths, {e['id'] for e in card['evidence']})
            cards.append(card)
    return {'schema': 's2a.capability-card.v1', 'sourceRevision': revision, 'cards': cards,
            'releases': release_view(cards)}


def release_view(cards):
    """一包一值：每个（程序号, 构建号）给 iOS、macOS 各一条，出包 pack/gen_caps.sh 只读这里。
    取该平台各比例卡的 releaseDefaults；该平台没有专属卡时取平台未记载的卡（那张卡没有平台限定的
    逻辑速度 / 满屏读数，只会给出关或「游戏原生 60 帧」，不会借出平台验证）。
    同一包各卡给出的值不一致时取 0、原因「未验：证据冲突」，不选乐观值。"""
    groups = {}
    for card in cards:
        identity = card['identity']
        if not identity['buildId']:
            continue
        g = groups.setdefault((identity['programId'], identity['buildId']), {'name': card['name'], 'cards': {}})
        g['cards'].setdefault(identity['targetPlatform'], []).append(card['releaseDefaults'])
    out = []
    for (pid, bid), g in sorted(groups.items()):
        for platform in ('ios', 'macos'):
            defaults = g['cards'].get(platform) or g['cards'].get(None)
            if not defaults:
                continue
            entry = {'programId': pid, 'buildId': bid, 'targetPlatform': platform, 'name': g['name']}
            for key in ('fps60', 'fullscreen'):
                values = {(d[key]['value'], d[key]['reason']) for d in defaults}
                value, reason = values.pop() if len(values) == 1 else (0, '未验：证据冲突')
                refs = sorted({ref for d in defaults for ref in d[key]['evidenceRefs']})
                entry[key] = {'value': value, 'reason': reason, 'evidenceRefs': refs}
            out.append(entry)
    return out


def render_evidence(model):
    """仅显示模型既定状态；与 JSON 共用唯一判据，不从来源重新推导。"""
    out = ['# 兼容性清单（仓内证据能力卡）', '', '来源提交：' + model['sourceRevision'],
           '仅登记范围的引用，非本方新实测、非当前包验证；packageDigest 均未记载。',
           '缺真机证据时：未验：无真机局；联机暂无结构化记录：未验：无实机联机局。',
           '按程序号＋构建号＋平台＋比例分行。冲突记录保留，不合并结论；缺身份不当通配符。', '',
           '| 款 / 程序号 | 构建号 | 平台 / 比例 | 直连 | 满屏 | 60帧 | 联机 / 手柄 / 震动 / 陀螺仪 / 快捷菜单 | 能力：来源文字（非实测） | 来源 |',
           '|---|---|---|---|---|---|---|---|---|']
    for card in model['cards']:
        identity, features = card['identity'], card['features']
        layers = ['%s：%s' % (key, item['display']) for key, items in card['fpsLayers'].items() for item in items]
        links = []
        for ev in card['evidence']:
            loc = ev['locator']
            url = 'https://github.com/jhaizhou-ops/S2Arm/blob/' + loc['revision'] + '/' + quote(loc['path'])
            if 'line' in loc:
                url += '#L' + str(loc['line'])
            # 不存在的树路径指向固定目录；不造一个失效文件链接。
            if ev.get('exists') is False:
                url = url.rsplit('/', 1)[0]
            links.append('[来源](' + url + ')')
        vals = [card['name'] + ' / ' + identity['programId'], identity['buildId'] or '未记载',
                (identity['targetPlatform'] or '未记载') + ' / ' + (card['scope']['ratio'] or '未记载'),
                features['direct']['display'], features['fullscreen']['display'] + '；' + features['fullscreen']['reason'], features['fps60']['display'] + '；' + features['fps60']['reason'],
                '；'.join(features[k]['display'] for k in FEATURES[3:]), '；'.join(layers) or '未验：无能力登记',
                '；'.join(h['text'] for h in card['history']) + '；' + '；'.join(sorted(set(links)))]
        out.append('| ' + ' | '.join(vals) + ' |')
    out.extend(['', '未解析日志或下载来源链接；静态普查/LDN文字、接口和单测不是游戏实测。', ''])
    return '\n'.join(out)


TITLES = 'pack/oneclick/titles.tsv'
NAMES = 'pack/display_names.tsv'
WORDING = 'docs/能力原因_玩家文案.tsv'
ACCEPTANCE = 'docs/发布验收.tsv'
PLAYER_SOURCES = (TITLES, NAMES, WORDING, ACCEPTANCE)
ALL_SOURCES = tuple(reglist.dir_of(reglist.name_of(p)) if reglist.name_of(p) else p for p in SOURCES) + ('runtime/fps',) + PLAYER_SOURCES + tuple(sorted({n for v in SIGNAL_IMPL['apple'].values() for n in v}))   # 强信号失效键的文件改了，能力卡也要重出（能力卡是苹果口径，取 apple 域）
ACCEPTANCE_HEADER = '程序号 构建号 款 平台 机型 包提交 包哈希 包身份 进局 崩溃报红 帧率 能耗 首局卡顿 画面 能力比对 逻辑速度 存档往返 外设 玩家路径 能玩 jhz看过 日期 依据'.split()
PLAYER_FEATURES = ('direct', 'controller', 'rumble', 'gyro', 'online')


def fixed_rows(text, path, header=None, width=None):
    rows = []
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.startswith('#'):
            continue
        cells = raw.split('\t')
        if header is not None and not rows:
            if cells != header:
                raise ValueError(f'{path}:{number}: 表头不匹配')
        elif len(cells) != (len(header) if header is not None else width):
            raise ValueError(f'{path}:{number}: 列数不匹配')
        rows.append(cells)
    if header is not None:
        if not rows:
            raise ValueError(f'{path}: 缺少表头')
        return [dict(zip(header, row)) for row in rows[1:]]
    return rows


def player_copy(text):
    rows = fixed_rows(text, WORDING, ['键', '匹配', '玩家文案'])
    keys = {}
    for row in rows:
        if (not all(row.values()) or row['键'] in keys or
                re.search(r'逻辑速度|登记|证据|来源列|构建号|MARK', row['玩家文案'])):
            raise ValueError(f'{WORDING}: 无效或重复文案键 {row["键"]}')
        keys[row['键']] = row
    for required in ('无平台登记', '证据冲突'):
        if required not in keys:
            raise ValueError(f'{WORDING}: 缺少 {required}')

    def translate(reason):
        matches = [row for row in rows if reason.startswith(row['匹配'])]
        if len(matches) != 1:
            raise ValueError(f'{WORDING}: 原因应恰好命中一条文案（实际 {len(matches)}）：{reason}')
        return matches[0]['玩家文案']
    return translate, {key: row['玩家文案'] for key, row in keys.items()}


def acceptance_rows(text):
    latest = {}
    for row in fixed_rows(text, ACCEPTANCE, ACCEPTANCE_HEADER):
        if not TID.fullmatch(row['程序号']) or not BID.fullmatch(row['构建号']):
            raise ValueError(f'{ACCEPTANCE}: 程序号/构建号格式错误')
        if row['平台'] not in ('ios', 'macos') or row['能玩'] not in ('过', '不过', '未验'):
            raise ValueError(f'{ACCEPTANCE}: 平台或能玩枚举无效')
        checks = [row[key] for key in ACCEPTANCE_HEADER[7:19]]
        if any(value not in ('过', '不过', '未验', '不适用') for value in checks):
            raise ValueError(f'{ACCEPTANCE}: 验收项枚举无效')
        if not row['日期']:
            raise ValueError(f'{ACCEPTANCE}: 日期必填')
        for field in ('jhz看过', '日期'):
            value = row[field]
            if value:
                if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
                    raise ValueError(f'{ACCEPTANCE}: {field}无效')
                datetime.date.fromisoformat(value)
        if row['能玩'] == '过' and (any(v not in ('过', '不适用') for v in checks) or not row['jhz看过']):
            raise ValueError(f'{ACCEPTANCE}: 能玩=过须全项通过且 jhz看过')
        key = (row['程序号'], row['构建号'], row['平台'])
        # 同日并列保持文件中第一行；不按能玩值择优。
        if key not in latest or row['日期'] > latest[key]['日期']:
            latest[key] = row
    return latest


def player_model(model, texts):
    """仅投影 build_model 已算出的发布值/各卡 display，不重新解释能力源表。"""
    translate, special = player_copy(texts[WORDING])
    acceptance = acceptance_rows(texts[ACCEPTANCE])
    names = dict(fixed_rows(texts[NAMES], NAMES, width=2))
    titles = fixed_rows(texts[TITLES], TITLES, width=2)
    if len({pid for pid, _ in titles}) != len(titles) or any(not TID.fullmatch(pid) for pid, _ in titles):
        raise ValueError(f'{TITLES}: 程序号无效或重复')
    # 校验所有现存 reason/display，包括不在出包名单的卡，避免静默忽略新原因类型。
    for release in model['releases']:
        for key in ('fps60', 'fullscreen'):
            translate(release[key]['reason'])
    for card in model['cards']:
        for feature in card['features'].values():
            translate(feature['display'])
    releases = {(r['programId'], r['buildId'], r['targetPlatform']): r for r in model['releases']}
    player = []
    for pid, title in titles:
        bids = sorted({r['buildId'] for r in model['releases'] if r['programId'] == pid}) or [None]
        builds = []
        for bid in bids:
            build = {'buildId': bid, 'playable': {}, 'fps60': {}, 'fullscreen': {}, 'features': {}, 'verification': {}}
            for platform in ('ios', 'macos'):
                release = releases.get((pid, bid, platform))
                for key in ('fps60', 'fullscreen'):
                    build[key][platform] = ('开' if release and release[key]['value'] == 1 else
                        '关（' + (translate(release[key]['reason']) if release else special['无平台登记']) + '）')
                checked = acceptance.get((pid, bid, platform))
                build['playable'][platform] = {'过': '能玩', '不过': '不能玩', '未验': '还没验收'}[checked['能玩']] if checked else '还没验收'
                build['verification'][platform] = (checked['日期'] or '—') + ' / ' + (checked['包提交'][:9] or '—') if checked else '—'
            cards = [c for c in model['cards'] if (c['identity']['programId'], c['identity']['buildId']) == (pid, bid)]
            for key in PLAYER_FEATURES:
                displays = {c['features'][key]['display'] for c in cards}
                build['features'][key] = (translate(next(iter(displays))) if len(displays) == 1 else
                    special['证据冲突'] if displays else special['无平台登记'])
            builds.append(build)
        player.append({'programId': pid, 'title': title, 'name': names.get(title, title), 'builds': builds})
    return dict(model, player=player)


def render_model(model):
    """渲染已准备的 player 和能力模型；不读取或重新推导源表。"""
    out = ['# 兼容性清单', '', '下表列出出包名单中的游戏；开关状态不等于能玩，未完成验收会明确标出。', '',
           '| 游戏 | 能玩（iPhone / Mac） | 60 帧（iPhone / Mac） | 满屏（iPhone / Mac） | 直连 | 手柄 / 震动 / 陀螺仪 | 联机 | 验证日期 / 包版本 |',
           '|---|---|---|---|---|---|---|---|']
    def escape(value):
        return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('|', '&#124;').replace('\n', ' ')
    for row in model.get('player', []):
        values = [[] for _ in range(7)]
        for build in row['builds']:
            prefix = ((build['buildId'] or '未知版本')[:8] + '：') if len(row['builds']) > 1 else ''
            def both(key):
                ios, mac = build[key]['ios'], build[key]['macos']
                if key != 'verification' and ios == mac:
                    return ios
                return 'iPhone ' + ios + ' / Mac ' + mac
            peripherals = [build['features'][key] for key in ('controller', 'rumble', 'gyro')]
            peripheral_text = peripherals[0] if len(set(peripherals)) == 1 else ' / '.join(peripherals)
            cells = [both('playable'), both('fps60'), both('fullscreen'), build['features']['direct'],
                     peripheral_text, build['features']['online'], both('verification')]
            for column, value in zip(values, cells):
                column.append(escape(prefix + value))
        out.append('| ' + ' | '.join([escape(row['name'])] + ['<br>'.join(column) for column in values]) + ' |')
    out.extend(['', '## 附录：证据索引', '', '源表最后改动提交：' + model['sourceRevision'], ''])
    # 原逐卡表及注记逐字保留，只调整标题/提交标签和所在位置。
    out.extend(render_evidence(model).splitlines()[3:])
    return '\n'.join(out) + '\n'


def read_player_sources(repo, revision):
    texts = {}
    for path in PLAYER_SOURCES:
        entry = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', revision, '--', path],stderr=subprocess.DEVNULL, text=True)
        if not entry.startswith('100644 blob '):
            raise ValueError(f'{path}: 不是普通跟踪文件')
        texts[path] = subprocess.check_output(['git', '-C', str(repo), 'show', revision + ':' + path],stderr=subprocess.DEVNULL).decode('utf-8')
    return texts


def source_revision(repo, revision, sources=None):
    paths = ALL_SOURCES
    # 空输入表（含首次增加空 schema）不是新证据，不能仅因此重写旧清单提交号。
    input_lines = [line for line in (sources or {}).get(INPUT, '').splitlines() if line.strip() and not line.startswith('#')]
    has_input = sources is None or len(input_lines) > 1
    if not has_input:
        paths = tuple(p for p in paths if p != reglist.dir_of(reglist.name_of(INPUT)))
    return subprocess.check_output(['git', '-C', str(repo), 'log', '-1', '--format=%H', revision, '--', *paths],stderr=subprocess.DEVNULL, text=True).strip()


def render(sources, revision):
    return render_model(build_model(sources, revision))

def load(repo, revision):
    full=subprocess.check_output(['git','-C',str(repo),'rev-parse','--verify','--end-of-options',revision+'^{commit}'],stderr=subprocess.DEVNULL,text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}',full):raise ValueError('提交身份错误')
    sources={}
    def show(n):
        try: return subprocess.check_output(['git', '-C', str(repo), 'show', full + ':' + n], stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError: return None
    def ls(d):   # 按款登记目录的文件（-z：中文路径不转义）；每个都必须是普通跟踪文件（符号链接 / 子模块拒收，同单文件来源的口径）
        out = []
        for e in subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-r', '-z', full, '--', d + '/'], stderr=subprocess.DEVNULL, text=True).split('\0'):
            if not e: continue
            meta, path = e.split('\t', 1)
            if not meta.startswith('100644 blob '): raise ValueError(f'{path}: 不是普通跟踪文件')
            out.append(path)
        return out
    for path in SOURCES:
        n = reglist.name_of(path)
        if n:   # 按款登记表（10-30）：按本提交列目录、合并读，定位表另存
            sources[path], sources.setdefault('__loc__', {})[path] = reglist.read_at(show, ls, n)
            if path == INPUT:
                sources['__loc__'][path] = [(file or f'{reglist.dir_of(n)}/{reglist.HEAD}', line) for file, line in sources['__loc__'][path]]
                if not sources[path] and ls(reglist.dir_of(n)):
                    raise ValueError(f'{reglist.dir_of(n)}/{reglist.HEAD}:1: 缺少表头')
            if not sources[path] and path != INPUT: raise ValueError(f'{reglist.dir_of(n)}: 不是按款登记目录')
            continue
        entry=subprocess.check_output(['git','-C',str(repo),'ls-tree',full,'--',path],stderr=subprocess.DEVNULL,text=True)
        if not entry.startswith('100644 blob '):raise ValueError(f'{path}: 不是普通跟踪文件')
        sources[path]=subprocess.check_output(['git','-C',str(repo),'show',full+':'+path],stderr=subprocess.DEVNULL).decode('utf-8')
    entries = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-rz', full, '--', 'runtime/fps'],stderr=subprocess.DEVNULL, text=True)
    fps_tables = []
    for entry in entries.split('\0'):
        if not entry:
            continue
        metadata, path = entry.split('\t', 1)
        if not FPS_PATH.fullmatch(path):
            raise ValueError('帧率表树路径无效')
        if not metadata.startswith('100644 blob '):
            raise ValueError('帧率表不是普通跟踪文件')
        fps_tables.append(path)
    sources['__fps_tables__'] = tuple(sorted(fps_tables))
    # 强信号失效键：同出包（tools/caps_policy.py signal_hashes）一份文件清单、按本提交读，过时的强信号能力卡也不认，与包里清单一致
    def at_rev(n):
        try: return subprocess.check_output(['git', '-C', str(repo), 'show', full + ':' + n], stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError: return None
    sources['__signal_hashes__'] = signal_hashes(at_rev)
    return sources,full


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo',required=True);p.add_argument('--revision',required=True);p.add_argument('--output',required=True)
    p.add_argument('--format', choices=('markdown', 'json'), default='markdown')
    p.add_argument('--check', help='与重新生成的内容逐字节比较')
    a=p.parse_args()
    try:
        sources,revision=load(a.repo,a.revision)
        texts=read_player_sources(a.repo,revision)
        revision=source_revision(a.repo,revision,sources)
        model=player_model(build_model(sources,revision),texts)
        result=render_model(model) if a.format=='markdown' else json.dumps(model, ensure_ascii=False, sort_keys=True, indent=2)+'\n'
        if a.check:
            with open(a.check,'rb') as f:existing=f.read()
            expected=result.encode('utf-8')
            if existing != expected:
                limit=min(len(existing),len(expected))
                offset=next((i for i in range(limit) if existing[i] != expected[i]),limit)
                line=expected[:offset].count(b'\n')+1
                print(f'兼容性清单不一致：第一处差异行 {line}',file=sys.stderr)
                return 1
        with open(a.output,'w',encoding='utf-8',newline='\n') as f:f.write(result)
    except (OSError,subprocess.CalledProcessError,UnicodeError) as e:
        print('兼容表生成失败（'+type(e).__name__+'）：无法读取来源或写出结果，请检查输入与输出。',file=sys.stderr);return 1
    except ValueError as e:
        print('兼容表生成失败（'+type(e).__name__+'）：'+str(e),file=sys.stderr);return 1
    return 0

if __name__=='__main__':raise SystemExit(main())
