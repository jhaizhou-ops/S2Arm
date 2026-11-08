#!/usr/bin/env python3
# 门禁手动：要传参数：--out 须是已含预构建 build/bin/ReadonlyCopy.Tests 的目录（本脚本不构建）；同组消费者模式已由 texture_read_test.py 在 android/test.sh 门禁跑
"""本机 ARM64 .NET 真实纹理消费者；Mach VM 适配不冒充 Android/Linux alias。"""
import argparse,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--dotnet',default=os.environ.get('DOTNET', 'dotnet'));a=p.parse_args();out=a.out.resolve()
dotnet=shutil.which(a.dotnet)
if dotnet is None: p.error('dotnet not found; pass --dotnet or set DOTNET/PATH')
app=out/'build/bin/ReadonlyCopy.Tests/debug/S2A.SpecTest.dll';results=[]
env=os.environ.copy();env.update(DOTNET_ROOT=str(Path(dotnet).parent),DYLD_LIBRARY_PATH=str(out))
for mode in ['red','neighbor','direct','partial','borrowed','multi','hole','wrong-thread','overflow']:
    cmd=[dotnet,str(app),mode];r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30,env=env)
    red=mode=='red';passed=(r.returncode!=0 and 'ENTER protected actual Texture.SynchronizeFull' in r.stdout and 'AccessViolation' in r.stdout) if red else r.returncode==0 and 'PASS '+mode+':' in r.stdout
    (out/('mac-'+mode+'.log')).write_text(r.stdout);results.append(dict(case=mode,passed=passed,expected_red=red,exit_code=r.returncode,command=cmd,output=r.stdout));print(mode,r.returncode,passed,r.stdout[-400:],flush=True)
    (out/'mac-consumer-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
