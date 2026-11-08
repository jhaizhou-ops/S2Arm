// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "../native/direct/vk_record.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static struct s2a_record_dispatch_state got;
static int calls;
// Original non-identity GPU-VA seam; no guest bytes or Vulkan device are used.
#define FIXTURE_GA UINT64_C(0xC000000000)
#define FIXTURE_CA UINT64_C(0x400000000)
static unsigned ga_calls;
uint64_t nvn_ga2ca(uint64_t a) {
 ga_calls++;
 return a >= FIXTURE_GA && a - FIXTURE_GA <= UINT64_C(65536)
     ? FIXTURE_CA + (a - FIXTURE_GA) : a;
}
static struct s2a_record_draw_state draw_got;
static int draw_calls;
static int capture_draw(struct s2a_vk_device*d,const struct s2a_record_draw_state*s,
 struct s2a_record_result*r,void*o){(void)d;(void)o;draw_got=*s;draw_calls++;r->code=-78;return -78;}
static int rd(void *o,uint64_t a,void *b,size_t n){(void)o;memcpy(b,(void*)(uintptr_t)a,n);return 0;}
static int wr(void *o,uint64_t a,const void *b,size_t n){(void)o;memcpy((void*)(uintptr_t)a,b,n);return 0;}
static int capture(struct s2a_vk_device*d,const struct s2a_record_dispatch_state*s,
 const struct s2a_record_memory*m,struct s2a_record_dispatch_output*out,
 struct s2a_record_result*r,void*o){(void)d;(void)m;(void)out;(void)o;got=*s;calls++;r->code=-77;return -77;}
// Default production entry is tested independently of explicitly registered callback.
int nvn_vk_compute_build(struct s2a_vk_device*d,const struct s2a_record_dispatch_state*s,
 const struct s2a_record_memory*m,struct s2a_record_dispatch_output*out,
 struct s2a_record_result*r,void*o){return capture(d,s,m,out,r,o);}
