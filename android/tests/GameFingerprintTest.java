package org.s2arm.android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.FileTime;
import java.util.Map;

/** Synthetic input through real install/current/admission; no Android device or game bytes. */
public final class GameFingerprintTest {
    private static int checks;
    private static void check(boolean ok, String message) { checks++; if (!ok) throw new AssertionError(message); }
    private static Map<String,Object> current(Path game) throws IOException {
        return Json.object(Json.parse(new String(Files.readAllBytes(game.resolve("current.json")), StandardCharsets.UTF_8)),"current");
    }
    private static Path table(Path game) throws Exception {
        Map<String,Object> doc=current(game), ref=Json.object(doc.get("fingerprint"),"fingerprint");
        String sha=(String)ref.get("sha256");
        Path file=game.resolve((String)doc.get("revisionDir")).resolve((String)ref.get("path"));
        check(sha.equals(GamePack.sha256(Files.readAllBytes(file))),"current binds exact table SHA");
        check(((String)doc.get("contentRoot")).equals("sha256-"+ref.get("indexSha256")),"table binds original index identity");
        return file;
    }
    private static String load(Path app, Path game) throws Exception {
        try (GameSession session=GameSession.load(GameSessionAdmissionTest.spec(app,game),app.toFile(),null,true,true)) {
            return session.resourceValidation;
        }
    }
    private static void counts(String line, int hit, int rehash) {
        check(line.startsWith("资源校验：指纹命中 "+hit+" / 重算 "+rehash+" / 用时 ") && line.endsWith(" ms"),"unexpected resource counts: "+line);
    }
    private static void refused(Path app, Path game, String why) throws Exception {
        try { load(app,game); throw new AssertionError("accepted "+why); }
        catch (IOException expected) { checks++; }
    }
    private static void corruptedReplacement(Path app, Path game, Path target) throws Exception {
        // Owner's condition: same size and restored mtime, but a provably different inode.
        Object oldKey=Files.readAttributes(target,"unix:dev,ino");
        FileTime time=Files.getLastModifiedTime(target);
        Path replacement=Files.createTempFile(target.getParent(),"replacement-",".tmp");
        Files.write(replacement,new byte[]{8}); Files.setLastModifiedTime(replacement,time);
        Files.move(replacement,target,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        Object newKey=Files.readAttributes(target,"unix:dev,ino");
        check(!oldKey.equals(newKey) && time.equals(Files.getLastModifiedTime(target)) && Files.size(target)==1,
                "corrupt replacement really changed inode while keeping size/mtime");
        byte[] before=Files.readAllBytes(game.resolve("current.json"));
        refused(app,game,"corrupt replacement with preserved size/mtime");
        check(java.util.Arrays.equals(before,Files.readAllBytes(game.resolve("current.json"))),"failed resource leaves current unchanged");
    }
    private static void sameContentRefresh(Path app) throws Exception {
        Path game=GameSessionAdmissionTest.fixture(app), pack=app.resolve("pack");
        Path table=table(game);
        GameInstall.Result identical=GameInstall.install(app.resolve("games").toFile(),GameInstall.directory(pack.toFile()),null);
        check(identical.alreadyActive,"same package remains already active");
        counts(load(app,game),8,0);
        Path artifact=pack.resolve(GamePack.ARTIFACT);
        String old=Files.readString(artifact);
        Files.writeString(artifact,old.replaceFirst("\\{","{\"fixtureMarker\":1,"));
        GameInstall.Result refreshed=GameInstall.install(app.resolve("games").toFile(),GameInstall.directory(pack.toFile()),null);
        check(refreshed.artifactRefreshed,"same resource root refreshes artifact");
        check(table.equals(table(game)),"artifact refresh preserves fingerprint reference");
        counts(load(app,game),8,0);
    }
    private static void interruptedPublish(Path app) throws Exception {
        Path game=GameSessionAdmissionTest.fixture(app);
        Path revision=game.resolve(BootContract.readCurrent(game.toFile()).revisionDir);
        Path target=revision.resolve("romfs/readme").toRealPath();
        Files.setLastModifiedTime(target,FileTime.fromMillis(Files.getLastModifiedTime(target).toMillis()+5000));
        byte[] before=Files.readAllBytes(game.resolve("current.json"));
        Path obstacle=Files.createDirectory(game.resolve("current.json.tmp"));
        refused(app,game,"unsafe current temporary path");
        check(Files.isDirectory(obstacle),"temporary directory is not overwritten or deleted");
        check(java.util.Arrays.equals(before,Files.readAllBytes(game.resolve("current.json"))),"failed switch leaves current unchanged");
        Files.delete(obstacle);
        counts(load(app,game),7,1);
        check(!java.util.Arrays.equals(before,Files.readAllBytes(game.resolve("current.json"))),"later retry commits the complete updated table");
        counts(load(app,game),8,0);
    }
    private static void reuseCorruption(Path app) throws Exception {
        Path game=GameSessionAdmissionTest.fixture(app);
        Path revision=game.resolve(BootContract.readCurrent(game.toFile()).revisionDir);
        Path shared=revision.resolve("modules/main.patched.bin").toRealPath();
        shared.toFile().setWritable(true);
        Files.write(shared,new byte[]{1,2,3,5});
        Path pack=app.resolve("pack"), rom=pack.resolve("romfs/readme"), index=pack.resolve("index.tsv");
        String oldIndex=Files.readString(index), oldHash=GamePack.sha256(oldIndex.getBytes(StandardCharsets.UTF_8));
        String oldFileHash=GamePack.sha256(Files.readAllBytes(rom));
        Files.write(rom,new byte[]{9});
        String newIndex=oldIndex.replace(oldFileHash,GamePack.sha256(new byte[]{9}));
        String newHash=GamePack.sha256(newIndex.getBytes(StandardCharsets.UTF_8));
        Files.writeString(index,newIndex);
        for (String name : new String[]{"manifest.json",GamePack.ARTIFACT}) {
            Path f=pack.resolve(name); Files.writeString(f,Files.readString(f).replace(oldHash,newHash));
        }
        byte[] before=Files.readAllBytes(game.resolve("current.json"));
        try { GameInstall.install(app.resolve("games").toFile(),GameInstall.directory(pack.toFile()),null); throw new AssertionError("corrupt reused CAS object was trusted"); }
        catch (IOException expected) { checks++; }
        check(java.util.Arrays.equals(before,Files.readAllBytes(game.resolve("current.json"))),"bad reused CAS leaves prior current");
    }
    public static void main(String[] args) throws Exception {
        Path app=Files.createTempDirectory("s2a-fingerprint-");
        try {
            if (args.length == 1 && args[0].equals("corrupt-only")) {
                Path game=GameSessionAdmissionTest.fixture(app);
                Path target=game.resolve(BootContract.readCurrent(game.toFile()).revisionDir).resolve("romfs/readme").toRealPath();
                counts(load(app,game),8,0);
                corruptedReplacement(app,game,target);
                System.out.println("GameFingerprint corrupt-only: PASS");
                return;
            }
            Path game=GameSessionAdmissionTest.fixture(app);
            String root=(String)current(game).get("contentRoot");
            Path originalTable=table(game);
            counts(load(app,game),8,0);
            final int[] probes = {0};
            GameFingerprint.setStatProbe(file -> { probes[0]++; if (probes[0] == 2) throw new IOException("synthetic replay failure"); });
            counts(load(app,game),8,0);
            check(probes[0] == 0, "disabled timing performs no replay");
            GameFingerprint.Timing timing = new GameFingerprint.Timing();
            try (GameSession timed = GameSession.load(GameSessionAdmissionTest.spec(app,game), app.toFile(), null, true, true, timing)) {
                counts(timed.resourceValidation,8,0);
                check(timed.bootTiming == timing, "timing is attached to the admitted session");
                String report = String.join("\n", timing.lines());
                for (String phase : new String[]{"storage_lock", "session_open", "artifact_checks", "index_manifest_read_hash_parse",
                        "fingerprint_reference", "fingerprint_table_read", "verify_walk", "fingerprint_verify_loop",
                        "admitted_maps_checks", "revision_modules", "fingerprint_update_clean"})
                    check(report.contains("phase=" + phase + " ns="), "missing timing " + phase);
                check(report.contains("sample=under interval=128 count=0 errors=0"),
                    "a warm hit needs no under() canonicalization");
                check(report.contains("sample=resolve interval=128 count=1 errors=0"),
                    "link targets resolve via readlink, not canonicalization");
                check(report.contains("sample=stat interval=128 count=1 errors=0"), "stat sample accounting");
                check(report.contains("phase=lstat_replay ns="), "replay elapsed is reported");
                check(report.contains("replay=lstat count=8 errors=1") && probes[0] == 8,
                    "enabled replay counts calls and errors without changing admission");
            }
            Path revision=game.resolve(BootContract.readCurrent(game.toFile()).revisionDir);
            Path target=revision.resolve("romfs/readme").toRealPath();
            FileTime originalTime=Files.getLastModifiedTime(target);
            Files.setLastModifiedTime(target, FileTime.fromMillis(originalTime.toMillis()+5000));
            check(!originalTime.equals(Files.getLastModifiedTime(target)),"actual target mtime changed");
            counts(load(app,game),7,1);
            Path newTable=table(game);
            check(!newTable.equals(originalTable),"one touched resource creates a new bound table");
            check(!Files.exists(originalTable),"unreferenced old regular table is collected under the lock");
            check(root.equals(current(game).get("contentRoot")),"touch preserves package identity");
            counts(load(app,game),8,0);

            Path orphan=revision.resolve(".s2a-fingerprint-"+"a".repeat(64)+".tsv");
            Files.write(orphan,new byte[]{1});
            Path interruptedTemp=revision.resolve(".s2a-fingerprint-tmp-"+"c".repeat(32)+".tsv");
            Files.write(interruptedTemp,new byte[]{1});
            counts(load(app,game),8,0);
            check(!Files.exists(orphan),"orphan regular table cleaned");
            check(!Files.exists(interruptedTemp),"interrupted regular temporary table cleaned");
            Path linked=revision.resolve(".s2a-fingerprint-"+"b".repeat(64)+".tsv");
            Files.createSymbolicLink(linked,target);
            refused(app,game,"metadata symlink");
            check(Files.isSymbolicLink(linked),"untrusted symlink not deleted");
            Files.delete(linked);

            Files.delete(newTable);
            counts(load(app,game),0,8);
            table(game);
            counts(load(app,game),8,0);
            Path corruptedTable=table(game);
            Files.write(corruptedTable,new byte[]{1,2,3});
            counts(load(app,game),0,8);
            table(game);
            counts(load(app,game),8,0);

            corruptedReplacement(app,game,target);
            Path timedApp=Files.createDirectory(app.resolve("timed-corruption"));
            Path timedGame=GameSessionAdmissionTest.fixture(timedApp);
            Path timedRevision=timedGame.resolve(BootContract.readCurrent(timedGame.toFile()).revisionDir);
            Path timedTarget=timedRevision.resolve("romfs/readme").toRealPath();
            Path timedReplacement=Files.createTempFile(timedTarget.getParent(), "bad", ".tmp");
            Files.write(timedReplacement, new byte[]{8});
            Files.move(timedReplacement, timedTarget, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            try {
                GameSession.load(GameSessionAdmissionTest.spec(timedApp,timedGame),timedApp.toFile(),null,true,true,new GameFingerprint.Timing());
                throw new AssertionError("timed admission accepted corrupted content");
            } catch (IOException expected) { checks++; }
            Path coldApp=Files.createDirectory(app.resolve("cold-under"));
            Path coldGame=GameSessionAdmissionTest.fixture(coldApp);
            Files.delete(table(coldGame)); // install pre-warms; deleting forces the cold path
            GameFingerprint.Timing coldTiming=new GameFingerprint.Timing();
            try (GameSession cold=GameSession.load(GameSessionAdmissionTest.spec(coldApp,coldGame),coldApp.toFile(),null,true,true,coldTiming)) {
                counts(cold.resourceValidation,0,8);
                check(String.join("\n",coldTiming.lines()).contains("sample=under interval=128 count=1"),
                    "cold-boot recalculation still resolves every indexed path through under()");
            }
            counts(load(coldApp,coldGame),8,0);
            Path second=Files.createDirectory(app.resolve("reuse-cas"));
            reuseCorruption(second);
            sameContentRefresh(Files.createDirectory(app.resolve("refresh")));
            interruptedPublish(Files.createDirectory(app.resolve("interrupted")));
            Path noStat=Files.createDirectory(app.resolve("unavailable-stat"));
            Path noStatGame=GameSessionAdmissionTest.fixture(noStat);
            GameFingerprint.setStatProvider(f -> null);
            counts(load(noStat,noStatGame),0,8);
            System.out.println("GameFingerprint: "+checks+" checks PASS (synthetic host only)");
        } finally { GameInstall.deleteTree(app.toFile()); }
    }
}
