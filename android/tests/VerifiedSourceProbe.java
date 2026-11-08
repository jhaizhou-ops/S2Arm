package org.s2arm.android;

import java.nio.file.*;
import java.util.List;

/** Actual production native callback + actual admission/digest, using authored bytes on a host JVM. */
public final class VerifiedSourceProbe {
    private static native int read(String path);
    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        Path root = Files.createTempDirectory("s2a-verified-source-");
        int checks = 0;
        try {
            for (String suffix : List.of("patched.bin","fixups.tsv","gates.tsv")) {
                for (boolean symlink : new boolean[]{false,true}) {
                    Path app = Files.createDirectories(root.resolve(suffix + symlink));
                    Path game = GameSessionAdmissionTest.fixture(app);
                    try (GameSession session = GameSession.load(GameSessionAdmissionTest.spec(app,game),app.toFile(),null,true,true)) {
                        var start = session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD);
                        Path path = Path.of(start.revisionDir,"modules/main." + suffix);
                        if (read(path.toString()) != 0) throw new AssertionError("valid source rejected");
                        checks++;
                        if (symlink) {
                            Path outside = root.resolve("outside-" + suffix); Files.write(outside,new byte[]{9,8,7,6});
                            Files.delete(path); Files.createSymbolicLink(path,outside);
                        } else {
                            // Same inode write defeats an fd-only snapshot as well as path checks.
                            Path target = path.toRealPath(); target.toFile().setWritable(true); Files.write(target,new byte[]{9,8,7,6});
                        }
                        if (read(path.toString()) == 0) throw new AssertionError("native callback accepted post-admission " + suffix + "/symlink=" + symlink);
                        checks++;
                        if (GameSession.verifyNativeBytes(path.toString(),java.nio.ByteBuffer.wrap(new byte[]{9,8,7,6})))
                            throw new AssertionError("digest accepted replaced bytes");
                    }
                }
            }
            System.out.println("Verified native source: " + checks + " checks PASS (real JNI callback, host synthetic bytes)");
        } finally { GameInstall.deleteTree(root.toFile()); }
    }
}