static struct s2a_vk_device dev;
static struct s2a_record_memory mem={NULL,rd,wr};
static int packet(unsigned op,const void*p,size_t n){
 uint8_t b[4096]={0};size_t z=(sizeof(op_hdr)+n+7)&~(size_t)7;
 op_hdr h={op,z};memcpy(b,&h,sizeof h);if(n)memcpy(b+sizeof h,p,n);
 struct s2a_record_result r;return s2a_record_exec_one(&dev,b,z,&mem,&r);
}
static int packet_r(unsigned op,const void*p,size_t n,struct s2a_record_result*out){
 uint8_t b[4096]={0};size_t z=(sizeof(op_hdr)+n+7)&~(size_t)7;
 op_hdr h={op,z};memcpy(b,&h,sizeof h);if(n)memcpy(b+sizeof h,p,n);
 return s2a_record_exec_one(&dev,b,z,&mem,out);
}
// Synthetic host snapshot seam for the production compact BindProgram decoder.
// Entries remain live; keys/stage mapping are fixture inputs, not decoder outputs.
static p_bind_program program_snapshots[128];
const prog_t *nvn_prog_snap_get(uint64_t serial, uint8_t keys[6][8], uint8_t *ok, uint8_t stage[6]) {
    if (!serial || serial >= 128 || program_snapshots[serial].snap.serial != serial) return NULL;
    const p_bind_program *p = &program_snapshots[serial];
    memcpy(keys, p->keys, sizeof p->keys); *ok = p->kok;
    memcpy(stage, p->stage_of, sizeof p->stage_of);
    return &p->snap;
}
static void bind(int stage,int index,uint64_t serial,uint8_t key){
 p_bind_program p={0};p.prog=(void*)(uintptr_t)(0x1000+serial);p.stages=1<<stage;p.kok=1<<index;
 p.snap.serial=serial;memset(p.stage_of,255,sizeof p.stage_of);p.stage_of[index]=stage;
 memset(p.keys[index],key,8); assert(serial < 128); program_snapshots[serial]=p;
 p_bind_program_id id={.prog=p.prog,.serial=serial,.stages=p.stages};
 _Static_assert(sizeof(p_bind_program_id)==24,"compact program payload");
 assert(packet(OP_BIND_PROGRAM,&id,sizeof id)==0);
}
// Mock only the dispatch submit API: no Vulkan device or GPU work is performed.
static int submitted, dispatched, finishes, last_completion, sets_bound;
static int command_dispatched, host_visible, host_barriers;
static int freed_commands, terminal_finishes, live_owners;
static VkResult wait_result = VK_SUCCESS;
struct test_owner { int live, command_freed; };
static struct test_owner owners[128];
static unsigned owner_count;
static int wait_odd_only;
VKAPI_ATTR VkResult VKAPI_CALL vkAllocateCommandBuffers(VkDevice d,const VkCommandBufferAllocateInfo*i,VkCommandBuffer*c){(void)d;(void)i;*c=(VkCommandBuffer)(uintptr_t)(owner_count+1);return VK_SUCCESS;}
VKAPI_ATTR VkResult VKAPI_CALL vkBeginCommandBuffer(VkCommandBuffer c,const VkCommandBufferBeginInfo*i){(void)c;(void)i;command_dispatched=host_visible=0;return VK_SUCCESS;}
VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer c){(void)c;return VK_SUCCESS;}
VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(VkDevice d,VkCommandPool p,uint32_t n,const VkCommandBuffer*c){(void)d;(void)p;assert(n==1);unsigned i=(unsigned)(uintptr_t)*c-2;assert(i<owner_count);assert(!owners[i].command_freed);owners[i].command_freed=1;freed_commands++;}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateFence(VkDevice d,const VkFenceCreateInfo*i,const VkAllocationCallbacks*a,VkFence*f){(void)d;(void)i;(void)a;*f=(VkFence)(uintptr_t)(owner_count+1);return VK_SUCCESS;}
VKAPI_ATTR void VKAPI_CALL vkDestroyFence(VkDevice d,VkFence f,const VkAllocationCallbacks*a){(void)d;(void)f;(void)a;}
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue q,uint32_t n,const VkSubmitInfo*i,VkFence f){(void)q;(void)n;(void)i;(void)f;assert(command_dispatched && host_visible);submitted++;return VK_SUCCESS;}
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d,uint32_t n,const VkFence*f,VkBool32 all,uint64_t t){(void)d;assert(n==1);(void)all;(void)t;
 if(wait_odd_only && ((uintptr_t)*f%2)==0)return VK_TIMEOUT;return wait_result;}
VKAPI_ATTR void VKAPI_CALL vkCmdBindPipeline(VkCommandBuffer c,VkPipelineBindPoint p,VkPipeline v){(void)c;assert(p==VK_PIPELINE_BIND_POINT_COMPUTE);assert(v);}
VKAPI_ATTR void VKAPI_CALL vkCmdBindDescriptorSets(VkCommandBuffer c,VkPipelineBindPoint p,VkPipelineLayout l,uint32_t first,uint32_t n,const VkDescriptorSet*s,uint32_t dc,const uint32_t*ds){(void)c;(void)l;(void)dc;(void)ds;assert(p==VK_PIPELINE_BIND_POINT_COMPUTE && first==0);assert(n==2 && s[0] && s[1]);sets_bound++;}
VKAPI_ATTR void VKAPI_CALL vkCmdDispatch(VkCommandBuffer c,uint32_t x,uint32_t y,uint32_t z){(void)c;assert(x==2 && y==3 && z==4);dispatched++;command_dispatched=1;}
VKAPI_ATTR void VKAPI_CALL vkCmdPipelineBarrier(VkCommandBuffer c,VkPipelineStageFlags src,VkPipelineStageFlags dst,VkDependencyFlags dep,uint32_t nm,const VkMemoryBarrier*m,uint32_t nb,const VkBufferMemoryBarrier*b,uint32_t ni,const VkImageMemoryBarrier*i){
 (void)c;(void)b;(void)i;assert(command_dispatched && !host_visible);
 assert(src==VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT && dst==VK_PIPELINE_STAGE_HOST_BIT && dep==0);
 assert(nm==1 && m && nb==0 && ni==0);
 assert(m->sType==VK_STRUCTURE_TYPE_MEMORY_BARRIER && !m->pNext);
 assert(m->srcAccessMask==VK_ACCESS_SHADER_WRITE_BIT && m->dstAccessMask==VK_ACCESS_HOST_READ_BIT);
 host_visible=1;host_barriers++;
}
static int finished(struct s2a_vk_device*d,void*o,int completion){(void)d;struct test_owner *token=o;assert(token>=owners && token<owners+owner_count && token->live);finishes++;last_completion=completion;
 assert(completion==0 || completion==-1 || completion==-2);
 if(completion!=-2){
  // Completion copyback/release is forbidden until its command buffer is freed.
  assert(freed_commands==terminal_finishes+1);
  assert(token->command_freed);token->live=0;
  assert(live_owners>0);live_owners--;terminal_finishes++;
 }
 return 0;}
