#!/bin/bash
# 出包路径 → 运行时命中端到端单测（#116 / M3-9 第二批）。退出 0 = 绿，约 3 秒。
# 链：合成 MSL → .air → metallib + 离线索引（gal.idx / 程序表）→ PSO_M3=1 pso_gen.py 出 .mtlp-json
#     → pso_chunk.sh 的 Metal 3 分支（metal-tt）出归档 → t_m3devarch --pack 用老接口载入，
#       按 pso_gen 写进脚本的基础管线描述（8 个颜色附件 Invalid）+ MTLPipelineOptionFailOnBinaryArchiveMiss 查。
# 期望（不跑被测实现算）：夹具只有 1 条图形程序 + 1 条计算程序 → 归档里各 1 条 → 基础描述命中 1、换 BGRA8 未命中 0。
# 同时跑 A 段（设备归档：addRenderPipelineFunctions + serializeToURL → 重开 → 同描述命中、换格式 / 换写掩码未命中）。
# 不测的：iOS 目标（留给 #91）、九款真实组合数（没有游戏数据，见 graphics/tools/shbake/m3_combo.py --self-test）。
set -u
R=$(cd "$(dirname "$0")/../../.." && pwd); H=$R/graphics/tools/shbake
T=$(mktemp -d "${TMPDIR:-/tmp}/t_m3pack.XXXXXX"); trap 'rm -rf "$T"' EXIT
fail=0; n=0
ck() { n=$((n + 1)); if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=$((fail + 1)); fi; }
for t in metal metallib metal-tt; do
  xcrun -f "$t" > /dev/null 2>&1 \
    || { echo "✗ 本机没有 Metal 工具链（xcrun -f ${t}），Metal 3 归档单测没跑"; echo "t_m3pack：0 项，失败 1（缺工具链）"; exit 1; }
done
OSVER=$(sw_vers -productVersion | cut -d. -f1-2)            # 归档的最低系统版本必须与运行时一致（27.0 命中，26.0 / 15.0 不命中）
OSMAJ=$(sw_vers -productVersion | cut -d. -f1)
clang -fobjc-arc -O1 -o "$T/gpu_arch" "$H/gpu_arch.m" -framework Metal -framework Foundation 2> /dev/null \
  || { echo "✗ 编 GPU 架构探针失败"; echo "t_m3pack：0 项，失败 1"; exit 1; }
ARCH=$("$T/gpu_arch"); [ -n "$ARCH" ] || { echo "✗ 取不到本机 GPU 架构"; echo "t_m3pack：0 项，失败 1"; exit 1; }

# ---------- 夹具：1 条图形程序（顶点自取）+ 1 条计算程序 ----------
S=$T/fx; mkdir -p "$S/src" "$S/o" "$S/w" "$S/pc"
msl() { printf '#include <metal_stdlib>\nusing namespace metal;\n%s\n' "$2" > "$S/src/$1.metal" \
  && xcrun -sdk macosx metal -mmacosx-version-min=15.0 -c "$S/src/$1.metal" -o "$S/src/$1.air"; }   # 库按下限 15.0 编（与出包同，见 graphics/metal/设计.md）；归档另按运行时系统版本出
msl V 'struct VOut { float4 pos [[position]]; }; vertex VOut s1000000000000000(uint vid [[vertex_id]]) { VOut o; float2 p = float2(float((vid << 1) & 2u), float(vid & 2u)); o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }'
msl F 'fragment float4 s2000000000000000(float4 p [[position]]) { return float4(p.xy * 0.5, 0.0, 1.0); }'
msl C 'kernel void s3000000000000000(device float4 *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += 1.0; }'
ck "夹具 3 支 MSL 编成 .air" '[ -s "$S/src/V.air" ] && [ -s "$S/src/F.air" ] && [ -s "$S/src/C.air" ]'
xcrun -sdk macosx metallib "$S/src/V.air" "$S/src/F.air" "$S/src/C.air" -o "$S/gal.0.metallib"
printf '0000000000000000\tgal.0.metallib\n' > "$S/gal.shards"
# 程序表（pso_gen 第 1 个参数）：图形程序的第 7 栏是「顶点键,片元键」；计算程序 1 个键
printf 'idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n0\tt\tok\tgraphics\tt\tt\t1000000000000000,2000000000000000\t0\t\n1\tt\tok\tcompute\tt\tt\t3000000000000000\t0\t\n' > "$S/programs.tsv"
# 离线索引（gal_prog.m rec_write 的读法：u64 键 / u32 阶段 / 8×u32 集大小 / u32 输入输出位 / 32 字节类型 / 3×u32 线程组 / i32 长度表 / u32 标志）
#   顶点记录标志位 4 = 顶点自取（pso_gen 据此出基础管线，与运行时 pso_desc(…, unspec=1) 同形）
python3 - "$S/gal.idx" <<'EOF'
import struct, sys
ks = [(0x1000000000000000, 4), (0x2000000000000000, 0), (0x3000000000000000, 0)]
base = 24 + 16 * len(ks); hd = bytearray(24); hd[:4] = b'GALI'; struct.pack_into('<I', hd, 16, len(ks))
ent = recs = b''
for k, fl in ks:
    r = bytearray(100); struct.pack_into('<I', r, 96, fl)
    ent += struct.pack('<QII', k, base + len(recs), 100); recs += bytes(r)
