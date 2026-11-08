package org.s2arm.android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/** Blocking Android preparation adapter. Call on a background worker with a workspace
 * beneath Context.getFilesDir(), separate from revisions and current.json. Inputs must
 * already be in that workspace. Each call copies private, read-only snapshots and owns
 * a new staging directory; it never activates a revision or defines a job lifecycle.
 * The native library serializes its C API calls. Other DSOs/direct C callers are outside
 * that lock. This class loads the optional preparation library only when rewrite runs. */
public final class NativeRewriter {
    private static final int DIAGNOSTIC_LIMIT = 65536;
    private static final String ABI = "android-sp-safe-v1";

    private NativeRewriter() {}

    public static final class FileIdentity {
        public final long bytes;
        public final String sha256;
        private FileIdentity(long bytes, String sha256) {
            this.bytes = bytes;
            this.sha256 = sha256;
        }
    }

    public static final class Result {
        public final int nativeStatus;
        public final Path attempt;
        public final Path output;
        public final String validationError;
        public final String diagnostics;
        public final Map<String, FileIdentity> inputs;
        public final Map<String, FileIdentity> artifacts;

        private Result(int status, Path attempt, String error, String diagnostics,
                       Map<String, FileIdentity> inputs, Map<String, FileIdentity> artifacts) {
            this.nativeStatus = status;
            this.attempt = attempt;
            this.output = attempt.resolve("output");
            this.validationError = error;
            this.diagnostics = diagnostics;
            this.inputs = Collections.unmodifiableMap(new LinkedHashMap<>(inputs));
            this.artifacts = Collections.unmodifiableMap(new LinkedHashMap<>(artifacts));
        }

        /** A zero C status alone does not authorize consuming or activating outputs. */
        public boolean succeeded() { return nativeStatus == 0 && validationError == null; }
    }

