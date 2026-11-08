package org.s2arm.android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** J09-S1's device-independent first slice; not yet connected to SAF or LibHac.
 *
 * The caller supplies Context.getDataDir().toPath(), an existing 0700 keys directory from that
 * same Context.getFilesDir().toPath().resolve("keys"), and an already-authorized stream. Neither
 * path may come from a user/SAF/provider. The data directory's parent must be system-managed;
 * files/ or another App-owned child is NOT a valid data-directory argument. Only this system
 * parent (Context.getDataDir().toPath().getParent()) is canonicalized, allowing system aliases.
 * Every App-owned component below it (including package directory, files and keys) and prod.keys
 * must not be symlinks. The app must exclude other processes and other same-UID writers from
 * these directories and their ancestors for the whole operation.
 * These checks are not a sandbox against a hostile concurrent path renamer. All writes through
 * this class are serialized within this process; no cross-process locking is promised.
 *
 * The final cancellation observation is before the atomic replacement. Once that replacement
 * succeeds this call succeeds, even if cancellation is requested immediately afterwards. A
 * failed/unsupported atomic move is never retried with a non-atomic copy. File contents are
 * forced before replacement; power-loss durability of the directory entry is NOT promised.
 * The caller owns/closes the stream. No key bytes, names, source paths or underlying exception
 * messages are returned in failures. A format pass does not verify decryption capability.
 */
final class PlayerKeys {
    static final int MAX_BYTES = 1 << 20;
    private static final Set<PosixFilePermission> PRIVATE_FILE =
            PosixFilePermissions.fromString("rw-------");
    private static final Set<PosixFilePermission> PRIVATE_DIR =
            PosixFilePermissions.fromString("rwx------");
    // Python str.isspace()/re \s, including U+001C..001F (not Java's default \s).
    private static final String SPACE = "[\\u0009-\\u000d\\u001c-\\u0020\\u0085\\u00a0\\u1680"
            + "\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]";
    private static final Pattern ENTRY = Pattern.compile(
            "([A-Za-z0-9_]+)" + SPACE + "*=" + SPACE + "*((?:0x)?[a-fA-F0-9]{2,2048})");
    private static final Pattern LINES = Pattern.compile("\\r\\n|[\\n\\r\\u000b\\f\\u001c-\\u001e\\u0085\\u2028\\u2029]");

    interface Cancellation {
        boolean isCancelled();
    }

    static final class InvalidKeysException extends IOException {
        InvalidKeysException(String message) { super(message); }
    }

    static final class CancelledException extends IOException {
        CancelledException() { super("密钥导入已取消。"); }
    }

    private PlayerKeys() {}