open(sys.argv[1], 'wb').write(bytes(hd) + ent + recs)
EOF
# 头 24 + 3 条索引项 48 + 3 条记录 300 = 372 字节
ck "离线索引 gal.idx 造出 3 条记录（$(stat -f%z "$S/gal.idx") 字节）" '[ "$(stat -f%z "$S/gal.idx")" = 372 ]'

# ---------- ① pso_gen：PSO_M3=1 出 .mtlp-json ----------
PSO_M3=1 python3 "$H/pso_gen.py" "$S/programs.tsv" "$S/gal.idx" "$S/gal.shards" "$S/o/pso" 300 > "$S/pso_gen.log" 2> "$S/pso_gen.err"
ck "① pso_gen 出 .mtlp-json（不是 .mtl4-json）：$(basename "$S/o/pso.0.mtlp-json")" \
   '[ -s "$S/o/pso.0.mtlp-json" ] && [ ! -e "$S/o/pso.0.mtl4-json" ]'
ck "① 脚本条数：图形 1 / 计算 1（$(cat "$S/pso_gen.log")）" 'grep -q "\"render\": 1, \"compute\": 1" "$S/pso_gen.log"'
SB=$(stat -f%z "$S/o/pso.0.mtlp-json" 2> /dev/null || echo 0); echo "  脚本字节数：${SB}"

# ---------- ② pso_chunk.sh 的 Metal 3 分支：metal-tt 出归档 ----------
export PSO_M3=1 PSO_M3VER=$OSVER PSO_A=$ARCH PSO_PLAT=macos PSO_M=$OSMAJ
export PSO_SV=$(xcrun --sdk macosx --show-sdk-version) PSO_NTV=$(xcrun -sdk macosx metal-tt -version 2> /dev/null | head -1)
export PSO_SIG=t_m3pack PSO_O=$S/o PSO_W=$S/w PSO_PC=$S/pc
bash "$H/pso_chunk.sh" "$S/o/pso.0.mtlp-json" > "$S/chunk.out" 2>&1
BIN=$S/o/gal_pso.$ARCH.macos$OSMAJ.0.bin
ck "② pso_chunk（metal-tt）出归档：$(basename "$BIN" 2> /dev/null)" '[ -s "$BIN" ]'
L2=$(tail -1 "$S"/w/pso_*.log 2> /dev/null)
ck "② 分片没报失败（日志：${L2:-无输出}）" '! ls "$S/w"/*.fail > /dev/null 2>&1'
AB=$(stat -f%z "$BIN" 2> /dev/null || echo 0); echo "  归档字节数：${AB}"

# ---------- ③ 运行时老接口载入 + 按描述查（A 段设备归档 + B 段出包归档）----------
clang -fobjc-arc -O1 -o "$S/t_m3devarch" "$R/graphics/metal/tests/t_m3devarch.m" -framework Metal -framework Foundation -framework QuartzCore 2> "$S/cc.log" \
  || { echo "✗ 编 t_m3devarch 失败：$(head -3 "$S/cc.log")"; echo "t_m3pack：$n 项，失败 $((fail + 1))"; exit 1; }
