#!/usr/bin/env python3
"""Exercise the APK native-payload checker using explicit real binaries or format fixtures.

--format-fixture is a device-free gate of format/admission rules. Supplying actual
host/JNI libraries and generated licenses additionally checks their real bytes.
Neither mode creates installable APKs or App UID evidence.
"""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('apk_verifier', ROOT / 'android/verify-apk.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def exercise(base, host, rewriter, licenses):
    notices = {f'assets/licenses/{name}': (licenses / name).read_bytes()
               for name in ('capstone-LICENSE.txt', 'lz4-LICENSE.txt')}
    if not all(notices.values()):
        raise ValueError('use the actual nonempty generated license assets')
    libs = {'lib/arm64-v8a/libs2arm_android.so': host.read_bytes(),
            'lib/arm64-v8a/libs2arm_rewriter.so': rewriter.read_bytes()}
    results = []

    def case(label, *, prepare=True, missing=None, blank=None, extra=False,
             compressed=False, aligned=True, bad_elf=False, bad_abi=False, bad_host_abi=False, expect=None):
        path = base / (label + '.zip')
        files = dict(notices) if prepare else {}
        if missing: files.pop('assets/licenses/' + missing)
        if blank: files['assets/licenses/' + blank] = b' \n\t'
        host_binary = libs['lib/arm64-v8a/libs2arm_android.so']
        if bad_host_abi:
            identity = verifier.jni_abi().encode()
            assert identity in host_binary
            host_binary = host_binary.replace(identity, b'0' * len(identity))
        files['lib/arm64-v8a/libs2arm_android.so'] = host_binary
        # verify-apk 把打包的 capprobe 助手列为必需条目；夹具库借用同一 ELF
        # 载荷即可过格式层（rewriter 与 fixture 都不含第三方许可标记）。
        files['lib/arm64-v8a/libs2a_capprobe.so'] = libs['lib/arm64-v8a/libs2arm_rewriter.so']
        if prepare:
            binary = bytearray(libs['lib/arm64-v8a/libs2arm_rewriter.so'])
            if bad_elf:
                phoff = struct.unpack_from('<Q', binary, 32)[0]
                size, count = struct.unpack_from('<HH', binary, 54)
                for index in range(count):
                    at = phoff + size * index
                    if struct.unpack_from('<I', binary, at)[0] == 1:
                        struct.pack_into('<Q', binary, at + 48, 4096)
                        break
            if bad_abi: struct.pack_into('<H', binary, 18, 62)
            files['lib/arm64-v8a/libs2arm_rewriter.so'] = binary
        if extra: files['lib/arm64-v8a/libunapproved.so'] = libs['lib/arm64-v8a/libs2arm_rewriter.so']
        with zipfile.ZipFile(path, 'w') as archive:
            for name, content in files.items():
                entry = zipfile.ZipInfo(name)
                entry.compress_type = zipfile.ZIP_DEFLATED if compressed and name.endswith('rewriter.so') else zipfile.ZIP_STORED
                if name.endswith('.so') and aligned:
                    padding = -(archive.fp.tell() + 30 + len(name.encode('utf-8'))) % 16384
                    if padding:
                        if padding < 4: padding += 16384
                        entry.extra = struct.pack('<HH', 0xcafe, padding - 4) + bytes(padding - 4)
                archive.writestr(entry, content)
        try:
            with contextlib.redirect_stdout(io.StringIO()): verifier.verify(path)
        except ValueError as error:
            if expect is None or expect not in str(error): raise
            results.append(dict(case=label, rejected=True, reason=str(error)))
        else:
            if expect is not None: raise AssertionError('invalid ZIP admitted: ' + label)
            results.append(dict(case=label, verified=True))

    case('real-host-and-preparation')
    case('default-host-no-preparation', prepare=False)
    case('missing-capstone', missing='capstone-LICENSE.txt', expect='license')
    case('missing-lz4', missing='lz4-LICENSE.txt', expect='license')
    case('empty-lz4', blank='lz4-LICENSE.txt', expect='license')
    case('unapproved-library', extra=True, expect='declared')
    case('compressed-library', compressed=True, expect='uncompressed')
    case('unaligned-payload', aligned=False, expect='payload')
    case('bad-elf-alignment', bad_elf=True, expect='LOAD segment')
    case('wrong-machine', bad_abi=True, expect='AArch64')
    case('wrong-host-jni-abi', bad_host_abi=True, expect='JNI ABI')
    (base / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'JNI native ZIP checker: {len(results)} cases passed (ZIP fixtures only; no APK/App UID claim)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path)
    parser.add_argument('--rewriter', type=Path)
    parser.add_argument('--licenses', type=Path)
    parser.add_argument('--format-fixture', action='store_true')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    if args.format_fixture and any((args.host, args.rewriter, args.licenses)):
        parser.error('format fixtures and real binary inputs are separate modes')
    if not args.format_fixture and not all((args.host, args.rewriter, args.licenses)):
        parser.error('supply real --host/--rewriter/--licenses, or explicit --format-fixture')

    def selected(base):
        if args.format_fixture:
            # Independent ELF64/AArch64 format fixture: one RX PT_LOAD at offset
            # zero with 16 KiB p_align. It has no Android runtime or rewriter code.
            binary = bytearray(256)
            ident = b'\x7fELF\x02\x01\x01' + bytes(9)
            struct.pack_into('<16sHHIQQQIHHHHHH', binary, 0, ident, 3, 183, 1,
                             128, 64, 0, 0, 64, 56, 1, 0, 0, 0)
            struct.pack_into('<IIQQQQQQ', binary, 64, 1, 5, 0, 0, 0, 256, 256, 16384)
            struct.pack_into('<I', binary, 128, 0xd65f03c0)
            binary[160:224] = verifier.jni_abi().encode()
            host = base / 'format.so'; host.write_bytes(binary)
            notices = base / 'format-notices'; notices.mkdir()
            for name in ('capstone-LICENSE.txt', 'lz4-LICENSE.txt'):
                (notices / name).write_text('Synthetic nonempty admission fixture, not a third-party license.\n')
            (base / 'source-mode.txt').write_text('synthetic ELF/notice format fixtures only\n')
            exercise(base, host, host, notices)
        else:
            (base / 'source-mode.txt').write_text('explicit real binary and generated license inputs\n')
            exercise(base, args.host, args.rewriter, args.licenses)
    if args.evidence:
        args.evidence.mkdir(parents=True, exist_ok=False)
        selected(args.evidence)
    else:
        with tempfile.TemporaryDirectory(prefix='s2arm-jni-zip-') as tmp:
            selected(Path(tmp))
