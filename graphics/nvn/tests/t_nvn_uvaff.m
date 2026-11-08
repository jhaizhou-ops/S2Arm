// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 着色器事实里的常量引用覆盖整个 64 KB 常量缓冲（照上游参考实现（MIT）d6a2808a）：反射 uv_affine 的 [槽, 第几个 vec4, 分量]，vec4 序号 0..4095。
//   旧编码 (槽 << 8) | (vec4 << 2) | 分量 只装得下 vec4 0..63（1 KB），序号过 63 的整条仿射信息被丢掉（uv_aff_attr = -1），合批读块退回不认得。
// 期望按 NVN 语义手写，不由被测实现推出：常量缓冲槽 2 是 64 KB，第 v 个 vec4 的第 c 个分量在字节 v * 16 + c * 4：
//   ① 反射 {"0": attr 1, sx [2,100,1], ox [2,0,0], sy [2,4095,3], oy [2,63,2]} → 插值量 0 认作属性 1 的仿射（uv_aff_attr[0] = 1）
//   ② 四个引用按 ubo_float 读回：字节 1604 = 3.5、字节 0 = -2.0、字节 65532 = 7.25、字节 1016 = 0.125
//   ③ 越界仍拒：vec4 4096 → 整条丢掉（uv_aff_attr[1] = -1）
// 反证：撤修复（vec4 上限 63、编码 << 8）→ ① 红（uv_aff_attr[0] = -1），② 跟着读不到
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    mtl_init();
    uint8_t *mem=NULL; REQUIRE(!posix_memalign((void **)&mem,65536,65536)); memset(mem,0,65536); nvn_be_pool_add(mem,65536);   // 活到进程结束
    const struct { int byte; float v; } put[4]={{100*16+1*4,3.5f},{0,-2.0f},{4095*16+3*4,7.25f},{63*16+2*4,0.125f}};
    for (int i=0;i<4;i++) memcpy(mem+put[i].byte,&put[i].v,4);
    nvn_refl rf; memset(&rf,0,sizeof rf); char err[256]="";
    NSDictionary *j=@{ @"route": @"B", @"bindings": @[], @"raster": @{ @"uv_affine": @{
        @"0": @{ @"attr": @1, @"sx": @[@2,@100,@1], @"ox": @[@2,@0,@0], @"sy": @[@2,@4095,@3], @"oy": @[@2,@63,@2] },
        @"1": @{ @"attr": @2, @"sx": @[@2,@4096,@0], @"ox": @[@2,@0,@0], @"sy": @[@2,@0,@0], @"oy": @[@2,@0,@0] } } } };
    int rc=nvn_refl_from_json(j,&rf,err,sizeof err); REQUIRE(!rc);
    CHECK(rf.uv_aff_attr[0]==1,"① vec4 序号 100 / 4095 的仿射引用：插值量 0 认作属性 %d 的仿射（期望 1）",rf.uv_aff_attr[0]);
    S.ubo[0][2]=(p_bind_buf){.addr=(uint64_t)(uintptr_t)mem,.size=65536};
    float got[4]={-9,-9,-9,-9}; int all=1; for (int q=0;q<4;q++) if (ubo_float(0,rf.uv_aff[0][q],&got[q])!=1) { printf("  引用 %d（%#x）读不到\n",q,rf.uv_aff[0][q]); all=0; }
    CHECK(all && got[0]==3.5f && got[1]==-2.0f && got[2]==7.25f && got[3]==0.125f,"② 读回 sx %.3f ox %.3f sy %.3f oy %.3f（期望 3.500 / -2.000 / 7.250 / 0.125）",got[0],got[1],got[2],got[3]);
    CHECK(rf.uv_aff_attr[1]==-1,"③ vec4 序号 4096 越界：整条丢掉（uv_aff_attr[1] = %d，期望 -1）",rf.uv_aff_attr[1]);
    printf("%s t_nvn_uvaff：%u 项，%u 项失败（常量引用覆盖整 64 KB）\n",failures?"✗":"✓",checks,failures);
    return failures!=0;
} }
