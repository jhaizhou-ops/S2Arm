package org.s2arm.android;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.Objects;
import java.util.Set;

/** T07's device-independent raw-container snapshot primitive, not SAF or LibHac integration.
 *
 * The caller supplies Context.getDataDir().toPath(), an existing 0700 private sources directory
 * under that data directory, and an already-authorized stream. Neither path comes from a
 * provider/user. The data directory's parent must be system-managed; an App-owned files/ child
 * is NOT a valid data-directory argument. Only that system-managed parent is canonicalized.
 * App-owned components (including the package directory) must not be symlinks. The caller must
 * exclude other processes and other same-UID writers from the directories and their ancestors
 * throughout this call. This is not a sandbox against a hostile concurrent path renamer.
 * Calls through this class are serialized within this process, not across processes.
 *
 * A successful result identifies the bytes copied, NOT a valid/decryptable/playable NSP/XCI.
 * Its path and full lowercase SHA256 fit W7's existing sources.inspect / games.resolve source
 * tuple; consumers must use Snapshot.path rather than reconstruct it from a literal dataDir
 * alias. Later consumers must still rehash, inspect and resolve. No schema/catalog is written.
 * Content-addressed objects are never modified by this class after publication. This is not
 * an OS immutable-file guarantee: a same-UID writer can change them, hence consumer rehashing.
 * An invalid existing object is deliberately not chmodded or overwritten: recovery requires
 * the caller's exclusive maintenance window to quarantine/remove that exact object, then
 * reimport. This primitive neither decides reference lifetime nor sweeps old candidates.
 *
 * declaredBytes is an exact length, or -1 when the provider cannot supply one. Both cases use
 * bounded streaming. Copy budget follows pack/jobs/library.py: source bytes plus 512 MiB spare,
 * not the separate unpack/build budget. Unknown lengths are bounded by initial usable space
 * minus that spare; usable space is checked again before every write. This is a preflight and
 * guard, not a filesystem reservation against other disk users; write failures still fail red.
 *
 * The caller owns/closes the input stream. Cancellation is cooperative between reads/writes;
 * it cannot interrupt a blocked provider read. The last cancellation check precedes atomic
 * publication (or a verified duplicate return). Once published this call succeeds even if
 * cancellation is requested immediately afterwards. Atomic move failure has no copy fallback.
 * Data is forced before publication; directory-entry power-loss durability is NOT promised.
 * Failure cleans only this call's candidate, best effort if unlink itself fails. Such a private
 * candidate is never a published source. Errors contain no provider text, private paths or
 * source bytes. No Android App UID/SELinux/FUSE or device integration is asserted by host tests.
 */
final class PlayerSources {
    static final long COPY_RESERVE_BYTES = 512L << 20;
    static final int BUFFER_BYTES = 64 << 10;
    private static final Set<PosixFilePermission> PRIVATE_FILE =
            PosixFilePermissions.fromString("rw-------");
    private static final Set<PosixFilePermission> PRIVATE_DIR =
            PosixFilePermissions.fromString("rwx------");

    enum Kind {
        NSP("nsp"), XCI("xci");
        final String suffix;
        Kind(String suffix) { this.suffix = suffix; }
    }

    interface Cancellation { boolean isCancelled(); }

    static final class Snapshot {
        final Path path;
        final String sha256;
        final long bytes;
        final boolean duplicate;
        private Snapshot(Path path, String sha256, long bytes, boolean duplicate) {
            this.path = path; this.sha256 = sha256; this.bytes = bytes; this.duplicate = duplicate;
        }
    }

    static final class Failure extends IOException {
        private static final long serialVersionUID = 1L;
        final String code;
        private Failure(String code) {
            super("原始游戏快照导入失败：" + code + "。");
            this.code = code;
        }
    }

    /** Internal fault-injection seam. Production uses the real filesystem operations below. */
    static class Operations {
        long usableSpace(Path directory) throws IOException {
            // Android's NIO provider rejects getFileStore even for private App directories.
            // File.getUsableSpace is public since API9 and uses statvfs f_bavail (non-root
            // availability) in Android libcore. Zero/denial remains fail-closed below; this
            // is the production default, not a device-test-only Operations override.
            // https://developer.android.com/reference/java/io/File#getUsableSpace()
            return directory.toFile().getUsableSpace();
        }
        FileChannel openOutput(Path temporary) throws IOException {
            return FileChannel.open(temporary, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
        }
        void force(FileChannel output) throws IOException { output.force(true); }
        void publish(Path temporary, Path destination) throws IOException {
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE);
        }
    }

