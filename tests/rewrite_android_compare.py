#!/usr/bin/env python3
"""Run the C rewriter on an Android device and compare all outputs with host C.

Explicit device test only; no downloads, builds, APK installation or game launch.
Inputs, device work directory, command records and raw logs remain private.
"""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import struct
import subprocess
import time

from rewrite_benchmark import sha256


REPO = Path(__file__).resolve().parent.parent
SETTINGS = {'S2A_TARGET': 'android', 'S2A_REWRITE_SPIN': '0', 'S2A_SDK_ADDR_CUT': '1'}
DEVICE_TEMPLATE = '/data/local/tmp/s2arm-rewriter-XXXXXXXX'


def device_directory(value):
    pattern = re.escape(DEVICE_TEMPLATE).replace('XXXXXXXX', r'[A-Za-z0-9]{8}')
    if not re.fullmatch(pattern, value):
        raise RuntimeError('unexpected device work directory')
    return value


def apple_double(path):
    with path.open('rb') as stream:
        header = stream.read(26)
        if len(header) != 26 or header[:8] != b'\x00\x05\x16\x07\x00\x02\x00\x00':
            return False
        count = int.from_bytes(header[24:26], 'big')
        entries = stream.read(count * 12)
    if len(entries) != count * 12:
        return False
    size = path.stat().st_size
    return all(offset >= 26 + count * 12 and offset + length <= size
               for _, offset, length in struct.iter_unpack('>III', entries))


def artifact_hashes(directory):
    files = {}
    for path in sorted(directory.iterdir()):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError('artifact directories must contain only regular files')
        if path.name.startswith('._') and (directory / path.name[2:]).is_file():
            if apple_double(path):
                continue  # Validated AppleDouble metadata on exFAT; not rewriter output.
        files[path.name] = sha256(path)
    required = {f'main.{suffix}' for suffix in
                ('patched.bin', 'fixups.tsv', 'gates.tsv', 'sites.tsv', 'gaps.tsv')}
    if not required <= files.keys():
        raise RuntimeError('missing required rewriter artifacts')
    return files


def summary(log):
    rows = re.findall(r'^PFRW mod=main need=(\d+) gaps=(\d+) fatal=(\d+)$', log, re.M)
    if len(rows) != 1:
        raise RuntimeError('expected exactly one PFRW summary')
    result = dict(zip(('need', 'gaps', 'fatal'), map(int, rows[0])))
    if result['gaps'] or result['fatal']:
        raise RuntimeError('PFRW reports gaps or fatal failure')
    return result


def byte_equal(first, second):
    with first.open('rb') as left, second.open('rb') as right:
        while True:
            block = left.read(1024 * 1024)
            if block != right.read(1024 * 1024):
                return False
            if not block:
                return True