    /** Mirrors pack/jobs/library.py validate_keys; deliberately retains its duplicate semantics. */
    static int validate(byte[] bytes) throws InvalidKeysException {
        if (bytes == null || bytes.length > MAX_BYTES) {
            throw new InvalidKeysException("密钥文件过大。");
        }
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw invalidFormat();
        }
        String body = text.startsWith("\ufeff") ? text.substring(1) : text;
        Map<String, String> entries = new HashMap<>();
        for (String raw : LINES.split(body, -1)) {
            int comment = raw.indexOf('#');
            String line = stripPythonSpace(comment < 0 ? raw : raw.substring(0, comment));
            if (line.isEmpty()) continue;
            Matcher match = ENTRY.matcher(line);
            if (!match.matches()) throw invalidFormat();
            String name = match.group(1), value = match.group(2);
            String unprefixed = value.startsWith("0x") ? value.substring(2) : value;
            if ((unprefixed.length() & 1) != 0) throw invalidFormat();
            // The host compares its stored unprefixed value against the next RAW value.
            // In particular, a repeated 0x-prefixed entry is a conflict; do not normalize it.
            if (entries.containsKey(name) && !entries.get(name).equals(value)) {
                throw new InvalidKeysException("密钥文件存在冲突条目。");
            }
            entries.put(name, unprefixed);
        }
        if (entries.getOrDefault("header_key", "").length() != 64) {
            throw new InvalidKeysException("缺少有效的 header_key。");
        }
        return entries.size();
    }

    private static String stripPythonSpace(String value) {
        // Search only the two edges. An unanchored SPACE+$ search retries every internal space
        // and becomes quadratic when a long whitespace run is followed by a non-space value.
        int start = 0, end = value.length();
        while (start < end && isPythonSpace(value.charAt(start))) start++;
        while (end > start && isPythonSpace(value.charAt(end - 1))) end--;
        return value.substring(start, end);
    }

    private static boolean isPythonSpace(char c) {
        // Same set as SPACE, not Character.isWhitespace (which excludes e.g. NBSP).
        return (c >= 0x0009 && c <= 0x000d) || (c >= 0x001c && c <= 0x0020)
                || c == 0x0085 || c == 0x00a0 || c == 0x1680
                || (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029
                || c == 0x202f || c == 0x205f || c == 0x3000;
    }

    private static InvalidKeysException invalidFormat() {
        return new InvalidKeysException("密钥文件格式无效，请选择 prod.keys 文本文件。");
    }

    /** Same Context for both paths: importKeys(context.getDataDir().toPath(),
     * context.getFilesDir().toPath().resolve("keys"), source, cancellation).
     * Returns only the entry count, never key values or a decrypt-verified status.
     */
    static synchronized int importKeys(Path appDataDirectory, Path directory, InputStream source,
                                       Cancellation cancellation)
            throws IOException {
        byte[] bytes = null;
        Path temporary = null;
        try {
            if (appDataDirectory == null || directory == null || source == null || cancellation == null) {
                throw new IOException("密钥导入参数无效。");
            }
            if (!appDataDirectory.isAbsolute() || !directory.isAbsolute()
                    || appDataDirectory.getParent() == null
                    || !appDataDirectory.equals(appDataDirectory.normalize())
                    || !directory.equals(directory.normalize())
                    || !directory.startsWith(appDataDirectory) || directory.equals(appDataDirectory)) {
                throw new IOException("密钥目录无效。");
            }
            // Resolve only the system-managed prefix, never App-owned files/keys components.
            Path systemPath = appDataDirectory.getParent();
            Path system = systemPath.toRealPath();
            Path relative = systemPath.relativize(directory);
            Path root = system.resolve(relative);
            checkDirectory(system, relative);
            Path destination = root.resolve("prod.keys");
            checkDestination(destination);
            checkCancelled(cancellation);
            bytes = readBounded(source, cancellation);
            int count = validate(bytes);
            checkCancelled(cancellation);
            // POSIX permissions are installed at creation, before any secret byte is written.
            temporary = Files.createTempFile(root, ".player-keys-", ".candidate",
                    PosixFilePermissions.asFileAttribute(PRIVATE_FILE));
            try (FileChannel output = FileChannel.open(temporary, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS)) {
                ByteBuffer data = ByteBuffer.wrap(bytes);
                while (data.hasRemaining()) {
                    checkCancelled(cancellation);
                    output.write(data);
                }
                output.force(true);
            }
            checkDirectory(system, relative);
            checkDestination(destination);
            checkCancelled(cancellation); // Last observation; commit is the following atomic move.
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
            temporary = null;
            return count;
        } catch (InvalidKeysException | CancelledException e) {
            throw e;
        } catch (IOException | RuntimeException e) {
            // Even a ContentProvider/InputStream exception may contain a key or private URI.
            throw new IOException("密钥导入失败，原密钥保持不变。");
        } finally {
            if (bytes != null) Arrays.fill(bytes, (byte) 0);
            if (temporary != null) {
                try { Files.deleteIfExists(temporary); }
                catch (IOException | RuntimeException ignored) {
                    // No recursive cleanup and no second exception leaking the private path.
                    // An unremovable 0600 candidate may remain; it is never used as prod.keys.
                }
            }
        }
    }

    private static byte[] readBounded(InputStream source, Cancellation cancellation) throws IOException {
        ByteArrayOutputStream contents = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        try {
            while (true) {
                checkCancelled(cancellation);
                int n = readSource(source, chunk, Math.min(chunk.length, MAX_BYTES + 1 - contents.size()));
                if (n < 0) return contents.toByteArray();
                if (n == 0) {
                    int one = readSource(source, chunk, 1);
                    if (one == 0) throw new IOException();
                    if (one < 0) return contents.toByteArray();
                    contents.write(chunk[0]);
                } else {
                    contents.write(chunk, 0, n);
                }
                if (contents.size() > MAX_BYTES) throw new InvalidKeysException("密钥文件过大。");
            }
        } finally {
            Arrays.fill(chunk, (byte) 0);
        }
    }

    private static int readSource(InputStream source, byte[] buffer, int length) throws IOException {
        try {
            return source.read(buffer, 0, length);
        } catch (IOException | RuntimeException external) {
            // An external stream may even throw our exception subtype with an arbitrary message.
            // Never let it masquerade as an internally generated, safe validation/cancel error.
            throw new IOException("密钥输入读取失败。");
        }
    }

    private static void checkCancelled(Cancellation cancellation) throws CancelledException {
        if (cancellation.isCancelled()) throw new CancelledException();
    }

    private static void checkDirectory(Path system, Path relative) throws IOException {
        Path directory = system;
        for (Path component : relative) {
            directory = directory.resolve(component);
            BasicFileAttributes attributes = Files.readAttributes(directory, BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS);
            if (!attributes.isDirectory() || attributes.isSymbolicLink()) throw new IOException();
        }
        if (!Files.getPosixFilePermissions(directory, LinkOption.NOFOLLOW_LINKS).equals(PRIVATE_DIR)) {
            throw new IOException();
        }
    }

    private static void checkDestination(Path destination) throws IOException {
        try {
            BasicFileAttributes attributes = Files.readAttributes(destination, BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS);
            // A restored regular file may have old permissions. Replace its directory entry
            // with our new 0600 file, never chmod it (which would also alter external hardlinks).
            if (!attributes.isRegularFile() || attributes.isSymbolicLink()) {
                throw new IOException();
            }
        } catch (java.nio.file.NoSuchFileException absent) {
            // An absent leaf is the first-import case; missing/unsafe parents fail checkDirectory.
        }
    }
}
