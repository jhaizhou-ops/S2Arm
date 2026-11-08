#!/usr/bin/env python3
"""Join verified real NSO slot census evidence with the maintained NVN table.

The private JSON manifest has a nonempty samples list. Each sample supplies key,
name, version, programId, nso (real input path), and census (report directory).
Outputs must share a directory. They contain names/counts/hashes only, never
NSO bytes or private paths.
"""
import argparse
from collections import Counter
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'graphics/nvn/tools'))
from nvn_func_table import classes

CLASSES = ('已实现', '部分', '空操作', '未实现', '表外')
SOURCES = ('graphics/nvn/tools/nvn_func_table.py', 'graphics/nvn/gfx/nvn/hle_nvn.c',
           'graphics/nvn/gfx/nvn/names.txt')


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sample_data(sample):
    directory = Path(sample['census']).resolve(strict=True)
    report = json.loads((directory / 'census.json').read_text())
    require(report['status'] == 'complete' and report['schemaVersion'] in (2, 3), 'Incomplete census')
    source = Path(sample['nso']).resolve(strict=True)
    require(sha256(source) == report['input']['sha256'], f'{sample["key"]}: input hash mismatch')
    require(source.stat().st_size == report['input']['bytes'], 'Input size mismatch')
    slots = directory / 'slots.tsv'
    require(sha256(slots) == report['slotsTsvSha256'], 'Slot TSV hash mismatch')
    with slots.open(encoding='utf-8', newline='') as stream:
        rows = list(csv.DictReader((line for line in stream if not line.startswith('#')), delimiter='\t'))
    counts = {row['name']: int(row['nuses']) for row in rows}
    require(len(counts) == len(rows) == report['fetchedNames'], 'Duplicate or missing names')
    require(all(value >= 0 for value in counts.values()), 'Negative static read count')
    require(sum(value > 0 for value in counts.values()) == report['namesWithSlotReads'], 'Read-name count mismatch')
    require(sum(counts.values()) == report['staticSlotReadSites'], 'Read-site count mismatch')
    for key in ('key', 'name', 'version', 'programId'):
        require(isinstance(sample[key], str) and sample[key] and not any(c in sample[key] for c in '\t\r\n|'),
                f'Invalid sample field: {key}')
    require(len(sample['programId']) == 16 and all(c in '0123456789abcdefABCDEF' for c in sample['programId']),
            'programId must contain 16 hexadecimal digits')
    return dict(sample, counts=counts, report=report)


