package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermission;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.EnumSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 本进程运行哪一份 libs2arm_android.so。缺省是 APK 里的。开发替换库只给可调试包，而且要本次起局显式带
 * {@code --es s2arm.dev_runtime <sha256>}：推到 files/dev-runtime/&lt;sha256&gt;/ 的库加载前逐项核对，任何一项不符
 * 都拒绝起局，不退回 APK 里的库；没带 extra 时，私有目录里留着的替换库不生效。
 *
 * 威胁模型：Activity 是 exported 的，extra 来源不可信（任何 app 都能带它拉起）。extra 只能从私有目录里选一份
 * 已有且通过全部核对的库，不能引入新代码；能做到的只是诱发一个开发局或一次红字拒绝。私有目录内容只有本 app 的
 * uid（含 run-as）能写，核对防的是推送错误和误用，不防本 uid 自己。
 * 纯 JDK，单测直接用（tests/RuntimeLibraryTest.java）。
 */
final class RuntimeLibrary {
    static final String EXTRA = "s2arm.dev_runtime";
    static final String DIRECTORY = "dev-runtime";
    static final String FILE = "libs2arm_android.so";
    static final String MANIFEST = "dev-runtime.json";
    /** Under the code cache: the copy actually loaded, written and hashed by this process. */
    static final String STAGE = "s2a-dev-runtime";
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final Pattern COMMIT = Pattern.compile("[0-9a-f]{40}");
    private static final Set<PosixFilePermission> WRITE = EnumSet.of(
        PosixFilePermission.OWNER_WRITE, PosixFilePermission.GROUP_WRITE, PosixFilePermission.OTHERS_WRITE);

    /** null: the APK's library (System.loadLibrary); otherwise the staged copy of the verified override. */
    final File file;
    /** null for the APK's library. */
    final String sha256;
    private final String line, json;

    private RuntimeLibrary(File file, String sha256, String line, String json) {
        this.file = file;
        this.sha256 = sha256;
        this.line = line;
        this.json = json;
    }

    static final RuntimeLibrary APK = new RuntimeLibrary(null, null, "runtime-library: apk", "{\"kind\": \"apk\"}");

    /** The installed base APK's SHA-256, computed only when an override asks for it. */
    interface ApkDigest { String sha256() throws IOException; }

    static final class Rejected extends Exception {
        Rejected(String message) { super("runtime library rejected: " + message); }
    }

    /** One line for logcat and the status panel. */
    String line() { return line; }

    /** BootSpec diagnostics.runtimeLibrary and the session's runtime-library.json (boot-spec.v1 schema). */
    String json() { return json; }

    boolean override() { return file != null; }

    /** What a launch intent asks for: null without the extra, "" when the extra is not a string. */
    static String requested(boolean hasExtra, String value) {
        if (!hasExtra) return null;
        return value == null ? "" : value;
    }

    /** A later launch of this process may only ask for what the process already runs (no extra = the APK's). */
    boolean selectedBy(String requested) {
        return requested == null ? file == null : requested.equals(sha256);
    }

    /**
     * Whether an intent delivered to a running Activity is a launch (bound to the loaded library) rather than
     * a control intent: it names the library, or carries an s2arm.* extra that is not one of the controls the
     * running Activity handles, or no s2arm.* extra at all (a plain am start).
     */
    static boolean isLaunch(Iterable<String> extraKeys, Set<String> controls) {
        boolean control = false;
        for (String key : extraKeys) {
            if (!key.startsWith("s2arm.")) continue;
            if (key.equals(EXTRA) || !controls.contains(key)) return true;
            control = true;
        }
        return !control;
    }

