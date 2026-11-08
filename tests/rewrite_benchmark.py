#!/usr/bin/env python3
"""Private NSO timing + full artifact hashes for the C rewriter; never copy inputs or print their absolute paths.

10-31 删 Python 改写器后不再做 Python / C 对照；要核真实输入的产物，用 tests/rewrite_front_real_test.py 对独立冻结的哈希。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def artifact_hashes(out, module):
    required = {f'{module}.{suffix}' for suffix in
                ('patched.bin', 'fixups.tsv', 'gates.tsv', 'sites.tsv', 'gaps.tsv')}
    files = {path.name: sha256(path) for path in sorted(out.iterdir())}
    missing = required - files.keys()
    if missing:
        raise RuntimeError(f'missing artifacts: {", ".join(sorted(missing))}')
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rew', required=True, type=Path)
    parser.add_argument('--target', choices=('apple', 'android'), default='apple')
    parser.add_argument('--spin', choices=('0', '1'), default='0')
    parser.add_argument('--module', default='main', help='module name for every input (default: main)')
    parser.add_argument('--widen', type=Path, help='existing widen_sites.tsv passed to the rewriter')
    parser.add_argument('--output', type=Path, help='new private directory; also retain successful runs')
    parser.add_argument('--timeout', type=float, default=600, help='seconds per rewrite (default: 600)')
    parser.add_argument('inputs', nargs='+', type=Path)
    args = parser.parse_args()
    if not args.module or args.module in ('.', '..') or Path(args.module).name != args.module:
        parser.error('--module must be a single filename component')
    if not 0 < args.timeout < float('inf'):
        parser.error('--timeout must be finite and positive')
    env = dict(os.environ, S2A_TARGET=args.target, S2A_REWRITE_SPIN=args.spin)
    elapsed = 0.0
    # Failed runs contain game-derived artifacts and raw logs; keep them private.
    try:
        if args.output:
            root = args.output.resolve()
            root.mkdir(mode=0o700)
        else:
            root = Path(tempfile.mkdtemp(prefix='rewrite-bench-'))
    except OSError as error:
        parser.exit(1, f'cannot create a new private output directory: {error.strerror}\n')
    report = dict(module=args.module, target=args.target, spin=args.spin, timeout=args.timeout,
                  sdk_addr_cut=env.get('S2A_SDK_ADDR_CUT', '1'), inputs=[], passed=False)
    context = 'setup'
    try:
        report['c_sha256'] = sha256(args.rew)
        report['widen_sha256'] = sha256(args.widen) if args.widen else None
        for i, source in enumerate(args.inputs):
            context = f'input {i+1}'
            row = dict(sha256=sha256(source), implementations={})
            report['inputs'].append(row)
            name = 'C'
            context = f'input {i+1} {name}'
            run = root/f'{i+1}-{name}'
            run.mkdir()
            out = run/'artifacts'
            out.mkdir()
            status = {}
            row['implementations'][name] = status
            command = [str(args.rew.resolve()), str(source), str(out), args.module]
            if args.widen:
                command.append(str(args.widen))
            start = time.perf_counter()
            try:
                with (run/'stdout.log').open('wb') as stdout, (run/'stderr.log').open('wb') as stderr:
                    result = subprocess.run(command, env=env, stdout=stdout, stderr=stderr,
                                            timeout=args.timeout)
            finally:
                status['seconds'] = time.perf_counter()-start
                elapsed += status['seconds']
            status['returncode'] = result.returncode
            if result.returncode:
                raise RuntimeError(f'rewriter rc={result.returncode}')
            status['artifacts'] = artifact_hashes(out, args.module)
            context = f'input {i+1}'
            print(f'input {i+1}: {status["artifacts"]}')
        report['passed'] = True
    except (OSError, RuntimeError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        if isinstance(error, OSError):
            detail = error.strerror
        elif isinstance(error, subprocess.TimeoutExpired):
            detail = f'rewriter timed out after {args.timeout:g}s'
        elif isinstance(error, KeyboardInterrupt):
            detail = 'interrupted'
        else:
            detail = str(error)
        report['error'] = f'{context}: {detail}'
        raise SystemExit(f'{report["error"]}\nprivate diagnostics retained: {root}\n'
                         'do not publish raw artifacts/logs') from None
    finally:
        (root/'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'inputs={len(args.inputs)} target={args.target} spin={args.spin} C={elapsed:.3f}s (includes process startup)')
    if args.output:
        print(f'private diagnostics retained: {root}')
    else:
        shutil.rmtree(root)


if __name__ == '__main__':
    main()
