// 描述符 set 帧内复用缓存的反例（宿主）：命中要真命中，不该命中必须不命中。
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "nvn_vk_desc_cache.h"

static int fails;
static void check(int cond, const char *what) {
    printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
    if (!cond) fails++;
}

static void make_key(struct s2a_desc_set_key *k, uint64_t layout, uint64_t layout_gen, uint64_t pool_gen,
                     uint32_t frame, uint64_t buf, uint64_t off, uint64_t range) {
    memset(k, 0, sizeof *k);
    k->layout = layout;
    k->layout_gen = layout_gen;
    k->pool_gen = pool_gen;
    k->frame_seq = frame;
    k->nbind = 2;
    k->bind[0] = (struct s2a_desc_bind_key){ 0, 0, 6 /* UNIFORM_BUFFER */, 1, buf, off, range };
    k->bind[1] = (struct s2a_desc_bind_key){ 1, 0, 1 /* COMBINED_IMAGE_SAMPLER */, 1, 0xBEEF, 0xCAFE, 42 };
    k->hash = s2a_desc_key_hash(k);
}

int main(void) {
    static struct s2a_desc_set_entry tab[64];
    struct s2a_desc_set_key a, b;
    uint64_t set_a = 0x1000;

    printf("== 描述符 set 缓存 ==\n");
    memset(tab, 0, sizeof tab);

    make_key(&a, /*layout*/ 0x11, 1, 1, 7, 0xAA, 256, 64);
    check(s2a_desc_cache_find(tab, 64, &a, NULL) == NULL, "空表不命中");
    s2a_desc_cache_store(tab, 64, &a, set_a);
    struct s2a_desc_set_entry *hit = s2a_desc_cache_find(tab, 64, &a, NULL);
    check(hit && hit->set == set_a, "相同键命中且拿到同一个 set");

    // 1. 同 buffer、不同 offset：必须不命中（否则改写已录制的命令）
    make_key(&b, 0x11, 1, 1, 7, 0xAA, 512, 64);
    check(s2a_desc_cache_find(tab, 64, &b, NULL) == NULL, "不同 offset 不命中");

    // 2. 同 buffer、不同 range
    make_key(&b, 0x11, 1, 1, 7, 0xAA, 256, 128);
    check(s2a_desc_cache_find(tab, 64, &b, NULL) == NULL, "不同 range 不命中");

    // 3. 句柄复用但布局代际变了
    make_key(&b, 0x11, 2, 1, 7, 0xAA, 256, 64);
    check(s2a_desc_cache_find(tab, 64, &b, NULL) == NULL, "布局代际变化不命中");

    // 4. 池 reset 换代际
    make_key(&b, 0x11, 1, 2, 7, 0xAA, 256, 64);
    check(s2a_desc_cache_find(tab, 64, &b, NULL) == NULL, "池代际变化不命中");

    // 5. 换一帧（复用只限同一录制帧内，不能拿帧号当 GPU 完成证明）
    make_key(&b, 0x11, 1, 1, 8, 0xAA, 256, 64);
    check(s2a_desc_cache_find(tab, 64, &b, NULL) == NULL, "跨帧不命中");

    // 6. 强制哈希碰撞：哈希相同但键不同，必须靠整键比较拒绝
    {
        struct s2a_desc_set_key c, d;
        make_key(&c, 0x22, 1, 1, 7, 0xCC, 0, 16);
        c.hash = 12345;
        s2a_desc_cache_store(tab, 64, &c, 0x2000);
        d = c;
        d.bind[0].b = 4096;          // 唯一区别在 offset
        d.hash = 12345;              // 强制同哈希
        check(s2a_desc_cache_find(tab, 64, &d, NULL) == NULL, "哈希碰撞不误命中");
        check(s2a_desc_cache_find(tab, 64, &c, NULL) != NULL, "碰撞表里原条目仍可命中");
    }

    // 7. 登记不覆盖已有同名条目（已登记的 set 不被改写）
    {
        struct s2a_desc_set_entry *e = s2a_desc_cache_find(tab, 64, &a, NULL);
        s2a_desc_cache_store(tab, 64, &a, 0x9999);
        check(e->set == set_a, "重复登记不改写已登记的 set");
    }
    printf("%s\n", fails ? "nvn-vk-desc-cache: 失败" : "nvn-vk-desc-cache: 通过");
    return fails ? 1 : 0;
}