static int gpu_builder(struct s2a_vk_device*d,const struct s2a_record_dispatch_state*s,
 const struct s2a_record_memory*m,struct s2a_record_dispatch_output*out,
 struct s2a_record_result*r,void*o){(void)d;(void)s;(void)m;(void)r;(void)o;
 out->pipeline=(VkPipeline)(uintptr_t)4;out->layout=(VkPipelineLayout)(uintptr_t)5;
 out->sets[0]=(VkDescriptorSet)(uintptr_t)6;out->sets[1]=(VkDescriptorSet)(uintptr_t)7;out->set_count=2;
 assert(owner_count<128);out->owner=&owners[owner_count++];
 ((struct test_owner*)out->owner)->live=1;out->finish=finished;live_owners++;return 0;
}

int main(void){
 dev.device=(VkDevice)(uintptr_t)1; s2a_record_reset_state();
 p_dispatch dp={.x=2,.y=3,.z=4};
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_INVALID);assert(calls==0);
 bind(5,3,42,0xab);bind(0,1,99,0xcd);
 p_bind_buf ub={.stage=5,.index=1,.addr=0x2000,.size=64};assert(packet(OP_BIND_UBO,&ub,sizeof ub)==0);
 p_bind_buf gu={.stage=0,.index=5,.addr=0x3000,.size=32};assert(packet(OP_BIND_UBO,&gu,sizeof gu)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);assert(calls==1);
 assert(got.program_serial==42 && got.program==(void*)(uintptr_t)0x102a);
 assert(got.stages==32 && got.groups[0]==2 && got.groups[1]==3 && got.groups[2]==4);
 for(int i=0;i<8;i++)assert(got.keys[0][i]==0xab);
 for(int i=1;i<6;i++)for(int j=0;j<8;j++)assert(got.keys[i][j]==0);
 for(int i=0;i<5;i++)assert(got.ubo_use[i]==0);
 assert(got.ubo_seen==(1u<<1) && !got.ssbo_seen);
 assert(got.ubo_use[5]==16 && !got.ubo_use_overflow && got.ubo[1].addr==0x2000);
 assert(!got.tex_pool_seen && !got.samp_pool_seen && !got.local_memory_seen);
 // 用户槽 2 → NVN cbuf 5：旧 5 位窗口容不下，现在按 cbuf 号掩码表达（位 3..18 全可达），
 // 不再判 overflow；cbuf 号的位由 record 填表直接给出。
 ub.index=2;assert(packet(OP_BIND_UBO,&ub,sizeof ub)==0);assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(!got.ubo_use_overflow && got.ubo_use[5]==(16u|(1u<<5)));
 ub.addr=0;assert(packet(OP_BIND_UBO,&ub,sizeof ub)==0);assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(!got.ubo_use_overflow && got.ubo_use[5]==16u);
 // 最高用户槽 15 → cbuf 18（位 18）也能表达；16 个用户槽全部在掩码内。
 ub.index=15;ub.addr=0x2000;ub.size=16;assert(packet(OP_BIND_UBO,&ub,sizeof ub)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);assert(!got.ubo_use_overflow && got.ubo_use[5]==((1u<<4)|(1u<<18)));
 ub.addr=0;assert(packet(OP_BIND_UBO,&ub,sizeof ub)==0);assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);assert(got.ubo_use[5]==16u);
 p_bind_buf sb={.stage=5,.index=7,.addr=0x7000,.size=128};
 assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==0);
 p_bind_handles handles={.stage=5,.first=4,.n=1};handles.h[0]=0x123456;
 assert(packet(OP_BIND_IMG,&handles,sizeof handles)==0);
 handles.first=2;handles.h[0]=0x800007;assert(packet(OP_BIND_TEX,&handles,sizeof handles)==0);
 handles.first=3;handles.h[0]=9;assert(packet(OP_BIND_SAMP,&handles,sizeof handles)==0);
 dpool_t pool={0};pool.n=17;p_set_pool pp={.pool=&pool};
 assert(packet(OP_SET_TEX_POOL,&pp,sizeof pp)==0);pool.n=23;
 assert(packet(OP_SET_SAMP_POOL,&pp,sizeof pp)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(got.ssbo_seen==(1u<<7));
 assert(got.ssbo[7].addr==0x7000 && got.ssbo[7].size==128);
 assert(got.image_present[4] && got.image_handle[4]==0x123456);
 assert(got.tex_present[2] && got.tex_handle[2]==0x800007);
 assert(got.samp_present[3] && got.samp_handle[3]==9);
 assert(got.tex_pool_seen && got.samp_pool_seen && got.tex_pool_n==17 && got.samp_pool_n==23);
 // Interleaved NVN VS=0, fragment=4, compute=5 keep every slot independently.
 p_bind_buf other={.stage=0,.index=7,.addr=0x1000,.size=32};
 assert(packet(OP_BIND_SSBO,&other,sizeof other)==0);
 other.stage=4;other.addr=0x4000;assert(packet(OP_BIND_SSBO,&other,sizeof other)==0);
 sb.index=15;sb.addr=0xf000;sb.size=16;assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==0);
 NVNbufferRange deferred={.address=0xd000,.size=96};
 p_bind_buf def={.stage=5|BIND_BUF_DEFER,.index=2,.addr=(uint64_t)(uintptr_t)&deferred};
 assert(packet(OP_BIND_SSBO,&def,sizeof def)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(got.ssbo[7].addr==0x7000 && got.ssbo[15].addr==0xf000 && got.ssbo[2].addr==0xd000 && got.ssbo[2].size==96);
 assert(got.ssbo_seen==((1u<<7)|(1u<<15)|(1u<<2)));
 // P0-3：图形常量掩码不再截断（用户槽 i → cbuf i+3 的位，3..18 全可达），解绑要能清位。
 {
  s2a_record_set_draw_builder(capture_draw,NULL);
  bind(0,0,3,0x21);bind(1,1,4,0x22);   // vs/fs 程序，draw 才能进 builder
  p_draw dr0={0};dr0.count=3;dr0.instances=1;
  p_bind_buf gu5={.stage=0,.index=5,.addr=0x3000,.size=32};
  p_bind_buf gu2={.stage=0,.index=2,.addr=0x3200,.size=16};
  p_bind_buf gu15={.stage=0,.index=15,.addr=0x3400,.size=16};
  assert(packet(OP_BIND_UBO,&gu5,sizeof gu5)==0);
  assert(packet(OP_DRAW,&dr0,sizeof dr0)==-78);
  assert(!draw_got.ubo_use_overflow);
  assert(draw_got.ubo_use[0]==(1u<<8) && draw_got.ubo_use[1]==0);
  assert(packet(OP_BIND_UBO,&gu2,sizeof gu2)==0);
  assert(packet(OP_DRAW,&dr0,sizeof dr0)==-78);
  assert(draw_got.ubo_use[0]==((1u<<8)|(1u<<5)));
  assert(packet(OP_BIND_UBO,&gu15,sizeof gu15)==0);
  assert(packet(OP_DRAW,&dr0,sizeof dr0)==-78);
  assert(!draw_got.ubo_use_overflow);
  assert(draw_got.ubo_use[0]==((1u<<8)|(1u<<5)|(1u<<18)));
  gu5.addr=0;gu5.size=0;assert(packet(OP_BIND_UBO,&gu5,sizeof gu5)==0);   // 解绑：位必须清掉
  assert(packet(OP_DRAW,&dr0,sizeof dr0)==-78);
  assert(draw_got.ubo_use[0]==((1u<<5)|(1u<<18)));
  gu2.addr=0;gu2.size=0;assert(packet(OP_BIND_UBO,&gu2,sizeof gu2)==0);
  gu15.addr=0;gu15.size=0;assert(packet(OP_BIND_UBO,&gu15,sizeof gu15)==0);
  assert(packet(OP_DRAW,&dr0,sizeof dr0)==-78);
  assert(draw_got.ubo_use[0]==0);
 }
 s2a_record_set_draw_builder(capture_draw,NULL);
 // P0-0a：间接参数由 GPU 写、multi-draw 计数在 GPU 侧、transform-feedback 顶点数来自计数器——
 // 三者都还没接。生产 builder 路径（adapter 已注册）必须在入口准确拒绝，不许静默空画
 // （记录里补的 count/first=0 会继续往下变成“返回成功但什么都没画”）。
 {
  struct s2a_record_result rr;int before=draw_calls;
  p_draw idr={0};idr.count=3;idr.instances=1;idr.ind=0x1234;
  assert(packet_r(OP_DRAW,&idr,sizeof idr,&rr)==S2A_RECORD_UNSUPPORTED);
  assert(strstr(rr.why,"op=OP_DRAW(25) ind=0x1234 mdi_cnt=0x0 mdi_i=0 tfc=0x0"));
  assert(strstr(rr.why,"not wired yet")&&draw_calls==before);
  idr.ind=0;idr.mdi_cnt=0x2222;idr.mdi_i=3;
  assert(packet_r(OP_DRAW,&idr,sizeof idr,&rr)==S2A_RECORD_UNSUPPORTED);
  assert(strstr(rr.why,"op=OP_DRAW(25) ind=0x0 mdi_cnt=0x2222 mdi_i=3 tfc=0x0")&&draw_calls==before);
  idr.mdi_cnt=0;idr.mdi_i=0;idr.tfc=0x3333;
  assert(packet_r(OP_DRAW,&idr,sizeof idr,&rr)==S2A_RECORD_UNSUPPORTED);
  assert(strstr(rr.why,"tfc=0x3333")&&draw_calls==before);
  p_draw_idx idir={0};idir.count=3;idir.instances=1;idir.ind=0x4444;idir.ibuf=0x1000;
  assert(packet_r(OP_DRAW_IDX,&idir,sizeof idir,&rr)==S2A_RECORD_UNSUPPORTED);
  assert(strstr(rr.why,"op=OP_DRAW_IDX(26) ind=0x4444")&&draw_calls==before);
  p_draw ok_dr={0};ok_dr.count=3;ok_dr.instances=2;ok_dr.base_instance=5;
  assert(packet(OP_DRAW,&ok_dr,sizeof ok_dr)==-78&&draw_calls==before+1);
  // P0-1：base_instance 必须进快照（Vulkan firstInstance 不能用固定 0），实例化绘制才读得到正确
  // 的 per-instance 属性/instance id。
  assert(draw_got.base_instance==5&&draw_got.instances==2);
  p_draw_idx ok_idr={0};ok_idr.count=3;ok_idr.instances=1;ok_idr.base_instance=7;ok_idr.base_vertex=9;
  ok_idr.ibuf=0x5000;ok_idr.itype=0;
  assert(packet(OP_DRAW_IDX,&ok_idr,sizeof ok_idr)==-78&&draw_calls==before+2);
  assert(draw_got.base_instance==7&&draw_got.base_vertex==9&&draw_got.indexed);
  assert(draw_got.index_address==0x5000&&draw_got.index_type==0);
 }
 p_draw dr={0};assert(packet(OP_DRAW,&dr,sizeof dr)==-78);
 assert(draw_got.ssbo[0][7].addr==0x1000 && draw_got.ssbo[4][7].addr==0x4000 && !draw_got.ssbo[1][7].addr);
 assert(draw_got.ssbo_bound[0]==(1u<<7) && draw_got.ssbo_bound[4]==(1u<<7));
 assert(draw_got.ssbo_bound[5]==((1u<<7)|(1u<<15)|(1u<<2)));
 other.addr=0;other.size=123;assert(packet(OP_BIND_SSBO,&other,sizeof other)==0);
 sb.index=7;sb.addr=0;sb.size=456;assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==0);
 assert(packet(OP_DRAW,&dr,sizeof dr)==-78);
 assert(!draw_got.ssbo_bound[4] && draw_got.ssbo_bound[0]==(1u<<7));
 assert(!draw_got.ssbo[4][7].addr && !draw_got.ssbo[4][7].size);
 assert(draw_got.ssbo_bound[5]==((1u<<15)|(1u<<2)));
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(!got.ssbo[7].addr && !got.ssbo[7].size && got.ssbo[15].addr==0xf000);
 assert(got.ssbo_seen==((1u<<7)|(1u<<15)|(1u<<2))); // unbound is still observed
 for(int i=0;i<4;i++){
  const int bad_slots[]={-1,16,63,64};sb.index=bad_slots[i];
  assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==S2A_RECORD_UNSUPPORTED);
 }
 sb.index=0;sb.stage=6;assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==S2A_RECORD_UNSUPPORTED);
 sb.stage=-1;assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==S2A_RECORD_UNSUPPORTED);
 s2a_record_set_draw_builder(NULL,NULL);
 // Every SSBO stage uses the same representable 16-slot contract.
 sb.stage=4;sb.index=16;assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==S2A_RECORD_UNSUPPORTED);
 sb.stage=5;sb.index=16;assert(packet(OP_BIND_SSBO,&sb,sizeof sb)==S2A_RECORD_UNSUPPORTED);
 handles.first=32;assert(packet(OP_BIND_TEX,&handles,sizeof handles)==S2A_RECORD_UNSUPPORTED);
 p_bind_program legacy={.stages=32};assert(packet(OP_BIND_PROGRAM,&legacy,sizeof legacy)==S2A_RECORD_INVALID);
 p_bind_program_id un={.stages=32};assert(packet(OP_BIND_PROGRAM,&un,sizeof un)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_INVALID);
 bind(5,0,44,0xef);s2a_record_set_dispatch_builder(capture,NULL);assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 s2a_record_reset_state();assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_INVALID);
 bind(5,0,45,0xfa);s2a_record_set_dispatch_builder(gpu_builder,NULL);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==0);
 assert(host_barriers==1);
 assert(submitted==1 && dispatched==1 && sets_bound==1 && finishes==1 && last_completion==0);
 s2a_record_set_submit_fault(2);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_GPU);
 assert(submitted==1 && finishes==2 && last_completion==-1);
 s2a_record_set_submit_fault(1);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_GPU);
 assert(submitted==2 && finishes==3 && last_completion==-2);
 assert(live_owners==1 && terminal_finishes==2);
 uint32_t left=99;
 wait_result=VK_TIMEOUT;
 assert(s2a_record_release_retained(&dev,1000000000,&left)==0 && left==1);
 assert(finishes==3 && live_owners==1 && freed_commands==2);
 wait_result=VK_ERROR_DEVICE_LOST;
 assert(s2a_record_release_retained(&dev,1000000000,&left)==0 && left==1);
 assert(finishes==3 && live_owners==1 && freed_commands==2);
 wait_result=VK_SUCCESS;
 assert(s2a_record_release_retained(&dev,1000000000,&left)==1 && left==0);
 assert(finishes==4 && last_completion==0 && live_owners==0 && terminal_finishes==3);
 assert(s2a_record_release_retained(&dev,1000000000,&left)==0 && left==0);
 assert(finishes==4); // No duplicate callback from a retired slot.
 for(int i=0;i<64;i++) assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_GPU);
 int before=finishes;
 assert(submitted==66 && live_owners==64);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==S2A_RECORD_LIMIT);
 assert(submitted==66 && finishes==before && live_owners==64);
 s2a_record_set_submit_fault(0);
 wait_odd_only=1;
 assert(s2a_record_release_retained(&dev,1000000000,&left)==32 && left==32);
 assert(finishes==before+32 && live_owners==32);
 wait_odd_only=0;
 assert(s2a_record_release_retained(&dev,1000000000,&left)==32 && left==0);
 assert(finishes==before+64 && live_owners==0 && terminal_finishes==67);
 // Reuse of a cleared ledger cannot call a stale owner.
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==0 && live_owners==0);
 assert(s2a_record_release_retained(&dev,1000000000,&left)==0 && left==0);
 // Deferred ranges carry GA, whereas immediate records already carry CA.
 s2a_record_reset_state();s2a_record_set_dispatch_builder(capture,NULL);
 s2a_record_set_draw_builder(capture_draw,NULL);bind(5,0,123,0x12);bind(0,1,124,0x13);
 NVNbufferRange gpu_range={.address=FIXTURE_GA+0x120,.size=48};
 p_bind_buf mapped={.stage=5|BIND_BUF_DEFER,.index=3,.addr=(uint64_t)(uintptr_t)&gpu_range};
 unsigned translations=ga_calls;
 assert(packet(OP_BIND_UBO,&mapped,sizeof mapped)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(ga_calls==translations+1 && got.ubo[3].addr==FIXTURE_CA+0x120 && got.ubo[3].size==48 && got.ubo_seen==(1u<<3));
 gpu_range.address=FIXTURE_GA+65520;gpu_range.size=16;mapped.index=6;
 assert(packet(OP_BIND_SSBO,&mapped,sizeof mapped)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(ga_calls==translations+2 && got.ssbo[6].addr==FIXTURE_CA+65520 && got.ssbo[6].size==16 && got.ssbo_seen==(1u<<6));
 gpu_range.address=FIXTURE_GA+0x240;gpu_range.size=32;mapped.stage=4|BIND_BUF_DEFER;
 assert(packet(OP_BIND_SSBO,&mapped,sizeof mapped)==0);
 assert(packet(OP_DRAW,&dr,sizeof dr)==-78);
 assert(draw_got.ssbo[4][6].addr==FIXTURE_CA+0x240 && draw_got.ssbo[4][6].size==32 && draw_got.ssbo_bound[4]==(1u<<6));
 mapped.stage=5;mapped.addr=FIXTURE_CA+0x360;mapped.size=64;
 translations=ga_calls;
 assert(packet(OP_BIND_SSBO,&mapped,sizeof mapped)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(ga_calls==translations && got.ssbo[6].addr==FIXTURE_CA+0x360 && got.ssbo[6].size==64);
 // Main accepts the segment end address, including an empty one-past range.
 gpu_range.address=FIXTURE_GA+65536;gpu_range.size=0;
 mapped.stage=5|BIND_BUF_DEFER;mapped.addr=(uint64_t)(uintptr_t)&gpu_range;
 assert(packet(OP_BIND_SSBO,&mapped,sizeof mapped)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(ga_calls==translations+1 && got.ssbo[6].addr==FIXTURE_CA+65536 && got.ssbo[6].size==0);
 translations=ga_calls;
 // Address translation alone does not validate mapped ranges or read memory.
 gpu_range.address=FIXTURE_GA+65537;gpu_range.size=8;
 mapped.stage=5|BIND_BUF_DEFER;mapped.addr=(uint64_t)(uintptr_t)&gpu_range;
 assert(packet(OP_BIND_SSBO,&mapped,sizeof mapped)==0);
 assert(packet(OP_DISPATCH,&dp,sizeof dp)==-77);
 assert(ga_calls==translations+1 && got.ssbo[6].addr==FIXTURE_GA+65537 && got.ssbo[6].size==8);
 puts("dispatch snapshot: 33 original + 6 GA/CA scenarios passed (no GPU execution)");return 0;
}
