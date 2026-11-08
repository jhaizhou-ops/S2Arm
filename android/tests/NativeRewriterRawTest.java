package org.s2arm.android;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * Raw host JVM -> real JNI control, deliberately without Java file/path APIs.
 *
 * The external Python harness owns all fixture creation and complete CLI byte/SHA
 * comparisons. Args: fixture-directory case-directory. Each case must already
 * have an empty out directory and a private log file; bad-log/log is a directory.
 * All cases use module main. Defaults are main.nso, spin=false, cut=true, no tables.
 * tables/concurrent-tables use both tables and spin=true; no-cut uses both tables
 * and cut=false. widen-only/fps-only use the named table. spin-off/on use spin.nso;
 * cut-on/off use sdk.nso. No Java facade or its ownership checks run in this test.
 */
public final class NativeRewriterRawTest {
    private static Method raw;
    private static String fixtures;
    private static String cases;
    private static final byte[] MODULE = bytes("main");

    private NativeRewriterRawTest() {}

    private static byte[] bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static int invoke(byte[] input, byte[] output, byte[] module,
                              boolean spin, boolean cut, byte[] widen, byte[] fps,
                              byte[] log) throws Exception {
        try {
            return (Integer) raw.invoke(null, input, output, module, spin, cut, widen, fps, log);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new AssertionError(cause);
        }
    }

    private static int run(String name, String input, boolean spin, boolean cut,
                           boolean widen, boolean fps) throws Exception {
        return invoke(bytes(fixtures + "/" + input), bytes(cases + "/" + name + "/out"),
                MODULE, spin, cut, widen ? bytes(fixtures + "/widen.tsv") : null,
                fps ? bytes(fixtures + "/fps.tsv") : null, bytes(cases + "/" + name + "/log"));
    }

    private static void result(String name, int actual, int expected) {
        System.out.println("CASE\t" + name + "\t" + actual);
        require(actual == expected, name + ": expected rc" + expected + ", got " + actual);
    }

    private static void check(String name, String input, boolean spin, boolean cut,
                              boolean widen, boolean fps, int expected) throws Exception {
        result(name, run(name, input, spin, cut, widen, fps), expected);
    }

    private static byte[] repeated(int length) {
        byte[] result = new byte[length];
        Arrays.fill(result, (byte) 'x');
        return result;
    }

    private static void invalidArguments() throws Exception {
        byte[] input = bytes(fixtures + "/main.nso");
        byte[] output = bytes(cases + "/normal-first/out");
        byte[] log = bytes(cases + "/normal-first/log");
        byte[][] invalidPaths = {null, {}, {0}, {'x', 0, 'y'}, {(byte) 0x80},
                {(byte) 0xc0, (byte) 0x80}, {(byte) 0xed, (byte) 0xa0, (byte) 0x80},
                {(byte) 0xf0, (byte) 0x9f, (byte) 0x98},
                {(byte) 0xf4, (byte) 0x90, (byte) 0x80, (byte) 0x80}, repeated(4096)};
        // Check every required path, then both optional paths when present. Later
        // argument rejection also exercises cleanup of buffers copied before it.
        int rejected = 0;
        for (int repeat = 0; repeat < 2; repeat++) {
            for (int field : new int[] {0, 1, 3, 4, 5}) {
                for (byte[] invalid : invalidPaths) {
                    if ((field == 3 || field == 4) && invalid == null) continue;
                    byte[][] request = {input, output, MODULE, null, null, log};
                    request[field] = invalid;
                    try {
                        invoke(request[0], request[1], request[2], false, true,
                                request[3], request[4], request[5]);
                        throw new AssertionError("invalid raw path accepted at field " + field);
                    } catch (IllegalArgumentException expected) {
                        rejected++;
                    }
                }
            }
            byte[][] invalidModules = {null, {}, {0}, repeated(65), bytes("../main"),
                    bytes("模块"), {(byte) 0xed, (byte) 0xa0, (byte) 0x80}};
            for (byte[] module : invalidModules) {
                try {
                    invoke(input, output, module, false, true, null, null, log);
                    throw new AssertionError("invalid raw module accepted");
                } catch (IllegalArgumentException expected) {
                    rejected++;
                }
            }
        }
        require(rejected == 110, "invalid request count differs");
        System.out.println("INVALID\tIllegalArgumentException\t" + rejected);
    }

    public static void main(String[] args) throws Exception {
        require(args.length == 2, "usage: NativeRewriterRawTest fixture-directory case-directory");
        fixtures = args[0]; cases = args[1];
        System.loadLibrary("s2arm_rewriter");
        raw = NativeRewriter.class.getDeclaredMethod("rewrite0", byte[].class, byte[].class,
                byte[].class, boolean.class, boolean.class, byte[].class, byte[].class, byte[].class);
        raw.setAccessible(true);

        check("normal-first", "main.nso", false, true, false, false, 0);
        check("bad", "bad.nso", false, true, false, false, 1);
        check("normal-after-bad", "main.nso", false, true, false, false, 0);
        check("gap", "gap.nso", false, true, false, false, 3);
        check("normal-after-gap", "main.nso", false, true, false, false, 0);
        check("tables", "main.nso", true, true, true, true, 0);
        check("no-cut", "main.nso", false, false, true, true, 0);
        check("widen-only", "main.nso", false, true, true, false, 0);
        check("fps-only", "main.nso", false, true, false, true, 0);
        check("spin-off", "spin.nso", false, true, false, false, 0);
        check("spin-on", "spin.nso", true, true, false, false, 0);
        check("cut-on", "sdk.nso", false, true, false, false, 0);
        check("cut-off", "sdk.nso", false, false, false, false, 0);
        invalidArguments();
        check("bad-log", "main.nso", false, true, false, false, 1);
        check("normal-after-invalid", "main.nso", false, true, false, false, 0);

        ExecutorService workers = Executors.newFixedThreadPool(2);
        CountDownLatch start = new CountDownLatch(1);
        Future<Integer> tables = workers.submit(() -> {
            start.await(); return run("concurrent-tables", "main.nso", true, true, true, true);
        });
        Future<Integer> plain = workers.submit(() -> {
            start.await(); return run("concurrent-plain", "main.nso", false, true, false, false);
        });
        start.countDown();
        try {
            result("concurrent-tables", tables.get(30, TimeUnit.SECONDS), 0);
            result("concurrent-plain", plain.get(30, TimeUnit.SECONDS), 0);
        } finally {
            workers.shutdownNow();
        }
        System.out.println("NativeRewriterRawTest: rc0/1/3 recovery, argument rejection and shared-DSO callers passed");
    }
}
