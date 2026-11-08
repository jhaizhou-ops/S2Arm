#!/usr/bin/env python3
# 门禁手动：辅助脚本，由 writers-gate/run.py 完整模式（Linux ARM64，gate_not_default.tsv 登记）传入编好的二进制与输出目录调用，本身不独立跑
"""Real serial acquisition followed by an independent 350ms G holder, R5 regression."""
import ctypes
import json, mmap, os, struct, subprocess, sys, time
from pathlib import Path
binary=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
old='--old-red' in sys.argv;rows=[]
for fg in (1,0):
    name='foreground' if fg else 'background'
    path=out/(name+'.shared');path.write_bytes(bytes(256))
    with path.open('r+b') as f, mmap.mmap(f.fileno(),256) as page:
        def put(i,v):struct.pack_into('Q',page,i*8,v)
        def get(i):return struct.unpack_from('Q',page,i*8)[0]
        for i,v in enumerate((1,3000,30000,fg,1,0,0)):put(i,v)
        p=subprocess.Popen([str(binary),'external-published'],env=dict(os.environ,S2A_BACKING_SHARED=str(path),S2A_TEST_ROSTER_HANDOFF='1'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        limit=time.monotonic()+3
        while not get(5) and p.poll() is None and time.monotonic()<limit:time.sleep(.005)
        assert get(5),'contender never entered admission'
        time.sleep(.3);start=time.monotonic();put(6,1)
        stdout,stderr=p.communicate(timeout=5);(out/(name+'.log')).write_text(stdout+stderr)
        row=dict(foreground=fg,exit=p.returncode,elapsed_after_release=time.monotonic()-start,injected='holds G for 350ms' in stderr,errno110='errno=110' in stderr);rows.append(row)
        assert row['injected'],row
        assert (p.returncode!=0 and row['errno110']) if old and not fg else p.returncode==0,row
(out/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS serial admission roster handoff',json.dumps(rows))
