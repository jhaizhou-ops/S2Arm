#!/usr/bin/env python3
# 门禁手动：要传参数：--library 编好的安卓解码库，手动跑
"""Execute the real shim and pinned decoder against independent per-AU hashes."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path

class Config(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('abi_version','struct_size','width','height')]
class Diag(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('abi_version','struct_size','stage','code','ivd_status','ivd_error','consumed','decoded','output','input_token','output_token','width','height','generation')]
class Plane(C.Structure):
    _fields_ = [('data',C.c_void_p),('capacity',C.c_uint64)]+[(n,C.c_uint32) for n in ('width','height','stride','reserved')]
class Planes(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('abi_version','struct_size','format','progressive','token','generation')]+[('plane',Plane*3)]

def diag(): return Diag(1,C.sizeof(Diag))
def bind(path):
    lib=C.CDLL(str(Path(path).resolve()))
    lib.s2a_avc_create.argtypes=[C.POINTER(Config),C.POINTER(C.c_void_p),C.POINTER(Diag)]
    lib.s2a_avc_decode.argtypes=[C.c_void_p,C.c_char_p,C.c_uint32,C.c_char_p,C.c_uint32,C.c_char_p,C.c_uint32,C.c_uint32,C.POINTER(Diag)]
    lib.s2a_avc_planes.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(Planes),C.POINTER(Diag)]
    lib.s2a_avc_destroy.argtypes=[C.c_void_p,C.POINTER(Diag)]
    lib.s2a_avc_test_fault.argtypes=[C.c_uint32]
    lib.s2a_avc_test_fail_allocation.argtypes=[C.c_int64]
    lib.s2a_avc_test_live_allocations.restype=C.c_uint64
    lib.s2a_avc_test_allocation_calls.restype=C.c_uint64
    return lib

def nals(data):
    import re
    starts=list(re.finditer(b'\x00\x00(?:\x00)?\x01',data))
    return [(m.start(), data[m.end():starts[i+1].start() if i+1<len(starts) else len(data)].rstrip(b'\0')) for i,m in enumerate(starts)]
def headers(data):
    return [b'\0\0\0\1'+next(v for _,v in nals(data) if v[0]&31==t) for t in (7,8)]
def ue_bits(value):
    size=(value+1).bit_length()
    return '0'*(size-1)+format(value+1,'0%db'%size)
def read_ue(bits,pos):
    zeros=0
    while bits[pos]=='0': zeros+=1; pos+=1
    pos+=1
    value=(1<<zeros)-1+(int(bits[pos:pos+zeros],2) if zeros else 0)
    return value,pos+zeros
def rbsp_bits(nal):
    out=bytearray(); zeros=0
    for i,value in enumerate(nal[1:]):
        if zeros>=2 and value==3:
            following=nal[i+2] if i+2<len(nal) else None
            if following is None or following>3: raise ValueError('bad emulation prevention')
            zeros=0; continue
        out.append(value); zeros=zeros+1 if value==0 else 0
    return ''.join(format(value,'08b') for value in out)
def rbsp_bytes(bits):
    bits+='0'*((-len(bits))%8)
    out=bytearray(); zeros=0
    for i in range(0,len(bits),8):
        value=int(bits[i:i+8],2)
        if zeros>=2 and value<=3: out.append(3); zeros=0
        out.append(value); zeros=zeros+1 if value==0 else 0
    return bytes(out)
def mixed_slice_type_au(au,old,new):
    """Retype the second slice of a real multi-slice AU from old to new.
    Both Exp-Golomb codes have the same width, so every other slice-header field
    and the AU length stay byte-identical; only the identity field slice_type differs."""
    assert len(ue_bits(old))==len(ue_bits(new)) and new<=9
    result=bytearray(); slices=0; changed=0
    for _,nal in nals(au):
        payload=bytes(nal)
        if (payload[0]&31) in (1,5):
            slices+=1
            if slices==2:
                bits=rbsp_bits(payload)
                mb,pos=read_ue(bits,0)
                slice_type,pos=read_ue(bits,pos)
                assert mb>0 and slice_type==old,(mb,slice_type)
                code=ue_bits(slice_type)
                assert bits[pos-len(code):pos]==code
                bits=bits[:pos-len(code)]+ue_bits(new)+bits[pos:]
                payload=payload[:1]+rbsp_bytes(bits)
                changed+=1
        result+=b'\0\0\0\1'+payload
    assert slices>=2 and changed==1
    return bytes(result)
def create(lib,w,h):
    ptr=C.c_void_p(); d=diag()
    rc=lib.s2a_avc_create(C.byref(Config(1,C.sizeof(Config),w,h)),C.byref(ptr),C.byref(d))
    assert rc==0, ('create',rc,describe(d))
    return ptr

def decode(lib,h,au,sps,pps,token):
    d=diag(); rc=lib.s2a_avc_decode(h,au,len(au),sps,len(sps),pps,len(pps),token,C.byref(d))
    return rc,d

def describe(d): return {n: getattr(d,n) for n,_ in d._fields_}
def run(lib,manifest,allocation_fail=False):
    data=(manifest.parent / json.loads(manifest.read_text())['file']).read_bytes()
    m=json.loads(manifest.read_text()); sps,pps=headers(data)
    assert hashlib.sha256(data).hexdigest()==m['sha256']
    h=create(lib,m['width'],m['height'])
    try:
        if m.get('display_height',m['height'])!=m['height']:
            row=m['frames'][0];rc,d=decode(lib,h,data[row['offset']:row['offset']+row['length']],sps,pps,0)
            assert rc<0, 'raw crop must not write a mismatched coded surface'
            return True
        for row in m['frames']:
            au=data[row['offset']:row['offset']+row['length']]
            token=(0xfffffff8+row['decode_index'])&0xffffffff
            rc,d=decode(lib,h,au,sps,pps,token)
            if allocation_fail and rc!=0: return False
            assert rc==0, (manifest.name,row['decode_index'],rc,describe(d))
            view=Planes(1,C.sizeof(Planes)); vd=diag()
            assert lib.s2a_avc_planes(h,token,C.byref(view),C.byref(vd))==0
            assert view.token==token and view.generation==1
            packed=[]
            for plane in view.plane:
                assert plane.stride>=plane.width and plane.capacity>=(plane.height-1)*plane.stride+plane.width
                packed.append(b''.join(C.string_at(plane.data+y*plane.stride,plane.width) for y in range(plane.height)))
            hashes=[hashlib.sha256(p).hexdigest() for p in packed]
            assert hashes==row['planes_sha256'], (manifest.name,row['decode_index'],'plane hash',hashes,row['planes_sha256'])
            assert hashlib.sha256(b''.join(packed)).hexdigest()==row['sha256']
        return True
    finally:
        d=diag(); assert lib.s2a_avc_destroy(h,C.byref(d))==0
        assert lib.s2a_avc_test_live_allocations()==0

def negative_tests(lib, directory):
    m=json.loads((directory/'b-refs4.json').read_text()); data=(directory/m['file']).read_bytes()
    sps,pps=headers(data)
    frames=[data[r['offset']:r['offset']+r['length']] for r in m['frames']]
    def reject(name,au,ss=sps,pp=pps,fault=0,expect=None):
        h=create(lib,m['width'],m['height'])
        try:
            lib.s2a_avc_test_fault(fault)
            rc,d=decode(lib,h,au,ss,pp,19)
            assert rc<0,(name,rc,describe(d))
            if expect is not None:
                want=(expect[0]&0xffffffff,expect[1])
                assert (d.code,d.stage)==want,(name,describe(d))
            rc,d=decode(lib,h,frames[0],sps,pps,20)
            assert rc<0,('failed context reused',name)
            view=Planes(1,C.sizeof(Planes)); vd=diag()
            assert lib.s2a_avc_planes(h,19,C.byref(view),C.byref(vd))<0
        finally:
            lib.s2a_avc_test_fault(0)
            d=diag(); assert lib.s2a_avc_destroy(h,C.byref(d))==0
            assert lib.s2a_avc_test_live_allocations()==0
        print('PASS negative',name,flush=True)
    for fault in range(1,9): reject('native-output-fault-'+str(fault),frames[0],fault=fault)
    def packed(bits):
        bits+='1'; bits+='0'*((-len(bits))%8)
        return int(bits,2).to_bytes(len(bits)//8,'big')
    high10=b'\0\0\0\1\x67\x6e\0\x1f'+packed('1'+'010'+'011'+'011'+'00')
    high422=b'\0\0\0\1\x67\x64\0\x1f'+packed('1'+'011'+'1'+'1'+'00')
    reject('High10-metadata-headers',frames[0],high10)
    reject('422-metadata-headers',frames[0],high422)
    reject('High10-inband-SPS',high10+frames[0])
    fmo=b'\0\0\0\1\x68'+packed('1'+'1'+'00'+'010')
    reject('FMO-PPS',frames[0],sps,fmo,expect=(-3,4))
    reject('FMO-inband-PPS',fmo+frames[0],expect=(-3,4))
    reject('mixed-slice-type-identity',mixed_slice_type_au(frames[1],5,6),expect=(-5,4))
    reject('empty',b'')
    reject('only-headers',sps+pps)
    reject('truncated',frames[0][:-200])
    reject('multiple-pictures',frames[0]+frames[1])
    reject('unsupported-extension',b'\0\0\1\x74\x80')
    reject('missing-SPS',frames[0],b'')
    reject('wrong-header-type',frames[0],pps)
    reject('non-IDR-start',frames[1])
    for width,height in ((0,240),(0xffffffff,240)):
        h=C.c_void_p(123);d=diag();cfg=Config(1,C.sizeof(Config),width,height)
        assert lib.s2a_avc_create(C.byref(cfg),C.byref(h),C.byref(d))<0 and not h.value
    cfg=Config(99,C.sizeof(Config),320,240);h=C.c_void_p();d=diag()
    assert lib.s2a_avc_create(C.byref(cfg),C.byref(h),C.byref(d))<0
    # Two live decoder contexts may be interleaved without sharing output/DPB.
    left=create(lib,320,240);right=create(lib,320,240)
    try:
        for i,au in enumerate(frames):
            for handle in (left,right):
                rc,d=decode(lib,handle,au,sps,pps,i)
                assert rc==0,describe(d)
        view=Planes(1,C.sizeof(Planes));d=diag()
        assert lib.s2a_avc_planes(left,999,C.byref(view),C.byref(d))<0
    finally:
        for handle in (left,right):
            d=diag();assert lib.s2a_avc_destroy(handle,C.byref(d))==0
    assert lib.s2a_avc_test_live_allocations()==0
    print('PASS ABI/oversize, wrong-token, interleaved contexts, live=0',flush=True)

def reconstructed_tests(lib,directory):
    for path in sorted(directory.glob('*.json')):
        m=json.loads(path.read_text());data=(directory/m['file']).read_bytes()
        raw=(directory/(path.stem+'.headers')).read_bytes()
        changed=(directory/(path.stem+'.pps-change')).read_bytes()
        assert hashlib.sha256(raw).hexdigest()==m['reconstructed_headers_sha256']
        assert hashlib.sha256(changed).hexdigest()==m['pps_changed_headers_sha256']
        sps,pps=headers(raw);_,next_pps=headers(changed)
        for mode in ('reconstructed','pps_changed'):
            h=create(lib,m['width'],m['height'])
            try:
                for row in m['frames']:
                    i=row['decode_index']
                    au=b''.join(b'\0\0\0\1'+v for _,v in nals(data[row['offset']:row['offset']+row['length']]) if v[0]&31 not in (7,8))
                    rc,d=decode(lib,h,au,sps,next_pps if mode=='pps_changed' and i>=4 else pps,i)
                    assert rc==0,(path.name,mode,i,describe(d))
                    view=Planes(1,C.sizeof(Planes));vd=diag()
                    assert lib.s2a_avc_planes(h,i,C.byref(view),C.byref(vd))==0
                    assert view.generation==1, 'identical SPS/PPS-only update recreated decoder'
                    packed=[b''.join(C.string_at(p.data+y*p.stride,p.width) for y in range(p.height)) for p in view.plane]
                    assert [hashlib.sha256(p).hexdigest() for p in packed]==row[mode+'_planes_sha256'],(path.name,mode,i)
            finally:
                d=diag();assert lib.s2a_avc_destroy(h,C.byref(d))==0
        print('PASS Level31/16refs + PPS-only oracle',path.name,flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',required=True)
    parser.add_argument('--vectors',type=Path,default=Path(__file__).parent/'vectors')
    args=parser.parse_args(); lib=bind(args.library)
    for m in sorted(args.vectors.glob('*.json')):
        assert run(lib,m); print('PASS',m.name,flush=True)
    reconstructed_tests(lib,args.vectors)
    negative_tests(lib,args.vectors)
    first=next(args.vectors.glob('*.json'))
    lib.s2a_avc_test_fail_allocation(-1); run(lib,first)
    count=lib.s2a_avc_test_allocation_calls()
    for index in range(count):
        lib.s2a_avc_test_fail_allocation(index)
        try:
            run(lib,first,True)
        except AssertionError as error:
            # Only wrapper CREATE may fail before a context is returned.
            assert error.args[0][0]=='create', error
        assert lib.s2a_avc_test_live_allocations()==0, ('allocation leak',index)
    lib.s2a_avc_test_fail_allocation(-1)
    d=diag(); assert lib.s2a_avc_destroy(None,C.byref(d))==0
    print('PASS allocation failures',count,'live=0; destroy(NULL)',flush=True)
if __name__=='__main__': main()
