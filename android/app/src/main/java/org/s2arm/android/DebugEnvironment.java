// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.nio.charset.StandardCharsets;
import java.util.HashSet;

/** Cold-process diagnostics only. No persistence and no values in errors/logs. */
final class DebugEnvironment {
    static final String EXTRA = "s2arm.debug_env";
    private DebugEnvironment() {}

    static byte[][] parse(Object extra) {
        if (!BuildConfig.DEBUG) return null;
        String[] entries;
        if (extra instanceof String) entries = new String[]{(String) extra};
        else if (extra instanceof String[]) entries = ((String[]) extra).clone();
        else throw invalid();
        if (entries.length == 0 || entries.length > 32) throw invalid();
        HashSet<String> keys = new HashSet<>();
        byte[][] encoded = new byte[entries.length][];
        int total = 0;
        for (int i = 0; i < entries.length; i++) {
            String entry = entries[i];
            if (entry == null || entry.length() > 8192) throw invalid();
            int equal = entry.indexOf('=');
            if (equal < 5 || !entry.substring(0, equal).matches("S2A_[A-Za-z0-9_]+")
                    || !keys.add(entry.substring(0, equal))) throw invalid();
            for (int j = 0; j < entry.length(); j++) {
                char c = entry.charAt(j);
                if (c == 0 || Character.isLowSurrogate(c)) throw invalid();
                if (Character.isHighSurrogate(c)
                        && (++j == entry.length() || !Character.isLowSurrogate(entry.charAt(j)))) throw invalid();
            }
            encoded[i] = entry.getBytes(StandardCharsets.UTF_8);
            total += encoded[i].length;
            if (encoded[i].length > 8192 || total > 65536) throw invalid();
        }
        return encoded;
    }

    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException("Invalid debug environment batch (values withheld)");
    }
}
