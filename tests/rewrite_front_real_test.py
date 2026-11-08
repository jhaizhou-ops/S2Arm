#!/usr/bin/env python3
# 门禁手动：要传参数：--manifest 私有真实用例表 + --output，手动回归（docs/研究/改写器FRONT容量重选.md）
"""用调用方的真实 NSO 和独立核验过的产物哈希（金样）检查 C 改写器的 FAR 重布局。所有证据留在私有输出目录。

10-31 删 Python 改写器后改跑 C 改写器（--rew，缺省取 python3 pack/rewriter.py c-path 末行）；用例表的 runName（Python 专用）不再支持。
"""

import argparse
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from rewrite_benchmark import artifact_hashes, sha256


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_case(case, output, rew):
    source = Path(case['input'])
    widen = Path(case['widen']) if case.get('widen') else None
    require(sha256(source) == case['sha256'], '真实 NSO 哈希与基线不符')
    if widen:
        require(sha256(widen) == case['widenSha256'], '宽屏候选表哈希与基线不符')
    require('runName' not in case, 'runName 只对已删除的 Python 改写器有意义，用例表去掉这一项')
    command = [str(rew)]
    output.mkdir(mode=0o700)
    artifacts = output / 'artifacts'
    artifacts.mkdir(mode=0o700)
    command += [str(source), str(artifacts), 'main']
    if widen:
        command.append(str(widen))
    env = {key: value for key, value in os.environ.items() if not key.startswith('S2A_')}
    env.update(S2A_TARGET=case['target'], S2A_REWRITE_SPIN=str(case['spin']))
    report = dict(inputSha256=case['sha256'], rewriterSha256=sha256(rew), command=command, passed=False)
    start = time.monotonic()
    try:
        with (output / 'stdout.log').open('x') as stdout, (output / 'stderr.log').open('x') as stderr:
            completed = subprocess.run(command, env=env, stdout=stdout, stderr=stderr,
                                       timeout=600, check=True)
        report['returncode'] = completed.returncode
        report['artifacts'] = artifact_hashes(artifacts, 'main')
        require(report['artifacts'] == case['artifacts'], 'C 完整产物与独立基线不符')
        log = (output / 'stdout.log').read_text() + (output / 'stderr.log').read_text()
        expected = f'PFRW mod=main need={case["need"]} gaps=0 fatal=0'
        require(re.findall(r'^PFRW .*$', log, re.M) == [expected], 'C 最终汇总不唯一或计数不符')
        require(log.count('补丁容量不足，重新生成：') == case['retries'], 'C 重试次数不符')
        with (artifacts / 'main.fixups.tsv').open() as stream:
            headers = dict(csv.reader(stream, delimiter='\t'))
        require(int(headers['# PATCH_OFF'], 0) == int(case['patchOff'], 0), 'C 布局不符')
        with (artifacts / 'main.sites.tsv').open() as stream:
            spins = sum(len(row) > 1 and row[1] == 'S' for row in csv.reader(stream, delimiter='\t'))
        require(spins == case['spins'], 'C 自旋区数量不符')
        report['passed'] = True
    finally:
        report['seconds'] = time.monotonic() - start
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True, help='私有真实输入与冻结预期 JSON')
    parser.add_argument('--output', type=Path, required=True, help='尚不存在的私有证据目录')
    parser.add_argument('--rew', type=Path, help='C 改写器命令行（缺省取 python3 pack/rewriter.py c-path 末行）')
    args = parser.parse_args()
    rew = args.rew or Path((subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / 'pack/rewriter.py'), 'c-path'],
                                           capture_output=True, text=True).stdout.strip().splitlines() or [''])[-1])
    require(rew.is_file() and os.access(rew, os.X_OK), '取不到 C 改写器（--rew 或 python3 pack/rewriter.py c-path）')
    manifest = json.loads(args.manifest.read_text())
    require(manifest['schemaVersion'] == 1 and manifest['cases'], '需要 schemaVersion=1 的非空用例表')
    names = [case['name'] for case in manifest['cases']]
    require(len(set(names)) == len(names) and all(re.fullmatch(r'[a-z0-9_-]+', name) for name in names),
            '用例名须唯一，且只含小写字母、数字、下划线、连字符')
    args.output.mkdir(mode=0o700)
    results = dict(manifestSha256=sha256(args.manifest), passed=False, cases=[])
    try:
        for case in manifest['cases']:
            report = check_case(case, args.output / case['name'], rew)
            results['cases'].append(dict(name=case['name'], report=report))
            print(f'{case["name"]}: C 与独立基线全同；唯一 PFRW、布局、自旋区、重试次数通过', flush=True)
        results['passed'] = True
    finally:
        (args.output / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
