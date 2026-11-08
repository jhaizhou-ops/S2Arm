#!/usr/bin/env python3
# 门禁手动：辅助脚本（用例生成器），先跑 Avc.Tests 输出重建头，再由它独立生成期望，要传向量与输出目录，本身不是单测
"""Explicit independent oracle for headers emitted by production reconstruction.
First run Avc.Tests <vectors> <header-output-directory>, then this script.
The decoder under test never generates expected pixels.
"""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from native_test import nals

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--headers',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent/'vectors'
sha=lambda p:hashlib.sha256(p).hexdigest()
for path in sorted(root.glob('*.json')):
    m=json.loads(path.read_text());w,h=m['width'],m['height']
    data=(root/m['file']).read_bytes()
    initial=(args.headers/(path.stem+'.headers')).read_bytes()
    changed=(args.headers/(path.stem+'.pps-change')).read_bytes()
    (root/(path.stem+'.headers')).write_bytes(initial)
    (root/(path.stem+'.pps-change')).write_bytes(changed)
    changed_pps=b'\0\0\0\1'+next(v for _,v in nals(changed) if v[0]&31==8)
    m['reconstructed_headers_sha256']=sha(initial);m['pps_changed_headers_sha256']=sha(changed)
    m['reconstructed_reference']='FFmpeg 9.0.2 software H.264 decoder, -threads 1; headers emitted by real PictureInfo.Convert + SpsAndPpsReconstruction; fixed High/31/16refs'
    for mode in ('reconstructed','pps_changed'):
        stream=bytearray(initial)
        for i,row in enumerate(m['frames']):
            if mode=='pps_changed' and i==4:stream.extend(changed_pps)
            au=data[row['offset']:row['offset']+row['length']]
            for _,v in nals(au):
                if v[0]&31 not in (7,8):stream.extend(b'\0\0\0\1'+v)
        m[mode+'_stream_sha256']=sha(stream)
        with tempfile.NamedTemporaryFile(suffix='.h264') as f:
            f.write(stream);f.flush()
            decoded=subprocess.run(['ffmpeg','-v','error','-threads','1','-i',f.name,'-pix_fmt','yuv420p','-f','rawvideo','-'],check=True,capture_output=True).stdout
        assert len(decoded)==len(m['frames'])*w*h*3//2
        for row in m['frames']:
            start=row['presentation_index']*w*h*3//2
            frame=decoded[start:start+w*h*3//2]
            planes=[frame[:w*h],frame[w*h:w*h*5//4],frame[w*h*5//4:]]
            row[mode+'_planes_sha256']=[sha(p) for p in planes];row[mode+'_sha256']=sha(frame)
    path.write_text(json.dumps(m,indent=2)+'\n')
    print('PASS reference',path.name,flush=True)