"$S/t_m3devarch" --pack "$BIN" "$S/gal.0.metallib" s1000000000000000 s2000000000000000 > "$S/probe.log" 2>&1
rc=$?
sed -n '1,20p' "$S/probe.log" | sed 's/^/  /'
ck "③ 设备归档 + 出包归档全部按描述命中 / 反证未命中（退出 ${rc}；$(tail -1 "$S/probe.log")）" \
   '[ $rc = 0 ] && grep -q "失败 0$" <<< "$(tail -1 "$S/probe.log")"'
ck "③ 出包归档按基础描述命中 1（B2）" 'grep -q "^B2 基础管线描述（8 个附件 Invalid）命中：期望 是 → 真结果 是" "$S/probe.log"'
ck "③ 反证：附件 0 换 BGRA8 未命中（B3）" 'grep -q "^B3 反证 附件 0 换 BGRA8：期望 否 → 真结果 否" "$S/probe.log"'
H2N=$(grep -c '^B2.*真结果 是' "$S/probe.log" 2> /dev/null); H3N=$(grep -c '^B3.*真结果 命中' "$S/probe.log" 2> /dev/null)
echo "  读数：脚本 ${SB} 字节、归档 ${AB} 字节、基础描述命中 ${H2N:-0}、换 BGRA8 命中 ${H3N:-0}（反证要求 0）"
# ---------- ④ 通用多库 v2 特化配置：正式离线归档 → 强制命中与缺配置反例 ----------
# 链接版已删除：本段只用普通顶点/片元库，不依赖桩、动态库或 gal_linked 接口。
python3 - "$R" "$S/multilib" > "$S/multilib.log" 2>&1 <<'MULTILIB_PY'
import json,os,pathlib,struct,subprocess,sys
repo=pathlib.Path(sys.argv[1]).resolve();out=pathlib.Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=False)
env=dict(os.environ);env['PATH']=str(repo/'tools/bin')+':'+env['PATH']
def run(name,cmd,**kw):
 p=subprocess.run([str(x) for x in cmd],env=kw.pop('env',env),capture_output=True,text=True,timeout=kw.pop('timeout',120),**kw)
 (out/(name+'.out')).write_text(p.stdout);(out/(name+'.err')).write_text(p.stderr)
 print(name,p.returncode,flush=True)
 if p.returncode:
  print(p.stdout[-2000:]+p.stderr[-2000:],flush=True);raise SystemExit(p.returncode)
 return p.stdout
V='00000a0000000001';F='00000b0000000002'
head='#include <metal_stdlib>\nusing namespace metal;\n'
sources={V:head+f'vertex float4 s{V}(uint i [[vertex_id]]) {{ float2 p[3]={{float2(-1,-1),float2(3,-1),float2(-1,3)}};return float4(p[i],0,1); }}\n',
         F:head+f'fragment float4 s{F}() {{ return float4(1,0,0,1); }}\n'}
for key,source in sources.items():
 (out/(key+'.metal')).write_text(source)
 run(key+'-air',['xcrun','-sdk','macosx','metal','-mmacosx-version-min=15.0','-c',out/(key+'.metal'),'-o',out/(key+'.air')])
 run(key+'-lib',['xcrun','-sdk','macosx','metallib',out/(key+'.air'),'-o',out/(key+'.metallib')])
(out/'programs.tsv').write_text('idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n0\tsynthetic\tok\tgraphics\tt\tt\t'+V+','+F+'\t0\t\n')
h=bytearray(24);h[:4]=b'GALI';struct.pack_into('<I',h,16,2);table=body=b''
for key,stage,flags in [(V,1,4),(F,5,0)]:
 b=bytearray(100);struct.pack_into('<I',b,8,stage);struct.pack_into('<I',b,96,flags)
 table+=struct.pack('<QII',int(key,16),56+len(body),100);body+=b
