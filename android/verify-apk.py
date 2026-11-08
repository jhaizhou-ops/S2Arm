#!/usr/bin/env python3
"""Device-free APK ABI, ELF and uncompressed native-library alignment checks."""
import importlib.util
import pathlib
import struct
import sys
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
JNI_SOURCES = [HERE / 'app/src/main/java/org/s2arm/android' / n for n in ('NativeBridge.java', 'TouchInputBridge.java')]


def jni_abi():
    """The JNI ABI hash of this tree's Java native declarations (native/jni_abi.py)."""
    spec = importlib.util.spec_from_file_location('jni_abi', HERE / 'native/jni_abi.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.identity(JNI_SOURCES)[1]

# A string each component always carries -> the license files it needs in the APK.
LICENSE_MARKERS = [
    (b'S2ARM_LIBAVC_d380d04a78c6c08702e36aca86d0fd4baee390f9',
     ['assets/licenses/libavc-LICENSE.txt', 'assets/licenses/libavc-NOTICE.txt',
      'assets/licenses/libavc-SOURCE.txt']),
    (b'System.Private.CoreLib', ['assets/licenses/dotnet-runtime-LICENSE.TXT',
                                 'assets/licenses/dotnet-runtime-THIRD-PARTY-NOTICES.TXT']),   # .NET runtime (MIT)
    (b'OpenSSL 3.', ['assets/licenses/openssl-LICENSE.txt']),                                 # Apache-2.0
    (b'libopus ', ['assets/licenses/opus-COPYING.txt']),                                      # BSD-3-Clause
    (b'WebM Project VP8 Decoder', ['assets/licenses/libvpx-LICENSE.txt',
                                   'assets/licenses/libvpx-PATENTS.txt']),                    # BSD-3-Clause + patent grant
]


def verify(path):
    with zipfile.ZipFile(path) as apk, open(path, 'rb') as raw:
        libraries = [p for p in apk.infolist() if p.filename.startswith('lib/') and p.filename.endswith('.so')]
        names = {p.filename for p in libraries}
        # The NativeAOT probe and service library (cs/build.sh) and OpenSSL for .NET's crypto
        # (openssl/build.sh), plus the opt-in preparation library, are optional. The capprobe
        # helper (an executable packaged as lib*.so through a jniLibs source directory —
        # AGP only packages shared libraries) is required: without it the device probe
        # cannot spawn and every fingerprint silently reports unsupported.
        if {'lib/arm64-v8a/libs2arm_android.so', 'lib/arm64-v8a/libs2a_capprobe.so'} - names or names - {
                'lib/arm64-v8a/' + n for n in ('libs2arm_android.so', 'libs2a_capprobe.so',
                                               'libs2a_cs_probe.so', 'libs2a_cs.so',
                                               'libssl.so', 'libcrypto.so', 'libs2arm_rewriter.so')}:
            raise ValueError('APK must contain the arm64-v8a Android host and capprobe helper libraries, and only the declared NativeAOT / OpenSSL / preparation libraries')
        # Redistributed third-party code carries its license text. What the libraries contain decides
        # what is needed: the single-library build links the .NET runtime and the codecs into the host library.
        files = set(apk.namelist())
        if 'lib/arm64-v8a/libs2arm_rewriter.so' in names:
            for license_path in ('assets/licenses/capstone-LICENSE.txt', 'assets/licenses/lz4-LICENSE.txt'):
                if license_path not in files or not apk.read(license_path).strip():
                    raise ValueError('APK lacks nonempty preparation license: ' + license_path)
        contents = [apk.read(entry) for entry in libraries]
        needs = [n for marker, licenses in LICENSE_MARKERS if any(marker in data for data in contents) for n in licenses]
        missing = [n for n in needs if n not in files]
        if missing:
            raise ValueError('APK lacks license files: ' + ', '.join(missing))
        # The host library carries the JNI ABI of the Java it was built with (NativeBridge.jniAbi()): it must be
        # this tree's, or every launch of this APK would be refused after the load.
        abi = jni_abi().encode()
        if abi not in apk.read('lib/arm64-v8a/libs2arm_android.so'):
            raise ValueError('libs2arm_android.so does not carry the JNI ABI ' + abi.decode() + ' of this tree\'s Java sources')
        for entry in libraries:
            data = apk.read(entry)
            if data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
                raise ValueError('Native library is not little-endian AArch64 ELF64')
            phoff = struct.unpack_from('<Q', data, 32)[0]
            phsize, phcount = struct.unpack_from('<HH', data, 54)
            loads = 0
            writable = []
            relros = []
            for index in range(phcount):
                kind, flags, offset, address, _, _, memsize, align = struct.unpack_from('<IIQQQQQQ', data, phoff + index * phsize)
                if kind == 1:
                    loads += 1
                    if flags & 2 and memsize:
                        writable.append((address, address + memsize))
                    if align < 16384 or (address - offset) % 16384:
                        raise ValueError('ELF LOAD segment is not 16 KB aligned')
                elif kind == 0x6474e552 and memsize:  # PT_GNU_RELRO
                    relros.append((address, address + memsize))
            for start, end in relros:
                if end % 16384 == 0:
                    continue
                # Bionic rounds the protection end up to a runtime page boundary.
                # Include writable tails in the *same* LOAD, not just later headers.
                # No subsequent writable byte may share the protected final page.
                following = [max(address, end) for address, limit in writable if limit > end]
                next_write = min(following, default=None)
                protected_end = (end + 16383) & ~16383
                if next_write is not None and next_write < protected_end:
                    raise ValueError(
                        f'{entry.filename}: GNU_RELRO [{start:#x}, {end:#x}) end is not '
                        f'16 KB aligned; writable address {next_write:#x} shares the protected '
                        f'page ending at {protected_end:#x}')
            if not loads:
                raise ValueError('ELF has no LOAD segments')
            if entry.compress_type != zipfile.ZIP_STORED:
                raise ValueError('Native library must be stored uncompressed')
            raw.seek(entry.header_offset)
            header = raw.read(30)
            name, extra = struct.unpack_from('<HH', header, 26)
            if (entry.header_offset + 30 + name + extra) % 16384:
                raise ValueError('APK native-library payload is not 16 KB aligned')
    print('APK verified: arm64-v8a, 16 KB ELF segments and APK alignment, JNI ABI ' + abi.decode()[:12])


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: verify-apk.py <app.apk>')
    try:
        verify(pathlib.Path(sys.argv[1]))
    except (OSError, ValueError, struct.error, zipfile.BadZipFile) as error:
        sys.exit('APK verification failed: ' + str(error))

