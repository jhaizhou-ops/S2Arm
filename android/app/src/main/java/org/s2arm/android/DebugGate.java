// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.content.Intent;
import android.os.Bundle;
import android.util.Log;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

/**
 * 调试入口两道门（10-31 总指挥）：调试构建（BuildConfig.DEBUG）且系统属性 debug.s2a.debug_env=1。
 * 普通 App 设不了 debug.* 属性，只有 adb shell 能开；正式构建（玩家包）里第一道门就关着。
 * 门没开时，MainActivity 收到的 intent 先剥掉全部调试参数，后面的读取点一律读不到；原生侧另有同名的第二道核对（native/debug_gate.h）。
 */
final class DebugGate {
    static final String PROPERTY = "debug.s2a.debug_env";
    // 调试参数：实验 / 诊断 / 调试前缀，加上测试钩子。玩家路径实际会带的只有 title_id / resume_session / gamemap（App 内部设）
    //   与部署用的 graphics_mode、导入目录（LibraryActivity），都不在这里。
    private static final String[] PREFIXES = {"s2arm.experimental_", "s2arm.diag_", "s2arm.debug_"};
    private static final String[] HOOKS = {"s2arm.lifecycle_test", "s2arm.release_stall_ms", "s2arm.stop_stall_ms",
        "s2arm.request_stop", "s2arm.dev_runtime", "s2arm.threaded_renderer", "s2arm.bounded_readonly_check",
        "s2arm.touchlog"};
    private static volatile Boolean open;

    private DebugGate() {}

    static boolean isDebugExtra(String key) {
        if (key == null) return false;
        for (String prefix : PREFIXES) if (key.startsWith(prefix)) return true;
        for (String hook : HOOKS) if (hook.equals(key)) return true;
        return false;
    }

    /** 两道门都开才为真；进程内只查一次属性（属性只在冷启动前由 adb 设）。 */
    static boolean open() {
        if (!BuildConfig.DEBUG) return false;
        Boolean value = open;
        if (value == null) open = value = "1".equals(property());
        return value;
    }

    /** 门没开：剥掉 intent 里的全部调试参数，返回剥掉的个数（只记个数，不记值）。 */
    static int scrub(Intent intent) {
        if (intent == null || open()) return 0;
        Bundle extras = intent.getExtras();
        if (extras == null) return 0;
        int removed = 0;
        for (String key : new ArrayList<>(extras.keySet())) {
            if (!isDebugExtra(key)) continue;
            intent.removeExtra(key);
            removed++;
        }
        if (removed > 0) Log.i("S2Arm", "Debug extras ignored: " + removed + " (needs a debug build and " + PROPERTY + "=1)");
        return removed;
    }

    private static String property() {
        try {
            Process process = new ProcessBuilder("/system/bin/getprop", PROPERTY).redirectErrorStream(true).start();
            String line;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
                line = reader.readLine();
            }
            process.waitFor();
            return line == null ? "" : line.trim();
        } catch (java.io.IOException | InterruptedException e) {
            if (e instanceof InterruptedException) Thread.currentThread().interrupt();
            return "";
        }
    }
}
