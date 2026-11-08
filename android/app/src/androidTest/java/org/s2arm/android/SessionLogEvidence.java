package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.util.Map;

/** Test-only snapshot before a later launch archives/deletes the old process's host log. */
final class SessionLogEvidence {
    static File capture(File privateRoot, File cache, File bootSpec, ProcessBirth birth) throws IOException {
        int pid = birth.pid;
        Map<String, Object> spec = Json.object(Json.parse(new String(Files.readAllBytes(bootSpec.toPath()), StandardCharsets.UTF_8)), "BootSpec");
        Map<String, Object> paths = Json.object(spec.get("paths"), "BootSpec.paths");
        Object save = paths.get("saveRoot");
        if (!(save instanceof String)) throw new IOException("BootSpec has no saveRoot");
        File root = privateRoot.getCanonicalFile();
        File state = new File((String)save, "ryujinx-android").getCanonicalFile();
        if (!state.toPath().startsWith(root.toPath())) throw new IOException("Host log state is outside private files");
        File[] matches = state.listFiles(f -> f.getName().matches("host-[0-9]+-" + pid + "-[A-Za-z0-9]+\\.log")
            && f.lastModified() >= birth.startWallMs);
        if (matches == null || matches.length != 1 || !Files.isRegularFile(matches[0].toPath(), LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Expected one persisted host log for PID " + pid + " in " + state);
        File source = matches[0];
        File snapshot = Files.createTempDirectory(cache.toPath(), "game-evidence-" + pid + "-").toFile();
        File target = new File(snapshot, source.getName());
        Files.copy(source.toPath(), target.toPath()); // raw bytes, including NUL; do not delete the source
        String sha = RuntimeLibrary.sha256(source);
        if (source.length() == 0 || source.length() != target.length() || !sha.equals(RuntimeLibrary.sha256(target)))
            throw new IOException("Host log copy failed size/SHA verification for PID " + pid);
        String manifest = "{\"pid\":" + pid + ",\"birth\":" + birth.json() + ",\"source\":" + BootSpec.quote(source.getAbsolutePath())
            + ",\"bytes\":" + target.length() + ",\"sha256\":" + BootSpec.quote(sha) + "}\n";
        Files.write(new File(snapshot, "manifest.json").toPath(), manifest.getBytes(StandardCharsets.UTF_8));
        return snapshot;
    }

    static String readVerified(File snapshot, ProcessBirth birth) throws IOException {
        Map<String,Object> manifest = Json.object(Json.parse(new String(Files.readAllBytes(
            new File(snapshot,"manifest.json").toPath()),StandardCharsets.UTF_8)),"host evidence");
        Map<String,Object> saved = Json.object(manifest.get("birth"),"host evidence birth");
        if (!Long.valueOf(birth.pid).equals(saved.get("pid")) || !Long.valueOf(birth.startTicks).equals(saved.get("startTicks"))
                || !Long.valueOf(birth.startElapsedMs).equals(saved.get("startElapsedMs"))
                || !Long.valueOf(birth.startWallMs).equals(saved.get("startWallMs")))
            throw new IOException("host evidence birth mismatch");
        File[] logs = snapshot.listFiles(f -> f.getName().endsWith(".log"));
        if (logs == null || logs.length != 1 || !RuntimeLibrary.sha256(logs[0]).equals(manifest.get("sha256")))
            throw new IOException("sealed host log SHA mismatch");
        return new String(Files.readAllBytes(logs[0].toPath()),StandardCharsets.UTF_8);
    }
}