    /**
     * @param requested what this launch asks for ({@link #requested}); null runs the APK's library
     * @param debuggable ApplicationInfo.FLAG_DEBUGGABLE of this package
     * @param codeCacheDir where the verified copy is staged (Context.getCodeCacheDir())
     * @param pid this process; a staged copy is removed only when its owning process is proven dead
     * @param loaded what this process already loaded (NativeBridge.loaded()), null before the first load:
     *     the same selection reuses it (its copy stays mapped), another one needs a cold start
     */
    static RuntimeLibrary select(String requested, boolean debuggable, File filesDir, File codeCacheDir, int pid,
                                 RuntimeLibrary loaded, ApkDigest apk) throws Rejected {
        if (loaded != null) {
            if (loaded.selectedBy(requested)) return loaded;
            throw new Rejected("this process already runs \"" + loaded.line() + "\"; cold start needed");
        }
        if (requested == null) {
            try {
                removeStale(codeCacheDir, pid);
            } catch (IOException error) {
                throw new Rejected(String.valueOf(error.getMessage()));
            }
            return APK;
        }
        if (!SHA256.matcher(requested).matches()) throw new Rejected(EXTRA + " is not a lowercase SHA-256: " + requested);
        if (!debuggable) throw new Rejected(EXTRA + " is only accepted by a debuggable package");
        try {
            // The canonical files directory is the trusted root (Android's /data/user/0 alias resolves here);
            // no component below it may be a link, so the library is exactly root/dev-runtime/<sha>/FILE.
            File root = filesDir.getCanonicalFile();
            File base = new File(root, DIRECTORY), dir = new File(base, requested);
            File lib = new File(dir, FILE), manifest = new File(dir, MANIFEST);
            for (File f : new File[] {base, dir, lib, manifest})
                if (Files.isSymbolicLink(f.toPath())) throw new Rejected(f + " is a symbolic link");
            if (!Files.isRegularFile(lib.toPath(), LinkOption.NOFOLLOW_LINKS)) throw new Rejected(lib + " is missing");
            if (!Files.isRegularFile(manifest.toPath(), LinkOption.NOFOLLOW_LINKS)) throw new Rejected(manifest + " is missing");
            for (File f : new File[] {dir, lib, manifest})
                if (!Collections.disjoint(Files.getPosixFilePermissions(f.toPath(), LinkOption.NOFOLLOW_LINKS), WRITE))
                    throw new Rejected(f + " is writable (push read-only: files 0444, directory 0555)");
            Map<String, Object> m = Json.object(Json.parse(new String(Files.readAllBytes(manifest.toPath()),
                StandardCharsets.UTF_8)), MANIFEST);
            if (!requested.equals(m.get("libSha256"))) throw new Rejected(MANIFEST + " libSha256 is not " + requested);
            String baseApk = text(m, "baseApkSha256", SHA256);
            String commit = text(m, "sourceCommit", COMMIT);
            String diff = text(m, "diffSha256", SHA256);
            String ilc = text(m, "ilcConfig", Pattern.compile("Release|Debug"));
            String host = text(m, "aotHost", Pattern.compile("linux-(arm64|x64)"));
            Object dirty = m.get("dirty");
            if (!(dirty instanceof Boolean)) throw new Rejected(MANIFEST + " dirty is not a boolean");
            String installed = apk.sha256();
            if (!baseApk.equals(installed))
                throw new Rejected("built against base APK " + baseApk + ", the installed APK is " + installed
                    + " (Java changed: reinstall the APK)");
            File copy = stage(lib, requested, codeCacheDir, pid);
            String elf = elf(copy);
            if (elf != null) throw new Rejected(lib + ": " + elf);
            return new RuntimeLibrary(copy, requested, String.format(Locale.ROOT,
                "runtime-library: dev-override sha256=%s base-apk=%s source-commit=%s dirty=%s diff=%s ilc=%s aot-host=%s"
                    + "; 开发局，不作性能读数", requested, baseApk, commit, dirty, diff, ilc, host),
                String.format(Locale.ROOT, "{\"kind\": \"dev-override\", \"sha256\": \"%s\", \"baseApkSha256\": \"%s\", "
                    + "\"sourceCommit\": \"%s\", \"dirty\": %s, \"diffSha256\": \"%s\", \"ilcConfig\": \"%s\", \"aotHost\": \"%s\"}",
                    requested, baseApk, commit, dirty, diff, ilc, host));
        } catch (IOException | IllegalArgumentException | UnsupportedOperationException error) {
            throw new Rejected(String.valueOf(error.getMessage()));
        }
    }

    /** Remove a staged copy only when procfs proves its owning PID no longer exists. */
    private static void removeStale(File codeCacheDir, int pid) throws IOException {
        File[] old = new File(codeCacheDir.getCanonicalFile(), STAGE).listFiles();
        if (old == null) return;
        Path proc = new File("/proc").toPath();
        // On hosts without procfs (or if it is unavailable), keep every copy.
        if (!Files.isDirectory(proc.resolve("self"))) return;
        for (File f : old) {
            String[] parts = f.getName().split("-");
            if (parts.length < 3) continue;
            final int owner;
            try { owner = Integer.parseInt(parts[1]); }
            catch (NumberFormatException error) { continue; }
            if (owner <= 0 || owner == pid) continue;
            try {
                Files.readAttributes(proc.resolve(Integer.toString(owner)), BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS);
                // A different app process can still have this copy mapped; leave it alone.
            } catch (NoSuchFileException dead) {
                // A disappearing or inaccessible procfs is not proof of a dead process.
                if (Files.isDirectory(proc.resolve("self"))) Files.deleteIfExists(f.toPath());
            } catch (SecurityException unavailable) {
                // Cannot prove the owner is dead: keep its copy.
            } catch (IOException unavailable) {
                // Cannot prove the owner is dead: keep its copy.
            }
        }
    }