def table(headers, rows):
    return ['| ' + ' | '.join(map(str, headers)) + ' |', '|' + '---|' * len(headers),
            *['| ' + ' | '.join(map(str, row)) + ' |' for row in rows], '']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--markdown', type=Path, required=True)
    parser.add_argument('--table', type=Path, required=True)
    args = parser.parse_args()
    require(args.markdown.resolve() != args.table.resolve(), 'Outputs must be different files')
    require(args.markdown.resolve().parent == args.table.resolve().parent, 'Outputs must share a directory')
    require(not args.markdown.exists() and not args.table.exists(), 'Use new output paths')
    samples = [sample_data(sample) for sample in json.loads(args.manifest.read_text())['samples']]
    require(samples and len({s['key'] for s in samples}) == len(samples), 'Missing or duplicate sample keys')
    host = classes()
    fetched = sorted(set().union(*(s['counts'].keys() for s in samples)))
    used = {name for s in samples for name, count in s['counts'].items() if count}
    unknown = sorted(set(fetched) - host.keys())
    classification = {name: host[name] if name in host else '表外' for name in fetched}
    summary = Counter(host.values())
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout.strip()
    lines = ['# NVN 函数覆盖静态普查：DanielZhangyc', '',
             f'关联 #264；本次 {len(samples)} 款均为自有游戏的真实 main。按名获取与静态槽读取取自 #249，宿主分类直接调用仓库现行 `nvn_func_table.classes()`。', '',
             '分类统计单位是有读取的函数名称数，“静态读取点”是指令位置数，不是动态调用次数。分类沿用维护者工具，不构成独立的派发表或函数语义审计。零读取不能证明未使用；部分实现和未实现项也不证明本次玩法触发了缺口。未运行游戏、出包或真机测试。', '',
             '## 实现表与输入身份', '', f'实现表源码基线：`{revision}`。', '',
             f'全表 {len(host)} 项：' + '、'.join(f'{key} {summary[key]}' for key in CLASSES[:-1]) + '。', '']
    lines += table(['来源', 'SHA-256'], [(name, sha256(ROOT / name)) for name in SOURCES] +
                   [('tools/nvn_coverage_report.py', sha256(Path(__file__)))])
    lines += table(['简称', '游戏', '版本', '程序号', 'main SHA-256'],
                   [(s['key'], s['name'], s['version'], s['programId'].upper(), s['report']['input']['sha256']) for s in samples])
    lines += ['## 每款统计', '']
    rows = []
    for sample in samples:
        counts = sample['counts']
        grouped = Counter(classification[name] for name, count in counts.items() if count)
        rows.append([sample['key'], len(counts), sum(value > 0 for value in counts.values()), sum(counts.values()),
                     *(grouped[key] for key in CLASSES)])
    lines += table(['简称', '取名入口', '有读取名称', '静态读取点', *CLASSES], rows)
    lines += [f'{len(samples)} 款合并去重：取名 {len(fetched)} 项、有读取 {len(used)} 项；取名表外 {len(unknown)} 项。', '',
              '## 有静态读取的差集', '',
              '下表只列“部分 / 未实现 / 表外”，数字是各款静态槽读取点数；0 只表示本次启发式未检出读取。', '']
    gaps = sorted(name for name in used if classification[name] in ('部分', '未实现', '表外'))
    lines += table(['函数', '分类', *(s['key'] for s in samples)],
                   [[name, classification[name], *(s['counts'].get(name, 0) for s in samples)] for name in gaps])
    lines += ['`nvnMemoryPoolMapVirtual` 的“部分”来自维护者当前分类，不代表读取点必然进入未实现分支。空操作是维护者定义的独立类别，不合并到未实现。', '',
              '## 空操作读取', '']
    lines += table(['函数', *(s['key'] for s in samples)],
                   [[name, *(s['counts'].get(name, 0) for s in samples)] for name in sorted(used)
                    if classification[name] == '空操作'])
    lines += ['## 完整名称表与复核', '',
              f'完整表见 [{args.table.name}]({args.table.name})：每行一个按名获取的 NVN 函数，附宿主分类和每款读取点数。`未取` 表示该款恢复出的表没有此名，`0` 表示取到了但未检出读取，正整数表示读取点数。', '',
              '生成时逐份校验真实 NSO 的 SHA-256 / 大小、基线 TSV 哈希、互异名称数、有读取名称数与读取点总和；任一不符立即失败。未把未知名字归成已实现或未实现。', '']
    lines += table(['简称', 'slots.tsv SHA-256'], [(s['key'], s['report']['slotsTsvSha256']) for s in samples])
    lines += ['复核命令（私有清单见工具文档字符串，包含真实输入与 census 目录，不能提交）：', '',
              '```sh', 'python3 tools/nvn_coverage_report.py --manifest /私有路径/manifest.json \\',
              '  --markdown /新输出/普查.md --table /新输出/普查.tsv', '```', '',
              '读取统计沿用 ADRP 回溯启发式，ADD / MOV 基址链等形态可能漏计。这里只覆盖每款恢复出的 main 加载表；其他模块、未识别加载器、动态调用、着色器与画面覆盖均未在此证明。函数实现表会随 main 前进，结论只对应上述源码哈希。', '']
    buffer = io.StringIO()
    writer = csv.writer(buffer, delimiter='\t', lineterminator='\n')
    writer.writerow(['name', 'class', *(s['key'] for s in samples)])
    writer.writerows([name, classification[name], *(s['counts'].get(name, '未取') for s in samples)] for name in fetched)
    args.table.write_text(buffer.getvalue(), encoding='utf-8')
    args.markdown.write_text('\n'.join(lines), encoding='utf-8')
    print(json.dumps(dict(samples=len(samples), fetchedNames=len(fetched), readNames=len(used),
                          gapNames=len(gaps), unknownNames=unknown), ensure_ascii=False))


if __name__ == '__main__':
    main()
