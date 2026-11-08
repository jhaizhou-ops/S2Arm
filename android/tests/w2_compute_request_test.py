#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Host REQUEST/pin/identity test; public synthetic bytes, no compiler or GPU claim."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'android/core-link'))
import link_symbols
NATIVE = ROOT / 'android/native'

def main():
    host = 'darwin-x86_64' if sys.platform == 'darwin' else 'linux-x86_64' if sys.platform.startswith('linux') else None
    if not host:
        raise RuntimeError('compute host test requires Linux or macOS')
    ndk = link_symbols.find_ndk()
    if ndk is None:
        raise RuntimeError('compute host test needs Android NDK 29.0.14206865; no download or skip')
    vulkan = ndk / 'toolchains/llvm/prebuilt' / host / 'sysroot/usr/include/vulkan'
    if not (vulkan / 'vulkan.h').is_file():
        raise RuntimeError('NDK Vulkan headers missing: ' + str(vulkan))
    with tempfile.TemporaryDirectory(prefix='w2-request-') as td:
        tmp=Path(td);inc=tmp/'include';inc.mkdir()
        (inc/'vulkan').symlink_to(vulkan)
        if (vulkan.parent/'vk_video').exists(): (inc/'vk_video').symlink_to(vulkan.parent/'vk_video')
        source=NATIVE/'nvn/nvn_vk_compute_request.c'
        def run(label, text):
            src=tmp/(label+'.c');src.write_text(text);exe=tmp/label
            cmd=[os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-pthread']
            cmd += ['-I'+str(p) for p in (inc,NATIVE,NATIVE/'nvn',ROOT/'graphics/nvn/gfx/nvn',ROOT/'graphics/nvn/gfx/nvn/include')]
            cmd += [str(ROOT/'android/tests/w2_compute_request_test.c'),str(src)]
            cmd += [str(NATIVE/'direct'/f) for f in ('source_store.c','control.c','input_identity.c','texture_facts.c','sha256.c','json.c')]
            subprocess.run(cmd+['-o',str(exe)],check=True,timeout=30)
            return subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
        text=source.read_text();result=run('positive',text)
        print(result.stderr.strip());assert result.returncode==0,result.stderr
        lines=result.stdout.splitlines();request=json.loads(lines[0]);p=request['program']
        assert p['kind']=='compute' and len(p['stages'])==1 and p['stages'][0]['stage']=='cs'
        assert p['computeState']=={'localSize':[8,2,1],'sharedMemoryBytes':32,'localMemoryBytes':32,'hasUnalignedStorageBuffer':True}
        assert request['requestId']=='quote"\\\n'
        assert p['textureArrayLength']==7 and p['samplerArrayLength']==9 and p['textures']==[]
        code=base64.b64decode(p['stages'][0]['code'],validate=True)
        ctl=base64.b64decode(p['stages'][0]['control'],validate=True)
        assert code==bytes([1,2,3,4])+bytes(12) and len(ctl)==0x760
        assert base64.b64decode(p['stages'][0]['c1'])==code[4:8]
        canonical=bytes.fromhex(lines[1].removeprefix('canonical='))
        # Independent fixed prefix checks: version, closure, profile hash, NVN CS mask,
        # packed key and complete source proof; not the REQUEST hash.
        prefix=b'S2AI1\x03'+struct.pack('<iI',1,len('closure-test'))+b'closure-test'
        prefix+=hashlib.sha256(b'{"schema":"s2a-direct-profile-v1","profileHash":"sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","capabilities":{"storageBufferOffsetAlignment":16}}').digest()+struct.pack('<I',32)
        sha=hashlib.sha256(ctl+code).digest()
        prefix+=sha[:8]+bytes(40)+b'\x01'+sha+struct.pack('<II',16,0x760)
        prefix+=struct.pack('<6I',0,0,0,0,0,3)+struct.pack('<II',7,9)+b'\x00'
        assert canonical.startswith(prefix),'independent canonical prefix'
        assert canonical[-2:]==b'\x01\x01','compute known/value suffix'
        for label,old,new,failure in [
            ('wrong-profile-A','out->storage_alignment = (uint32_t)field->unsigned_value;','out->storage_alignment = 32;','profile facts exact'),
            ('zero-alignment','id.compute_unaligned_ssbo = unaligned_ssbo;','id.compute_unaligned_ssbo = 0 * unaligned_ssbo;','alignment changes identity'),
            ('zero-local','out->local_memory_bytes = le32(out->source.control + 0x758);','out->local_memory_bytes = 0 * le32(out->source.control + 0x758);','control facts exact'),
            ('omit-release','if (r->source.ref) s2a_source_release(r->source.ref);','/* mutation: leaked source pin */','last release reclaims source'),
            ('narrow-cbuf-mask','(s->ubo_use[5] & ~0x7FFFFu)','(s->ubo_use[5] & ~31u)','cbuf 5 accepted'),
            ('compute-ins-offset','cs_off = 0x100;','cs_off = 0x30;','0x12345679 compute header strips 0x100 bytes (instructions at +0x100)'),
        ]:
            assert text.count(old)==1,(label,'anchor')
            negative=run(label,text.replace(old,new))
            assert negative.returncode!=0 and failure in negative.stderr,(label,negative.stderr)
            print(label+': expected assertion failure')
        print('PASS: independent REQUEST bytes/canonical prefix, real source pin lifecycle, 6 negative controls')
if __name__=='__main__': main()
