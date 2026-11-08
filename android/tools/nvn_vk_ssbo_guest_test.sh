#!/usr/bin/env bash
# 可写 graphics storage buffer（帧内影子 + 退休回写）、零附件 render pass、驱动常量段 c0、BC 视图
# 格式判定的宿主回归：L 级纯逻辑 + 真 Vulkan 语义（Mesa lavapipe）。
#
# 一条命令：bash android/tools/nvn_vk_ssbo_guest_test.sh
# 退出码：0 = 全绿；1 = 有用例红/生产接缝缺失/反例没被抓到；2 = 缺 lavapipe ICD（不静默跳过）。
#
# 覆盖：
#   A. 帧内影子账本（生产 fd_ssbo_wb_find 的等价契约）：同一 guest 区间第二次绑定复用同一
#      VkBuffer/偏移；不同区间重叠准确拒绝；地址未按 minStorageBufferOffsetAlignment 对齐拒绝；
#      一帧 16 个影子上限；退休回写只写 writable。
#   B. 真 Vulkan：同一影子复用 → 后一笔看到前一笔的 GPU 写（反例：新建影子就看不到）；host-visible
#      coherent 影子由 GPU 写、fence 信号后 host memcpy 读回，逐字节与 GPU 写一致（fence 可见性）。
#   C. 真 Vulkan：VkRenderPass/VkFramebuffer attachmentCount=0 + renderArea 覆盖视口时，draw 真的
#      执行、片元着色器写满 SSBO；反例：renderArea 小于视口时视口外没有片元。
#   D. 生产 nvn_vk_mrt.c：c0 表基址/16 字节描述符/0x610 最大点径/0x644 base instance、未知 stage 与
#      缓冲区过小拒绝；nvn_vk_bcrt_view_format 的接受/拒绝与 why。
#
# 反例先行：
#   · 用例内先断言错误策略（永不复用 / 只按 guest 起点匹配 / 重叠不拒绝）会产生的错误结果；
#   · 本脚本再把生产 nvn_vk_mrt.c 改坏两处（c0 vs 表基址、4 字节视图编码 8 字节块）做变异构建，
#     要求用例变红且红在对应断言上——证明断言真的锁住了布局与格式判据。
#
# 生产接缝检查：first_draw.c 里的 static 影子账本/回写/零附件分支不链接（任务约束），这里只检查
# 接缝仍在（函数名/回写调用/旧实现报红文案已删）；功能语义由本用例的等价契约 + 真 Vulkan 语义证明。
# 生产代码结构大改时这里会红，按提示同步用例即可，不是功能红。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
first_draw="$android/native/nvn/nvn_vk_first_draw.c"
mrt_src="$android/native/nvn/nvn_vk_mrt.c"

find_icd() {
    if [ -n "${S2A_LAVAPIPE_ICD:-}" ]; then printf '%s\n' "$S2A_LAVAPIPE_ICD"; return; fi
    for f in "$HOME/.local/share/vulkan/icd.d/lvp_icd.json" "$HOME/.local/share/vulkan/icd.d/lvp_icd."*.json \
             /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return; }
    done
}
icd=$(find_icd || true)
if [ -z "$icd" ] || [ ! -f "$icd" ]; then
    echo "【红】找不到 lavapipe ICD（${icd:-空}）：本用例要求 CPU Vulkan 参考实现，不静默跳过。" >&2
    exit 2
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
inc=(-I "$android/native" -I "$android/native/direct" -I "$android/native/nvn"
     -I "$android/tests/vkhost" -I "$android/tests/hostvk"
     -I "$repo/graphics/nvn/third_party/vulkan-headers/include"
     -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn"
     -I "$repo/graphics/nvn/gfx/tex" -I "$repo/runtime/include" -I "$repo/runtime/src")

# build <输出> <nvn_vk_mrt.c 源>：只编生产 nvn_vk_mrt.c + nvn_vk_format.c + vk_device.c。
build() {
    "$cc_bin" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
        -Wno-missing-field-initializers "${inc[@]}" \
        -o "$1" \
        "$android/tests/nvn_vk_ssbo_guest_test.c" \
        "$2" \
        "$android/native/nvn/nvn_vk_format.c" \
        "$android/native/direct/vk_device.c" \
        -lvulkan -lm -pthread
}

