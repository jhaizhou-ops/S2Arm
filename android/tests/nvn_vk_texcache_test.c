// 纹理缓存语义：同身份复用、同址新 serial 重建、未知格式拒绝。
#include <stdio.h>
#include <string.h>
#include "nvn_vk_texcache.h"
#include "nvn_vk_format.h"

int main(void) {
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct nvn_vk_texcache c; nvn_vk_texcache_init(&c, &d, NULL, 0);
    uint8_t green[16]; for (int i = 0; i < 4; i++) { green[i*4+0]=0; green[i*4+1]=255; green[i*4+2]=0; green[i*4+3]=255; }
    uint8_t g565[8] = {0xE0,0x07,0xE0,0x07,0xE0,0x07,0xE0,0x07};

    struct nvn_vk_tex *a = nvn_vk_texcache_get(&c, 0x1000, 1, 0x25, 2, 2, green, sizeof green);
    struct nvn_vk_tex *b = nvn_vk_texcache_get(&c, 0x1000, 1, 0x25, 2, 2, green, sizeof green);
    struct nvn_vk_tex *a2 = nvn_vk_texcache_get(&c, 0x1000, 2, 0x25, 2, 2, green, sizeof green);
    struct nvn_vk_tex *t565 = nvn_vk_texcache_get(&c, 0x2000, 3, 0x3c, 2, 2, g565, sizeof g565);
    struct nvn_vk_tex *bad = nvn_vk_texcache_get(&c, 0x3000, 4, 0xDEAD, 2, 2, NULL, 0);

    int ok = a && b && a2 && t565 && !bad;
    ok &= (a == b);                     // 同身份复用
    // 身份改 serial 后：同址新 serial 是**另一个对象**，各自持有自己的图像，不就地重建。
    ok &= (a2 != a && a2->serial == 2 && a2->image != a->image);
    ok &= (nvn_vk_texcache_get(&c, 0x1000, 2, 0x25, 2, 2, green, sizeof green) == a2);   // 重复访问 B 命中 B
    ok &= (nvn_vk_texcache_get(&c, 0x1000, 1, 0x25, 2, 2, green, sizeof green) == a);    // A 仍是自己的条目
    ok &= (c.reclaimed == 0);
    ok &= (t565 != a && t565->nvn_format == 0x3c);
    // ---- 退役回收与释放幂等（原生线 #1014 对齐）----
    tex_t tt; memset(&tt, 0, sizeof tt);
    // 无引用：Finalize 立即回收
    uint64_t fin = c.finalized;
    struct nvn_vk_tex *r1 = nvn_vk_texcache_get(&c, 0x4000, 11, 0x25, 2, 2, green, sizeof green);
    tt.mem = (void *)0x4000; tt.serial = 11;
    ok &= r1 && r1->bytes > 0 && r1->valid && r1->image;
    nvn_vk_texcache_drop_tex(&c, &tt);
    int r1_ok = (c.finalized == fin + 1) && (c.retired_n == 0) && (r1->valid == 0) && !r1->image;   // 槽可能被后续复用，立即判定
    ok &= r1_ok;
    // 底图引用在途：挂账；重复 Finalize 不重复释放；最后 unpin 恰好回收一次
    struct nvn_vk_tex *r2 = nvn_vk_texcache_get(&c, 0x5000, 12, 0x25, 2, 2, green, sizeof green);
    tt.mem = (void *)0x5000; tt.serial = 12;
    nvn_vk_texcache_pin(r2);
    nvn_vk_texcache_drop_tex(&c, &tt);
    ok &= (c.retired_n == 1) && (c.retired_bytes > 0) && r2->valid && r2->image;
    fin = c.finalized;
    nvn_vk_texcache_drop_tex(&c, &tt);
    ok &= (c.retired_n == 1) && (c.finalized == fin);
    nvn_vk_texcache_unpin(r2);
    int r2_ok = (c.retired_n == 0) && (c.retired_bytes == 0) && (c.finalized == fin + 1) && !r2->image;
    ok &= r2_ok;
    // 只有视图引用：视图先失效，最后 unpin_view 回收
    struct nvn_vk_tex *r3 = nvn_vk_texcache_get(&c, 0x6000, 13, 0x25, 2, 2, green, sizeof green);
    tt.mem = (void *)0x6000; tt.serial = 13;
    VkImageView v3 = nvn_vk_texcache_view(&c, r3, NULL, why, sizeof why);
    ok &= v3 && nvn_vk_texcache_pin_view(r3, v3) == 0;
    nvn_vk_texcache_drop_tex(&c, &tt);
    ok &= (c.retired_n == 1) && r3->valid && r3->image;
    fin = c.finalized;
    nvn_vk_texcache_unpin_view(r3, v3);
    int r3_ok = (c.retired_n == 0) && (c.finalized == fin + 1) && !r3->image;
    ok &= r3_ok;
    // 重复释放旧 serial 不得误伤同址新对象
    struct nvn_vk_tex *r4 = nvn_vk_texcache_get(&c, 0x7000, 21, 0x25, 2, 2, green, sizeof green);
    tt.mem = (void *)0x7000; tt.serial = 21;
    nvn_vk_texcache_pin(r4);
    nvn_vk_texcache_drop_tex(&c, &tt);
    nvn_vk_texcache_drop_tex(&c, &tt);
    nvn_vk_texcache_unpin(r4);
    struct nvn_vk_tex *r5 = nvn_vk_texcache_get(&c, 0x7000, 22, 0x25, 2, 2, green, sizeof green);
    ok &= r5 && r5->image && r5->serial == 22 && r5->valid;
    nvn_vk_texcache_drop_tex(&c, &tt);            // 旧 serial=21 再释放一次
    ok &= r5->valid && r5->serial == 22 && r5->image;
    // serial=0 的无身份释放必须被拒绝
    tex_t z; memset(&z, 0, sizeof z); z.mem = (void *)0x7000;
    nvn_vk_texcache_drop_tex(&c, &z);
    ok &= r5->valid && r5->serial == 22;
    printf("retire: finalized=%llu retired_n=%llu retired_bytes=%llu r1_ok=%d r2_ok=%d r3_ok=%d\n",
           (unsigned long long)c.finalized, (unsigned long long)c.retired_n, (unsigned long long)c.retired_bytes,
           r1_ok, r2_ok, r3_ok);
    // ---- BC compute 解码纹理的视图层（#1199）：条目 nvn_format 记 BC 格式、vk_format 记
    // 解码后图像格式；attachment_view / tex_view_core 必须按 t->vk_format 回报图像格式，
    // 不得从 nvn_format 反推（否则解码纹理的 attachment 视图会拿到不存在的 BC 图像格式）。
    {
        struct nvn_vk_tex *bc = nvn_vk_texcache_get(&c, 0x8000, 31, 0x25, 2, 2, green, sizeof green);
        ok &= bc && bc->view && bc->image;
        bc->nvn_format = 0x43;                          // BC2——白盒模拟解码路由后的条目状态
        bc->vk_format = VK_FORMAT_R8G8B8A8_UNORM;
        VkFormat fout = VK_FORMAT_UNDEFINED;
        VkImageView av = nvn_vk_texcache_attachment_view(&c, bc, NULL, &fout, why, sizeof why);
        ok &= av && fout == VK_FORMAT_R8G8B8A8_UNORM;   // 必须回报解码后图像格式
        bc->vk_format = VK_FORMAT_UNDEFINED;            // 无解码记录时退回 nvn 映射（原生路径语义）
        fout = VK_FORMAT_UNDEFINED;
        nvn_vk_texcache_attachment_view(&c, bc, NULL, &fout, why, sizeof why);
        ok &= fout == nvn_vk_format(0x43) && fout != VK_FORMAT_R8G8B8A8_UNORM;
    }
    // 释放 A 不影响 B
    {
        tex_t ta; memset(&ta, 0, sizeof ta); ta.mem = (void *)0x1000; ta.serial = 1;
        nvn_vk_texcache_drop_tex(&c, &ta);
        ok &= (a->valid == 0) && a2->valid && a2->image;
        ok &= (nvn_vk_texcache_get(&c, 0x1000, 2, 0x25, 2, 2, green, sizeof green) == a2);
    }
    printf("a=%p b=%p a2=%p t565=%p bad=%p reclaimed=%u alias_shared=%llu\n", (void*)a, (void*)b, (void*)a2, (void*)t565, (void*)bad, c.reclaimed, (unsigned long long)c.alias_shared);
    printf("nvn-vk-texcache: %s\n", ok ? "ok" : "FAIL");
    nvn_vk_texcache_destroy(&c);
    s2a_vk_device_destroy(&d, 0);
    return ok ? 0 : 1;
}
