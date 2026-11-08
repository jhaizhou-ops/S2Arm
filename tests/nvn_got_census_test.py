#!/usr/bin/env python3
# 门禁手动：要维护方私有真实 NSO 清单与结果路径（--manifest / --results），门禁机（mini、本机）上没有；手动回归见 docs/研究/NVN_GOT自动普查.md
"""Run NSO census regressions from a mandatory private real-input manifest.

See docs/研究/NVN_GOT自动普查.md for manifest fields. No game inputs or
address tables are distributed; missing inputs fail instead of skipping tests.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

TOOLS = Path(__file__).resolve().parents[1] / 'graphics/nvn/tools'
sys.path.insert(0, str(TOOLS))
from direct_census import loader


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def verified_path(path, sha256):
    path = Path(path).resolve(strict=True)
    require(hashlib.sha256(path.read_bytes()).hexdigest() == sha256, f'Hash mismatch: {path}')
    return path


def tsv_rows(path):
    with path.open(encoding='utf-8', newline='') as stream:
        return list(csv.DictReader((line for line in stream if not line.startswith('#')), delimiter='\t'))


def check_case(case, output):
    source = verified_path(case['nso'], case['sha256'])
    command = [sys.executable, *(['-O'] if case.get('optimize') else []),
               str(TOOLS / 'nvn_got_census.py'), str(source), '--output', str(output)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    require(result.returncode == case['exitCode'], f'{case["name"]}: {result.stdout}\n{result.stderr}')
    require(output.stat().st_mode & 0o777 == 0o700, 'Output directory must be private')
    if case['exitCode']:
        failure = json.loads((output / 'failure.json').read_text())
        require(failure['status'] == 'failed', 'Expected failed status')
        require(case['errorContains'] in failure['error'], failure['error'])
        require(not (output / 'census.json').exists() and not (output / 'slots.tsv').exists(),
                'Rejected input produced success artifacts')
        if 'integrationErrorContains' in case:
            try:
                loader(source)
            except RuntimeError as error:
                require(str(source) in str(error) and case['integrationErrorContains'] in str(error),
                        f'Integration failure lost its context: {error}')
                require('candidates.json' not in str(error), 'Integration points to an unwritten file')
            else:
                raise AssertionError('Integration accepted an unsupported real input')
        return {'name': case['name'], 'status': 'passed', 'error': failure['error'],
                'integrationChecked': 'integrationErrorContains' in case}
    report = json.loads((output / 'census.json').read_text())
    require(report['status'] == 'complete' and report['schemaVersion'] == 3, 'Invalid success report')
    require(report['input']['sha256'] == case['sha256'], 'Report input mismatch')
    baseline = verified_path(case['slots'], case['slotsSha256'])
    rows = tsv_rows(baseline)
    require(tsv_rows(output / 'slots.tsv') == rows, f'{case["name"]}: slot data rows changed')
    for key, expected in case['counts'].items():
        require(report[key] == expected, f'{key}: {report[key]} != {expected}')
    live = next(row for row in report['candidates'] if row['supported'])['registerLiveness']
    for key, expected in case['stores'].items():
        require(live[key] == expected, f'{key}: {live[key]} != {expected}')
    if 'shape' in case:
        count, names, shape = loader(source)
        require(count == len(rows) and shape == case['shape'], f'Integration count/shape: {count}, {shape}')
        require(names == {row['name'] for row in rows if int(row['nuses'])}, 'Integration read names differ')
    return {'name': case['name'], 'status': 'passed', **case['counts'],
            'allTsvDataRowsIdentical': True, 'integrationChecked': 'shape' in case}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    require(manifest['schemaVersion'] == 1 and manifest['cases'], 'Empty or unsupported manifest')
    require(not args.results.exists(), 'Use a new results path')
    results = []
    with tempfile.TemporaryDirectory(prefix='nvn-census-tests-') as temporary:
        for index, case in enumerate(manifest['cases']):
            result = check_case(case, Path(temporary) / str(index))
            results.append(result)
            args.results.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
            print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
