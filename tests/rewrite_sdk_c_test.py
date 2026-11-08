#!/usr/bin/env python3
"""SDK code-shape / exported-return contracts, with independent expected words.

全部产物另对金样（tests/fixtures/rewrite_golden/rewrite_sdk_c.tsv，见 tests/rewrite_golden.py；原为对 Python 改写器逐字节对拍）。
"""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tests/rewrite_corpus'))
spec = importlib.util.spec_from_file_location('corpus', ROOT / 'tests/rewrite_corpus/run.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)
sys.path.insert(0, str(ROOT / 'tests'))
from rewrite_golden import Golden
EXPORT = b'_ZN2nn2os6detail11VammManager21AllocateAddressRegionEPmm'


def source(path, *, variant='valid', export='valid'):
    first = '.inst 0x52a7fc08'  # MOVZ w8, #0x3fe0, lsl #16
    second = 'orr w10, wzr, #0x3fe00000'
    add = 'add x9, x1, x8'
    store = 'str x9, [x0, #0x28]'
    node = 'mov w2, #0x30'
    if variant == 'orr_first':
        first, second = 'orr w8, wzr, #0x3fe00000', '.inst 0x52a7fc0a'
    if variant == 'bad_add': add = 'add x9, x1, x7'
    if variant == 'bad_store': store = 'str x9, [x0, #0x30]'
    if variant == 'stp_store': store = 'stp x9, x10, [x0, #0x28]'
    if variant == 'bad_node': node = 'mov w2, #0x38'
    distance = {'distant_pair': 0x144, 'max_pair': 0x140}.get(variant, 0x10)
    align = 0x480 if variant == 'distant_align' else max(0x40, distance + 0x20)
    small = 'mov w14, #0x10000' if variant != 'missing_align_class' else 'nop'
    asm = f"""
      {first}
      {add}
      {store}
      {node}
.org {distance}
      {second}
.org {align}
      mov w11, #0x40000000
      mov w12, #0x2000000
      mov w13, #0x400000
      mov w15, #0x200000
      {small}
.org 0x600
      svc #1
      cbz w0, other
      ret
      ret x19
other: ret
      ret
"""
    words = corpus.assemble(variant + '-' + export, asm)
    corpus.nso(words, {}, len(words) * 4, str(path))
    raw = bytearray(path.read_bytes())
    ro_file = 0x1100
    # MOD0 -> .dynamic -> ELF64 symbols / strings. No fixed game addresses.
    struct.pack_into('<i', raw, ro_file + 4, 0x300)
    for off, tag, value in ((0x300, 6, 0x1400), (0x310, 5, 0x1600), (0x320, 0, 0)):
        struct.pack_into('<QQ', raw, ro_file + off, tag, value)
    name = EXPORT if export != 'missing' else EXPORT + b'Other'
    raw[ro_file + 0x601:ro_file + 0x602 + len(name)] = name + b'\0'
    val = 0 if export == 'zero_value' else 0x700
    size = {'zero_size': 0, 'large_size': 0x4000, 'outside_text': 0xa00}.get(export, 0x14)
    struct.pack_into('<IBBHQQ', raw, ro_file + 0x418, 1, 2, 0,
                     0 if export == 'undefined' else 1, val, size)
    path.write_bytes(raw)
    cuts = variant not in ('bad_add', 'bad_store', 'bad_node', 'distant_pair')
    aligned = cuts and variant not in ('missing_align_class', 'distant_align')
    return words, [(0x100, 8), (0x100 + distance, 10)] if cuts else [], \
        [(0x100 + align, 11)] if aligned else [], [0x708, 0x710] if export == 'valid' else []


def compress(raw):
    import lz4.block
    header, payload = bytearray(raw[:0x100]), bytearray()
    struct.pack_into('<I', header, 12, 7)
    for i in range(3):
        off, _, size = struct.unpack_from('<III', header, 0x10 + 16 * i)
        block = lz4.block.compress(raw[off:off + size], store_size=False)
        struct.pack_into('<I', header, 0x10 + 16 * i, 0x100 + len(payload))
        struct.pack_into('<I', header, 0x60 + 4 * i, len(block))
        payload += block
    return header + payload


def files(path):
    return {p.name: p.read_bytes() for p in path.iterdir()}


def check_artifacts(actual, raw, nodes, aligns, rets, enabled):
    patched = actual['sdk.patched.bin']
    original = raw[0x100:0x1100]
    expected = {at: 0x52a00000 | ((0x3e00000 >> 16) << 5) | reg for at, reg in nodes}
    expected.update({at: 0x52a00000 | ((0x2000000 >> 16) << 5) | reg for at, reg in aligns})
    for at, word in expected.items():
        want = word if enabled else struct.unpack_from('<I', original, at)[0]
        assert struct.unpack_from('<I', patched, at)[0] == want, (at, want)
    gates = [line.split('\t') for line in actual['sdk.gates.tsv'].decode().splitlines()]
    aregion = [fields for fields in gates if fields[1] == 'aregion']
    assert [int(fields[3], 16) for fields in aregion] == (rets if enabled else [])
    # Each gate restores x29/x30 then returns. These are architecture encodings,
    # checked independently of the emitter as well as by the golden digests.
    for fields in aregion:
        at = int(fields[0], 16)
        assert struct.unpack_from('<II', patched, at) == (0xa8c17bfd, 0xd65f03c0)
    for at in (0x70c, 0x714):  # explicit ret x19 and a ret beyond st_size
        assert patched[at:at + 4] == original[at:at + 4], at


def main():
    native = Path(os.environ['REW']).resolve()
    variants = ['valid', 'orr_first', 'stp_store', 'max_pair', 'bad_add', 'bad_store',
                'bad_node', 'distant_pair', 'missing_align_class', 'distant_align']
    exports = ['missing', 'undefined', 'zero_value', 'zero_size', 'large_size', 'outside_text']
    cases = [(v, 'valid') for v in variants] + [('valid', e) for e in exports]
    count = 0
    golden = Golden('rewrite_sdk_c'); problems = []
    try:
        with tempfile.TemporaryDirectory(prefix='rewrite-sdk-c-') as tmp:
            root = Path(tmp)
            for variant, export in cases:
                source_path = root / 'sdk.nso'
                _, nodes, aligns, rets = source(source_path, variant=variant, export=export)
                raw = source_path.read_bytes()
                for packed in ((False, True) if variant in ('valid', 'orr_first') and export == 'valid' else (False,)):
                    source_path.write_bytes(compress(raw) if packed else raw)
                    for target in ('apple', 'android'):
                        for spin in ((0, 1) if variant == 'valid' and export == 'valid' else (0,)):
                            for enabled in (False, True):
                                env = dict(os.environ, S2A_TARGET=target,
                                           S2A_REWRITE_SPIN=str(spin), S2A_SDK_ADDR_CUT=str(int(enabled)))
                                out = root / 'out'
                                if out.exists(): shutil.rmtree(out)
                                result = subprocess.run([str(native), str(source_path), str(out), 'sdk'], env=env, capture_output=True, text=True, timeout=60)
                                assert result.returncode == 0 and not result.stderr, (variant, export, result.stdout, result.stderr)
                                check_artifacts(files(out), raw, nodes, aligns, rets, enabled)
                                label = f'{variant}/{export}/packed{int(packed)}/{target}/spin{spin}/cut{int(enabled)}'
                                problems += [e for e in [golden.check(label, result.returncode, source_path, out)] if e]
                                count += 1
                print('SDK 契约通过、产物已对金样', variant, export, flush=True)
            # The old ABI uses enabled defaults even when the process environment
            # disables cuts; the explicit options on the other thread stay off.
            source(source_path)
            harness = native.with_name('s2a-rewrite-api-test')
            env = dict(os.environ, S2A_SDK_ADDR_CUT='0')
            result = subprocess.run([str(harness), str(source_path), str(root / 'api-apple'), str(root / 'api-android'), 'sdk'], env=env, capture_output=True, text=True, timeout=60)
            assert result.returncode == 0 and not result.stderr, (result.stdout, result.stderr)
            # 线程输出 = 对应目标（安卓开自旋、苹果开 SDK 地址削减）的 CLI 产物
            for target in ('apple', 'android'):
                problems += [e for e in [golden.check('api-' + target, 0, source_path, root / f'api-{target}')] if e]
            problems += golden.finish()
            assert not problems, problems
            print(f'SDK：{count} 组合 + C ABI 2 组全部产物与金样相同；C ABI 默认开 / 显式关双线程各 8 次隔离通过')
    finally:
        shutil.rmtree(corpus.T)


if __name__ == '__main__':
    main()