    private PlayerSources() {}

    static Snapshot importSource(Path appDataDirectory, Path directory, InputStream source,
                                 Kind kind, long declaredBytes, Cancellation cancellation)
            throws IOException {
        return importSource(appDataDirectory, directory, source, kind, declaredBytes,
                cancellation, new Operations());
    }

    static synchronized Snapshot importSource(Path appDataDirectory, Path directory,
            InputStream source, Kind kind, long declaredBytes, Cancellation cancellation,
            Operations operations) throws IOException {
        Path temporary = null;
        byte[] buffer = new byte[BUFFER_BYTES];
        try {
            if (source == null || kind == null || cancellation == null || operations == null
                    || declaredBytes < -1) throw fail("invalid-arguments");
            PrivateRoot root = privateRoot(appDataDirectory, directory);
            checkCancelled(cancellation);
            long usable = operations.usableSpace(root.directory);
            requireSpace(usable, 0);
            long limit = usable - COPY_RESERVE_BYTES; // Subtraction only after nonnegative check.
            if (declaredBytes >= 0 && declaredBytes > limit) throw fail("insufficient-space");
            temporary = Files.createTempFile(root.directory, ".player-source-", ".candidate",
                    PosixFilePermissions.asFileAttribute(PRIVATE_FILE));
            MessageDigest digest = digest();
            long copied = 0;
            try (FileChannel output = operations.openOutput(temporary)) {
                while (true) {
                    checkCancelled(cancellation);
                    int n = read(source, buffer);
                    if (n < 0) break;
                    if (n == 0) throw fail("no-progress");
                    if (n > limit - copied) throw fail("insufficient-space");
                    if (declaredBytes >= 0 && n > declaredBytes - copied) throw fail("size-mismatch");
                    checkCancelled(cancellation);
                    requireSpace(operations.usableSpace(root.directory), n);
                    ByteBuffer data = ByteBuffer.wrap(buffer, 0, n);
                    while (data.hasRemaining()) {
                        checkCancelled(cancellation);
                        if (output.write(data) <= 0) throw fail("no-progress");
                    }
                    digest.update(buffer, 0, n);
                    copied += n; // Bounded by nonnegative limit <= Long.MAX_VALUE - spare.
                }
                if (declaredBytes >= 0 && copied != declaredBytes) throw fail("size-mismatch");
                checkCancelled(cancellation);
                operations.force(output);
            }
            String hash = hex(digest.digest());
            Identity verify = hashFile(temporary, buffer, cancellation);
            if (verify.bytes != copied || !verify.sha256.equals(hash)) throw fail("copy-verification-failed");
            checkDirectory(root.system, root.relative);
            requireSpace(operations.usableSpace(root.directory), 0);
            Path destination = root.directory.resolve(hash + "." + kind.suffix);
            boolean duplicate = existing(destination, copied, hash, buffer, cancellation);
            checkDirectory(root.system, root.relative);
            checkCancelled(cancellation);
            if (duplicate) {
                // The published object remains untouched; cleanup owns only our unique candidate.
                Files.delete(temporary);
                temporary = null;
            } else {
                // Caller exclusion and class serialization cover the absent-check -> move window.
                // ATOMIC_MOVE's provider-specific existing-target semantics are NOT a lock.
                operations.publish(temporary, destination);
                temporary = null;
            }
            return new Snapshot(destination, hash, copied, duplicate);
        } catch (Failure safe) {
            // Closing a channel can attach an external suppressed exception to an internal
            // failure. Return only its fixed code, never provider/path-bearing exception text.
            throw fail(safe.code);
        } catch (IOException | RuntimeException external) {
            throw fail("io-failed");
        } finally {
            Arrays.fill(buffer, (byte) 0);
            if (temporary != null) {
                try { Files.deleteIfExists(temporary); }
                catch (IOException | RuntimeException ignored) {
                    // Never recursively clean the store or leak the private candidate path.
                }
            }
        }
    }

    private static int read(InputStream source, byte[] buffer) throws Failure {
        final int n;
        try { n = source.read(buffer, 0, buffer.length); }
        catch (IOException | RuntimeException external) { throw fail("source-read-failed"); }
        if (n < -1 || n > buffer.length) throw fail("source-read-failed");
        return n;
    }

