#!/usr/bin/env python3
# 门禁手动：辅助脚本（用例生成器），用 FFmpeg/libx264 重新生成已提交的码流夹具，门禁只读已提交码流，本身不是单测
"""Explicit, network-free fixture generation (requires FFmpeg/libx264).
The mathematical source patterns and generated bitstreams are dedicated to CC0.
Normal tests only read committed bitstreams and independent decoded SHA values.
"""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path
from native_test import nals

HERE=Path(__file__).resolve().parent

def sha(data): return hashlib.sha256(data).hexdigest()
def command(args): return subprocess.run(args,check=True,capture_output=True)
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--only');args=parser.parse_args()
    version=command(['ffmpeg','-version']).stdout.decode()
    specifications=[('b-refs4',320,240,16,4,3,1,3),('cavlc',320,240,8,4,0,0,3),
                    ('b-refs16',320,240,16,16,3,1,1),('b-720',1280,720,12,4,3,1,3),
                    ('b-1088',1920,1088,12,4,3,1,3),('b-1080-crop',1920,1080,12,4,3,1,3)]
    target=HERE/'vectors'; target.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name,w,h,count,refs,bframes,cabac,slices in specifications:
            if args.only and args.only!=name: continue
            raw=Path(tmp)/'source.yuv'
            pattern=f'nullsrc=s={w}x{h}:r=30,geq=lum=mod(X+Y+N*13\\,220)+16:cb=80+mod(X+N*5\\,70):cr=90+mod(Y+N*7\\,80)'
            command(['ffmpeg','-v','error','-f','lavfi','-i',pattern,'-frames:v',str(count),'-pix_fmt','yuv420p','-f','rawvideo','-y',str(raw)])
            params=f'aud=1:repeat-headers=1:slices={slices}:ref={refs}:bframes={bframes}:cabac={cabac}:b-adapt=0:b-pyramid=normal:keyint=60:weightp=0:weightb=0:scenecut=0'
            path=target/(name+'.h264')
            args=['ffmpeg','-hide_banner','-f','rawvideo','-pixel_format','yuv420p','-video_size',f'{w}x{h}','-framerate','30','-i',str(raw),'-frames:v',str(count),'-c:v','libx264','-preset','medium','-x264-params',params,'-f','h264','-y',str(path)]
            encoded=command(args)
            (target/(name+'.encoder.txt')).write_text(encoded.stderr.decode().replace(str(raw),'<source.yuv>').replace(str(path),path.name))
            data=path.read_bytes()
            probe=json.loads(command(['ffprobe','-v','error','-show_frames','-show_entries','frame=pkt_pos,pict_type','-of','json',str(path)]).stdout)['frames']
            golden=command(['ffmpeg','-v','error','-threads','1','-i',str(path),'-pix_fmt','yuv420p','-f','rawvideo','-']).stdout
            trace=command(['ffmpeg','-v','verbose','-i',str(path),'-c:v','copy','-bsf:v','trace_headers','-f','null','-']).stderr.decode()
            fields={key:int(value) for key,value in re.findall(r'\]\s+\d+\s+([a-z0-9_]+)\s+[01]+\s+=\s+(-?\d+)',trace)}
            keys=['chroma_format_idc','log2_max_frame_num_minus4','pic_order_cnt_type','log2_max_pic_order_cnt_lsb_minus4','frame_mbs_only_flag','direct_8x8_inference_flag','entropy_coding_mode_flag','bottom_field_pic_order_in_frame_present_flag','num_ref_idx_l0_default_active_minus1','num_ref_idx_l1_default_active_minus1','weighted_pred_flag','weighted_bipred_idc','pic_init_qp_minus26','chroma_qp_index_offset','second_chroma_qp_index_offset','deblocking_filter_control_present_flag','constrained_intra_pred_flag','redundant_pic_cnt_present_flag','transform_8x8_mode_flag']
            info={key:fields.get(key,0) for key in keys}; info['chroma_format_idc']=fields.get('chroma_format_idc',1)
            positions=[off for off,v in nals(data) if v[0]&31==9]+[len(data)]
            rows=[]
            for i,(a,b) in enumerate(zip(positions,positions[1:])):
                display=next(j for j,f in enumerate(probe) if int(f['pkt_pos'])==a)
                frame=golden[display*w*h*3//2:(display+1)*w*h*3//2]
                planes=[frame[:w*h],frame[w*h:w*h*5//4],frame[w*h*5//4:]]
                types=[v for _,v in nals(data[a:b]) if v[0]&31 in (1,5)]
                rows.append(dict(offset=a,length=b-a,decode_index=i,presentation_index=display,poc=display*2,pict_type=probe[display]['pict_type'],idr=types[0][0]&31==5,reference=bool(types[0][0]&96),planes_sha256=[sha(p) for p in planes],sha256=sha(frame)))
            manifest=dict(file=path.name,width=w,height=(h+15)//16*16,display_width=w,display_height=h,sha256=sha(data),source_sha256=sha(raw.read_bytes()),source='Original mathematical pattern in generate_vectors.py',license='CC0-1.0',encoder_version=version,encoder_parameters=params,reference='FFmpeg 9.0.2 software H.264, threads=1, native decoder (no hardware)',picture_info=info,frames=rows)
            path.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
            print(name,len(data),'bytes',flush=True)
if __name__=='__main__': main()
