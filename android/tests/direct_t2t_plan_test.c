// 宿主回归：OP_COPY_T2T（NVN CopyTextureToTexture / Downsample）的回放计划 t2t_plan。
// 修前（8E Wonder READY+73.8s op=35）：flags / 视图 / 非整图区域一律 unsupported。
// 覆盖：负控（无 flags 无视图的整图拷仍是直拷）、本局候选组合（DM_COPY_RESOLVE、视图、
// LINEAR 缩放）、全部 flags、视图各字段、区域/格式/DS 面/压缩/3D 的边界与不报红的拒绝。
#include <stdio.h>
#include <string.h>

#include "direct/t2t_plan.h"
#include "nvn.h"   // NVN_FORMAT_*

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

static struct s2a_t2t_tex tex(uint32_t fmt, uint32_t w, uint32_t h) {
    struct s2a_t2t_tex t;
    memset(&t, 0, sizeof t);
    t.nvn_format = fmt; t.vk_format = 0x1000 + fmt;
    t.width = w; t.height = h; t.depth = 1; t.layers = 1; t.levels = 1;
    t.target = 1;   // NVN_TEXTURE_TARGET_2D
    return t;
}
static struct s2a_t2t_region full(uint32_t w, uint32_t h) {
    struct s2a_t2t_region r = {0, 0, 0, (int32_t)w, (int32_t)h, 1};
    return r;
}

