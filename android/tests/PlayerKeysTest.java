package org.s2arm.android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Only generated dummy keys; never loads user keys or game data. */
public final class PlayerKeysTest {
    private static final String ZERO = "0".repeat(64), ONE = "1".repeat(64);
    private static final String BASE = "header_key = " + ZERO + "\n";
    private static final String NEXT = "header_key = " + ONE + "\n";
    private static int checks;
    private static Path appDataDirectory;
    private static final PlayerKeys.Cancellation NEVER = () -> false;

    private static void check(boolean condition, String label) {
        checks++;
        if (!condition) throw new AssertionError(label); // Label only; never print input values.
    }
    private static byte[] bytes(String text) { return text.getBytes(StandardCharsets.UTF_8); }
    private static void valid(String label, String input, int count) throws Exception {
        check(PlayerKeys.validate(bytes(input)) == count, label);
    }
    private static void invalid(String label, byte[] input, String message) throws Exception {
        try { PlayerKeys.validate(input); throw new AssertionError(label); }
        catch (PlayerKeys.InvalidKeysException e) { check(message.equals(e.getMessage()), label); }
    }
    private static List<Path> candidates(Path directory) throws IOException {
        List<Path> result = new ArrayList<>();
        try (var files = Files.list(directory)) {
            files.filter(p -> p.getFileName().toString().startsWith(".player-keys-"))
                    .forEach(result::add);
        }
        return result;
    }
    private static Path privateDirectory(Path parent, String name) throws IOException {
        return Files.createDirectory(parent.resolve(name), PosixFilePermissions.asFileAttribute(
                PosixFilePermissions.fromString("rwx------")));
    }
    private static void unchanged(Path directory, byte[] old, String label) throws IOException {
        check(Arrays.equals(Files.readAllBytes(directory.resolve("prod.keys")), old), label);
        check(candidates(directory).isEmpty(), label + " cleanup");
    }
    private static void refused(Path directory, InputStream stream, PlayerKeys.Cancellation cancel,
                                Class<? extends IOException> type, String label) throws Exception {
        refused(appDataDirectory, directory, stream, cancel, type, label);
    }
    private static void refused(Path dataDirectory, Path directory, InputStream stream,
                                PlayerKeys.Cancellation cancel, Class<? extends IOException> type,
                                String label) throws Exception {
        try { PlayerKeys.importKeys(dataDirectory, directory, stream, cancel); throw new AssertionError(label); }
        catch (IOException e) {
            check(type.isInstance(e), label);
            check(e.getCause() == null && e.getSuppressed().length == 0
                    && !e.getMessage().contains("DUMMY_SECRET"), label + " sanitized");
        }
    }
    private static void formats() throws Exception {
        String format = "密钥文件格式无效，请选择 prod.keys 文本文件。";
        String missing = "缺少有效的 header_key。", conflict = "密钥文件存在冲突条目。";
        valid("minimal", BASE, 1);
        valid("BOM comments", "\ufeff# dummy\r\n" + BASE + "# trailing", 1);
        valid("unknown name", BASE + "OTHER_01=0a\n", 2);
        valid("lowercase prefix", "header_key=0x" + ZERO, 1);
        valid("same duplicate", BASE + BASE, 1);
        valid("prefixed then plain", "header_key=0x" + ZERO + "\n" + BASE, 1);
        valid("Unicode whitespace", "\u00a0header_key\u2003=\u001f" + ZERO + "\u3000", 1);
        for (String separator : new String[]{"\n", "\r", "\r\n", "\u000b", "\f", "\u001c",
                "\u001d", "\u001e", "\u0085", "\u2028", "\u2029"}) {
            valid("Python line boundary", BASE.strip() + separator + "other=0a", 2);
        }
        valid("value limit", BASE + "other=" + "a".repeat(2048), 2);
        invalid("empty", new byte[0], missing);
        invalid("missing header", bytes("other=00"), missing);
        invalid("case sensitive header", bytes("HEADER_KEY=" + ZERO), missing);
        invalid("short header", bytes("header_key=00"), missing);
        invalid("uppercase prefix", bytes("header_key=0X" + ZERO), format);
        invalid("odd hex", bytes(BASE + "other=aaa"), format);
        invalid("nonhex", bytes(BASE + "other=gg"), format);
        invalid("long value", bytes(BASE + "other=" + "a".repeat(2050)), format);
        invalid("name whitespace", bytes(BASE + "other name=00"), format);
        invalid("conflicting duplicate", bytes(BASE + NEXT), conflict);
        invalid("same prefixed duplicate", bytes("header_key=0x" + ZERO + "\nheader_key=0x" + ZERO), conflict);
        invalid("plain then prefixed", bytes(BASE + "header_key=0x" + ZERO), conflict);
        invalid("value case conflict", bytes(BASE + "other=aa\nother=AA"), conflict);
        invalid("second BOM", bytes("\ufeff\ufeff" + BASE), format);
        invalid("bad UTF8 comment", new byte[]{'#', (byte) 0xff}, format);
        invalid("U001F not linebreak", bytes(BASE.strip() + "\u001fother=00"), format);
        byte[] exact = bytes(BASE + "#" + "a".repeat(PlayerKeys.MAX_BYTES - bytes(BASE).length - 1));
        check(exact.length == 1 << 20 && PlayerKeys.validate(exact) == 1, "one MiB accepted");
        invalid("over one MiB", Arrays.copyOf(exact, exact.length + 1), "密钥文件过大。");
    }
    private static void longWhitespace() throws Exception {
        // Run only in a child JVM: a regex complexity regression must not hang the test suite.
        String spaces = " ".repeat(100_000);
        valid("long internal ASCII space", "header_key=" + spaces + ZERO, 1);
        valid("long before equals", "header_key" + spaces + "=" + ZERO, 1);
        valid("long edges", spaces + BASE.strip() + spaces, 1);
        for (String space : new String[]{"\u00a0", "\u2003", "\u001f"}) {
            valid("long Python-only whitespace", space.repeat(100_000) + "header_key="
                    + space.repeat(100_000) + ZERO + space.repeat(100_000), 1);
        }
        valid("one MiB internal whitespace", "header_key="
                + " ".repeat(PlayerKeys.MAX_BYTES - 11 - ZERO.length()) + ZERO, 1);
        invalid("long whitespace only", bytes(spaces), "缺少有效的 header_key。");
        invalid("long invalid tail", bytes("header_key=" + spaces + ZERO + "!"),
                "密钥文件格式无效，请选择 prod.keys 文本文件。");
        System.out.println("PlayerKeys long-whitespace: " + checks + " checks passed (synthetic)");
    }
    private static void boundedWhitespaceProcess() throws Exception {
        Process child = new ProcessBuilder(Path.of(System.getProperty("java.home"), "bin", "java").toString(),
                "-cp", System.getProperty("java.class.path"), PlayerKeysTest.class.getName(),
                "--long-whitespace").inheritIO().start();
        try {
            // This is a hang guard, not a microbenchmark/per-device performance acceptance bar.
            check(child.waitFor(10, TimeUnit.SECONDS), "long-whitespace child timed out");
            check(child.exitValue() == 0, "long-whitespace child failed");
        } finally {
            // Only this exact child, never process groups or unrelated Java processes.
            if (child.isAlive()) {
                child.destroyForcibly();
                if (!child.waitFor(5, TimeUnit.SECONDS)) throw new AssertionError("child cleanup timed out");
            }
        }
    }
    private static void storage(Path root) throws Exception {
        Path directory = privateDirectory(root, "keys");
        byte[] original = bytes("\ufeff# preserved verbatim\n" + BASE);
        check(PlayerKeys.importKeys(appDataDirectory, directory, new ByteArrayInputStream(original), NEVER) == 1,
                "first import");
        Path target = directory.resolve("prod.keys");
        check(Arrays.equals(original, Files.readAllBytes(target)), "bytes preserved");
        check(Files.getPosixFilePermissions(target).equals(PosixFilePermissions.fromString("rw-------")),
                "published mode 0600");
        refused(directory, new ByteArrayInputStream(bytes("header_key=DUMMY_SECRET")), NEVER,
                PlayerKeys.InvalidKeysException.class, "bad format");
        unchanged(directory, original, "bad format old retained");
        refused(directory, new ByteArrayInputStream(bytes(NEXT)), () -> true,
                PlayerKeys.CancelledException.class, "pre-cancel");
        unchanged(directory, original, "pre-cancel old retained");
        InputStream broken = new InputStream() {
            public int read() throws IOException { throw new IOException("DUMMY_SECRET source URI"); }
        };
        refused(directory, broken, NEVER, IOException.class, "source IO failure");
        unchanged(directory, original, "source failure old retained");
        InputStream typedFailure = new InputStream() {
            public int read() throws IOException {
                throw new PlayerKeys.InvalidKeysException("DUMMY_SECRET typed provider");
            }
        };
        refused(directory, typedFailure, NEVER, IOException.class, "typed source failure sanitized");
        unchanged(directory, original, "typed source failure old retained");

        refused(directory, new ByteArrayInputStream(bytes(NEXT)), () -> {
            throw new IllegalStateException("DUMMY_SECRET provider");
        }, IOException.class, "callback failure");
        unchanged(directory, original, "callback failure old retained");
        final boolean[] sawPrivate = {false};
        refused(directory, new ByteArrayInputStream(bytes(NEXT)), () -> {
            try {
                for (Path candidate : candidates(directory)) {
                    sawPrivate[0] = Files.size(candidate) == 0
                            && Files.getPosixFilePermissions(candidate).equals(
                                    PosixFilePermissions.fromString("rw-------"));
                    return true;
                }
                return false;
            } catch (IOException e) { throw new IllegalStateException(); }
        }, PlayerKeys.CancelledException.class, "cancel before first write");
        check(sawPrivate[0], "candidate mode 0600 before first byte");
        unchanged(directory, original, "pre-write cancel old retained");
        refused(directory, new ByteArrayInputStream(bytes(NEXT)), () -> {
            try {
                for (Path candidate : candidates(directory)) if (Files.size(candidate) > 0) return true;
                return false;
            } catch (IOException e) { throw new IllegalStateException(); }
        }, PlayerKeys.CancelledException.class, "cancel before commit");
        unchanged(directory, original, "commit cancel old retained");
        // A real filesystem move failure: substitute an empty directory for our own candidate.
        // No product hook or fake Files.move; the old regular destination must not be overwritten.
        final boolean[] fault = {false};
        refused(directory, new ByteArrayInputStream(bytes(NEXT)), () -> {
            try {
                for (Path candidate : candidates(directory)) if (!fault[0] && Files.size(candidate) > 0) {
                    Files.delete(candidate);
                    Files.createDirectory(candidate);
                    fault[0] = true;
                }
                return false;
            } catch (IOException e) { throw new IllegalStateException(); }
        }, IOException.class, "real atomic move failure");
        check(fault[0], "move fault reached");
        unchanged(directory, original, "move failure old retained");
        check(PlayerKeys.importKeys(appDataDirectory, directory, new ByteArrayInputStream(bytes(NEXT)), NEVER) == 1,
                "retry after failure");
        unchanged(directory, bytes(NEXT), "successful replacement");
        final boolean[] closed = {false};
        ByteArrayInputStream owned = new ByteArrayInputStream(bytes(BASE)) {
            public void close() { closed[0] = true; }
        };
        PlayerKeys.importKeys(appDataDirectory, directory, owned, NEVER);
        check(!closed[0], "caller retains stream ownership");
        // Different serialized callers use distinct candidates and cannot remove each other's work.
        CountDownLatch reading = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicReference<Throwable> error = new AtomicReference<>();
        ByteArrayInputStream slow = new ByteArrayInputStream(bytes(NEXT)) {
            public synchronized int read(byte[] b, int off, int len) {
                reading.countDown();
                try { if (!release.await(5, TimeUnit.SECONDS)) throw new IllegalStateException(); }
                catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IllegalStateException(); }
                return super.read(b, off, len);
            }
        };
        Thread first = new Thread(() -> {
            try { PlayerKeys.importKeys(appDataDirectory, directory, slow, NEVER); } catch (Throwable e) { error.set(e); }
        });
        Thread second = new Thread(() -> {
            try { PlayerKeys.importKeys(appDataDirectory, directory, new ByteArrayInputStream(original), NEVER); }
            catch (Throwable e) { error.set(e); }
        });
        first.start();
        check(reading.await(5, TimeUnit.SECONDS), "first reader started");
        second.start();
        release.countDown();
        first.join(5000); second.join(5000);
        check(!first.isAlive() && !second.isAlive() && error.get() == null, "serialized imports complete");
        unchanged(directory, original, "serialized second value complete");
    }
    private static void paths(Path root) throws Exception {
        Path outside = privateDirectory(root, "outside");
        Path safe = privateDirectory(root, "safe");
        Path sentinel = outside.resolve("sentinel");
        Files.writeString(sentinel, "not a key");
        Path link = safe.resolve("prod.keys");
        Files.createSymbolicLink(link, sentinel);
        refused(safe, new ByteArrayInputStream(bytes(BASE)), NEVER, IOException.class, "leaf symlink");
        check(Files.readString(sentinel).equals("not a key") && Files.isSymbolicLink(link),
                "outside and symlink preserved");
        Files.delete(link);
        Files.createSymbolicLink(link, outside.resolve("missing"));
        refused(safe, new ByteArrayInputStream(bytes(BASE)), NEVER, IOException.class, "dangling leaf");
        check(!Files.exists(outside.resolve("missing")), "dangling target not created");
        Files.delete(link);
        Files.createDirectory(link);
        refused(safe, new ByteArrayInputStream(bytes(BASE)), NEVER, IOException.class, "nonregular leaf");
        Files.delete(link);
        Files.write(link, bytes(BASE));
        Files.setPosixFilePermissions(link, PosixFilePermissions.fromString("rw-r--r--"));
        Path restoredAlias = outside.resolve("restored-hardlink");
        Files.createLink(restoredAlias, link);
        refused(safe, new ByteArrayInputStream(bytes("invalid")), NEVER,
                PlayerKeys.InvalidKeysException.class, "restored mode invalid format");
        unchanged(safe, bytes(BASE), "restored mode invalid format retained");
        refused(safe, new ByteArrayInputStream(bytes(NEXT)), () -> true,
                PlayerKeys.CancelledException.class, "restored mode cancelled");
        unchanged(safe, bytes(BASE), "restored mode cancel retained");
        refused(safe, new InputStream() {
            public int read() throws IOException { throw new IOException("DUMMY_SECRET restored source"); }
        }, NEVER, IOException.class, "restored mode source failure");
        unchanged(safe, bytes(BASE), "restored mode source failure retained");
        refused(safe, new ByteArrayInputStream(bytes(NEXT)), () -> {
            try {
                for (Path candidate : candidates(safe)) if (Files.size(candidate) > 0) return true;
                return false;
            } catch (IOException e) { throw new IllegalStateException(); }
        }, PlayerKeys.CancelledException.class, "restored mode cancel before commit");
        unchanged(safe, bytes(BASE), "restored mode final cancel retained");
        check(Files.getPosixFilePermissions(link).equals(PosixFilePermissions.fromString("rw-r--r--")),
                "rejected import does not chmod restored file");
        check(PlayerKeys.importKeys(appDataDirectory, safe, new ByteArrayInputStream(bytes(NEXT)), NEVER) == 1,
                "restored regular mode replaced");
        unchanged(safe, bytes(NEXT), "restored regular replacement bytes");
        check(Files.getPosixFilePermissions(link).equals(PosixFilePermissions.fromString("rw-------")),
                "restored regular replacement mode 0600");
        check(!Files.isSameFile(link, restoredAlias)
                && Arrays.equals(Files.readAllBytes(restoredAlias), bytes(BASE))
                && Files.getPosixFilePermissions(restoredAlias).equals(
                        PosixFilePermissions.fromString("rw-r--r--")), "external hardlink unchanged");
        Files.delete(link);
        Path alias = root.resolve("alias");
        Files.createSymbolicLink(alias, safe);
        refused(alias, new ByteArrayInputStream(bytes(BASE)), NEVER, IOException.class, "directory symlink");
        Path child = privateDirectory(safe, "child");
        refused(alias.resolve("child"), new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "app files ancestor symlink");
        check(!Files.exists(child.resolve("prod.keys")), "app files alias target untouched");
        Path nestedKeys = privateDirectory(child, "keys");
        Path intermediate = privateDirectory(safe, "nested");
        Files.createSymbolicLink(intermediate.resolve("alias"), child);
        refused(intermediate.resolve("alias").resolve("keys"), new ByteArrayInputStream(bytes(BASE)),
                NEVER, IOException.class, "app intermediate ancestor symlink");
        check(!Files.exists(nestedKeys.resolve("prod.keys")), "app intermediate alias target untouched");
        // Only an alias above the app data root models a trusted system-managed alias.
        Path systemAlias = root.getParent().resolve("system-alias");
        Files.createSymbolicLink(systemAlias, root.getParent());
        Path aliasedApp = systemAlias.resolve(root.getFileName());
        Path aliasedKeys = aliasedApp.resolve("safe").resolve("child");
        check(PlayerKeys.importKeys(aliasedApp, aliasedKeys, new ByteArrayInputStream(bytes(BASE)), NEVER) == 1,
                "trusted system ancestor symlink accepted");
        unchanged(child, bytes(BASE), "trusted system ancestor writes own directory");
        check(Files.getPosixFilePermissions(child.resolve("prod.keys")).equals(
                PosixFilePermissions.fromString("rw-------")), "trusted ancestor published mode 0600");
        Files.createSymbolicLink(safe.resolve("linked-keys"), outside);
        refused(aliasedApp, aliasedApp.resolve("safe").resolve("linked-keys"),
                new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "keys directory symlink under trusted ancestor");
        Files.delete(child.resolve("prod.keys"));
        Files.createSymbolicLink(child.resolve("prod.keys"), sentinel);
        refused(aliasedApp, aliasedKeys, new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "leaf symlink under trusted ancestor");
        check(Files.readString(sentinel).equals("not a key") && !Files.exists(outside.resolve("prod.keys")),
                "trusted ancestor does not grant linked target access");
        Path appAlias = root.getParent().resolve("app-alias");
        Files.createSymbolicLink(appAlias, root);
        refused(appAlias, appAlias.resolve("keys"), new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "app data directory itself symlink");
        refused(root, root, new ByteArrayInputStream(bytes(BASE)), NEVER, IOException.class,
                "keys must be strictly below app data directory");
        Path otherApp = privateDirectory(root.getParent(), "app-other");
        refused(root, otherApp, new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "outside app data directory");
        check(!Files.exists(otherApp.resolve("prod.keys")), "outside app directory untouched");
        refused(Path.of("app"), safe, new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "relative app data directory");
        refused(root, Path.of("keys"), new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "relative keys directory");
        refused(safe.resolve("..").resolve("safe"), new ByteArrayInputStream(bytes(BASE)), NEVER,
                IOException.class, "dot traversal");
        Files.setPosixFilePermissions(safe, PosixFilePermissions.fromString("rwxr-xr-x"));
        refused(safe, new ByteArrayInputStream(bytes(BASE)), NEVER, IOException.class, "unsafe directory mode");
        Files.setPosixFilePermissions(safe, PosixFilePermissions.fromString("rwx------"));
        check(candidates(safe).isEmpty(), "rejected paths create no candidates");
    }
    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("--long-whitespace")) {
            longWhitespace();
            return;
        }
        boundedWhitespaceProcess();
        formats();
        Path root = Files.createTempDirectory("s2arm-player-keys-test-").toRealPath();
        appDataDirectory = privateDirectory(root, "app");
        try { storage(appDataDirectory); paths(appDataDirectory); }
        finally {
            // The test-created tree only, no symlink traversal; never touch caller input paths.
            try (var files = Files.walk(root)) {
                for (Path path : files.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
        System.out.println("PlayerKeys: " + checks + " checks passed (synthetic, host filesystem only)");
    }
}