    private static void requireSpace(long usable, long nextBytes) throws Failure {
        // Avoid size + spare overflow for long-sized provider lengths or filesystem reports.
        if (usable < COPY_RESERVE_BYTES || nextBytes < 0 || nextBytes > usable - COPY_RESERVE_BYTES)
            throw fail("insufficient-space");
    }

    private static boolean existing(Path path, long bytes, String hash, byte[] buffer,
                                    Cancellation cancellation) throws IOException {
        try { checkFile(path); }
        catch (NoSuchFileException absent) { return false; }
        Identity identity = hashFile(path, buffer, cancellation);
        if (identity.bytes != bytes || !identity.sha256.equals(hash)) throw fail("existing-corrupt");
        return true;
    }

    private static final class Identity {
        final long bytes;
        final String sha256;
        Identity(long bytes, String sha256) { this.bytes = bytes; this.sha256 = sha256; }
    }

    private static Identity hashFile(Path path, byte[] buffer, Cancellation cancellation)
            throws IOException {
        BasicFileAttributes before = checkFile(path);
        MessageDigest hash = digest();
        long bytes = 0;
        try (FileChannel input = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer data = ByteBuffer.wrap(buffer);
            while (true) {
                checkCancelled(cancellation);
                data.clear();
                int n = input.read(data);
                if (n < 0) break;
                if (n == 0 || bytes > Long.MAX_VALUE - n) throw fail("copy-verification-failed");
                hash.update(buffer, 0, n);
                bytes += n;
            }
        }
        BasicFileAttributes after = checkFile(path);
        if (bytes != before.size() || bytes != after.size()
                || !Objects.equals(before.fileKey(), after.fileKey())) throw fail("copy-verification-failed");
        return new Identity(bytes, hex(hash.digest()));
    }

    private static BasicFileAttributes checkFile(Path path) throws IOException {
        BasicFileAttributes attributes = Files.readAttributes(path, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!attributes.isRegularFile() || attributes.isSymbolicLink()
                || !Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS).equals(PRIVATE_FILE))
            throw fail("invalid-entry");
        return attributes;
    }

    private static final class PrivateRoot {
        final Path system, relative, directory;
        PrivateRoot(Path system, Path relative) {
            this.system = system; this.relative = relative; this.directory = system.resolve(relative);
        }
    }

    private static PrivateRoot privateRoot(Path appDataDirectory, Path directory) throws IOException {
        if (appDataDirectory == null || directory == null || !appDataDirectory.isAbsolute()
                || !directory.isAbsolute() || appDataDirectory.getParent() == null
                || !appDataDirectory.equals(appDataDirectory.normalize())
                || !directory.equals(directory.normalize()) || !directory.startsWith(appDataDirectory)
                || directory.equals(appDataDirectory)) throw fail("invalid-directory");
        Path systemPath = appDataDirectory.getParent();
        Path system = systemPath.toRealPath();
        Path relative = systemPath.relativize(directory);
        checkDirectory(system, relative);
        return new PrivateRoot(system, relative);
    }

    private static void checkDirectory(Path system, Path relative) throws IOException {
        Path directory = system;
        for (Path component : relative) {
            directory = directory.resolve(component);
            BasicFileAttributes attributes = Files.readAttributes(directory, BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS);
            if (!attributes.isDirectory() || attributes.isSymbolicLink()) throw fail("invalid-directory");
        }
        if (!Files.getPosixFilePermissions(directory, LinkOption.NOFOLLOW_LINKS).equals(PRIVATE_DIR))
            throw fail("invalid-directory");
    }

    private static void checkCancelled(Cancellation cancellation) throws Failure {
        final boolean cancelled;
        try { cancelled = cancellation.isCancelled(); }
        catch (RuntimeException external) { throw fail("io-failed"); }
        if (cancelled) throw fail("cancelled");
    }

    private static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(); }
    }

    private static String hex(byte[] bytes) {
        char[] text = new char[bytes.length * 2];
        char[] digits = "0123456789abcdef".toCharArray();
        for (int i = 0; i < bytes.length; i++) {
            text[2 * i] = digits[(bytes[i] & 255) >>> 4];
            text[2 * i + 1] = digits[bytes[i] & 15];
        }
        return new String(text);
    }

    private static Failure fail(String code) { return new Failure(code); }
}
