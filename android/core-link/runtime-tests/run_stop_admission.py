#!/usr/bin/env python3
# 门禁手动：只能 Linux（-Wl,--wrap=pthread_create 要 GNU ld），本机跑不了，门禁 Linux 路径本轮没实跑验证
"""Linux 实际 HostApi 并发测试；负控可指定修复前 production runtime。"""
import argparse, json, pathlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--out',type=pathlib.Path,required=True)
p.add_argument('--baseline-runtime',type=pathlib.Path)
p.add_argument('--cc',default='cc')
a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[3]
out=a.out.resolve(); out.mkdir(parents=True,exist_ok=True)
base=[a.cc,'-D_GNU_SOURCE','-std=c11','-Wall','-Wextra','-Werror','-pthread','-Wl,--wrap=pthread_create']
for directory in ['runtime/include','runtime/src','android/native','android/native/runtime']:
    base+=['-I',str(root/directory)]
sources=[root/'android/core-link/runtime-tests/stop_admission_test.c',root/'runtime/src/guest_main.c']
sources += [root/f'android/native/{name}.c' for name in ['host_android','hostapi','input','wsi_lease']]
# 合并后的 runtime.c 引用 dev 的 v2/direct 选择器；stop-admission 夹具也需链接这些生产源。
sources += [root/f'android/native/direct/{name}.c' for name in ['selection','attempt','graphics','json','sha256','s2a_direct_abi']]
# merged host_android.c 发布 HostApi.ui：链接真实 Android UI 表。
sources += [root/'android/native/host_ui.c', root/'android/native/host_ui_android.c']
results=[]
for label,runtime,cases in [('candidate',root/'android/native/runtime/runtime.c',['late-host-stop','runtime-stop','admitted-first','latch','vk-direct-nvn'])] + ([('baseline',a.baseline_runtime,['late-host-stop','vk-direct-nvn'])] if a.baseline_runtime else []):
    exe=out/label
    subprocess.run(base+list(map(str,sources))+[str(runtime),'-o',str(exe)],check=True)
    for case in cases:
        r=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=10)
        passed=r.returncode==0 if label=='candidate' else r.returncode!=0
        results.append(dict(label=label,case=case,passed=passed,returncode=r.returncode,stdout=r.stdout,stderr=r.stderr))
        print(label,case,'PASS' if passed else 'FAIL',r.returncode,flush=True)
(out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
if not all(r['passed'] for r in results): raise SystemExit(1)
