package org.s2arm.android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.ReadableByteChannel;
import java.nio.channels.WritableByteChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.Permission;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.Stream;

/** Real host files plus explicitly injected operation failures; not SAF/App UID/device evidence. */
public final class PlayerSourcesTest {
    private static final byte[] ABC = "abc".getBytes(StandardCharsets.US_ASCII);
    // Published SHA-256 test vector, independent of the implementation under test.
    private static final String ABC_SHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    private static final long RESERVE = 512L << 20;
    private static final PlayerSources.Cancellation NEVER = () -> false;
    private static int passed, failed, assertions;

    @FunctionalInterface private interface Checked { void run() throws Exception; }

    private static void check(boolean condition, String what) {
        assertions++;
        if (!condition) throw new AssertionError(what);
    }

    private static void test(String name, Checked body) {
        try {
            body.run();
            passed++;
            System.out.println("PASS " + name);
        } catch (Throwable problem) {
            failed++;
            System.err.println("FAIL " + name);
            problem.printStackTrace(System.err);
        }
    }

    private static IOException refusal(String code, Checked action) throws Exception {
        try {
            action.run();
        } catch (IOException expected) {
            check(expected.getCause() == null, "failure has no external cause");
            check(expected.getSuppressed().length == 0, "failure has no suppressed provider/filesystem details");
            if (code != null) {
                check(expected instanceof PlayerSources.Failure, "typed failure for " + code);
                check(((PlayerSources.Failure) expected).code.equals(code), "failure code " + code
                        + ", got " + ((PlayerSources.Failure) expected).code);
            }
            return expected;
        }
        throw new AssertionError("operation unexpectedly succeeded: " + code);
    }