    /**
     * Copies the pushed library (opened without following links) into a new file of the code cache, hashing
     * exactly the bytes written, and makes the copy read-only. The library loaded is this copy, so a swap of
     * the pushed file between the check and System.load cannot change what runs.
     */
    private static File stage(File lib, String sha, File codeCacheDir, int pid) throws IOException, Rejected {
        File dir = new File(codeCacheDir.getCanonicalFile(), STAGE);
        if (Files.isSymbolicLink(dir.toPath())) throw new Rejected(dir + " is a symbolic link");
        Files.createDirectories(dir.toPath());
        removeStale(codeCacheDir, pid);
        Path copy = Files.createTempFile(dir.toPath(), sha.substring(0, 16) + "-" + pid + "-", ".so");
        MessageDigest digest = sha256Digest();
        try (InputStream in = Files.newInputStream(lib.toPath(), LinkOption.NOFOLLOW_LINKS);
             OutputStream out = Files.newOutputStream(copy, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)) {
            byte[] buffer = new byte[1 << 20];
            int n;
            while ((n = in.read(buffer)) != -1) {
                digest.update(buffer, 0, n);
                out.write(buffer, 0, n);
            }
        }
        String actual = hex(digest.digest());
        if (!actual.equals(sha)) {
            Files.delete(copy);
            throw new Rejected(lib + " has SHA-256 " + actual + ", the launch asked for " + sha);
        }
        if (!copy.toFile().setWritable(false, false)) throw new IOException("cannot make " + copy + " read-only");
        return copy.toFile();
    }

    /**
     * After the load: the file the dynamic linker bound this process's JNI methods to must be the one
     * selected (the staged copy by its real path; otherwise an entry of the installed base or split APK,
     * or the extracted library directory, each also by its canonical path).
     */
    static void verifyLoaded(RuntimeLibrary selected, String loadedPath, String apkPath, String[] splitPaths,
                             String nativeLibraryDir) throws Rejected {
        if (loadedPath == null || loadedPath.isEmpty()) throw new Rejected("the loaded library has no path");
        try {
            if (selected.override()) {
                if (!new File(loadedPath).getCanonicalPath().equals(selected.file.getCanonicalPath()))
                    throw new Rejected("JNI is bound to " + loadedPath + ", not to the override " + selected.file);
                return;
            }
            List<String> apks = new ArrayList<>();
            apks.add(apkPath);
            if (splitPaths != null) Collections.addAll(apks, splitPaths);
            List<String> prefixes = new ArrayList<>();
            for (String a : apks) {
                prefixes.add(a + "!/");
                prefixes.add(new File(a).getCanonicalPath() + "!/");
            }
            prefixes.add(nativeLibraryDir + "/");
            prefixes.add(new File(nativeLibraryDir).getCanonicalPath() + "/");
            for (String p : prefixes) if (loadedPath.startsWith(p)) return;
            throw new Rejected("JNI is bound to " + loadedPath + ", which is not this APK's library");
        } catch (IOException error) {
            throw new Rejected(String.valueOf(error.getMessage()));
        }
    }

    /**
     * The JNI ABI the Java side was compiled with: SHA-256 over "Class.method(Param,...)Return" of every
     * native method, sorted, one per line (simple type names). native/jni_abi.py computes the same from
     * the Java sources at CMake time and bakes it into the library (NativeBridge.jniAbi()).
     */
    static String jniAbi(Class<?>... classes) {
        List<String> entries = new ArrayList<>();
        for (Class<?> c : classes)
            for (Method m : c.getDeclaredMethods()) {
                if (!Modifier.isNative(m.getModifiers())) continue;
                StringBuilder e = new StringBuilder(c.getSimpleName()).append('.').append(m.getName()).append('(');
                Class<?>[] params = m.getParameterTypes();
                for (int i = 0; i < params.length; i++) e.append(i == 0 ? "" : ",").append(params[i].getSimpleName());
                entries.add(e.append(')').append(m.getReturnType().getSimpleName()).toString());
            }
        Collections.sort(entries);
        return hex(sha256Digest().digest(String.join("\n", entries).getBytes(StandardCharsets.UTF_8)));
    }

