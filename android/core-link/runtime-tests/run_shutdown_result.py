#!/usr/bin/env python3
# 门禁手动：只能 Linux（direct/selection.c 用 getrandom，macOS 编不过），本机跑不了，门禁 Linux 路径本轮没实跑验证
"""真实native cleanup结果门，不把合成status生产者当managed cleanup已验。"""
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path,required=True);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[3];out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
f=['cc','-D_GNU_SOURCE','-std=c11','-Wall','-Wextra','-Werror','-pthread']
for d in ['runtime/include','runtime/src','android/native','android/native/runtime']:f+=['-I',str(root/d)]
exe=out/'shutdown-result';subprocess.run(f+[str(root/'android/native/runtime/runtime.c'),str(root/'runtime/src/guest_main.c'),*[str(root/f'android/native/direct/{n}.c') for n in ['selection','attempt','graphics','json','sha256','s2a_direct_abi']],str(pathlib.Path(__file__).with_name('shutdown_result_test.c')),'-o',str(exe)],check=True)
results=[]
for case in ['stopped','never-start','missing-cleanup','wrong-session','failed-cleanup','error-with-stopped','query-fail']:
 r=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=10);results.append(dict(case=case,returncode=r.returncode,stdout=r.stdout,stderr=r.stderr));print(case,'PASS' if r.returncode==0 else 'FAIL')
(out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
if any(r['returncode'] for r in results):raise SystemExit(1)
