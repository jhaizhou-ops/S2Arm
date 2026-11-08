#!/usr/bin/env python3
# 门禁手动：只能 Linux（tracking/platform.c 非 Linux 直接 #error），本机 macOS 跑不了；Linux 上 texture_read_test.py 编同一份生产源
import argparse,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args();o=a.out;o.mkdir(parents=True,exist_ok=True)
d='android/core-link/runtime-tests/readonly-copy/';sources=[d+'native_fixture.c',d+'native_test.c','android/native/runtime/tracking/readonly_copy.c','graphics/track/track.c','android/native/runtime/tracking/platform.c','android/native/plat_android.c','android/native/memory.c','android/native/guest_signal.c','android/native/tsd.c']
cmd=['cc','-D_GNU_SOURCE','-std=gnu11','-O2','-pthread','-Iruntime/include',*sources,'-ldl','-o',str(o/'native-readonly')]
r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(o/'build.log').write_text(r.stdout);r.check_returncode();results=[]
for mode in ['red','neighbor','legacy','private']:
    r=subprocess.run([str(o/'native-readonly'),mode],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=15)
    passed=r.returncode==-11 and 'ENTER original protected source load' in r.stdout if mode=='red' else r.returncode==0 and 'PASS '+mode+':' in r.stdout
    results.append(dict(case=mode,exit_code=r.returncode,passed=passed,output=r.stdout));print(mode,r.returncode,passed,r.stdout[-300:],flush=True)
(o/'results.json').write_text(json.dumps(dict(build_command=cmd,cases=results),ensure_ascii=False,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
