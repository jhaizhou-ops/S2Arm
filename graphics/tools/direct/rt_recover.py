#!/usr/bin/env python3
"""#281 R2-a: inventory local runtime shaders; never alter or rebuild a library.

See rt_recover.md for the host-log library stamp contract and exit codes.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

from merge_extract import STAGE_WORD, ctl_len, nx_key, records, split_rec

KEY = re.compile(r'[0-9a-f]{16}')
CHAIN = re.compile(r'[0-9a-f]{12}')
STAGES = {**{s: s for s in STAGE_WORD}, **{w: s for s, w in STAGE_WORD.items()}}
TABLES = ('game.tsv', 'shader_facts.tsv', 'shader_pairs.tsv', 'shader_map.tsv',
          'shader_map.tsv.conflicts.tsv', 'bf_want.tsv', 'ps_inputs.tsv')
REPO = Path(__file__).resolve().parents[3]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    value = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(value, dict):
        raise ValueError('JSON 顶层必须为对象')
    return value


def current_chain(header):
    matches = re.findall(r'^#define\s+DMSH_CHAIN\s+"([0-9a-f]{12})"\s*$',
                         header.read_text(), re.MULTILINE)
    if len(matches) != 1:
        raise ValueError('当前链头缺失或有歧义')
    return matches[0]


def log_evidence(path):
    if path is None:
        return {'provided': False, 'complete': False, 'events': {}, 'stamps': [], 'stamp_line_count': 0}
    lines = path.read_text(errors='replace').splitlines()
    events, seq = {}, []
    for line in lines:
        m = re.search(r'直连着色器现编 (\d+) 次：([0-9a-f]{16})（([^，]+)，', line)
        if m:
            n, key, stage = m.groups()
            seq.append(int(n))
            events.setdefault(key, []).append(STAGES.get(stage, stage))
    summaries = [re.search(r'直连着色器现编汇总：成功 (\d+)、失败 (\d+)、跳过 (\d+)、复用上局 (\d+)、输出类型变体 (\d+)（([^）]+)）', line)
                 for line in lines]
    summaries = [m for m in summaries if m]
    complete = (len(summaries) == 1 and summaries[0][6] == '正常收局'
                and seq == list(range(1, int(summaries[0][1]) + 1)))
    stamp_lines = [line for line in lines if 'shader library stamp:' in line]
    stamps = []
    for line in stamp_lines:
        match = re.search(r'shader library stamp: game ([0-9a-fA-F]{16}), inputs ([0-9a-f]{12})\s*$', line)
        if match:
            stamps.append(list(match.groups()))
    return {'provided': True, 'complete': complete, 'events': events,
            'summary_count': len(summaries), 'stamps': stamps,
            'stamp_line_count': len(stamp_lines)}



def raw_index(cache):
    index = {}
    for line in (cache / 'work/merged/shader_map.tsv').read_text().splitlines():
        c = line.split('\t')
        if not line or line.startswith('#') or c[0] == 'package':
            continue
        if len(c) < 5:
            raise ValueError('shader_map.tsv 行不完整')
        index.setdefault(c[3], []).append(c)
    return index


def raw_record(cache, key, stage, index, packages):
    merged = cache / 'work/merged'
    locations = index.get(key, [])
    if not locations:
        raise ValueError('并集中有键，映射表没有对应原料位置')
    found = []
    for c in locations:
        name, index, word = c[:3]
        if Path(name).name != name or not name.endswith('.bin') or not index.isdecimal():
            raise ValueError('原料位置不合法')
        if STAGES.get(word) != stage:
            raise ValueError('原料阶段与运行时阶段不符')
        package = merged / 'pkg' / name
        if package.is_symlink():
            raise ValueError('原料包不能为软链')
        if package not in packages:
            packages[package] = records(package.read_bytes())
        data = packages[package]
        if int(index) >= len(data):
            raise ValueError('原料记录序号越界')
        record = data[int(index)]
        if len(record) < 0x38:
            raise ValueError('原料记录头被截短')
        code, control = split_rec(record)
        if not code or len(record) != 0x38 + len(code) + len(control):
            raise ValueError('原料记录长度不符')
        if len(control) < 0x24 or len(control) < ctl_len(control):
            raise ValueError('控制段不足键口径要求的长度')
        if nx_key(control, code) != key:
            raise ValueError('原料重算键不符')
        found.append((code, control))
    if any(value != found[0] for value in found[1:]):
        raise ValueError('同键原料冲突')
    return found[0]


def library_built(lib, key, stage, chain):
    binary = lib / (key + '_b.metallib')
    if not binary.is_file() or not binary.stat().st_size:
        return False
    meta = read_json(lib / (key + '_b.json'))
    return (meta.get('key') == key + '_b' and meta.get('chain') == chain
            and STAGES.get(meta.get('stage')) == stage)


def table_stamp_ok(tables, lib):
    """Reuse the actual offline chain's inputs() contract, including profile rows."""
    spec = importlib.util.spec_from_file_location('_rt_chain', REPO / 'translator/dmsh_chain.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    game_spec = importlib.util.spec_from_file_location('_rt_game', REPO / 'graphics/nvn/games/game.py')
    game_mod = importlib.util.module_from_spec(game_spec)
    game_spec.loader.exec_module(game_mod)
    profile = game_mod.Game(tables)
    stamp = dict(line.split('\t', 1) for line in (lib / mod.STAMP).read_text().splitlines()
                 if '\t' in line and not line.startswith('#'))
    if not re.fullmatch(r'[0-9a-fA-F]{16}', stamp.get('game', '')):
        raise ValueError('离线库缺有效程序号戳')
    if stamp.get('inputs') != mod.inputs(profile):
        raise ValueError('离线库输入戳与当前表不符')
    return [stamp['game'].lower(), stamp['inputs']]


def compare(key, stage, fallback, lib, tables, log, context):
    """Bind context to the runtime's existing library stamp, then compare bytes."""
    if not log['provided'] or log['stamp_line_count'] != 1 or len(log['stamps']) != 1:
        raise ValueError('单局日志缺唯一有效库输入戳')
    if 'stamp' not in context:
        stamp = table_stamp_ok(tables, lib)
        for name in TABLES:
            if not (tables / name).is_file():
                raise ValueError('事实表、配对表或片元输入缺失：' + name)
        pattern = re.compile(r'([0-9a-f]{16})_(?:b|bg\d+|bgv)\.metal')
        offline_index = {}
        for path in lib.iterdir():
            match = pattern.fullmatch(path.name)
            if match:
                offline_index.setdefault(match[1], {})[path.name] = path
        context.update(stamp=stamp, offline=offline_index)
    game, inputs = log['stamps'][0]
    if [game.lower(), inputs] != context['stamp']:
        raise ValueError('单局库输入戳的程序号或输入指纹与离线库不符')
    # Geometry can emit several entries; checking just _b.metal would miss changes.
    pattern = re.compile(re.escape(key) + r'_(?:b|bg\d+|bgv)\.metal')
    runtime = {p.name: p for p in fallback.iterdir() if pattern.fullmatch(p.name)}
    offline = context['offline'].get(key, {})
    if not runtime or key + '_b.metal' not in runtime or set(runtime) != set(offline):
        raise ValueError('MSL 产物集合不完整')
    if any(not p.is_file() or p.is_symlink() or not p.stat().st_size for p in runtime.values()):
        raise ValueError('运行时 MSL 缺失、为空或为软链')
    if stage == 'vs':
        for line in (tables / 'shader_pairs.tsv').read_text().splitlines():
            c = line.split()
            if not c or line.startswith('#') or c[0] != key:
                continue
            if len(c) < 2 or not KEY.fullmatch(c[1]):
                raise ValueError('配对上下文坏行')
            name = c[1] + '_b.metal'
            a, b = fallback / name, lib / name
            if (not a.is_file() or not b.is_file()
                    or a.read_bytes() != b.read_bytes()):
                raise ValueError('配对片元 MSL 上下文不齐或不同')
    for n, p in offline.items():
        if not p.is_file() or p.is_symlink() or not p.stat().st_size:
            raise ValueError('离线 MSL 缺失')
    return 'same' if all(runtime[n].read_bytes() == p.read_bytes() for n, p in offline.items()) else 'diff'


def recover(dirs, cache, library, tables, header, host_log=None):
    chain = current_chain(header)
    lib = library / ('b-' + chain)
    counts, issues, detail, candidates = Counter(), [], {}, {}
    log = log_evidence(host_log)
    if log['provided'] and not log['complete']:
        counts['log_incomplete'] += 1
    for directory in dirs:
        if not directory.is_dir():
            issues.append({'path': str(directory), 'reason': '兜底目录不存在'})
            counts['invalid'] += 1
            continue
        for source in directory.glob('*_b.metal'):
            if KEY.fullmatch(source.name[:-8]) and not (directory / (source.name[:-6] + '.json')).is_file():
                counts['invalid'] += 1
                issues.append({'path': str(source), 'reason': 'MSL 缺对应反射 JSON'})
        for path in sorted(directory.glob('*_b.json')):
            key = path.name[:-7]
            try:
                if not KEY.fullmatch(key) or path.is_symlink():
                    raise ValueError('文件名键不合法或为软链')
                meta = read_json(path)
                stage, have = STAGES.get(meta.get('stage')), meta.get('chain')
                if meta.get('key') != key + '_b' or stage is None or not isinstance(have, str) or not CHAIN.fullmatch(have):
                    raise ValueError('键、阶段或链版本不合法')
                value = {'key': key, 'stage': stage, 'chain': have, 'directory': directory,
                         'meta': meta, 'comparison': 'n/a'}
                # Old chains are counted without reading their source or treating it as current.
                if have != chain:
                    counts['chain_skip_entries'] += 1
                else:
                    source = directory / (key + '_b.metal')
                    if source.is_symlink() or not source.is_file() or not source.stat().st_size:
                        raise ValueError('现编 MSL 缺失、为空或为软链')
                    pattern = re.compile(re.escape(key) + r'_(?:b|bg\d+|bgv)\.metal')
                    artifacts = [p for p in directory.iterdir() if pattern.fullmatch(p.name)]
                    if any(p.is_symlink() or not p.is_file() or not p.stat().st_size for p in artifacts):
                        raise ValueError('现编产物集合有缺失或软链')
                    value['msl_sha256'] = {p.name: sha(p.read_bytes()) for p in artifacts}
                old = candidates.get(key)
                if old is not None:
                    if old['chain'] == chain and have != chain:
                        continue
                    if old['chain'] != chain and have == chain:
                        candidates[key] = value
                        continue
                    if (old['chain'], old['stage'], old['meta'], old.get('msl_sha256')) != (have, stage, meta, value.get('msl_sha256')):
                        old['conflict'] = True
                        counts['duplicate_conflict'] += 1
                    else:
                        counts['duplicate'] += 1
                    continue
                candidates[key] = value
            except (OSError, ValueError, TypeError) as exc:
                counts['invalid'] += 1
                issues.append({'path': str(path), 'reason': str(exc)})
    union = set()
    needs_cache = any(v['chain'] == chain for v in candidates.values())
    union_lines = (cache / 'work/merged/union_keys.tsv').read_text().splitlines() if needs_cache else []
    for line in union_lines:
        if not line or line.startswith('#'):
            continue
        if not KEY.fullmatch(line):
            raise ValueError('并集清单有不合法键，不能据此判抽取缺口')
        union.add(line)
    index, packages, context = raw_index(cache) if needs_cache else {}, {}, {}
    rows = []
    for key, value in sorted(candidates.items()):
        stage, have, directory = value['stage'], value['chain'], value['directory']
        reason = ''
        if have != chain:
            kind = 'chain_skip'
        elif key not in union:
            kind = 'extract_gap'
            reason = '并集清单没有本键；交 WP8'
        else:
            try:
                kind = 'lib_miss' if library_built(lib, key, stage, chain) else 'build_fail'
            except (OSError, ValueError, TypeError):
                kind = 'build_fail'
            if kind == 'build_fail':
                build = cache / 'work/build.log'
                lines = build.read_text(errors='replace').splitlines() if build.is_file() else []
                reason = next((s[:300] for s in lines if key in s), 'build.log 没有本键原因或日志缺失；需维护线核对')
            try:
                raw = raw_record(cache, key, stage, index, packages)
            except (OSError, ValueError, TypeError, IndexError) as exc:
                counts['invalid'] += 1
                value['comparison_reason'] = '原料无效：' + str(exc)
            else:
                try:
                    if value.get('conflict'):
                        raise ValueError('同键兜底产物冲突')
                    if log['provided'] and (not log['complete'] or stage not in log['events'].get(key, [])):
                        raise ValueError('单局日志不完整或未关联本键成功现编')
                    value['comparison'] = compare(key, stage, directory, lib, tables, log, context)
                except (OSError, ValueError, TypeError, AttributeError, IndexError, KeyError) as exc:
                    value['comparison_reason'] = str(exc)
        if value.get('conflict'):
            counts['invalid'] += 1
            value['comparison_reason'] = '同键兜底产物冲突'
            value['comparison'] = 'n/a'
        counts[kind] += 1
        counts[value['comparison']] += 1
        rows.append([key, stage, have, kind, value['comparison']])
        detail[key] = {'classification_reason': reason,
                       'comparison_reason': value.get('comparison_reason', ''),
                       'log_events': log['events'].get(key, []), 'directory': str(directory)}
    # A classification is useful even when a comparison remains unverified.
    incomplete = bool(counts['n/a'] - counts['chain_skip'] or counts['log_incomplete'] or not rows)
    exit_code = 1 if counts['invalid'] or counts['diff'] else 2 if incomplete else 0
    return {'chain': chain, 'rows': rows, 'counts': dict(counts), 'issues': issues,
            'detail': detail, 'log': log, 'exit_code': exit_code}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fallback', type=Path, action='append', required=True)
    parser.add_argument('--direct-cache', type=Path, required=True)
    parser.add_argument('--library', type=Path, help='含 b-<链> 的离线库目录；缺省 <cache>/mac')
    parser.add_argument('--tables', type=Path, required=True)
    parser.add_argument('--chain-header', type=Path, default=REPO / 'graphics/nvn/gfx/nvn/dmsh_chain.h')
    parser.add_argument('--host-log', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    inputs = [*args.fallback, args.direct_cache, args.library or args.direct_cache / 'mac', args.tables]
    if any(args.out.resolve().is_relative_to(path.resolve()) for path in inputs):
        print('【红】rt_recover：输出目录不能位于输入目录内', file=sys.stderr)
        return 1
    if args.out.exists() and (not args.out.is_dir() or any(args.out.iterdir())):
        print('【红】rt_recover：输出目录必须是新目录或空目录', file=sys.stderr)
        return 1
    try:
        result = recover(args.fallback, args.direct_cache, args.library or args.direct_cache / 'mac',
                         args.tables, args.chain_header, args.host_log)
    except (OSError, ValueError, TypeError) as exc:
        print('【红】rt_recover：' + str(exc), file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    lines = ['# key\tstage\tchain\tclassification\tcomparison\n']
    lines += ['\t'.join(row) + '\n' for row in result['rows']]
    lines.append('# summary ' + json.dumps(result['counts'], sort_keys=True) + '\n')
    for name, content in [('rt_recover.tsv', ''.join(lines)),
                          ('rt_recover.json', json.dumps(result, ensure_ascii=False, indent=2) + '\n')]:
        tmp = args.out / (name + '.tmp')
        tmp.write_text(content, encoding='utf-8')
        tmp.replace(args.out / name)
    print('rt_recover：' + json.dumps(result['counts'], ensure_ascii=False, sort_keys=True))
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