    private static final class Fixture implements AutoCloseable {
        // Only the system-owned test prefix is canonicalized, not later App-owned components.
        // macOS /var -> /private/var must not make the expected Snapshot.path a literal alias.
        final Path base = Files.createTempDirectory("player-sources-test-").toRealPath();
        final Path system = Files.createDirectory(base.resolve("system"));
        final Path app = Files.createDirectory(system.resolve("app"));
        final Path root = Files.createDirectories(app.resolve("files/sources"));
        Fixture() throws IOException { mode(root, "rwx------"); }
        Path destination(byte[] bytes, String extension) throws Exception {
            return root.resolve(hash(bytes) + "." + extension);
        }
        PlayerSources.Snapshot copy(byte[] bytes, PlayerSources.Kind kind, long declared) throws IOException {
            return PlayerSources.importSource(app, root, new ByteArrayInputStream(bytes), kind, declared, NEVER);
        }
        PlayerSources.Snapshot copy(byte[] bytes, long declared, PlayerSources.Operations operations) throws IOException {
            return PlayerSources.importSource(app, root, new ByteArrayInputStream(bytes),
                    PlayerSources.Kind.NSP, declared, NEVER, operations);
        }
        void empty() throws IOException { check(names(root).isEmpty(), "no final or own temporary file remains"); }
        @Override public void close() throws IOException {
            // Test-owned tree only; walkFileTree does not follow the symlinks used by negative cases.
            Files.walkFileTree(base, new SimpleFileVisitor<Path>() {
                @Override public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes)
                        throws IOException {
                    mode(directory, "rwx------");
                    return FileVisitResult.CONTINUE;
                }
                @Override public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                    Files.delete(file);
                    return FileVisitResult.CONTINUE;
                }
                @Override public FileVisitResult postVisitDirectory(Path directory, IOException error) throws IOException {
                    if (error != null) throw error;
                    Files.delete(directory);
                    return FileVisitResult.CONTINUE;
                }
            });
        }
    }

    private static void mode(Path path, String permissions) throws IOException {
        Files.setPosixFilePermissions(path, PosixFilePermissions.fromString(permissions));
    }

    private static List<String> names(Path root) throws IOException {
        try (Stream<Path> paths = Files.list(root)) {
            return paths.map(path -> path.getFileName().toString()).sorted().toList();
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte value : bytes) result.append(String.format("%02x", value & 255));
        return result.toString();
    }

    private static String hash(byte[] bytes) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static String hashFile(Path path) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[8192];
        try (InputStream input = Files.newInputStream(path)) {
            int count;
            while ((count = input.read(buffer)) >= 0) hash.update(buffer, 0, count);
        }
        return hex(hash.digest());
    }

    private static PlayerSources.Operations space(long bytes) {
        return new PlayerSources.Operations() {
            @Override long usableSpace(Path directory) { return bytes; }
        };
    }

    private static final class TrackedInput extends ByteArrayInputStream {
        boolean closed;
        int calls;
        TrackedInput(byte[] bytes) { super(bytes); }
        @Override public synchronized int read(byte[] bytes, int offset, int length) {
            calls++;
            return super.read(bytes, offset, length);
        }
        @Override public void close() { closed = true; }
    }

    /** All I/O remains real; only close adds an external failure after closing the descriptor. */
    private static final class CloseFailureChannel extends FileChannel {
        final FileChannel channel;
        CloseFailureChannel(FileChannel channel) { this.channel = channel; }
        @Override public int read(ByteBuffer target) throws IOException { return channel.read(target); }
        @Override public int write(ByteBuffer source) throws IOException { return channel.write(source); }
        @Override public long read(ByteBuffer[] targets, int offset, int length) throws IOException {
            return channel.read(targets, offset, length);
        }
        @Override public long write(ByteBuffer[] sources, int offset, int length) throws IOException {
            return channel.write(sources, offset, length);
        }
        @Override public long position() throws IOException { return channel.position(); }
        @Override public FileChannel position(long value) throws IOException { channel.position(value); return this; }
        @Override public long size() throws IOException { return channel.size(); }
        @Override public FileChannel truncate(long value) throws IOException { channel.truncate(value); return this; }
        @Override public void force(boolean metadata) throws IOException { channel.force(metadata); }
        @Override public long transferTo(long start, long count, WritableByteChannel target) throws IOException {
            return channel.transferTo(start, count, target);
        }
        @Override public long transferFrom(ReadableByteChannel source, long start, long count) throws IOException {
            return channel.transferFrom(source, start, count);
        }
        @Override public int read(ByteBuffer target, long start) throws IOException { return channel.read(target, start); }
        @Override public int write(ByteBuffer source, long start) throws IOException { return channel.write(source, start); }
        @Override public MappedByteBuffer map(MapMode mode, long start, long size) throws IOException {
            return channel.map(mode, start, size);
        }
        @Override public FileLock lock(long start, long size, boolean shared) throws IOException {
            return channel.lock(start, size, shared);
        }
        @Override public FileLock tryLock(long start, long size, boolean shared) throws IOException {
            return channel.tryLock(start, size, shared);
        }
        @Override protected void implCloseChannel() throws IOException {
            channel.close();
            throw new IOException("SECRET_CLOSE_PRIVATE_PATH");
        }
    }

    private static void privateFile(Path path, byte[] bytes) throws IOException {
        Files.write(path, bytes);
        mode(path, "rw-------");
    }

    /** JDK17-only permission model, NOT Android classes, SELinux or App UID emulation. */
    @SuppressWarnings("removal")
    private static void denySpacePermissions(boolean denyFileApi, Checked action) throws Exception {
        SecurityManager previous = System.getSecurityManager();
        check(previous == null, "permission regression runs in a fresh host VM");
        System.setSecurityManager(new SecurityManager() {
            @Override public void checkPermission(Permission permission) {
                if (permission instanceof RuntimePermission
                        && (permission.getName().equals("getFileStoreAttributes")
                        || (denyFileApi && permission.getName().equals("getFileSystemAttributes")))) {
                    throw new SecurityException("HOST_TEST_DENIED_SPACE_API");
                }
            }
        });
        try { action.run(); }
        finally { System.setSecurityManager(previous); }
    }

    private static void spaceApiRegressions() {
        test("host permission model: real default import does not require FileStore", () -> {
            try (Fixture f = new Fixture()) {
                denySpacePermissions(false, () -> {
                    boolean blocked = false;
                    try { Files.getFileStore(f.root); }
                    catch (SecurityException expected) { blocked = true; }
                    check(blocked, "real host FileStore permission is denied, not an Operations stub");
                    PlayerSources.Snapshot result = f.copy(ABC, PlayerSources.Kind.NSP, 3);
                    check(result.sha256.equals(ABC_SHA), "six-argument production default succeeds");
                    check(Arrays.equals(Files.readAllBytes(result.path), ABC), "actual bytes published");
                    check(new PlayerSources.Operations().usableSpace(f.root.resolve("absent")) == 0,
                            "unavailable File space is zero, not invented capacity");
                });
            }
        });
        test("host permission model: denied supported space API still fails closed", () -> {
            try (Fixture f = new Fixture()) {
                TrackedInput source = new TrackedInput(ABC);
                denySpacePermissions(true, () -> refusal("io-failed", () -> PlayerSources.importSource(
                        f.app, f.root, source, PlayerSources.Kind.NSP, 3, NEVER)));
                check(source.calls == 0 && !source.closed, "no input read or ownership change on denied space");
                f.empty();
            }
        });
    }

    /** The runner supplies a real symlink java.io.tmpdir; this is not a macOS platform mock. */
    private static void temporaryAliasRegressions() {
        test("temporary system prefix alias uses canonical fixture oracle", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Snapshot result = f.copy(ABC, PlayerSources.Kind.NSP, 3);
                check(result.path.equals(f.root.resolve(ABC_SHA + ".nsp")), "canonical source path");
                check(Files.isSameFile(result.path, f.root.resolve(ABC_SHA + ".nsp")), "same actual file");
            }
        });
        test("temporary alias plus explicit system alias preserves path identity", () -> {
            try (Fixture f = new Fixture()) {
                Path alias = Files.createSymbolicLink(f.base.resolve("system-alias"), f.system);
                Path app = alias.resolve("app");
                PlayerSources.Snapshot result = PlayerSources.importSource(app, app.resolve("files/sources"),
                        new ByteArrayInputStream(ABC), PlayerSources.Kind.NSP, 3, NEVER);
                check(result.path.equals(f.root.resolve(ABC_SHA + ".nsp")), "result uses real system-managed prefix");
                Path appLink = Files.createSymbolicLink(f.system.resolve("app-link"), f.app);
                refusal("invalid-directory", () -> PlayerSources.importSource(appLink,
                        appLink.resolve("files/sources"), new ByteArrayInputStream(ABC),
                        PlayerSources.Kind.NSP, 3, NEVER));
                check(Files.isSymbolicLink(appLink), "App-owned alias remains rejected and unchanged");
            }
        });
    }

    private static void finish() {
        System.out.println("PlayerSources: " + passed + " passed, " + failed + " failed; " + assertions + " assertions");
        if (failed != 0) throw new AssertionError("PlayerSources tests failed");
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 0) {
            if (args.length != 1) throw new IllegalArgumentException("one test mode expected");
            if (args[0].equals("--space-api")) spaceApiRegressions();
            else if (args[0].equals("--temp-root")) temporaryAliasRegressions();
            else throw new IllegalArgumentException("unknown test mode");
            finish();
            return;
        }
        test("real filesystem copy, known digest and private content-addressed identity", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Snapshot result = f.copy(ABC, PlayerSources.Kind.NSP, 3);
                check(result.sha256.equals(ABC_SHA), "SHA-256 abc vector");
                check(result.path.equals(f.root.resolve(ABC_SHA + ".nsp")), "canonical source path");
                check(result.bytes == 3 && !result.duplicate, "new snapshot metadata");
                check(Arrays.equals(Files.readAllBytes(result.path), ABC), "exact complete bytes");
                check(Files.getPosixFilePermissions(result.path).equals(
                        PosixFilePermissions.fromString("rw-------")), "published file mode is 0600");
                check(names(f.root).equals(List.of(ABC_SHA + ".nsp")), "no staging residue");
            }
        });
        test("unknown length XCI copy preserves suffix, not a validity/decryption claim", () -> {
            try (Fixture f = new Fixture()) {
                byte[] invalidContainer = {0, 1, 2, 3, (byte) 255};
                PlayerSources.Snapshot result = f.copy(invalidContainer, PlayerSources.Kind.XCI, -1);
                check(result.path.getFileName().toString().equals(hash(invalidContainer) + ".xci"), "XCI suffix");
                check(Arrays.equals(Files.readAllBytes(result.path), invalidContainer), "arbitrary synthetic bytes copied");
            }
        });
        test("zero byte stream is copied without claiming valid container", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Snapshot result = f.copy(new byte[0], 0, space(RESERVE));
                check(result.bytes == 0 && Files.size(result.path) == 0, "empty byte snapshot");
                check(result.sha256.equals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), "empty SHA");
            }
        });
        test("duplicate content is verified and not replaced", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Snapshot original = f.copy(ABC, PlayerSources.Kind.NSP, -1);
                Object fileKey = Files.readAttributes(original.path, BasicFileAttributes.class).fileKey();
                PlayerSources.Snapshot duplicate = f.copy(ABC, PlayerSources.Kind.NSP, 3);
                check(duplicate.duplicate && duplicate.path.equals(original.path), "duplicate identity");
                check(java.util.Objects.equals(fileKey,
                        Files.readAttributes(original.path, BasicFileAttributes.class).fileKey()), "existing inode retained");
                check(names(f.root).size() == 1, "duplicate staging cleaned");
            }
        });
        test("same bytes with NSP and XCI extensions remain separately consumable", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Snapshot a = f.copy(ABC, PlayerSources.Kind.NSP, -1);
                PlayerSources.Snapshot b = f.copy(ABC, PlayerSources.Kind.XCI, -1);
                check(a.sha256.equals(b.sha256) && !a.path.equals(b.path), "same hash, distinct consumer suffix");
                check(!b.duplicate && names(f.root).size() == 2, "both extension identities exist");
            }
        });
        test("corrupt preexisting hash target is never overwritten", () -> {
            try (Fixture f = new Fixture()) {
                Path destination = f.destination(ABC, "nsp");
                privateFile(destination, "bad".getBytes(StandardCharsets.US_ASCII));
                refusal("existing-corrupt", () -> f.copy(ABC, PlayerSources.Kind.NSP, 3));
                check(Files.readString(destination).equals("bad"), "corruption left for explicit recovery");
                check(names(f.root).size() == 1, "only preexisting object remains");
            }
        });
        test("same hash target wrong length is rejected", () -> {
            try (Fixture f = new Fixture()) {
                Path destination = f.destination(ABC, "nsp");
                privateFile(destination, new byte[0]);
                refusal("existing-corrupt", () -> f.copy(ABC, PlayerSources.Kind.NSP, 3));
                check(Files.size(destination) == 0 && names(f.root).size() == 1, "wrong length object preserved");
            }
        });
        test("known-length exact copy budget boundary", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Snapshot result = f.copy(ABC, 3, space(RESERVE + 3));
                check(result.bytes == 3, "source bytes plus exactly 512 MiB succeeds");
            }
        });
        test("known-length budget one byte short rejects before reading", () -> {
            try (Fixture f = new Fixture()) {
                TrackedInput input = new TrackedInput(ABC);
                refusal("insufficient-space", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, 3, NEVER, space(RESERVE + 2)));
                check(input.calls == 0 && !input.closed, "budget preflight does not read or own input");
                f.empty();
            }
        });
        test("unknown-length stream cannot exceed initial copy budget", () -> {
            try (Fixture f = new Fixture()) {
                refusal("insufficient-space", () -> f.copy(ABC, -1, space(RESERVE + 2)));
                f.empty();
            }
        });
        test("negative available space and below reserve fail closed", () -> {
            for (long free : new long[] {-1, 0, RESERVE - 1}) {
                try (Fixture f = new Fixture()) {
                    refusal("insufficient-space", () -> f.copy(new byte[0], -1, space(free)));
                    f.empty();
                }
            }
        });
        test("budget arithmetic cannot overflow with Long.MAX_VALUE source", () -> {
            try (Fixture f = new Fixture()) {
                TrackedInput input = new TrackedInput(ABC);
                refusal("insufficient-space", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, Long.MAX_VALUE, NEVER, space(Long.MAX_VALUE)));
                check(input.calls == 0, "overflow rejected at preflight");
                f.empty();
            }
        });
        test("free space falling after preflight prevents a write", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    int checks;
                    @Override long usableSpace(Path path) { return checks++ == 0 ? RESERVE + 3 : RESERVE; }
                };
                refusal("insufficient-space", () -> f.copy(ABC, 3, operations));
                f.empty();
            }
        });
        test("declared-length short and long streams cannot publish", () -> {
            for (long declared : new long[] {2, 4}) {
                try (Fixture f = new Fixture()) {
                    refusal("size-mismatch", () -> f.copy(ABC, PlayerSources.Kind.NSP, declared));
                    f.empty();
                }
            }
        });
        test("invalid arguments fail without reading input", () -> {
            try (Fixture f = new Fixture()) {
                TrackedInput input = new TrackedInput(ABC);
                refusal("invalid-arguments", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, -2, NEVER));
                refusal("invalid-arguments", () -> PlayerSources.importSource(f.app, f.root, input, null, 3, NEVER));
                refusal("invalid-arguments", () -> PlayerSources.importSource(f.app, f.root, null,
                        PlayerSources.Kind.NSP, 3, NEVER));
                refusal("invalid-arguments", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, 3, null));
                check(input.calls == 0, "no source use for invalid arguments");
                f.empty();
            }
        });
        test("input is owned by caller on both success and failure", () -> {
            try (Fixture f = new Fixture()) {
                TrackedInput input = new TrackedInput(ABC);
                PlayerSources.importSource(f.app, f.root, input, PlayerSources.Kind.NSP, 3, NEVER);
                check(!input.closed, "success leaves source open");
                TrackedInput shortInput = new TrackedInput(ABC);
                refusal("size-mismatch", () -> PlayerSources.importSource(f.app, f.root, shortInput,
                        PlayerSources.Kind.NSP, 4, NEVER));
                check(!shortInput.closed, "failure leaves source open");
            }
        });
        test("positive short reads still form one complete snapshot", () -> {
            try (Fixture f = new Fixture()) {
                InputStream input = new ByteArrayInputStream(ABC) {
                    @Override public synchronized int read(byte[] b, int off, int len) {
                        return super.read(b, off, Math.min(1, len));
                    }
                };
                PlayerSources.Snapshot result = PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, 3, NEVER);
                check(result.sha256.equals(ABC_SHA) && result.bytes == 3, "one-byte reads retain complete identity");
                check(Arrays.equals(Files.readAllBytes(result.path), ABC), "one-byte chunks preserve complete bytes");
            }
        });
        test("invalid provider return counts are rejected", () -> {
            for (int invalid : new int[] {-2, 65537}) {
                try (Fixture f = new Fixture()) {
                    InputStream input = new InputStream() {
                        @Override public int read() { throw new AssertionError(); }
                        @Override public int read(byte[] b, int off, int len) { return invalid; }
                    };
                    refusal("source-read-failed", () -> PlayerSources.importSource(f.app, f.root, input,
                            PlayerSources.Kind.NSP, -1, NEVER));
                    f.empty();
                }
            }
        });
        test("zero-progress provider is rejected without a busy loop", () -> {
            try (Fixture f = new Fixture()) {
                int[] reads = {0};
                InputStream input = new InputStream() {
                    @Override public int read() { throw new AssertionError("unexpected single-byte fallback"); }
                    @Override public int read(byte[] b, int off, int len) {
                        check(++reads[0] <= 2, "bounded zero-progress reads");
                        return 0;
                    }
                };
                refusal("no-progress", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, -1, NEVER));
                f.empty();
            }
        });
        test("provider IOException after partial copy is sanitized and cleaned", () -> {
            try (Fixture f = new Fixture()) {
                InputStream input = new InputStream() {
                    int calls;
                    @Override public int read() { throw new AssertionError(); }
                    @Override public int read(byte[] b, int off, int len) throws IOException {
                        if (calls++ != 0) throw new IOException("SECRET_PROVIDER_URI_TOKEN");
                        System.arraycopy(ABC, 0, b, off, 3);
                        return 3;
                    }
                };
                IOException error = refusal("source-read-failed", () -> PlayerSources.importSource(f.app, f.root,
                        input, PlayerSources.Kind.NSP, -1, NEVER));
                check(!error.toString().contains("SECRET_PROVIDER") && error.getCause() == null,
                        "private provider message/cause not exposed");
                f.empty();
            }
        });
        test("provider runtime exception is sanitized", () -> {
            try (Fixture f = new Fixture()) {
                InputStream input = new InputStream() {
                    @Override public int read() { throw new IllegalStateException("SECRET_PROVIDER_URI_TOKEN"); }
                    @Override public int read(byte[] b, int off, int len) {
                        throw new IllegalStateException("SECRET_PROVIDER_URI_TOKEN");
                    }
                };
                IOException error = refusal("source-read-failed", () -> PlayerSources.importSource(f.app, f.root,
                        input, PlayerSources.Kind.NSP, -1, NEVER));
                check(!error.toString().contains("SECRET_PROVIDER") && error.getCause() == null, "no runtime leak");
                f.empty();
            }
        });
        test("already cancelled import has no side effects", () -> {
            try (Fixture f = new Fixture()) {
                TrackedInput input = new TrackedInput(ABC);
                refusal("cancelled", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, 3, () -> true));
                check(input.calls == 0, "cancel before read");
                f.empty();
            }
        });
        test("cancellation after a partial read discards only own staging", () -> {
            try (Fixture f = new Fixture()) {
                Path foreign = f.root.resolve(".player-source-foreign.candidate");
                privateFile(foreign, ABC);
                AtomicBoolean cancelled = new AtomicBoolean();
                InputStream input = new ByteArrayInputStream(new byte[100000]) {
                    @Override public synchronized int read(byte[] b, int off, int len) {
                        int count = super.read(b, off, Math.min(len, 32768));
                        cancelled.set(true);
                        return count;
                    }
                };
                refusal("cancelled", () -> PlayerSources.importSource(f.app, f.root, input,
                        PlayerSources.Kind.NSP, -1, cancelled::get));
                check(names(f.root).equals(List.of(".player-source-foreign.candidate")), "foreign staging untouched");
                check(Arrays.equals(Files.readAllBytes(foreign), ABC), "foreign bytes untouched");
            }
        });
        test("cancellation after force prevents publication", () -> {
            try (Fixture f = new Fixture()) {
                AtomicBoolean cancelled = new AtomicBoolean();
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override void force(FileChannel output) throws IOException {
                        super.force(output);
                        cancelled.set(true);
                    }
                    @Override void publish(Path from, Path to) { throw new AssertionError("published after cancellation"); }
                };
                refusal("cancelled", () -> PlayerSources.importSource(f.app, f.root, new ByteArrayInputStream(ABC),
                        PlayerSources.Kind.NSP, 3, cancelled::get, operations));
                f.empty();
            }
        });
        test("final cancellation observation prevents publication after verification", () -> {
            try (Fixture f = new Fixture()) {
                AtomicBoolean cancelled = new AtomicBoolean();
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    boolean forced;
                    @Override void force(FileChannel output) throws IOException {
                        super.force(output);
                        forced = true;
                    }
                    @Override long usableSpace(Path directory) throws IOException {
                        // The post-verification space check precedes the final cancellation check.
                        if (forced) cancelled.set(true);
                        return super.usableSpace(directory);
                    }
                    @Override void publish(Path from, Path to) { throw new AssertionError("late cancellation ignored"); }
                };
                refusal("cancelled", () -> PlayerSources.importSource(f.app, f.root, new ByteArrayInputStream(ABC),
                        PlayerSources.Kind.NSP, 3, cancelled::get, operations));
                check(cancelled.get(), "cancellation injected only after force/readback stage");
                f.empty();
            }
        });
        test("private candidate permissions exist before opening for first write", () -> {
            try (Fixture f = new Fixture()) {
                boolean[] opened = {false};
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override FileChannel openOutput(Path path) throws IOException {
                        check(Files.size(path) == 0, "new candidate initially empty");
                        check(Files.getPosixFilePermissions(path).equals(PosixFilePermissions.fromString("rw-------")),
                                "0600 installed at creation, before any source bytes");
                        opened[0] = true;
                        return super.openOutput(path);
                    }
                };
                f.copy(ABC, 3, operations);
                check(opened[0], "actual candidate channel observed");
            }
        });
        test("cancellation after successful atomic publication does not report failure", () -> {
            try (Fixture f = new Fixture()) {
                AtomicBoolean cancelled = new AtomicBoolean();
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override void publish(Path from, Path to) throws IOException {
                        super.publish(from, to);
                        cancelled.set(true);
                    }
                };
                PlayerSources.Snapshot result = PlayerSources.importSource(f.app, f.root,
                        new ByteArrayInputStream(ABC), PlayerSources.Kind.NSP, 3, cancelled::get, operations);
                check(cancelled.get() && Files.exists(result.path), "commit succeeded before late cancellation");
                check(Arrays.equals(Files.readAllBytes(result.path), ABC), "committed complete bytes");
            }
        });
        test("external close failure cannot leak as suppressed on a safe internal error", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override FileChannel openOutput(Path path) throws IOException {
                        return new CloseFailureChannel(super.openOutput(path));
                    }
                };
                IOException error = refusal("size-mismatch", () -> f.copy(ABC, 2, operations));
                check(!error.toString().contains("SECRET_CLOSE"), "close detail does not escape");
                f.empty();
            }
        });
        test("throwing cancellation callback is sanitized and its candidate is removed", () -> {
            try (Fixture f = new Fixture()) {
                int[] checks = {0};
                IOException error = refusal("io-failed", () -> PlayerSources.importSource(f.app, f.root,
                        new ByteArrayInputStream(ABC), PlayerSources.Kind.NSP, 3, () -> {
                            if (++checks[0] > 1) throw new IllegalStateException("SECRET_CALLBACK_PRIVATE_URI");
                            return false;
                        }));
                check(!error.toString().contains("SECRET_CALLBACK"), "callback detail does not escape");
                check(checks[0] > 1, "callback failed after initial cancellation preflight");
                f.empty();
            }
        });
        test("closed real output channel fails and staging is cleaned", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override FileChannel openOutput(Path path) throws IOException {
                        FileChannel output = super.openOutput(path);
                        output.close();
                        return output;
                    }
                };
                refusal("io-failed", () -> f.copy(ABC, 3, operations));
                f.empty();
            }
        });
        test("full copied bytes are re-read and verified before publication", () -> {
            try (Fixture f = new Fixture()) {
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override void force(FileChannel output) throws IOException {
                        super.force(output);
                        output.position(0);
                        output.write(ByteBuffer.wrap("xyz".getBytes(StandardCharsets.US_ASCII)));
                        output.force(true);
                    }
                    @Override void publish(Path from, Path to) { throw new AssertionError("unverified copy published"); }
                };
                refusal("copy-verification-failed", () -> f.copy(ABC, 3, operations));
                f.empty();
            }
        });
        test("atomic move unsupported does not fall back or disturb existing objects", () -> {
            try (Fixture f = new Fixture()) {
                Path previous = f.root.resolve("previous.nsp");
                privateFile(previous, ABC);
                int[] moves = {0};
                PlayerSources.Operations operations = new PlayerSources.Operations() {
                    @Override void publish(Path from, Path to) throws IOException {
                        moves[0]++;
                        throw new AtomicMoveNotSupportedException("PRIVATE_FROM", "PRIVATE_TO", "SECRET_REASON");
                    }
                };
                IOException failure = refusal("io-failed", () -> f.copy(ABC, 3, operations));
                check(moves[0] == 1, "atomic move attempted once");
                check(names(f.root).equals(List.of("previous.nsp")), "no non-atomic destination or own temp");
                check(Arrays.equals(Files.readAllBytes(previous), ABC), "previous snapshot preserved");
                check(!failure.toString().contains("PRIVATE_") && failure.getCause() == null, "move failure sanitized");
            }
        });
        test("unsafe roots and noncanonical arguments are rejected", () -> {
            try (Fixture f = new Fixture()) {
                for (Path badRoot : List.of(f.app, f.system, Path.of("relative"),
                        f.root.resolve(".."), f.app.resolve("missing"))) {
                    refusal(null, () -> PlayerSources.importSource(f.app, badRoot, new ByteArrayInputStream(ABC),
                            PlayerSources.Kind.NSP, 3, NEVER));
                }
                refusal(null, () -> PlayerSources.importSource(Path.of("relative"), f.root,
                        new ByteArrayInputStream(ABC), PlayerSources.Kind.NSP, 3, NEVER));
                f.empty();
            }
        });
        test("source store must already have private 0700 mode", () -> {
            try (Fixture f = new Fixture()) {
                mode(f.root, "rwxr-xr-x");
                refusal(null, () -> f.copy(ABC, PlayerSources.Kind.NSP, 3));
                check(Files.getPosixFilePermissions(f.root).equals(PosixFilePermissions.fromString("rwxr-xr-x")),
                        "unsafe root not silently chmodded");
                f.empty();
            }
        });
        test("App-owned symlink components are rejected", () -> {
            for (int level = 0; level < 3; level++) {
                try (Fixture f = new Fixture()) {
                    Path component = level == 0 ? f.app : level == 1 ? f.app.resolve("files") : f.root;
                    Path saved = component.resolveSibling(component.getFileName() + "-real");
                    Files.move(component, saved);
                    Files.createSymbolicLink(component, saved);
                    refusal(null, () -> f.copy(ABC, PlayerSources.Kind.NSP, 3));
                    check(Files.isSymbolicLink(component), "rejected link unchanged");
                }
            }
        });
        test("system-managed parent alias is resolved, not rejected as App-owned", () -> {
            try (Fixture f = new Fixture()) {
                Path alias = f.base.resolve("system-alias");
                Files.createSymbolicLink(alias, f.system);
                Path appAlias = alias.resolve("app");
                PlayerSources.Snapshot result = PlayerSources.importSource(appAlias, appAlias.resolve("files/sources"),
                        new ByteArrayInputStream(ABC), PlayerSources.Kind.NSP, 3, NEVER);
                check(result.path.equals(f.root.resolve(ABC_SHA + ".nsp")), "result uses real system-managed prefix");
            }
        });
        test("existing target symlink, directory and unsafe mode are never changed", () -> {
            for (int kind = 0; kind < 3; kind++) {
                try (Fixture f = new Fixture()) {
                    Path destination = f.destination(ABC, "nsp");
                    Path outside = f.base.resolve("outside");
                    privateFile(outside, ABC);
                    if (kind == 0) Files.createSymbolicLink(destination, outside);
                    else if (kind == 1) Files.createDirectory(destination);
                    else { privateFile(destination, ABC); mode(destination, "rw-r--r--"); }
                    refusal(null, () -> f.copy(ABC, PlayerSources.Kind.NSP, 3));
                    check(Arrays.equals(Files.readAllBytes(outside), ABC), "external object unaffected");
                    check(names(f.root).size() == 1, "only unsafe original entry remains");
                    if (kind == 0) check(Files.isSymbolicLink(destination), "link retained, not followed or replaced");
                    if (kind == 1) check(Files.isDirectory(destination, LinkOption.NOFOLLOW_LINKS), "directory retained");
                    if (kind == 2) check(Files.getPosixFilePermissions(destination).equals(
                            PosixFilePermissions.fromString("rw-r--r--")), "unsafe mode not silently repaired");
                }
            }
        });
        test("large generated stream is bounded and independently rehashed", () -> {
            try (Fixture f = new Fixture()) {
                final long length = 64L << 20;
                MessageDigest expected = MessageDigest.getInstance("SHA-256");
                long[] readBytes = {0};
                int[] largestRequest = {0};
                InputStream generated = new InputStream() {
                    @Override public int read() { throw new AssertionError("single-byte path not expected"); }
                    @Override public int read(byte[] buffer, int offset, int count) {
                        largestRequest[0] = Math.max(largestRequest[0], count);
                        if (readBytes[0] == length) return -1;
                        int actual = (int) Math.min(count, length - readBytes[0]);
                        for (int i = 0; i < actual; i++) buffer[offset + i] = (byte) ((readBytes[0] + i) % 251);
                        expected.update(buffer, offset, actual);
                        readBytes[0] += actual;
                        return actual;
                    }
                };
                PlayerSources.Snapshot result = PlayerSources.importSource(f.app, f.root, generated,
                        PlayerSources.Kind.XCI, -1, NEVER);
                check(result.bytes == length && Files.size(result.path) == length, "all 64 MiB copied");
                check(largestRequest[0] <= 64 * 1024, "source requests bounded to 64 KiB");
                String expectedHash = hex(expected.digest());
                check(result.sha256.equals(expectedHash) && hashFile(result.path).equals(expectedHash),
                        "stream oracle and independent file digest agree");
            }
        });
        finish();
    }
}