(out/'gal.idx').write_bytes(h+table+body)
(out/'gal.shards').write_text(f'0000000000000000\t{V}.metallib\n{F}\t{F}.metallib\n')
(out/'spec.tsv').write_text(''.join(f'v2\ts{V}\ts{F}\t3\t1\t0\t0\t1\t0:{pf}:15:0:0:1:0:0:1:0\n' for pf in (80,70)))
pe=dict(env,PSO_M3='1',S2A_PSO_SPEC_ONLY='0')
for d in ['o','w','pc']:(out/d).mkdir()
args=[sys.executable,repo/'graphics/tools/shbake/pso_gen.py',out/'programs.tsv',out/'gal.idx',out/'gal.shards']
run('pso-gen',args+[out/'o/pso','300','','',out/'spec.tsv'],env=pe)
desc=json.loads((out/'o/pso.0.mtlp-json').read_text());pipes=desc['pipelines']['render_pipelines']
assert len(pipes)==3,'基础管线 1 + 完整特化配置 2'
assert all(p['vertex_function']=='alias:gal0#s'+V and p['fragment_function']=='alias:gal1#s'+F for p in pipes),'每个函数都须保留正确库归属'
assert all(len(p['color_attachments'])==8 and all(a['pixel_format']=='Invalid' for a in p['color_attachments'][1:]) for p in pipes),'空附件缺省 Invalid'
assert {p['color_attachments'][0]['pixel_format'] for p in pipes}=={'Invalid','BGRA8Unorm','RGBA8Unorm'},'两种完整颜色配置均保留'
print('描述断言：3 条管线、跨库 alias、空附件 Invalid、两种颜色配置全过',flush=True)
run('arch-compile',['clang','-fobjc-arc',repo/'graphics/tools/shbake/gpu_arch.m','-framework','Metal','-framework','Foundation','-o',out/'gpu_arch'])
arch=run('arch',[out/'gpu_arch']).strip();version=run('os',['sw_vers','-productVersion']).strip();major=version.split('.')[0]
pe.update(PSO_M3VER='.'.join(version.split('.')[:2]),PSO_A=arch,PSO_PLAT='macos',PSO_M=major,PSO_SV=run('sdk',['xcrun','--sdk','macosx','--show-sdk-version']).strip(),PSO_NTV='m3-multilib-probe',PSO_SIG='m3-multilib',PSO_O=str(out/'o'),PSO_W=str(out/'w'),PSO_PC=str(out/'pc'))
run('chunk',['bash',repo/'graphics/tools/shbake/pso_chunk.sh',out/'o/pso.0.mtlp-json'],env=pe,timeout=650)
archive=out/'o'/f'gal_pso.{arch}.macos{major}.0.bin'
assert archive.is_file() and not list((out/'w').glob('*.fail')),'必须确实出归档，不能仅看 chunk 退出码'
(out/"probe.m").write_text(r"""#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
static int failures, checks;
#define CK(x,s) do {checks++;if(!(x)){failures++;printf("FAIL %s\n",s);}}while(0)
static BOOL pixels(id<MTLDevice>d,id<MTLRenderPipelineState>p,MTLPixelFormat f,unsigned char*b){
 if(!p)return NO;
 MTLTextureDescriptor*t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:32 height:32 mipmapped:NO];t.storageMode=MTLStorageModeShared;t.usage=MTLTextureUsageRenderTarget;
 id<MTLTexture>x=[d newTextureWithDescriptor:t];id<MTLCommandQueue>q=[d newCommandQueue];id<MTLCommandBuffer>c=[q commandBuffer];if(!x||!c)return NO;
 MTLRenderPassDescriptor*r=[MTLRenderPassDescriptor renderPassDescriptor];r.colorAttachments[0].texture=x;r.colorAttachments[0].loadAction=MTLLoadActionClear;r.colorAttachments[0].storeAction=MTLStoreActionStore;r.colorAttachments[0].clearColor=MTLClearColorMake(0,1,0,1);
 id<MTLRenderCommandEncoder>en=[c renderCommandEncoderWithDescriptor:r];if(!en)return NO;
 [en setRenderPipelineState:p];[en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[en endEncoding];[c commit];[c waitUntilCompleted];if(c.status!=MTLCommandBufferStatusCompleted||c.error)return NO;
 [x getBytes:b bytesPerRow:128 fromRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0];return YES;
}
static int red(const unsigned char*b,MTLPixelFormat f){
 int n=0;for(int i=0;i<1024;i++)n+=b[i*4+(f==80?2:0)]==255&&b[i*4+1]==0&&b[i*4+(f==80?0:2)]==0&&b[i*4+3]==255;return n;
}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=5)return 2;id<MTLDevice>d=MTLCreateSystemDefaultDevice();NSError*e=nil;
 id<MTLLibrary>v=[d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e],f=[d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[2])] error:&e];
 MTLBinaryArchiveDescriptor*ad=[MTLBinaryArchiveDescriptor new];ad.url=[NSURL fileURLWithPath:@(argv[3])];id<MTLBinaryArchive>a=[d newBinaryArchiveWithDescriptor:ad error:&e];
 CK(v&&f&&a,"load separate libraries and offline archive");if(failures)return 1;
 for(NSNumber*nf in @[@80,@70]){
  MTLPixelFormat fmt=(MTLPixelFormat)nf.unsignedIntegerValue;
  MTLRenderPipelineDescriptor*ref=[MTLRenderPipelineDescriptor new];ref.vertexFunction=[v newFunctionWithName:@"s00000a0000000001"];ref.fragmentFunction=[f newFunctionWithName:@"s00000b0000000002"];ref.inputPrimitiveTopology=MTLPrimitiveTopologyClassTriangle;ref.colorAttachments[0].pixelFormat=fmt;
  if(!ref.vertexFunction||!ref.fragmentFunction){CK(0,"fixture function names");continue;}
  id<MTLRenderPipelineState>base=[d newRenderPipelineStateWithDescriptor:ref error:&e];unsigned char rb[4096]={0};BOOL refOK=pixels(d,base,fmt,rb);CK(refOK&&red(rb,fmt)==1024,"reference draw 1024 red pixels");
  MTLRenderPipelineDescriptor*p=[ref copy];p.binaryArchives=@[a];e=nil;
  id<MTLRenderPipelineState>hit=[d newRenderPipelineStateWithDescriptor:p options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];printf("format %lu archive hit %d error=%ld\n",(unsigned long)fmt,hit!=nil,(long)(e?e.code:0));
  if(!strcmp(argv[4],"missing")&&fmt==70){CK(hit==nil&&e!=nil,"missing color must miss with error");continue;}
  CK(hit!=nil,"offline archive hit");unsigned char b[4096]={0};BOOL ok=pixels(d,hit,fmt,b);CK(ok&&red(b,fmt)==1024,"archive draw 1024 red pixels");CK(refOK&&ok&&!memcmp(rb,b,4096),"archive pixels equal reference");printf("red %d/1024\n",red(b,fmt));
 }
 printf("offline probe %d checks %d failures\n",checks,failures);return failures?1:0;
}}
""")
run('probe-compile',['clang','-fobjc-arc','-mmacosx-version-min=15.0',out/'probe.m','-framework','Metal','-framework','Foundation','-o',out/'probe'])
probe=[out/'probe',out/(V+'.metallib'),out/(F+'.metallib')]
normal=run('positive',probe+[archive,'full']);print(normal,flush=True)
miss=out/'missing';miss.mkdir()
for d in ['o','w','pc']:(miss/d).mkdir()
sp=miss/'spec.tsv';sp.write_text((out/'spec.tsv').read_text().splitlines()[0]+'\n')
run('missing-gen',args+[miss/'o/pso','300','','',sp],env=pe)
mpe=dict(pe,PSO_O=str(miss/'o'),PSO_W=str(miss/'w'),PSO_PC=str(miss/'pc'))
run('missing-chunk',['bash',repo/'graphics/tools/shbake/pso_chunk.sh',miss/'o/pso.0.mtlp-json'],env=mpe,timeout=650)
ma=miss/'o'/archive.name
assert ma.is_file() and not list((miss/'w').glob('*.fail')),'缺配置用例自身也须出有效归档'
missing=run('missing-probe',probe+[ma,'missing']);print(missing,flush=True)
p=subprocess.run([str(x) for x in probe+[ma,'full']],env=env,capture_output=True,text=True,timeout=60)
(out/'negative-control.log').write_text(p.stdout+p.stderr)
assert p.returncode!=0,'缺配置归档不能通过完整配置验收'
print('正例：'+normal.strip().splitlines()[-1],flush=True)
print('缺颜色：'+missing.strip().splitlines()[-1],flush=True)
print('缺配置负对照：完整验收退出',p.returncode,flush=True)
MULTILIB_PY
lrc=$?
tail -12 "$S/multilib.log" | sed 's/^/  /'
ck "④ 正式多库特化归档与缺颜色负控（退出 ${lrc}）" '[ $lrc = 0 ]'
echo "t_m3pack：$n 项，失败 $fail"
[ $fail = 0 ] || exit 1
exit 0
