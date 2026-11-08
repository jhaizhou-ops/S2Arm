package org.s2arm.android;

/**
 * Vulkan 款直连的冷启动选择（#274 零配置就绪判定）。取值与 native direct_choice.h 的 S2A_VK_CHOICE_* 同值，
 * 经 NativeBridge.configureVulkanDirect 交给 s2a_android_vk_select；只在冷启动设一次，局内冻结。
 * 冷启动 intent 的 s2arm.experimental_vulkan_direct：true = 手动直连，false = 通用，"auto" = AUTO
 * （按包内 direct-vulkan.txt 与上局 fail / attempt 标记判，判不成回通用并打一行原因）。没给就用 DEFAULT。
 */
final class VulkanDirectChoice {
    static final int GENERIC = 0;
    static final int DIRECT = 1;
    static final int AUTO = 2;
    /** Vulkan 款缺省选择：缺省仍不开 AUTO。维护方真机验收后只改这一行（改成 AUTO），#274。 */
    static final int DEFAULT = GENERIC;

    private VulkanDirectChoice() {}

    /** intent extra 的值 → 选择。类型或取值不对直接拒绝，不按通用兜底。 */
    static int parse(Object value) {
        if (value instanceof Boolean) return (Boolean)value ? DIRECT : GENERIC;
        if ("auto".equals(value)) return AUTO;
        throw new IllegalArgumentException("Vulkan direct choice must be true, false or \"auto\"");
    }

    static String name(int choice) {
        switch (choice) {
            case GENERIC: return "generic";
            case DIRECT: return "direct";
            case AUTO: return "auto";
            default: throw new IllegalArgumentException("unknown Vulkan direct choice " + choice);
        }
    }
}
