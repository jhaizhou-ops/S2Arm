// 管线对象缓存身份回归（宿主）：完整规范配方必须覆盖构建管线真正读取的全部输入。
//
// 反例基线（方案 §8.5.11）：旧 `fd_pipe_key` 用 64 位 FNV 命中、命中时不比较完整配方；
// 这里用生产的 `nvk_pipe_recipe_fill/hash/hit` 证明：
//   1) 任一配方输入变化 → hash 与配方字节都变化（不会“键变但配方没变”或反之）；
//   2) 即使两个配方被强行给同一个 hash（模拟碰撞），`nvk_pipe_recipe_hit` 也必须拒绝；
//   3) 未被绑定的状态对象不影响管线，不应改变配方（正向对照，避免把无关内存当判据）；
//   4) request_id 只作日志/定位，不参与判据：跨局 stage key 组变化不能让预热/缓存 miss。
#include <stdio.h>
#include <string.h>

#include "nvn/nvn_vk_pipe_recipe.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

static void fixture(struct s2a_record_draw_state *st) {
    memset(st, 0, sizeof *st);
    st->stages = 0x3;
    st->prim = 0x4;                 // Triangles
    st->rt_count = 1;
    st->state_seen = 0x3f;
    for (int k = 0; k < 6; k++)
        for (int b = 0; b < 0x18; b++) st->state_obj[k][b] = (uint8_t)(k * 0x18 + b + 1);
    for (int i = 0; i < 32; i++) {
        st->vattr[i].format = 0x1 + (uint32_t)(i & 3);
        st->vattr[i].offset = (uint32_t)(i * 4);
        st->vattr[i].stream = (uint32_t)(i & 1);
    }
    for (int s = 0; s < 16; s++) {
        st->vstream_stride[s] = (uint32_t)(8 + s * 4);
        st->vstream_divisor[s] = (s & 1) ? 1u : 0u;
    }
}

