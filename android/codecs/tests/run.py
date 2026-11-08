#!/usr/bin/env python3
# 门禁手动：要传参数：--archive 按 codecs/build.sh 固定 SHA 预置的 libavc 源码包（门禁不联网），见 android/tests/gate_not_default.tsv
"""Offline real libavc/shim tests. Source acquisition is a separate explicit build."""
import argparse
import importlib.util
import platform
import re
import subprocess
from pathlib import Path

here=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive',type=Path,required=True)
parser.add_argument('--out',type=Path,required=True)
parser.add_argument('--cc',default='clang',help='host C compiler (Clang by default)')
parser.add_argument('--sanitize',action='store_true')
parser.add_argument('--sanitize-shim',action='store_true',help='upstream ASan; shim/driver strict ASan+UBSan')
args=parser.parse_args()
args.out.mkdir(parents=True,exist_ok=False)
expected=re.search(r'^avc_content_sha=([a-f0-9]{64})$',(here.parent/'build.sh').read_text(),re.M)[1]
spec=importlib.util.spec_from_file_location('avc_source',here.parent/'avc_source.py')
verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
verifier.verify(args.archive,expected)
source=args.out/'source'; source.mkdir()
# Verify the private bytes that will actually be extracted, as in production.
import shutil
archive=args.out/'source.tar.gz';shutil.copyfile(args.archive,archive)
verifier.verify(archive,expected)
subprocess.run(['tar','-xzf',str(archive),'-C',str(source)],check=True)

def run(name,cmd):
    with (args.out/(name+'.log')).open('w') as log:
        import os
        env=dict(os.environ)
        env['UBSAN_OPTIONS']='halt_on_error='+('0' if args.sanitize else '1')+':print_stacktrace=1'
        subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True,env=env)
    report=(args.out/(name+'.log')).read_text()
    from sanitizer_report import inspect
    known=inspect(report,args.out/'source',allow_upstream=args.sanitize and name.startswith('asan-'))
    if known: print('KNOWN UPSTREAM UBSAN (full scope not clean):',name,len(known),'diagnostic sites; complete log retained',flush=True)
    print('PASS',name,flush=True)

system=platform.system(); machine='arm64' if system=='Darwin' else 'aarch64'
assert platform.machine().lower() in ('arm64','aarch64'),'suite requires ARM64'
config=['cmake','-S',str(source),'-B',str(args.out/'build'),'-DSYSTEM_NAME='+system,'-DSYSTEM_PROCESSOR='+machine,'-DENABLE_TESTS=OFF','-DENABLE_MVC=OFF','-DENABLE_SVC=OFF','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POSITION_INDEPENDENT_CODE=ON']
sanitized=args.sanitize or args.sanitize_shim
if sanitized: config+=['-DSANITIZE='+('address,undefined' if args.sanitize else 'address')]
run('configure',config)
run('build',['cmake','--build',str(args.out/'build'),'--target','libavcdec','--parallel','2'])
# The real production shim is compiled, never copied into the fixture.
lib=args.out/('libs2arm_android.dylib' if system=='Darwin' else 'libs2arm_android.so')
compile=[args.cc,'-std=c11','-Wall','-Wextra','-Werror','-fPIC','-shared','-DS2A_AVC_TESTING',
         '-I'+str(source/'common'),'-I'+str(source/'decoder'),str(here.parent/'s2a_avc.c'),str(args.out/'build/libavcdec.a'),'-lpthread','-lm','-o',str(lib)]
if sanitized: compile+=['-fsanitize=address,undefined','-fno-sanitize-recover=all']
run('shim',compile)
import sys
if not sanitized:
    run('vectors',[sys.executable,str(here/'native_test.py'),'--library',str(lib)])
else:
    import struct,json
    from native_test import nals,headers
    driver=args.out/'asan_test'
    command=[v for v in compile if v!='-shared']
    command[command.index('-o')+1]=str(driver)
    command += [str(here/'asan_test.c')]
    run('asan-driver-build',command)
    pps_driver=args.out/'pps_update_test'
    if args.sanitize_shim:
        pps_command=[v for v in compile if v!='-shared']
        pps_command[pps_command.index('-o')+1]=str(pps_driver)
        pps_command += [str(here/'pps_update_test.c')]
        run('pps-update-build',pps_command)
        # P0 regression: an 18-byte slice-only IDR AU grows a 44-byte scratch,
        # then a 47-byte production-reconstructed PPS must reallocate without
        # touching freed memory (pre-fix this is an ASan heap-buffer-overflow).
        tiny=bytes.fromhex((here/'vectors/tiny.h264.hex').read_text())
        sps,pps=headers(tiny)
        au=b'\0\0\0\1'+next(v for _,v in nals(tiny) if v[0]&31==5)
        _,changed=headers((here/'vectors/b-refs4.headers').read_bytes())
        assert len(au)==18 and len(changed)==47
        fixture=args.out/'pps-update.input'
        fixture.write_bytes(b''.join(struct.pack('<I',len(x)) for x in (sps,pps,au,changed))+sps+pps+au+changed)
        run('asan-pps-update',[str(pps_driver),str(fixture)])
    for path in sorted((here/'vectors').glob('*.json')):
        manifest=json.loads(path.read_text());data=(path.parent/manifest['file']).read_bytes()
        sps,pps=headers((path.parent/(path.stem+'.headers')).read_bytes())
        package=bytearray(struct.pack('<IIIII',manifest['width'],manifest['height'],len(sps),len(pps),len(manifest['frames'])))+sps+pps
        for row in manifest['frames']:
            au=b''.join(b'\0\0\0\1'+v for _,v in nals(data[row['offset']:row['offset']+row['length']]) if v[0]&31 not in (7,8))
            package+=struct.pack('<II',len(au),row['decode_index'])+au
        fixture=args.out/(path.stem+'.input');fixture.write_bytes(package)
        run('asan-'+path.stem,[str(driver),str(fixture)])

if not sanitized:
    for mutation,signal in [('S2A_AVC_MUTATE_DISPLAY_ORDER','AssertionError'),
                            ('S2A_AVC_MUTATE_SWAP_UV','plane hash'),
                            ('S2A_AVC_MUTATE_RESEND_SPS','AssertionError')]:
        mutated=args.out/(mutation+lib.suffix)
        command=compile.copy(); command[command.index('-o')+1]=str(mutated);command+=['-D'+mutation]
        run(mutation+'-compile',command)
        result=subprocess.run([sys.executable,str(here/'native_test.py'),'--library',str(mutated)],capture_output=True,text=True)
        text=result.stdout+result.stderr
        (args.out/(mutation+'.log')).write_text(text)
        assert result.returncode!=0 and signal in text, mutation+' was not rejected'
        print('PASS rejected mutation',mutation,flush=True)
