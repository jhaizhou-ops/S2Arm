#!/usr/bin/env python3
"""用真实编译的自有 AArch64 程序运行生产 CLI；非游戏覆盖证明。

普通门禁校验并读取已编译模块；--verify-assembly 另用既有 LLVM 工具
重新编译，逐一核对固定 SHA，不修改夹具或手算期望。
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'graphics/nvn/tools'
SOURCE = ROOT / 'tests/nvn_got_census'


def tool(name, variable):
    requested = os.environ.get(variable, name)
    found = shutil.which(requested) or shutil.which(
        requested, path='/opt/homebrew/opt/llvm/bin:/usr/local/opt/llvm/bin')
    if not found:
        sys.exit(f'未测：缺少 {name}，可用 {variable} 指定既有工具（不自动安装）')
    return found


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{command!r} 退出 {result.returncode}\n{result.stdout}{result.stderr}')
    return result.stdout


def main():
    if sys.flags.optimize:
        sys.exit('失败：本回归需要断言，不支持 Python -O / PYTHONOPTIMIZE')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-assembly', action='store_true')
    args = parser.parse_args()
    fixture = json.loads((SOURCE / 'compiled.json').read_text())
    assert fixture['schemaVersion'] == 1
    for name, expected in fixture['sourceSha256'].items():
        assert hashlib.sha256((SOURCE / name).read_bytes()).hexdigest() == expected, name
    if args.verify_assembly:
        clang = tool('clang', 'S2A_CLANG')
        linker = tool('ld.lld', 'S2A_LD_LLD')
        objcopy = tool('llvm-objcopy', 'S2A_LLVM_OBJCOPY')
    (ROOT / 'build').mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='nvn-got-instructions-', dir=ROOT / 'build'))
    print(f'自有汇编回归：{work}', flush=True)
    if args.verify_assembly:
        print(f'工具：{clang}；{linker}；{objcopy}', flush=True)
    else:
        print('读取已编译自有程序；源码和模块 SHA256 核对，不需要 LLVM', flush=True)
    cases = {
        'mixed': None,
        'got': None,
        'direct': None,
        'name-clobber': 'NVN name in x1 is overwritten',
        'return-clobber': 'Fetched NVN pointer in x0 is overwritten',
        'missing-store': 'Fetched NVN pointer in x0 is overwritten',
        'unstored-final': 'consume and store each NVN fetch exactly once',
        'dup-got': 'one GOT entry or global slot',
        'dup-slot': 'one GOT entry or global slot',
        'dup-name': 'Repeated names',
        'no-names': 'no NVN x1 name-reference candidates',
    }
    assert set(fixture['modules']) == set(cases)
    for name, rejection in cases.items():
        case = work / name
        case.mkdir()
        module = fixture['modules'][name]
        image = zlib.decompress(bytes.fromhex(module['zlibHex']))
        assert len(image) == 0x3000, len(image)
        assert hashlib.sha256(image).hexdigest() == module['sha256'], name
        if args.verify_assembly:
            flags = [] if name == 'mixed' else ['-DCASE_' + name.upper().replace('-', '_')]
            run([clang, '--target=aarch64-none-elf', '-c', *flags,
                 str(SOURCE / 'loader.S'), '-o', str(case / 'module.o')])
            run([linker, '--no-relax', '-T', str(SOURCE / 'module.ld'),
                 str(case / 'module.o'), '-o', str(case / 'module.elf')])
            run([objcopy, '-O', 'binary', str(case / 'module.elf'), str(case / 'module.bin')])
            actual = (case / 'module.bin').read_bytes()
            assert hashlib.sha256(actual).hexdigest() == module['sha256'], name
            assert actual == image, name
        # 复用仓库现有 NSO 容器，不另写 NSO 序列化器或人工编码指令。
        nso = case / 'module.nso'
        run([sys.executable, str(ROOT / 'android/tools/selftest_nso.py'), str(nso)])
        container = nso.read_bytes()
        assert len(container) == 0x3100
        nso.write_bytes(container[:0x100] + image)
        output = case / 'census'
        result = subprocess.run([sys.executable, str(TOOLS / 'nvn_got_census.py'),
                                 str(nso), '--output', str(output)],
                                capture_output=True, text=True)
        (case / 'stdout.log').write_text(result.stdout)
        (case / 'stderr.log').write_text(result.stderr)
        if rejection:
            assert result.returncode == 1, (name, result.returncode, result.stdout, result.stderr)
            failure = json.loads((output / 'failure.json').read_text())
            assert rejection in failure['error'], (name, failure['error'])
            assert not (output / 'census.json').exists()
            assert not (output / 'slots.tsv').exists()
            print(f'{name}: 拒绝退出 1，{rejection}', flush=True)
            continue
        assert result.returncode == 0, (result.returncode, result.stderr)
        report = json.loads((output / 'census.json').read_text())
        # 手算：第一槽 GOT[0x2080] -> 0x2100，第二槽 ADRP+ADD -> 0x2108。
        # 读点 0x304 读 GOT，0x310/0x314 读直接槽；不把 0x308 的间接读再计一次。
        assert (report['fetchedNames'], report['namesWithSlotReads'],
                report['staticSlotReadSites']) == (2, 2, 3), report
        assert report['loaderStart'] == '0x100'
        # 正例均为 16 条指令：0x100 + 16*4 = 0x140（RET 在 0x13c）。
        assert report['loaderEndExclusive'] == '0x140'
        assert report['loaderReturnInstructionOffset'] == '0x13c'
        assert report['resolvedGotRelocations'] == (2 if name == 'got' else 1)
        proof = report['candidates'][0]['registerLiveness']
        got_stores = {'mixed': 1, 'got': 2, 'direct': 0}[name]
        assert (proof['gotStores'], proof['directStores'], proof['fetchCalls'],
                proof['resultStores'], proof['fetchRegister']) == (got_stores, 2 - got_stores, 2, 2, 'x19'), proof
        assert [row['addressKind'] for row in report['candidates'][0]['references']] == ['adrp_add', 'adr']
        with (output / 'slots.tsv').open() as stream:
            rows = list(csv.DictReader((line for line in stream if not line.startswith('#')), delimiter='\t'))
        assert rows == [
            dict(name='nvnDeviceGetInteger', slot='2100', nuses='1', first_use='304'),
            dict(name='nvnDeviceGetProcAddress', slot='2108', nuses='2', first_use='310'),
        ], rows
        # 实际集成入口也须走原扫描器零匹配后的混合形态支路。
        sys.path.insert(0, str(TOOLS))
        from direct_census import loader
        from nvn_got_census import analyze_nso
        shape = {'mixed': 'GOT / 直接全局槽混合形态', 'got': 'GOT 交错形态', 'direct': '直接全局槽'}[name]
        assert loader(nso) == (2, {'nvnDeviceGetInteger', 'nvnDeviceGetProcAddress'}, shape)
        slots, reads = analyze_nso(nso, {})
        assert slots == [
            dict(name='nvnDeviceGetInteger', got=None if name == 'direct' else 0x2080, slot=0x2100),
            dict(name='nvnDeviceGetProcAddress', got=0x2088 if name == 'got' else None, slot=0x2108),
        ], slots
        assert reads == {0x2100: [0x304], 0x2108: [0x310, 0x314]}, reads
        print(f'{name}: 退出 0，2 名称 / 2 有读取 / 3 读点，{shape}', flush=True)
    print(f'通过：3 个正例、8 个拒绝例；真实指令/CLI 证据保留于 {work}', flush=True)


if __name__ == '__main__':
    main()
