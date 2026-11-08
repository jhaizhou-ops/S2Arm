#!/usr/bin/env python3
"""Original synthetic ELF/APK fixtures; no executable or game-derived inputs."""
import pathlib
import importlib.util
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET

ANDROID = pathlib.Path(__file__).resolve().parents[1]
LIBRARY = 'lib/arm64-v8a/libs2arm_android.so'
# The packaged capprobe helper is a required APK entry (verify-apk.py fails
# without it); every fixture writes a valid stub so the checks under test
# run against the host library, not a missing-file rejection.
CAPPROBE = 'lib/arm64-v8a/libs2a_capprobe.so'
PAGE = 16384

# RELRO fixtures must satisfy the independently checked production JNI ABI,
# otherwise they fail before reaching the page-protection assertions.
spec = importlib.util.spec_from_file_location('jni_abi', ANDROID / 'native/jni_abi.py')
jni = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jni)
JNI_SOURCES = [ANDROID / 'app/src/main/java/org/s2arm/android' / name
               for name in ('NativeBridge.java', 'TouchInputBridge.java')]
JNI_ABI = jni.identity(JNI_SOURCES)[1].encode()


def segment(kind, address, size, flags=6, offset=0, align=PAGE):
    return struct.pack('<IIQQQQQQ', kind, flags, offset, address, 0, 0, size, align)


def elf(headers, abi=JNI_ABI):
    data = bytearray(64)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', data, 18, 183)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, len(headers))
    return data + b''.join(headers) + abi


class VerifyApkTest(unittest.TestCase):
    @staticmethod
    def add(apk, name, payload, offset, compressed=False, aligned=True):
        """Write one lib/*.so entry; returns the offset where the next entry starts."""
        info = zipfile.ZipInfo(name)
        info.compress_type = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
        if aligned:
            extra = (PAGE - (offset + 30 + len(name.encode())) % PAGE) % PAGE
            if 0 < extra < 4:    # an extra field needs at least its 4-byte header
                extra += PAGE
            if extra:
                info.extra = struct.pack('<HH', 0xffff, extra - 4) + bytes(extra - 4)
        apk.writestr(info, payload)
        return offset + 30 + len(name.encode()) + len(info.extra) + len(payload)

    def verify(self, headers, compressed=False, aligned=True, abi=JNI_ABI):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'fixture.apk'
            with zipfile.ZipFile(path, 'w') as apk:
                offset = self.add(apk, LIBRARY, elf(headers, abi), 0, compressed, aligned)
                self.add(apk, CAPPROBE, elf([segment(1, 0x4000, 0x1000)]), offset)
            return subprocess.run([sys.executable, str(ANDROID / 'verify-apk.py'), str(path)],
                                  capture_output=True, text=True)

    def assert_passes(self, headers):
        result = self.verify(headers)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_relro_fails(self, headers, end='0x7000'):
        result = self.verify(headers)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(LIBRARY, result.stderr)
        self.assertIn('GNU_RELRO', result.stderr)
        self.assertIn(end, result.stderr)

    def test_aligned_relro_end(self):
        self.assert_passes([segment(1, 0x4000, 0x8000), segment(0x6474e552, 0x4000, 0x4000)])

    def test_end_short_by_4kb_same_load(self):
        self.assert_relro_fails([segment(1, 0x4000, 0x8000), segment(0x6474e552, 0x4000, 0x3000)])

    def test_no_relro(self):
        self.assert_passes([segment(1, 0x4000, 0x8000)])

    def test_full_page_gap(self):
        self.assert_passes([segment(1, 0x4000, 0x3000), segment(0x6474e552, 0x4000, 0x3000),
                            segment(1, 0xc000, 0x1000)])

    def test_next_load_at_protection_boundary(self):
        self.assert_passes([segment(1, 0x4000, 0x3000), segment(0x6474e552, 0x4000, 0x3000),
                                 segment(1, 0x8000, 0x1000)])

    def test_exact_full_page_gap(self):
        self.assert_passes([segment(1, 0x4000, 0x3000), segment(0x6474e552, 0x4000, 0x3000),
                            segment(1, 0xb000, 0x1000, offset=0x3000)])

    def test_no_writable_bytes_after_relro(self):
        self.assert_passes([segment(1, 0x4000, 0x3000), segment(0x6474e552, 0x4000, 0x3000)])

    def test_readonly_following_segment_is_not_writable(self):
        self.assert_passes([segment(1, 0x4000, 0x3000), segment(0x6474e552, 0x4000, 0x3000),
                            segment(1, 0x7000, 0x1000, flags=4, offset=0x3000)])

    def test_next_load_same_page(self):
        self.assert_relro_fails([segment(1, 0x4000, 0x3000), segment(0x6474e552, 0x4000, 0x3000),
                                 segment(1, 0x7000, 0x1000, offset=0x3000)])

    def test_second_relro_also_checked(self):
        self.assert_relro_fails([segment(1, 0x4000, 0xc000), segment(0x6474e552, 0x4000, 0x4000),
                                 segment(0x6474e552, 0x8000, 0x3000)], '0xb000')

    def test_program_headers_need_not_be_address_sorted(self):
        self.assert_relro_fails([segment(1, 0x7000, 0x1000, offset=0x3000),
                                 segment(0x6474e552, 0x4000, 0x3000), segment(1, 0x4000, 0x3000)])

    def test_existing_load_alignment(self):
        result = self.verify([segment(1, 0x4000, 0x1000, align=4096)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('LOAD segment', result.stderr)

    def test_existing_zip_alignment(self):
        result = self.verify([segment(1, 0x4000, 0x1000)], aligned=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('payload is not 16 KB aligned', result.stderr)

    def test_existing_compression_check(self):
        result = self.verify([segment(1, 0x4000, 0x1000)], compressed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stored uncompressed', result.stderr)

    def test_manifest_disables_compatibility(self):
        application = ET.parse(ANDROID / 'app/src/main/AndroidManifest.xml').getroot().find('application')
        self.assertEqual(application.get('{http://schemas.android.com/apk/res/android}pageSizeCompat'), 'disabled')

    def test_missing_and_wrong_jni_abi_are_rejected(self):
        for abi in (b'', b'0' * len(JNI_ABI)):
            with self.subTest(abi=abi):
                result = self.verify([segment(1, 0x4000, 0x8000)], abi=abi)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('does not carry the JNI ABI', result.stderr)


if __name__ == '__main__':
    unittest.main()