def compare(first, second):
    left, right = artifact_hashes(first), artifact_hashes(second)
    if left.keys() != right.keys():
        raise RuntimeError('artifact filename sets differ')
    result = {}
    for name in left:
        if left[name] != right[name] or not byte_equal(first / name, second / name):
            raise RuntimeError('artifact bytes differ')
        result[name] = {'bytes': (first / name).stat().st_size, 'sha256': left[name]}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, type=Path, help='host C executable')
    parser.add_argument('--android', required=True, type=Path, help='arm64/API 28 C executable')
    parser.add_argument('--serial', required=True, help='explicit adb device; never in report.json')
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--output', required=True, type=Path, help='new private directory outside the repository')
    parser.add_argument('--timeout', type=float, default=600, help='seconds per command')
    parser.add_argument('input', type=Path, help='private NSO main')
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be finite and positive')
    root = args.output.resolve()
    if root.is_relative_to(REPO):
        parser.error('--output must be outside the repository')
    try:
        root.mkdir(mode=0o700)
    except OSError as error:
        parser.exit(1, f'cannot create a new private output directory: {error.strerror}\n')

    report = {'schemaVersion': 1, 'passed': False, 'settings': SETTINGS,
              'host': {'system': platform.system(), 'version': platform.mac_ver()[0] or platform.release(),
                       'architecture': platform.machine()}, 'runs': {}}
    commands = []
    stage = 'setup'

    def run(command, label, env=None, check=True):
        entry = {'command': command, 'label': label}
        commands.append(entry)
        start = time.perf_counter()
        try:
            process = subprocess.run(command, env=env, capture_output=True, timeout=args.timeout)
        except subprocess.TimeoutExpired as error:
            (root / f'{len(commands):02}-{label}.stdout.log').write_bytes(error.stdout or b'')
            (root / f'{len(commands):02}-{label}.stderr.log').write_bytes(error.stderr or b'')
            raise RuntimeError('command timed out; device work directory is retained') from None
        finally:
            entry['seconds'] = time.perf_counter() - start
        entry['returncode'] = process.returncode
        (root / f'{len(commands):02}-{label}.stdout.log').write_bytes(process.stdout)
        (root / f'{len(commands):02}-{label}.stderr.log').write_bytes(process.stderr)
        if check and process.returncode:
            raise RuntimeError(f'{label} failed with exit {process.returncode}')
        return process.stdout.decode('utf-8', errors='replace'), entry

    adb = [args.adb, '-s', args.serial]

    def shell(parts, label, **kwargs):
        return run(adb + ['shell', shlex.join(parts)], label, **kwargs)

    try:
        (root / 'binaries').mkdir()
        binaries = {}
        for kind, binary in (('host', args.host), ('android', args.android)):
            if not binary.is_file():
                raise RuntimeError('C executable is missing')
            snapshot = root / 'binaries' / kind
            shutil.copyfile(binary, snapshot)
            snapshot.chmod(0o700)
            if sha256(binary) != sha256(snapshot):
                raise RuntimeError('C executable changed while taking snapshot; finish the build first')
            binaries[kind] = snapshot
        with binaries['android'].open('rb') as stream:
            elf = stream.read(64)
        if (len(elf) != 64 or elf[:6] != b'\x7fELF\x02\x01'
                or int.from_bytes(elf[18:20], 'little') != 183):
            raise RuntimeError('Android executable must be a complete little-endian ELF64/AArch64 binary')
        report['binaries'] = {kind: sha256(path) for kind, path in binaries.items()}
        report['source'] = {name: sha256(REPO / 'runtime/rewriter' / name)
                            for name in ('rewriter.c', 'rewriter.h', 'main.c', 'CMakeLists.txt')}
        report['commit'] = subprocess.check_output(
            ['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip()
        (root / 'input').mkdir()
        source = root / 'input/main'
        shutil.copyfile(args.input, source)
        with source.open('rb') as stream:
            header = stream.read(0x100)
        if len(header) < 0x100 or header[:4] != b'NSO0':
            raise RuntimeError('input is not an NSO main')
        report['input'] = {'sha256': sha256(source), 'bytes': source.stat().st_size,
                           'buildId': header[0x40:0x60].hex()}

        stage = 'device preflight'
        state, _ = run(adb + ['get-state'], 'state')
        if state.strip() != 'device':
            raise RuntimeError('selected device is not ready')
        properties = {'manufacturer': 'ro.product.manufacturer', 'model': 'ro.product.model',
                      'androidVersion': 'ro.build.version.release', 'apiLevel': 'ro.build.version.sdk',
                      'abi': 'ro.product.cpu.abi', 'emulator': 'ro.kernel.qemu'}
        device = {}
        for key, prop in properties.items():
            value, _ = shell(['getprop', prop], key)
            device[key] = value.strip()
        arch, _ = shell(['uname', '-m'], 'architecture')
        device['architecture'] = arch.strip()
        report['device'] = device
        if (device['abi'] != 'arm64-v8a' or device['architecture'] != 'aarch64'
                or not device['apiLevel'].isdigit() or int(device['apiLevel']) < 28
                or device['emulator'] == '1' or args.serial.startswith('emulator-')):
            raise RuntimeError('requires a physical Android arm64 device with API >= 28')

        stage = 'host C rewrite'
        host_out = root / 'host'
        host_out.mkdir()
        env = {key: value for key, value in os.environ.items() if not key.startswith('S2A_')}
        env.update(SETTINGS)
        log, status = run([str(binaries['host']), str(source), str(host_out), 'main'],
                          'host-rewrite', env=env, check=False)
        report['runs']['host'] = {'returncode': status['returncode'], 'seconds': status['seconds']}
        if status['returncode']:
            raise RuntimeError('host C rewrite failed')
        report['runs']['host']['pfrw'] = summary(log)
        report['runs']['host']['artifacts'] = artifact_hashes(host_out)

        stage = 'device transfer'
        command = 'umask 077; ' + shlex.join(['mktemp', '-d', DEVICE_TEMPLATE])
        remote, _ = run(adb + ['shell', command], 'mktemp')
        remote = device_directory(remote.strip())
        (root / 'device-directory.txt').write_text(remote + '\n')
        shell(['mkdir', remote + '/out'], 'mkdir')
        run(adb + ['push', str(source), remote + '/main'], 'push-input')
        run(adb + ['push', str(binaries['android']), remote + '/s2a-rewrite'], 'push-cli')
        shell(['chmod', '700', remote + '/s2a-rewrite'], 'chmod')
        for name, expected in (('main', report['input']['sha256']),
                               ('s2a-rewrite', report['binaries']['android'])):
            value, _ = shell(['sha256sum', remote + '/' + name], 'hash-' + name)
            if not value.split() or value.split()[0] != expected:
                raise RuntimeError('device transfer SHA-256 mismatch')

        stage = 'device C rewrite'
        command = ['env', '-i', 'PATH=/system/bin:/system/xbin']
        command += [key + '=' + value for key, value in SETTINGS.items()]
        command += [remote + '/s2a-rewrite', remote + '/main', remote + '/out', 'main']
        log, status = shell(command, 'device-rewrite', check=False)
        report['runs']['android'] = {'returncode': status['returncode'], 'seconds': status['seconds']}
        if status['returncode']:
            raise RuntimeError('device C rewrite failed')
        report['runs']['android']['pfrw'] = summary(log)
        if report['runs']['host']['pfrw'] != report['runs']['android']['pfrw']:
            raise RuntimeError('host/device PFRW summaries differ')

        stage = 'complete artifact comparison'
        device_out = root / 'android'
        run(adb + ['pull', remote + '/out', str(device_out)], 'pull')
        report['runs']['android']['artifacts'] = artifact_hashes(device_out)
        report['artifacts'] = compare(host_out, device_out)
        if sha256(source) != report['input']['sha256']:
            raise RuntimeError('private input snapshot changed')
        report['passed'] = True
    except (OSError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        # Raw exception messages may include paths or device serials. Keep them private.
        (root / 'error.txt').write_text(f'{type(error).__name__}: {error}\n')
        report['failedStage'] = stage
        print(f'FAIL: {stage}; inspect private error.txt and command logs')
        return 1
    finally:
        (root / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: host/device C, android spin=0, {len(report["artifacts"])} files byte-identical')
    print('Private inputs/logs/device directory retained; review report.json before publishing.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