int main(void) {
    struct s2a_record_draw_state st;
    fixture(&st);
    uint8_t sha[32];
    for (int i = 0; i < 32; i++) sha[i] = (uint8_t)(0x70 + i);

    uint32_t rtf[8] = { VK_FORMAT_R8G8B8A8_UNORM, 0, 0, 0, 0, 0, 0, 0 };
    struct nvk_pipe_recipe base;
    nvk_pipe_recipe_fill(&base, &st, "18f2aadcec113d49a566892b88596132", sha,
                         rtf, 1, 0x1u, VK_FORMAT_UNDEFINED, 0, 0, 0x1000);
    const uint64_t base_key = nvk_pipe_recipe_hash(&base);
    CHECK(base_key == nvk_pipe_recipe_hash(&base), "hash is deterministic");
    CHECK(nvk_pipe_recipe_hit(base_key, &base, base_key, &base) == 1, "identical recipes hit");
    CHECK(sizeof base >= 512, "recipe carries the full pipeline inputs (not a truncated key)");

    // 每项输入变化：hash 与配方字节都要变，命中要拒绝。
    enum { N = 21 };
    static const char *what[N] = {
        "program content sha", "device", "layout policy", "state_seen",
        "bound blend state", "bound color state", "vertex attrib format", "vertex attrib offset",
        "vertex attrib stream", "vertex stream stride", "vertex stream divisor", "prim",
        "colour format 0", "depth format", "has_depth", "depth_only", "rt_count",
        "colour format 1", "bound mask", "colour count", "per-target blend state",
    };
    for (int i = 0; i < N; i++) {
        struct s2a_record_draw_state s2 = st;
        uint8_t sha2[32];
        memcpy(sha2, sha, 32);
        char id2[40];
        snprintf(id2, sizeof id2, "%s", "18f2aadcec113d49a566892b88596132");
        struct nvk_pipe_recipe r;
        uint32_t rtf2[8];
        memcpy(rtf2, rtf, sizeof rtf2);
        uint32_t df = VK_FORMAT_UNDEFINED, bound = 0x1u, colours = 1u;
        int has_depth = 0, depth_only = 0;
        uint64_t dev = 0x1000;
        switch (i) {
            case 0: sha2[31] ^= 1; break;
            case 1: dev = 0x2000; break;
            case 2: r = base; r.layout_policy++; goto compare;
            case 3: s2.state_seen &= (uint8_t)~0x10u; break;   // kind 4（poly）不再算已绑定
            case 4: s2.state_obj[0][3] ^= 0x40; break;
            case 5: s2.state_obj[1][0] ^= 0x01; break;
            case 6: s2.vattr[3].format = 0x3; break;
            case 7: s2.vattr[5].offset += 4; break;
            case 8: s2.vattr[7].stream ^= 1; break;
            case 9: s2.vstream_stride[2] += 16; break;
            case 10: s2.vstream_divisor[2] ^= 1; break;
            case 11: s2.prim = 0x1; break;
            case 12: rtf2[0] = VK_FORMAT_R8G8B8A8_UINT; break;
            case 13: df = VK_FORMAT_D24_UNORM_S8_UINT; break;
            case 14: has_depth = 1; break;
            case 15: depth_only = 1; break;
            case 16: s2.rt_count = 2; break;
            case 17: rtf2[1] = VK_FORMAT_R16G16B16A16_SFLOAT; colours = 2; bound = 0x3u; break;
            case 18: bound = 0x2u; break;
            case 19: colours = 2; break;
            case 20: s2.blend_obj[1][0] ^= 0x08; s2.blend_seen |= 0x2u; break;
            default: break;
        }
        nvk_pipe_recipe_fill(&r, &s2, id2, sha2, rtf2, colours, bound, df, has_depth, depth_only, dev);
        compare:
        {
            uint64_t k = nvk_pipe_recipe_hash(&r);
            CHECK(k != base_key, what[i]);
            CHECK(nvk_pipe_recipe_match(&r, &base) == 0, what[i]);
            // 关键反例：即使 hash 被强行注入成相同值，命中判据也必须拒绝不同配方。
            CHECK(nvk_pipe_recipe_hit(base_key, &base, base_key, &r) == 0,
                  "forced hash collision must not hit (full recipe is the criterion)");
        }
    }

    // 正向对照：request_id 只作日志/定位，换它不能让配方 miss（跨局预热可命中）。
    {
        struct nvk_pipe_recipe ra, rb;
        nvk_pipe_recipe_fill(&ra, &st, "18f2aadcec113d49a566892b88596132", sha,
                             rtf, 1, 0x1u, VK_FORMAT_UNDEFINED, 0, 0, 0x1000);
        nvk_pipe_recipe_fill(&rb, &st, "ffffffffffffffffffffffffffffffff", sha,
                             rtf, 1, 0x1u, VK_FORMAT_UNDEFINED, 0, 0, 0x1000);
        CHECK(nvk_pipe_recipe_hash(&ra) == nvk_pipe_recipe_hash(&rb) && nvk_pipe_recipe_match(&ra, &rb) == 1,
              "request id is location only (cross-session preheat can hit)");
    }

    // 正向对照：未绑定的状态对象（state_seen 之外的 kind）不参与管线，改它不应改配方。
    {
        struct s2a_record_draw_state a = st, b = st;
        a.state_seen &= (uint8_t)~(1u << 2);   // kind 2（chmask）未标记已绑定
        b.state_seen &= (uint8_t)~(1u << 2);
        memset(b.state_obj[2], 0xEE, sizeof b.state_obj[2]);
        struct nvk_pipe_recipe ra, rb;
        nvk_pipe_recipe_fill(&ra, &a, "18f2aadcec113d49a566892b88596132", sha,
                             rtf, 1, 0x1u, VK_FORMAT_UNDEFINED, 0, 0, 0x1000);
        nvk_pipe_recipe_fill(&rb, &b, "18f2aadcec113d49a566892b88596132", sha,
                             rtf, 1, 0x1u, VK_FORMAT_UNDEFINED, 0, 0, 0x1000);
        CHECK(nvk_pipe_recipe_hash(&ra) == nvk_pipe_recipe_hash(&rb) && nvk_pipe_recipe_match(&ra, &rb) == 1,
              "unbound state objects are not part of the pipeline recipe");
    }

    if (fails) { printf("nvn pipe recipe test: %d FAILED\n", fails); return 1; }
    printf("nvn pipe recipe test: ok (%zu B recipe, %d inputs covered)\n", sizeof(struct nvk_pipe_recipe), N);
    return 0;
}
