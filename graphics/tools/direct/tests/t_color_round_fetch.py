#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Exercise the native export rewrite followed by the production tile variant.

Usage: t_color_round_fetch.py <libnxgal.dylib>. No game data is required.
Tile variant / integer entry / ladder flattening are the C# rewriters (S2A.Dsh: graphics/tools/direct/dsh/Fetch.cs DshFetch.Variant,
Dsh.cs DshCompiler.FsUint, Flat.cs DshFlat.Flatten) called through dsh_cmp --fn (dshfn.py); the shared integer body is the
library-batch rewrite (graphics/tools/direct/dsh/batch/Unity.cs Unity.Share) called through dsh_batch --unity share.
"""
import ctypes
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'translator'))
sys.path.insert(0, str(ROOT / 'graphics/tools/direct/tests'))
import dsh_batch
import dshfn

DSH_BATCH, _ = dsh_batch.get()
def share(src, temp):   # -> (source, shared), like the removed dmsh_ushare.share
    inp, out = pathlib.Path(temp) / 'share-in.metal', pathlib.Path(temp) / 'share-out.metal'
    inp.write_text(src)
    r = subprocess.run([*DSH_BATCH, '--unity', 'share', str(inp), str(out)], capture_output=True, text=True, check=True)
    return out.read_text(), r.stdout.strip() == 'shared 1'

lib = ctypes.CDLL(sys.argv[1])
rewrite = lib.nxgal_dmsh_color_round
rewrite.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p, ctypes.c_uint64]
rewrite.restype = ctypes.c_int32
release = lib.nxgal_dmsh_xc_free
release.argtypes = [ctypes.c_void_p]
def round_source(src):
    text = ctypes.c_void_p()
    error = ctypes.create_string_buffer(512)
    rc = rewrite(src.encode(), b'main0', ctypes.byref(text), error, len(error))
    assert rc == 0 and text.value, error.value.decode()
    try:
        return ctypes.string_at(text).decode()
    finally:
        release(text)

SOURCE = '''#include <metal_stdlib>
using namespace metal;
struct main0_out
{
    float4 m_0 [[color(0)]];
    float4 m_1 [[color(1)]];
};
fragment main0_out main0(constant uint* values [[buffer(0)]])
{
    main0_out out = {};
    out.m_0 = as_type<float4>(uint4(values[0]));
    out.m_1 = as_type<float4>(uint4(values[1]));
    EARLY
    return out;
}
'''
with tempfile.TemporaryDirectory(prefix='half-fetch-') as temp:
    for multiple in (False, True):
        src = SOURCE.replace('EARLY', 'if (values[2])\n    {\n        return out;\n    }' if multiple else '')
        rounded = round_source(src)
        for label, original in (('raw', src), ('rounded', rounded)):
            variant, result = dshfn.fn('fetch_variant', original, [], True)
            assert variant is not None, f'{label} multiple={multiple}: {result}'
            path = pathlib.Path(temp) / f'{label}-{multiple}.metal'
            path.write_text(variant)
            subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(path), '-o', str(path.with_suffix('.air'))], check=True)
            print(f'PASS {label} multiple={multiple}: production tile variant compiled')
            integer_source, integer_mask = dshfn.fn('fs_uint', original, src) or (None, 0)
            assert integer_mask == 3, 'both outputs write integer bits'
            shared, changed = share(integer_source, temp)
            assert changed, f'{label} multiple={multiple}: integer body was not shared'
            for kind, text in (('integer', integer_source), ('shared', shared)):
                path = pathlib.Path(temp) / f'{label}-{multiple}-{kind}.metal'
                path.write_text(text)
                subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(path), '-o', str(path.with_suffix('.air'))], check=True)
            print(f'PASS {label} multiple={multiple}: original and shared integer bodies compiled')
    ladder, indent = [], '    '
    for i in range(39):
        ladder += [f'{indent}bool _{100+i} = values[0] == {i}u;', f'{indent}if (!_{100+i})', indent + '{']
        indent += '    '
    ladder.append(indent + 'out.m_1 += float4(1.0);')
    for i in range(39):
        indent = indent[:-4]
        ladder.append(indent + '}')
    giant = SOURCE.replace('    EARLY', '\n'.join(ladder))
    flattened, levels = dshfn.fn('flatten', round_source(giant))
    assert levels > 0, 'half export formatting must preserve the existing giant shader optimization'
    path = pathlib.Path(temp) / 'rounded-flat.metal'
    path.write_text(flattened)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(path), '-o', str(path.with_suffix('.air'))], check=True)
    print(f'PASS rounded giant shader: {levels} ladder levels flattened and compiled')
print('PASS color-round consumers: 4 tile variants and 8 integer sources compiled (not gameplay)')
