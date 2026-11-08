package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.Arrays;

public final class SessionLogEvidenceTest {
    private static int checks;
    private static void check(boolean yes, String why) { checks++; if (!yes) throw new AssertionError(why); }
    public static void main(String[] args) throws Exception {
        File base = Files.createTempDirectory("s2a-host-evidence-").toFile();
        File root = new File(base,"files"), cache = new File(base,"cache"), save = new File(root,"user/0/saves/title");
        File state = new File(save,"ryujinx-android");
        Files.createDirectories(state.toPath()); Files.createDirectories(cache.toPath());
        File spec = new File(cache,"boot.json");
        Files.writeString(spec.toPath(),"{\"paths\":{\"saveRoot\":" + BootSpec.quote(save.getAbsolutePath()) + "}}");
        byte[] raw = new byte[]{'[','s','2','a',']',0,'x','\n'};
        File log = new File(state,"host-1-14110-Ab12.log"), other = new File(state,"host-1-14111-CD34.log");
        Files.write(log.toPath(),raw); Files.write(other.toPath(),new byte[]{1});
        ProcessBirth birth = new ProcessBirth(14110,400,4000,1000);
        File old = new File(state,"host-1-14110-Old1.log"); Files.write(old.toPath(),new byte[]{2});
        check(old.setLastModified(1),"old same-PID log timestamp");
        File evidence = SessionLogEvidence.capture(root,cache,spec,birth);
        check(Arrays.equals(Files.readAllBytes(new File(evidence,log.getName()).toPath()),raw),"NUL-bearing raw log preserved");
        check(log.isFile() && other.isFile(),"source and other PID logs retained");
        String receipt = Files.readString(new File(evidence,"manifest.json").toPath());
        check(receipt.contains(RuntimeLibrary.sha256(log)) && receipt.contains("\"pid\":14110"),"PID and SHA receipt");
        check(SessionLogEvidence.readVerified(evidence,birth).contains("[s2a]"),"sealed birth/SHA matches before read");
        boolean rejected=false; try { SessionLogEvidence.readVerified(evidence,new ProcessBirth(14110,399,3990,1000)); } catch(IOException e) { rejected=true; }
        check(rejected,"same PID older birth cannot borrow sealed log");
        Files.delete(log.toPath()); // reproduce the later verified prelaunch archive cleanup
        check(new File(evidence,log.getName()).length()==raw.length,"snapshot survives source archival");
        rejected=false; try { SessionLogEvidence.capture(root,cache,spec,birth); } catch(IOException e) { rejected=true; }
        check(rejected,"missing own PID cannot borrow another process log");
        Files.writeString(spec.toPath(),"{\"paths\":{\"saveRoot\":" + BootSpec.quote(base.getAbsolutePath()) + "}}");
        rejected=false; try { SessionLogEvidence.capture(root,cache,spec,birth); } catch(IOException e) { rejected=true; }
        check(rejected,"outside private files rejected");
        System.out.println("Session log evidence: " + checks + " checks PASS");
    }
}