int main(void) {
    char why[256];
    struct s2a_t2t_plan p;

    // 负控（修前就绿的唯一组合）：无 flags、无视图、整图同尺寸同格式 → 直拷。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 1280, 720), d = tex(NVN_FORMAT_RGBA8, 1280, 720);
        struct s2a_t2t_region fr = full(1280, 720);
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) == 0, "plain copy");
        CHECK(p.op == S2A_T2T_COPY && p.extent[0] == 1280 && p.extent[1] == 720 && p.extent[2] == 1,
              "plain copy extent");
        CHECK(p.src_aspect == S2A_T2T_ASPECT_COLOR && p.dst_aspect == S2A_T2T_ASPECT_COLOR, "color aspects");
        CHECK(p.src_level == 0 && p.dst_level == 0 && p.layer_count == 1, "level/layer defaults");
    }

    // 本局候选 1：Downsample 记录的 DM_COPY_RESOLVE——单采样同格式同尺寸 → 普通全图拷。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 1280, 720), d = tex(NVN_FORMAT_RGBA8, 1280, 720);
        struct s2a_t2t_region fr = full(1280, 720);
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x40000000u, &p, why, sizeof why) == 0,
              "DM_COPY_RESOLVE equal");
        CHECK(p.op == S2A_T2T_COPY, "resolve lowers to plain copy");
        d = tex(NVN_FORMAT_RGBA8, 640, 360);
        struct s2a_t2t_region dr = full(640, 360);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0x40000000u, &p, why, sizeof why) != 0,
              "resolve between sizes is red");
        // MS->1 resolve（Downsample 的真身）：同格式同尺寸 → vkCmdResolveImage。
        s.ms = 4; d = tex(NVN_FORMAT_RGBA8, 1280, 720);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x40000000u, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_RESOLVE, "MS->1 resolve resolves");
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x40000000u | 0x1u, &p, why, sizeof why) != 0,
              "resolve + other flags is red");
        d.nvn_format = NVN_FORMAT_BGRA8;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x40000000u, &p, why, sizeof why) != 0,
              "resolve across formats is red");
        d.nvn_format = NVN_FORMAT_RGBA8; d.ms = 4;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x40000000u, &p, why, sizeof why) != 0,
              "MS->MS resolve is red");
        // 普通拷贝碰 MS / DS 面解析仍然明确拒。
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "plain copy touching MS is red");
        struct s2a_t2t_tex ds_src = tex(NVN_FORMAT_DEPTH24_STENCIL8, 256, 256),
                          ds_dst = tex(NVN_FORMAT_DEPTH24_STENCIL8, 256, 256);
        ds_src.ms = 4;
        struct s2a_t2t_region dsr = full(256, 256);
        CHECK(s2a_t2t_plan(&ds_src, NULL, &dsr, &ds_dst, NULL, &dsr, 0x40000000u, &p, why, sizeof why) != 0,
              "depth-stencil resolve is red");
        s.ms = 0;
    }

    // 本局候选 2：视图选 mip —— 区域按该 mip 尺寸校验，拷进 src_level/dst_level。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 256, 256), d = tex(NVN_FORMAT_RGBA8, 256, 256);
        s.levels = d.levels = 5;
        struct s2a_t2t_view sv = {.has = 1, .base_level = 2}, dv = {.has = 1, .base_level = 1};
        struct s2a_t2t_region sr = full(64, 64), dr = full(128, 128);   // mip2=64x64 → mip1=128x128 放大
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, &sv, &sr, &d, &dv, &dr, 0, &p, why, sizeof why) == 0, "mip view scale");
        CHECK(p.op == S2A_T2T_BLIT_NEAREST && p.src_level == 2 && p.dst_level == 1, "mip blit levels");
        struct s2a_t2t_region over = full(128, 128);
        CHECK(s2a_t2t_plan(&s, &sv, &over, &d, &dv, &dr, 0, &p, why, sizeof why) != 0,
              "src region beyond its mip is red");
    }

    // 本局候选 3：LINEAR_FILTER + 缩放（最常见的带 flags 拷贝）。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 1280, 720), d = tex(NVN_FORMAT_RGBA8, 640, 360);
        struct s2a_t2t_region sr = full(1280, 720), dr = full(640, 360);
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0x1u, &p, why, sizeof why) == 0, "linear scale");
        CHECK(p.op == S2A_T2T_BLIT_LINEAR, "linear flag selects linear blit");
        CHECK(p.src_box[0][0] == 0 && p.src_box[1][0] == 1280 && p.dst_box[1][0] == 640, "blit boxes");
        // 同尺寸只是提示：filter 无意义仍直拷。
        d = tex(NVN_FORMAT_RGBA8, 1280, 720); dr = full(1280, 720);
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0x1u, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_COPY, "linear on a 1:1 copy stays a copy");
        // 缩放不带 LINEAR → nearest。
        d = tex(NVN_FORMAT_RGBA8, 640, 360); dr = full(640, 360);
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_BLIT_NEAREST, "scale without LINEAR is nearest");
    }

    // 镜像：MIRROR_X / MIRROR_Y 走 blit，dst 盒在该轴反向；MIRROR_Z 明确拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 320, 240), d = tex(NVN_FORMAT_RGBA8, 320, 240);
        struct s2a_t2t_region fr = full(320, 240);
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x4u, &p, why, sizeof why) == 0, "mirror X");
        CHECK(p.op == S2A_T2T_BLIT_NEAREST && p.dst_box[0][0] == 320 && p.dst_box[1][0] == 0,
              "mirror X flips dst box");
        CHECK(p.dst_box[0][1] == 0 && p.dst_box[1][1] == 240, "mirror X keeps y");
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x8u, &p, why, sizeof why) == 0 &&
              p.dst_box[0][1] == 240 && p.dst_box[1][1] == 0, "mirror Y flips dst box");
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x4u | 0x8u, &p, why, sizeof why) == 0 &&
              p.dst_box[0][0] == 320 && p.dst_box[0][1] == 240, "mirror XY flips both");
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x10u, &p, why, sizeof why) != 0,
              "MIRROR_Z is red");
    }

    // ENGINE_2D 只是引擎提示；未知位明确拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 64, 64), d = tex(NVN_FORMAT_RGBA8, 64, 64);
        struct s2a_t2t_region fr = full(64, 64);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x2u, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_COPY, "ENGINE_2D alone is a plain copy");
        d = tex(NVN_FORMAT_RGBA8, 32, 32);
        struct s2a_t2t_region dr = full(32, 32);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0x2u | 0x1u, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_BLIT_LINEAR, "ENGINE_2D|LINEAR scale is a linear blit");
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0x80u, &p, why, sizeof why) != 0,
              "unknown flag bit is red");
    }

    // 整数格式：可以 nearest blit / 直拷；LINEAR 明确拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8UI, 64, 64), d = tex(NVN_FORMAT_RGBA8UI, 64, 64);
        struct s2a_t2t_region fr = full(64, 64);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0x4u, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_BLIT_NEAREST, "integer mirror is a nearest blit");
        d = tex(NVN_FORMAT_RGBA8UI, 32, 32);
        struct s2a_t2t_region dr = full(32, 32);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0x1u, &p, why, sizeof why) != 0,
              "LINEAR on integer is red");
    }

    // 视图格式覆盖：同类（RGBA8 ↔ BGRA8）允许；跨尺寸类（RGBA8 ↔ RGBA16F）拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 64, 64), d = tex(NVN_FORMAT_BGRA8, 64, 64);
        struct s2a_t2t_view dv = {.has = 1, .has_format = 1, .nvn_format = NVN_FORMAT_BGRA8};
        struct s2a_t2t_region fr = full(64, 64);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, &dv, &fr, 0, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_COPY, "same-class view format copy");
        dv.nvn_format = NVN_FORMAT_RGBA16F;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, &dv, &fr, 0, &p, why, sizeof why) != 0,
              "cross-class view format is red");
        // 纹理与视图格式不同类（图像 RGBA8，视图说自己是 RG8）：像素网格不一致，拒。
        dv.nvn_format = NVN_FORMAT_RG8;
        d.nvn_format = NVN_FORMAT_RGBA8;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, &dv, &fr, 0, &p, why, sizeof why) != 0,
              "view format not matching texture class is red");
    }

    // 视图选层 + 区域 z/depth = 数组层区间。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 64, 64), d = tex(NVN_FORMAT_RGBA8, 64, 64);
        s.layers = 6; d.layers = 8;
        struct s2a_t2t_view sv = {.has = 1, .min_layer = 1}, dv = {.has = 1, .min_layer = 2};
        struct s2a_t2t_region sr = {0, 0, 1, 64, 64, 3}, dr = {0, 0, 0, 64, 64, 3};
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, &sv, &sr, &d, &dv, &dr, 0, &p, why, sizeof why) == 0, "array layers");
        CHECK(p.op == S2A_T2T_COPY && p.src_base_layer == 2 && p.dst_base_layer == 2 &&
              p.layer_count == 3, "layer view + z fold");
        sr.d = 6;
        CHECK(s2a_t2t_plan(&s, &sv, &sr, &d, &dv, &dr, 0, &p, why, sizeof why) != 0,
              "layer range past the end is red");
        sr.d = 2; dr.d = 3;
        CHECK(s2a_t2t_plan(&s, &sv, &sr, &d, &dv, &dr, 0, &p, why, sizeof why) != 0,
              "layer count mismatch is red");
        sv.min_layer = 7;
        CHECK(s2a_t2t_plan(&s, &sv, &sr, &d, &dv, &dr, 0, &p, why, sizeof why) != 0,
              "view base layer past the end is red");
    }

    // 视图字段拒绝：mip 越界、target 重定维度。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 64, 64), d = tex(NVN_FORMAT_RGBA8, 64, 64);
        struct s2a_t2t_region fr = full(64, 64);
        struct s2a_t2t_view sv = {.has = 1, .base_level = 3};
        CHECK(s2a_t2t_plan(&s, &sv, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "view mip beyond levels is red");
        sv.base_level = 0; sv.has_target = 1; sv.target = 4;   // 2D → 2D_ARRAY
        CHECK(s2a_t2t_plan(&s, &sv, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "view target retype is red");
    }

    // 深度/模板：同格式直拷 aspect 齐；stencil 模式选 stencil 面；跨面/缩放拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_DEPTH24_STENCIL8, 256, 256),
                           d = tex(NVN_FORMAT_DEPTH24_STENCIL8, 256, 256);
        struct s2a_t2t_region fr = full(256, 256);
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) == 0, "ds copy");
        CHECK(p.op == S2A_T2T_COPY &&
              p.src_aspect == (S2A_T2T_ASPECT_DEPTH | S2A_T2T_ASPECT_STENCIL) &&
              p.dst_aspect == (S2A_T2T_ASPECT_DEPTH | S2A_T2T_ASPECT_STENCIL), "ds copies both aspects");
        s.stencil_mode = d.stencil_mode = 1;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) == 0 &&
              p.src_aspect == S2A_T2T_ASPECT_STENCIL && p.dst_aspect == S2A_T2T_ASPECT_STENCIL,
              "stencil-mode selects the stencil plane");
        s.stencil_mode = 0;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "depth -> stencil mismatch is red");
        s.stencil_mode = 1;
        struct s2a_t2t_view sv = {.has = 1, .has_dsmode = 1, .dsmode_stencil = 0};   // 视图显式选 depth
        d.stencil_mode = 0;
        CHECK(s2a_t2t_plan(&s, &sv, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "view depth vs texture stencil mismatch is red");
        s.stencil_mode = 0; d.stencil_mode = 1;
        struct s2a_t2t_view dv = {.has = 1, .has_dsmode = 1, .dsmode_stencil = 1};
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, &dv, &fr, 0, &p, why, sizeof why) != 0,
              "depth+stencil -> stencil-only mismatch is red");
        d = tex(NVN_FORMAT_DEPTH24_STENCIL8, 128, 128);
        struct s2a_t2t_region dr = full(128, 128);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "scaled depth copy is red");
    }

    // 压缩块：整块对齐允许直拷；不对齐 / 缩放拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA_DXT5, 256, 256), d = tex(NVN_FORMAT_RGBA_DXT5, 256, 256);
        struct s2a_t2t_region fr = full(256, 256);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_COPY, "aligned compressed copy");
        struct s2a_t2t_region part = {8, 8, 0, 16, 16, 1};
        CHECK(s2a_t2t_plan(&s, NULL, &part, &d, NULL, &part, 0, &p, why, sizeof why) == 0,
              "block-aligned partial compressed copy");
        part.x = 6;
        CHECK(s2a_t2t_plan(&s, NULL, &part, &d, NULL, &part, 0, &p, why, sizeof why) != 0,
              "misaligned compressed copy is red");
        d = tex(NVN_FORMAT_RGBA_DXT5, 128, 128);
        struct s2a_t2t_region dr = full(128, 128);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "compressed scale is red");
    }

    // 3D：同尺寸同格式直拷（z 是真深度）；3D↔2D 拒；镜像 XY 在 3D 上也可 blit。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 64, 64), d = tex(NVN_FORMAT_RGBA8, 64, 64);
        s.is_3d = d.is_3d = 1; s.target = d.target = 2; s.depth = d.depth = 8; s.layers = d.layers = 1;
        struct s2a_t2t_region sr = {0, 0, 2, 64, 64, 4}, dr = {0, 0, 1, 64, 64, 4};
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) == 0, "3D copy");
        CHECK(p.op == S2A_T2T_COPY && p.extent[2] == 4 && p.src_offset[2] == 2 && p.dst_offset[2] == 1,
              "3D copies z slices in extents");
        CHECK(p.layer_count == 1 && p.src_base_layer == 0 && p.dst_base_layer == 0, "3D has no layers");
        sr.z = 6;
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "3D z past depth is red");
        sr.z = 2;
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0x4u, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_BLIT_NEAREST, "3D mirror blit");
        d.is_3d = 0; d.target = 1; d.depth = 1; d.layers = 8;
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "3D <-> 2D is red");
    }

    // 区域合法性：偏移直拷、越界/空区拒。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_RGBA8, 128, 128), d = tex(NVN_FORMAT_RGBA8, 128, 128);
        struct s2a_t2t_region sr = {16, 16, 0, 32, 32, 1}, dr = {0, 0, 0, 32, 32, 1};
        memset(&p, 0, sizeof p);
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_COPY && p.src_offset[0] == 16 && p.extent[0] == 32, "sub-rect copy");
        sr.w = 200;
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "src region past image is red");
        sr.w = 32; dr.x = -4;
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "negative dst offset is red");
        dr.x = 0; sr.w = 0;
        CHECK(s2a_t2t_plan(&s, NULL, &sr, &d, NULL, &dr, 0, &p, why, sizeof why) != 0,
              "empty region is red");
    }

    // BUFFER 目标不是纹理间拷贝的对象。
    {
        struct s2a_t2t_tex s = tex(NVN_FORMAT_R8, 64, 1), d = tex(NVN_FORMAT_R8, 64, 1);
        struct s2a_t2t_region fr = full(64, 1);
        s.target = 0xA;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "buffer target is red");
    }

    // 格式事实缺失（无快照）：同 VkFormat 仍可直拷；异 VkFormat / 需要 blit 的明确拒。
    {
        struct s2a_t2t_tex s = tex(0, 64, 64), d = tex(0, 64, 64);
        s.vk_format = d.vk_format = 37;
        struct s2a_t2t_region fr = full(64, 64);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) == 0 &&
              p.op == S2A_T2T_COPY, "unknown nvn fmt same VkFormat copies");
        d.vk_format = 38;
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &fr, 0, &p, why, sizeof why) != 0,
              "unknown nvn fmt differing VkFormat is red");
        d.vk_format = 37; d = tex(0, 32, 32); d.vk_format = 37;
        struct s2a_t2t_region dr = full(32, 32);
        CHECK(s2a_t2t_plan(&s, NULL, &fr, &d, NULL, &dr, 0x1u, &p, why, sizeof why) != 0,
              "linear blit with unknown format is red");
    }

    printf("%s (%d checks failed)\n", fails ? "FAIL" : "ok", fails);
    return fails ? 1 : 0;
}