    /** All options are explicit; the Android defaults are spin=false, sdkAddressCut=true.
     * A null table means absent. Failures retain this attempt for private diagnostics.
     * The caller owns retention and passes successful output to the existing installer. */
    public static Result rewrite(Path privateWorkspace, Path input, String module,
                                 boolean spin, boolean sdkAddressCut, Path widen, Path fps)
            throws IOException {
        if (module == null || !module.matches("[A-Za-z0-9_-]{1,64}")) {
            throw new IllegalArgumentException("invalid module identifier");
        }
        if (privateWorkspace == null || input == null) {
            throw new IllegalArgumentException("workspace and input are required");
        }
        Path requestedRoot = privateWorkspace.toAbsolutePath().normalize();
        if (Files.isSymbolicLink(requestedRoot)
                || !Files.isDirectory(requestedRoot, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("workspace must be an existing private directory");
        }
        Path root = requestedRoot.toRealPath();
        for (java.nio.file.attribute.PosixFilePermission permission : Files.getPosixFilePermissions(root)) {
            if (permission.name().startsWith("GROUP_") || permission.name().startsWith("OTHERS_")) {
                throw new IOException("workspace permissions must allow only its owner");
            }
        }
        Path source = ownedFile(requestedRoot, root, input);
        Path wideSource = widen == null ? null : ownedFile(requestedRoot, root, widen);
        Path fpsSource = fps == null ? null : ownedFile(requestedRoot, root, fps);
        // Validate encoding before creating an attempt or loading a native library.
        encodeUtf8(root.toString());
        encodeUtf8(source.toString());
        if (wideSource != null) encodeUtf8(wideSource.toString());
        if (fpsSource != null) encodeUtf8(fpsSource.toString());

        Path attempt = Files.createTempDirectory(root, "rewrite-",
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        Path snapshots = Files.createDirectory(attempt.resolve("snapshots"),
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        Path output = Files.createDirectory(attempt.resolve("output"),
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        Map<String, FileIdentity> inputs = new LinkedHashMap<>();
        Path frozenInput = snapshots.resolve("input.nso");
        inputs.put("input.nso", freeze(source, frozenInput));
        Path frozenWide = null, frozenFps = null;
        if (wideSource != null) {
            frozenWide = snapshots.resolve("widen.tsv");
            inputs.put("widen.tsv", freeze(wideSource, frozenWide));
        }
        if (fpsSource != null) {
            frozenFps = snapshots.resolve("fps.tsv");
            inputs.put("fps.tsv", freeze(fpsSource, frozenFps));
        }
        Path log = Files.createFile(attempt.resolve("native.log"),
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        Library.load();
        int status = rewrite0(encodeUtf8(frozenInput.toString()), encodeUtf8(output.toString()),
                encodeUtf8(module), spin, sdkAddressCut,
                frozenWide == null ? null : encodeUtf8(frozenWide.toString()),
                frozenFps == null ? null : encodeUtf8(frozenFps.toString()), encodeUtf8(log.toString()));
        Map<String, FileIdentity> artifacts = new LinkedHashMap<>();
        String error = status == 0 ? null : "native rewrite failed (" + status + ")";
        if (status == 0) {
            try {
                validate(output, module, frozenInput, artifacts);
            } catch (IOException invalid) {
                error = invalid.getMessage();
                artifacts.clear();
            }
        }
        return new Result(status, attempt, error, diagnostics(log), inputs, artifacts);
    }

    private static Path ownedFile(Path requestedRoot, Path root, Path input) throws IOException {
        Path path = input.toAbsolutePath().normalize();
        Path lexicalRoot = path.startsWith(requestedRoot) ? requestedRoot : root;
        if (!path.startsWith(lexicalRoot) || path.equals(lexicalRoot)) {
            throw new IOException("input must be beneath the private workspace");
        }
        Path cursor = lexicalRoot;
        for (Path part : lexicalRoot.relativize(path)) {
            cursor = cursor.resolve(part);
            if (Files.isSymbolicLink(cursor)) throw new IOException("input symlinks are not allowed");
        }
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("input must be a regular private file");
        }
        Path canonical = path.toRealPath();
        if (!canonical.startsWith(root)) throw new IOException("input escapes workspace");
        return canonical;
    }

    private static FileIdentity freeze(Path source, Path destination) throws IOException {
        MessageDigest hash = digest();
        long bytes = 0;
        Files.createFile(destination,
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        try (InputStream in = Files.newInputStream(source, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS);
             OutputStream out = Files.newOutputStream(destination, StandardOpenOption.WRITE)) {
            byte[] buffer = new byte[65536];
            int count;
            while ((count = in.read(buffer)) != -1) {
                out.write(buffer, 0, count);
                hash.update(buffer, 0, count);
                bytes += count;
            }
        }
        Files.setPosixFilePermissions(destination, PosixFilePermissions.fromString("r--------"));
        return new FileIdentity(bytes, hex(hash.digest()));
    }

    private static byte[] encodeUtf8(String value) {
        if (value.indexOf('\0') >= 0) throw new IllegalArgumentException("NUL is not allowed");
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(value));
            byte[] result = new byte[encoded.remaining()];
            encoded.get(result);
            if (result.length == 0 || result.length > 4095) {
                throw new IllegalArgumentException("invalid UTF-8 path length");
            }
            return result;
        } catch (CharacterCodingException invalid) {
            throw new IllegalArgumentException("invalid Unicode path", invalid);
        }
    }

    private static void validate(Path output, String module, Path source,
                                 Map<String, FileIdentity> artifacts) throws IOException {
        Set<String> required = new LinkedHashSet<>(Arrays.asList("patched.bin", "fixups.tsv",
                "gates.tsv", "sites.tsv", "gaps.tsv"));
        Set<String> found = new LinkedHashSet<>();
        try (DirectoryStream<Path> files = Files.newDirectoryStream(output)) {
            for (Path file : files) {
                String name = file.getFileName().toString();
                if (!name.startsWith(module + ".")) throw new IOException("unexpected output filename");
                String suffix = name.substring(module.length() + 1);
                if (!required.contains(suffix) && !suffix.equals("widen.tsv")) {
                    throw new IOException("unexpected output artifact");
                }
                if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(file)) {
                    throw new IOException("output artifact is not a regular file");
                }
                found.add(suffix);
                artifacts.put(name, identity(file));
            }
        }
        if (!found.containsAll(required) || artifacts.get(module + ".patched.bin").bytes == 0) {
            throw new IOException("incomplete rewrite artifacts");
        }
        Map<String, String> header = new LinkedHashMap<>();
        try (java.io.BufferedReader reader = Files.newBufferedReader(output.resolve(module + ".fixups.tsv"),
                StandardCharsets.UTF_8)) {
            String line;
            while ((line = reader.readLine()) != null && line.startsWith("# ")) {
                int tab = line.indexOf('\t');
                if (tab < 3 || header.put(line.substring(2, tab), line.substring(tab + 1)) != null) {
                    throw new IOException("invalid or duplicate fixups header");
                }
            }
        }
        if (!"android".equals(header.get("TARGET")) || !ABI.equals(header.get("REWRITE_ABI"))) {
            throw new IOException("wrong rewrite target or ABI");
        }
        try {
            if (Long.decode(header.containsKey("LOAD_BIAS") ? header.get("LOAD_BIAS") : "0") != 0) {
                throw new IOException("Android requires zero LOAD_BIAS");
            }
        } catch (NumberFormatException invalid) {
            throw new IOException("invalid LOAD_BIAS", invalid);
        }
        byte[] nso = new byte[80];
        try (InputStream in = Files.newInputStream(source)) {
            int used = 0, count;
            while (used < nso.length && (count = in.read(nso, used, nso.length - used)) > 0) used += count;
            if (used != nso.length || nso[0] != 'N' || nso[1] != 'S' || nso[2] != 'O' || nso[3] != '0') {
                throw new IOException("invalid source NSO identity");
            }
        }
        String build = hex(Arrays.copyOfRange(nso, 64, 80));
        if (!build.equals(header.get("BUILD_ID"))) throw new IOException("rewrite BUILD_ID differs from snapshot");
        try (java.io.BufferedReader reader = Files.newBufferedReader(output.resolve(module + ".gaps.tsv"),
                StandardCharsets.UTF_8)) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (!line.trim().isEmpty() && !line.startsWith("#")) throw new IOException("rewrite has gaps");
            }
        }
    }