export VK_DRIVER_FILES="$icd"
echo "lavapipe: $icd"
build "$tmp/t" "$mrt_src"
fail=0
"$tmp/t" || fail=1

# ---------- 生产接缝检查（不是功能断言；结构大改时按提示同步用例） ----------
seam_fail=0
seam_present() {
    if grep -Fq -- "$2" "$first_draw"; then
        printf '✓ 生产接缝：%s\n' "$1"
    else
        printf '✗ 生产接缝：%s（first_draw.c 找不到 "%s"；生产结构变了？）\n' "$1" "$2" >&2
        seam_fail=1
    fi
}
seam_absent() {
    if grep -Fq -- "$2" "$first_draw"; then
        printf '✗ 生产接缝：%s（旧实现串又出现了："%s"）\n' "$1" "$2" >&2
        seam_fail=1
    else
        printf '✓ 生产接缝：%s\n' "$1"
    fi
}
seam_present "可写 SSBO 帧内影子查找存在" "fd_ssbo_wb_find"
seam_present "可写 SSBO 帧内影子登记存在" "fd_ssbo_wb_add"
seam_present "帧退休回写函数存在" "fd_ssbo_wb_writeback"
seam_present "帧退休路径真的调用回写" "fd_ssbo_wb_writeback(q);"
seam_present "驱动 c0 合成真的被 first_draw 使用" "nvn_vk_driver_c0_fill_graphics("
seam_present "零附件分支存在（rt_count==0 不再直接失败）" "state->rt_count == 0"
seam_present "零附件 renderArea 仍夹到设备 framebuffer 上限" "maxFramebufferWidth"
seam_present "可写 SSBO 仍按 minStorageBufferOffsetAlignment 校验地址" "minStorageBufferOffsetAlignment"
seam_present "驱动 c0 仍按测量段大小填充" "NVN_VK_DRIVER_C0_BYTES"
seam_absent "可写 SSBO 不再被旧实现直接拒绝" "writable graphics storage buffer is not implemented"
seam_absent "零附件 draw 不再被旧实现直接拒绝" "first draw has no render target"
[ "$seam_fail" = 0 ] || fail=1

# ---------- 反例变异构建：改坏生产实现后用例必须变红在对应断言上 ----------
# mutate <名字> <sed 表达式> <必须出现的红断言定位>
mutate() {
    local name="$1" expr="$2" expect="$3" rc=0
    sed "$expr" "$mrt_src" > "$tmp/mut.c"
    if cmp -s "$mrt_src" "$tmp/mut.c"; then
        printf '✗ 反例变异「%s」没有应用（nvn_vk_mrt.c 结构变了？请同步本脚本）\n' "$name" >&2
        return 1
    fi
    if ! build "$tmp/mut" "$tmp/mut.c"; then
        printf '✗ 反例变异「%s」编不过（变异构建失败）\n' "$name" >&2
        return 1
    fi
    set +e
    "$tmp/mut" > "$tmp/mut.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        printf '✗ 反例变异「%s」没被抓到：期望用例红，真结果 全绿\n' "$name" >&2
        return 1
    fi
    if ! grep -Fq -- "$expect" "$tmp/mut.log"; then
        printf '✗ 反例变异「%s」红了但不是预期的断言（日志里找不到 "%s"）\n' "$name" "$expect" >&2
        sed -n '1,20p' "$tmp/mut.log" >&2
        return 1
    fi
    printf '✓ 反例变异「%s」被抓到（红在：%s）\n' "$name" "$expect"
}
mutate "c0 vs 表基址 0x110 → 0x100" 's/case 0: return 0x110;/case 0: return 0x100;/' \
    '[D1] vs 存储缓冲表基址' || fail=1
mutate "bcrt 跳过「块字节数 == 视图每像素字节数」校验" 's/if (pb != bb) {/if (0 \&\& pb != bb) {/' \
    '[D5] BC7(16B 块) + RGBA16UI' || fail=1

if [ "$fail" != 0 ]; then
    echo "nvn-vk-ssbo-guest: 失败（见上方 ✗）" >&2
    exit 1
fi
echo "nvn-vk-ssbo-guest: 全部用例通过（S 级：lavapipe）"
