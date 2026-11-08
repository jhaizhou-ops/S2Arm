// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class DebugEnvironmentTest {
    private static native int apply(byte[][] values);
    private static native boolean seal();
    private static native String value(String name);
    private static native void failSetenv();
    private static int checks;
    private static void check(boolean condition) {
        checks++;
        if (!condition) throw new AssertionError("debug env check " + checks);
    }
    private static void rejected(Object input) {
        try { DebugEnvironment.parse(input); throw new AssertionError("accepted malformed input"); }
        catch (IllegalArgumentException expected) { check(!expected.getMessage().contains("secret")); }
    }
    private static byte[][] bytes(String... values) {
        return Arrays.stream(values).map(s -> s.getBytes(StandardCharsets.UTF_8)).toArray(byte[][]::new);
    }
    public static void main(String[] args) {
        System.load(args[0]);
        boolean debug = Boolean.parseBoolean(args[1]);
        if (!debug) {
            // Release must not even validate/access arbitrary intent data.
            check(DebugEnvironment.parse(new Object()) == null);
            check(DebugEnvironment.parse("S2A_TEST_ENV=secret") == null);
            check(apply(bytes("S2A_TEST_ENV=secret")) != 0);
            check(value("S2A_TEST_ENV") == null);
            check(seal());
        } else switch (args[2]) {
            case "valid":
                byte[][] parsed = DebugEnvironment.parse(new String[]{"S2A_TEST_ENV=one=two", "S2A_TEST_EMPTY=", "S2A_TEST_UTF8=中文"});
                check(apply(parsed) == 0);
                check("one=two".equals(value("S2A_TEST_ENV")));
                check("".equals(value("S2A_TEST_EMPTY")));
                check("中文".equals(value("S2A_TEST_UTF8")));
                check(apply(bytes("S2A_TEST_ENV=changed")) != 0);
                check(seal());
                check(apply(bytes("S2A_TEST_ENV=changed")) != 0);
                check("one=two".equals(value("S2A_TEST_ENV")));
                break;
            case "invalid":
                for (Object bad : new Object[]{null, 3, new String[0], new String[]{null}, "=secret", "S2A_=secret", "OTHER=secret", "S2A_BAD-NAME=secret", "S2A_BAD NAME=secret", "S2A_名=secret", "S2A_TEST_ENV", "S2A_TEST_ENV=secret\0", "S2A_TEST_ENV=\ud800", new String[]{"S2A_TEST_ENV=secret", "S2A_TEST_ENV=second"}, "S2A_TEST_ENV=" + "x".repeat(8192)}) rejected(bad);
                check(DebugEnvironment.parse("S2A_TEST_ENV=a=b").length == 1);
                check(value("S2A_TEST_ENV") == null);
                break;
            case "bounds":
                String[] boundary = new String[32];
                for (int i = 0; i < boundary.length; i++) {
                    String prefix = "S2A_TEST_BOUND_" + i + "=";
                    boundary[i] = prefix + "v".repeat(2048 - prefix.length());
                }
                check(apply(DebugEnvironment.parse(boundary)) == 0); // exactly 65536 bytes, 32 entries
                check(value("S2A_TEST_BOUND_31").length() == 2030);
                break;
            case "sealed":
                check(seal());
                check(apply(bytes("S2A_TEST_ENV=changed")) != 0);
                check(value("S2A_TEST_ENV") == null);
                check(seal());
                break;
            case "raw":
                for (byte[][] bad : new byte[][][]{null, new byte[0][], {null}, bytes("S2A_TEST_ENV=secret", "OTHER=x"), bytes("S2A_=x"), bytes("S2A_X-Y=x"), bytes("S2A_TEST_ENV=x\0y"), bytes("S2A_TEST_ENV=x", "S2A_TEST_ENV=y")}) {
                    check(apply(bad) != 0);
                    check(value("S2A_TEST_ENV") == null);
                }
                String[] tooMany = new String[33];
                for (int i = 0; i < tooMany.length; i++) tooMany[i] = "S2A_TEST_" + i + "=x";
                rejected(tooMany);
                check(apply(bytes(tooMany)) != 0);
                check(apply(bytes("S2A_TEST_ENV=" + "x".repeat(8192))) != 0);
                String[] tooLarge = new String[9];
                for (int i = 0; i < tooLarge.length; i++) {
                    String prefix = "S2A_TEST_" + i + "=";
                    tooLarge[i] = prefix + "x".repeat(8192 - prefix.length());
                }
                rejected(tooLarge);
                check(apply(bytes(tooLarge)) != 0);
                String maxEntry = "S2A_TEST_ENV=" + "x".repeat(8192 - "S2A_TEST_ENV=".length());
                check(apply(DebugEnvironment.parse(maxEntry)) == 0);
                check(value("S2A_TEST_ENV").length() == 8192 - "S2A_TEST_ENV=".length());
                break;
            case "concurrent":
                java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(1);
                int[] outcome = {-1};
                Thread writer = new Thread(() -> {
                    try { ready.await(); } catch (InterruptedException error) { throw new AssertionError(error); }
                    outcome[0] = apply(bytes("S2A_TEST_ENV=race"));
                });
                writer.start(); ready.countDown(); check(seal());
                try { writer.join(); } catch (InterruptedException error) { throw new AssertionError(error); }
                check(outcome[0] == 0 ? "race".equals(value("S2A_TEST_ENV")) : value("S2A_TEST_ENV") == null);
                check(apply(bytes("S2A_TEST_ENV=changed")) != 0);
                break;
            case "failure":
                failSetenv();
                check(apply(bytes("S2A_TEST_FIRST=one", "S2A_TEST_ENV=two")) != 0);
                check(!seal()); // Never launch with partial configuration.
                check(apply(bytes("S2A_TEST_ENV=retry")) != 0);
                break;
            default: throw new AssertionError("unknown scenario");
        }
        System.out.println("debug_env " + debug + " " + args[2] + ": " + checks + " checks");
    }
}