    /** Overrides present in the private directory (logged when a launch does not ask for one). */
    static int present(File filesDir) {
        String[] names = new File(filesDir, DIRECTORY).list();
        return names == null ? 0 : names.length;
    }

    private static String text(Map<String, Object> m, String key, Pattern format) throws Rejected {
        Object value = m.get(key);
        if (!(value instanceof String) || !format.matcher((String) value).matches())
            throw new Rejected(MANIFEST + " " + key + " is missing or malformed");
        return (String) value;
    }

    private static MessageDigest sha256Digest() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("SHA-256 is unavailable", error);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) hex.append(String.format(Locale.ROOT, "%02x", value & 255));
        return hex.toString();
    }

    static String sha256(File file) throws IOException {
        MessageDigest digest = sha256Digest();
        try (InputStream input = Files.newInputStream(file.toPath())) {
            byte[] buffer = new byte[1 << 20];
            int n;
            while ((n = input.read(buffer)) != -1) digest.update(buffer, 0, n);
        }
        return hex(digest.digest());
    }

    /**
     * verify-apk.py's ELF rule (little-endian AArch64 ELF64, every LOAD segment 16 KB aligned) plus
     * DT_SONAME == libs2arm_android.so, so a lookup by that name (cs/aot/AndroidSelfTest.cs) finds this
     * library and never loads the APK's copy next to it. null = ok.
     */
    static String elf(File file) throws IOException {
        try (RandomAccessFile f = new RandomAccessFile(file, "r")) {
            byte[] header = new byte[64];
            if (f.length() < header.length) return "not an ELF file";
            f.readFully(header);
            if (header[0] != 0x7f || header[1] != 'E' || header[2] != 'L' || header[3] != 'F' || header[4] != 2 || header[5] != 1
                    || u16(header, 18) != 183) return "not a little-endian AArch64 ELF64";
            long phoff = u64(header, 32);
            int phsize = u16(header, 54), phcount = u16(header, 56);
            if (phsize < 56 || phoff < 0 || phoff + (long) phsize * phcount > f.length()) return "program headers out of range";
            byte[] ph = new byte[phsize];
            List<long[]> loads = new ArrayList<>();   // {offset, vaddr, filesz}
            long dynOffset = -1, dynSize = 0;
            for (int i = 0; i < phcount; i++) {
                f.seek(phoff + (long) i * phsize);
                f.readFully(ph);
                long type = u32(ph, 0), offset = u64(ph, 8), address = u64(ph, 16), size = u64(ph, 32), align = u64(ph, 48);
                if (type == 2) {
                    dynOffset = offset;
                    dynSize = size;
                }
                if (type != 1) continue;
                if (Long.compareUnsigned(align, 16384) < 0 || Long.remainderUnsigned(address - offset, 16384) != 0)
                    return "ELF LOAD segment is not 16 KB aligned";
                loads.add(new long[] {offset, address, size});
            }
            if (loads.isEmpty()) return "ELF has no LOAD segments";
            if (dynOffset < 0 || dynOffset + dynSize > f.length()) return "ELF has no dynamic section";
            long strtab = -1, soname = -1;
            byte[] entry = new byte[16];
            for (long at = dynOffset; at + 16 <= dynOffset + dynSize; at += 16) {
                f.seek(at);
                f.readFully(entry);
                long tag = u64(entry, 0), value = u64(entry, 8);
                if (tag == 0) break;
                if (tag == 5) strtab = value;
                if (tag == 14) soname = value;
            }
            if (strtab < 0 || soname < 0) return "ELF has no DT_SONAME";
            long name = -1;
            for (long[] l : loads)
                if (Long.compareUnsigned(strtab - l[1], l[2]) < 0) name = l[0] + (strtab - l[1]) + soname;
            byte[] want = (FILE + "\0").getBytes(StandardCharsets.US_ASCII), got = new byte[want.length];
            if (name < 0 || name + want.length > f.length()) return "DT_SONAME is not " + FILE;
            f.seek(name);
            f.readFully(got);
            return Arrays.equals(want, got) ? null : "DT_SONAME is not " + FILE;
        }
    }

    private static int u16(byte[] b, int at) { return (b[at] & 255) | (b[at + 1] & 255) << 8; }
    private static long u32(byte[] b, int at) { return u16(b, at) | (long) u16(b, at + 2) << 16; }
    private static long u64(byte[] b, int at) { return u32(b, at) | u32(b, at + 4) << 32; }
}