    private static FileIdentity identity(Path file) throws IOException {
        MessageDigest hash = digest();
        long bytes = 0;
        try (InputStream in = Files.newInputStream(file)) {
            byte[] buffer = new byte[65536];
            int count;
            while ((count = in.read(buffer)) != -1) { hash.update(buffer, 0, count); bytes += count; }
        }
        return new FileIdentity(bytes, hex(hash.digest()));
    }

    private static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException unavailable) { throw new AssertionError(unavailable); }
    }

    private static String hex(byte[] bytes) {
        char[] digits = "0123456789abcdef".toCharArray();
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(digits[(value & 255) >>> 4]).append(digits[value & 15]);
        return result.toString();
    }

    private static String diagnostics(Path log) throws IOException {
        try (InputStream in = Files.newInputStream(log); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int remaining = DIAGNOSTIC_LIMIT, count;
            while (remaining > 0 && (count = in.read(buffer, 0, Math.min(buffer.length, remaining))) != -1) {
                out.write(buffer, 0, count);
                remaining -= count;
            }
            String text = new String(out.toByteArray(), StandardCharsets.UTF_8);
            return in.read() == -1 ? text : text + "\n[diagnostic excerpt truncated]";
        }
    }

    private static final class Library {
        static { System.loadLibrary("s2arm_rewriter"); }
        static void load() {}
    }

    private static native int rewrite0(byte[] input, byte[] output, byte[] module,
            boolean spin, boolean sdkAddressCut, byte[] widen, byte[] fps, byte[] log);
}
