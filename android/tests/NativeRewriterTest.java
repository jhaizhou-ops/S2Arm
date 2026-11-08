package org.s2arm.android;

import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/** Real host VM -> JNI -> shared C API comparisons; never a device/App UID claim. */
public final class NativeRewriterTest {
    private static Path root;
    private static String cli;
    private static int sequence;
    private static final StringBuilder report = new StringBuilder("case\tfile\tbytes\tsha256\n");

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static Map<String, byte[]> files(Path directory) throws IOException {
        Map<String, byte[]> result = new LinkedHashMap<>();
        try (java.nio.file.DirectoryStream<Path> entries = Files.newDirectoryStream(directory)) {
            for (Path entry : entries) result.put(entry.getFileName().toString(), Files.readAllBytes(entry));
        }
        return result;
    }

    private static String sha(byte[] bytes) throws Exception {
        StringBuilder out = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) out.append(String.format("%02x", b & 255));
        return out.toString();
    }

    private static void compare(NativeRewriter.Result actual, Path input, String module,
                                boolean spin, boolean cut, Path wide, Path fps) throws Exception {
        require(actual.succeeded(), actual.nativeStatus + ": " + actual.validationError + "\n" + actual.diagnostics);
        Path expected = Files.createDirectory(root.resolve("cli-" + sequence++));
        List<String> command = new ArrayList<>(Arrays.asList(cli, input.toString(), expected.toString(), module));
        if (wide != null) command.add(wide.toString());
        ProcessBuilder builder = new ProcessBuilder(command);
        builder.environment().put("S2A_TARGET", "android");
        builder.environment().put("S2A_REWRITE_SPIN", spin ? "1" : "0");
        builder.environment().put("S2A_SDK_ADDR_CUT", cut ? "1" : "0");
        builder.environment().remove("S2A_FPS_TSV");
        if (fps != null) builder.environment().put("S2A_FPS_TSV", fps.toString());
        builder.redirectErrorStream(true).redirectOutput(root.resolve("cli-" + sequence + ".log").toFile());
        Process process = builder.start();
        require(process.waitFor(30, TimeUnit.SECONDS), "CLI timed out");
        require(process.exitValue() == 0, "CLI failed");
        Map<String, byte[]> left = files(expected), right = files(actual.output);
        require(left.keySet().equals(right.keySet()), "complete output set differs");
        require(actual.artifacts.keySet().equals(left.keySet()), "result artifact identities differ");
        for (String name : left.keySet()) {
            require(Arrays.equals(left.get(name), right.get(name)), "actual bytes differ: " + name);
            String digest = sha(left.get(name));
            require(digest.equals(sha(right.get(name))), "SHA differs: " + name);
            require(actual.artifacts.get(name).sha256.equals(digest), "reported SHA differs: " + name);
            require(actual.artifacts.get(name).bytes == left.get(name).length, "reported size differs");
            report.append(sequence).append('\t').append(name).append('\t')
                    .append(left.get(name).length).append('\t').append(digest).append('\n');
        }
        require(actual.inputs.get("input.nso").sha256.equals(sha(Files.readAllBytes(input))), "input snapshot hash differs");
        require(Files.getPosixFilePermissions(actual.attempt.resolve("snapshots/input.nso"))
                .equals(java.nio.file.attribute.PosixFilePermissions.fromString("r--------")), "snapshot is not read-only/private");
    }

    private static NativeRewriter.Result rewrite(String name, boolean spin, boolean cut, Path wide, Path fps)
            throws Exception {
        Path input = root.resolve(name);
        NativeRewriter.Result result = NativeRewriter.rewrite(root, input, "main", spin, cut, wide, fps);
        compare(result, input, "main", spin, cut, wide, fps);
        return result;
    }

    private static void rejected(Throwing action) throws Exception {
        try { action.run(); throw new AssertionError("invalid request was accepted"); }
        catch (IllegalArgumentException | IOException expected) { /* public argument/ownership rejection */ }
    }
    private interface Throwing { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        root = Paths.get(args[0]).toRealPath(); cli = args[1];
        Path input = root.resolve("main.nso"), wide = root.resolve("widen.tsv"), fps = root.resolve("fps.tsv");
        NativeRewriter.Result plain = rewrite("main.nso", false, true, null, null);
        Map<String, byte[]> oldOutput = files(plain.output);
        NativeRewriter.Result both = rewrite("main.nso", true, true, wide, fps);
        rewrite("main.nso", false, false, wide, fps);
        rewrite("main.nso", false, true, wide, null);
        rewrite("main.nso", false, true, null, fps);
        rewrite("compressed.nso", true, true, wide, fps);
        NativeRewriter.Result namedSdk = NativeRewriter.rewrite(root, root.resolve("sdk.nso"),
                "sdk", false, true, null, null);
        compare(namedSdk, root.resolve("sdk.nso"), "sdk", false, true, null, null);
        require(!Arrays.equals(Files.readAllBytes(plain.output.resolve("main.patched.bin")),
                Files.readAllBytes(both.output.resolve("main.patched.bin"))), "optional tables did not affect output");
        require(ByteBuffer.wrap(Files.readAllBytes(both.output.resolve("main.patched.bin")))
                .order(ByteOrder.LITTLE_ENDIAN).getInt(0x138) == 0x52800048, "FPS word patch missing");

        NativeRewriter.Result spinOff = rewrite("spin.nso", false, true, null, null);
        NativeRewriter.Result spinOn = rewrite("spin.nso", true, true, null, null);
        require(!Arrays.equals(Files.readAllBytes(spinOff.output.resolve("main.patched.bin")),
                Files.readAllBytes(spinOn.output.resolve("main.patched.bin"))), "spin option did not affect output");
        NativeRewriter.Result cutOn = rewrite("sdk.nso", false, true, null, null);
        NativeRewriter.Result cutOff = rewrite("sdk.nso", false, false, null, null);
        require(ByteBuffer.wrap(Files.readAllBytes(cutOn.output.resolve("main.patched.bin")))
                .order(ByteOrder.LITTLE_ENDIAN).getInt(0x100) == 0x52a07c08, "SDK cut expected word missing");
        require(ByteBuffer.wrap(Files.readAllBytes(cutOff.output.resolve("main.patched.bin")))
                .order(ByteOrder.LITTLE_ENDIAN).getInt(0x100) == 0x52a7fc08, "disabled SDK cut changed original word");

        NativeRewriter.Result bad = NativeRewriter.rewrite(root, root.resolve("bad.nso"), "main", false, true, null, null);
        require(bad.nativeStatus == 1 && !bad.succeeded(), "malformed input status differs");
        rewrite("main.nso", false, true, null, null);
        NativeRewriter.Result gaps = NativeRewriter.rewrite(root, root.resolve("gap.nso"), "main", false, true, null, null);
        require(gaps.nativeStatus == 3 && !gaps.succeeded(), "rewrite gap status differs");
        rewrite("main.nso", false, true, null, null);
        require(!plain.attempt.equals(both.attempt) && !plain.attempt.equals(bad.attempt), "staging was reused");
        require(Files.readAllBytes(plain.output.resolve("main.patched.bin")).length > 0, "old output changed after failure");

        rejected(() -> NativeRewriter.rewrite(root, input, "../escape", false, true, null, null));
        Path outside = Files.createTempFile("jni-outside-", ".nso");
        try { rejected(() -> NativeRewriter.rewrite(root, outside, "main", false, true, null, null)); }
        finally { Files.delete(outside); }
        Path link = Files.createSymbolicLink(root.resolve("input-link"), input);
        rejected(() -> NativeRewriter.rewrite(root, link, "main", false, true, null, null));
        Path permissive = Files.createDirectory(root.resolve("permissive"));
        Files.setPosixFilePermissions(permissive, java.nio.file.attribute.PosixFilePermissions.fromString("rwxr-xr-x"));
        rejected(() -> NativeRewriter.rewrite(permissive, input, "main", false, true, null, null));
        Method encode = NativeRewriter.class.getDeclaredMethod("encodeUtf8", String.class); encode.setAccessible(true);
        for (String invalid : Arrays.asList("nul\0path", "bad\ud800path")) {
            try { encode.invoke(null, invalid); throw new AssertionError("bad Java Unicode accepted"); }
            catch (InvocationTargetException error) { require(error.getCause() instanceof IllegalArgumentException, "wrong encoding exception"); }
        }

        Method raw = NativeRewriter.class.getDeclaredMethod("rewrite0", byte[].class, byte[].class, byte[].class,
                boolean.class, boolean.class, byte[].class, byte[].class, byte[].class);
        raw.setAccessible(true);
        Path rawOutput = Files.createDirectory(root.resolve("native-io")), log = Files.createFile(root.resolve("raw.log"));
        byte[] in = input.toString().getBytes(StandardCharsets.UTF_8), out = rawOutput.toString().getBytes(StandardCharsets.UTF_8);
        byte[] module = "main".getBytes(StandardCharsets.UTF_8), logBytes = log.toString().getBytes(StandardCharsets.UTF_8);
        byte[][] invalidBytes = {null, {}, {0}, {(byte)0x80}, {(byte)0xc0,(byte)0x80},
            {(byte)0xed,(byte)0xa0,(byte)0x80}, {(byte)0xf0,(byte)0x9f,(byte)0x98},
            {(byte)0xf4,(byte)0x90,(byte)0x80,(byte)0x80}, new byte[4096]};
        for (int repeat = 0; repeat < 8; repeat++) for (byte[] invalid : invalidBytes) {
            try { raw.invoke(null, invalid, out, module, false, true, null, null, logBytes);
                  throw new AssertionError("bad native path accepted"); }
            catch (InvocationTargetException error) { require(error.getCause() instanceof IllegalArgumentException, "wrong native argument exception"); }
        }
        Path blocked = Files.createFile(root.resolve("not-a-directory"));
        int io = (Integer)raw.invoke(null, in, blocked.toString().getBytes(StandardCharsets.UTF_8), module,
                false, true, null, null, logBytes);
        require(io == 1, "C I/O failure was not returned");
        int logFailure = (Integer)raw.invoke(null, in, out, module, false, true, null, null, out);
        require(logFailure == 1 && files(rawOutput).isEmpty(), "log open failure reached C output");
        rewrite("main.nso", false, true, null, null);

        ExecutorService workers = Executors.newFixedThreadPool(2);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<NativeRewriter.Result>> futures = new ArrayList<>();
        for (int i = 0; i < 6; i++) {
            final boolean tables = i % 2 == 0;
            futures.add(workers.submit(() -> { start.await(); return NativeRewriter.rewrite(root, input,
                    "main", tables, true, tables ? wide : null, tables ? fps : null); }));
        }
        start.countDown();
        try {
            for (int i = 0; i < futures.size(); i++) compare(futures.get(i).get(30, TimeUnit.SECONDS), input,
                    "main", i % 2 == 0, true, i % 2 == 0 ? wide : null, i % 2 == 0 ? fps : null);
        } finally { workers.shutdownNow(); }
        Map<String, byte[]> afterFailures = files(plain.output);
        require(oldOutput.keySet().equals(afterFailures.keySet()), "old output file set changed");
        for (String name : oldOutput.keySet()) require(Arrays.equals(oldOutput.get(name), afterFailures.get(name)),
                "old output bytes changed after failure: " + name);
        Files.write(root.resolve("comparisons.tsv"), report.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("NativeRewriter: actual JNI/CLI bytes+SHA, repeat/recovery, native rc1/3, UTF-8/ownership, explicit options and concurrent callers passed");
    }
}
