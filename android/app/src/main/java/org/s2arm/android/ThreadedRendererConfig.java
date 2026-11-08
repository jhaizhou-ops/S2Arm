package org.s2arm.android;

/** 冷启动 extra 到 JNI 环境变量值的转换；无法识别的值不可默默回退。 */
final class ThreadedRendererConfig {
    static final String EXTRA = "s2arm.threaded_renderer";

    static String resolve(boolean present, Object value) {
        if (!present) return "1";
        if (value instanceof Boolean) return ((Boolean) value) ? "1" : "0";
        if ("true".equals(value) || "1".equals(value)) return "1";
        if ("false".equals(value) || "0".equals(value)) return "0";
        if ("auto".equals(value)) return "auto";
        throw new IllegalStateException(EXTRA + " must be true|false|1|0|auto (got " + value + ")");
    }
}
