#!/usr/bin/env python3
# 门禁手动：只能 Linux（runtime_test.c 的 mkdtemp 等 glibc 声明，macOS 编不过），本机跑不了，门禁 Linux 路径本轮没实跑验证
"""真实runtime+共享Android入口；managed/fault provider为明确合成端点。"""
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--cc',default='cc');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[3];out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
exe=out/'thread-gate';flags=[a.cc,'-D__ANDROID__','-std=gnu11','-pthread','-Wall','-Wextra','-Werror']
for d in ['runtime/include','runtime/src','android/native','android/native/runtime']:flags+=['-I',str(root/d)]
objects=[]
sources=[(root/'android/native/runtime/runtime.c', []),
         (root/'runtime/src/guest_main.c', []),
         (pathlib.Path(__file__).with_name('thread_gate_test.c'), [])]
sources += [(root/f'android/native/direct/{n}.c', ['-U__ANDROID__']) for n in ['selection','attempt','graphics','json','sha256','s2a_direct_abi']]
for i,(source,extra) in enumerate(sources):
    obj=out/f'{i}.o'
    subprocess.run(flags+extra+['-c',str(source),'-o',str(obj)],check=True)
    objects.append(str(obj))
subprocess.run(flags+objects+['-o',str(exe)],check=True)
results=[]
for case in ['ready','attach-fail','attach-wrong-session','attach-stop','probe-fail','prepared-only']:
    r=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=10)
    passed=r.returncode==0 and 'SDK_ENTRY' in r.stdout if case=='ready' else r.returncode==-6 and 'SDK_ENTRY' not in r.stdout and '最终准入失败' in r.stderr
    results.append(dict(case=case,passed=passed,returncode=r.returncode,stdout=r.stdout,stderr=r.stderr));print(case,'PASS' if passed else 'FAIL')
(out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
if not all(x['passed'] for x in results):raise SystemExit(1)
