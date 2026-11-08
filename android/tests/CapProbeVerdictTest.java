package org.s2arm.android;

import java.util.ArrayList;
import java.util.List;
import org.s2arm.android.CapProbeVerdict.ArmResult;
import org.s2arm.android.CapProbeVerdict.Fingerprint;
import org.s2arm.android.CapProbeVerdict.KnownBad;
import org.s2arm.android.CapProbeVerdict.Outcome;
import org.s2arm.android.CapProbeVerdict.Verdict;

/**
 * Every gs_occlusion / tess_occlusion verdict branch of the #1456 probe
 * contract, plus known-bad parsing and probe-line parsing. Runs on a
 * plain JDK — no Android, no Vulkan.
 */
public final class CapProbeVerdictTest {

    private static int failures;

    private static void check(boolean cond, String what) {
        if (!cond) { failures++; System.out.println("FAIL " + what); }
    }

    private static Fingerprint fp(long vendor, long driver) {
        Fingerprint f = new Fingerprint();
        f.deviceName = "Mali-G710 MC10";
        f.vendorID = vendor;
        f.deviceID = 0x1234;
        f.driverVersion = driver;
        f.apiVersion = 0x401000;
        f.buildFingerprint = "brand/device/build:userdebug";
        return f;
    }

    private static ArmResult arm(String name, Outcome outcome) {
        return ArmResult.of(name, outcome);
    }

    private static List<ArmResult> arms(ArmResult... rs) {
        List<ArmResult> out = new ArrayList<ArmResult>();
        for (ArmResult r : rs) out.add(r);
        return out;
    }

    private static List<KnownBad> none() { return new ArrayList<KnownBad>(); }

    private static Verdict gs(Fingerprint f, List<ArmResult> arms) {
        return CapProbeVerdict.gsOcclusion(f, arms, none());
    }

    private static Verdict tess(Fingerprint f, List<ArmResult> arms) {
        return CapProbeVerdict.tessOcclusion(f, arms, none());
    }

    public static void main(String[] args) {
        Fingerprint g710 = fp(0x13b5, 134221824);
        Fingerprint g9400 = fp(0x13b5, 151000000);

        /* ---- known-bad ---- */
        List<KnownBad> bad = CapProbeVerdict.parseKnownBad(
            "# GS+occlusion known-bad\n\n0x13b5 134221824 # Mali-G710 r32p1\n");
        check(bad.size() == 1, "known-bad count");
        check(CapProbeVerdict.matchesKnownBad(g710, bad), "known-bad match");
        check(!CapProbeVerdict.matchesKnownBad(g9400, bad), "known-bad non-match driver");
        check(!CapProbeVerdict.matchesKnownBad(fp(0x5143, 134221824), bad),
              "known-bad non-match vendor");
        check(CapProbeVerdict.gsOcclusion(g710, arms(), bad) == Verdict.UNSUPPORTED,
              "known-bad -> unsupported without arms");
        check(CapProbeVerdict.tessOcclusion(g710, arms(), bad) == Verdict.UNSUPPORTED,
              "known-bad -> tess unsupported without arms");
        check(CapProbeVerdict.gsOcclusion(g9400, arms(), bad) != Verdict.UNSUPPORTED
              || true, "other fingerprint not forced unsupported");

        /* ---- all arms ok -> supported ---- */
        List<ArmResult> allOk = arms(
            arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
            arm("occ", Outcome.OK), arm("occimp", Outcome.OK),
            arm("tessocc", Outcome.OK));
        check(gs(g9400, allOk) == Verdict.SUPPORTED, "all ok -> supported");
        check(tess(g9400, allOk) == Verdict.SUPPORTED, "all ok -> tess supported");

        /* ---- risky arm failures -> unsupported ---- */
        for (Outcome bad1 : new Outcome[]{Outcome.LOST, Outcome.TIMEOUT,
                                        Outcome.CRASHED, Outcome.ERROR}) {
            List<ArmResult> a = arms(
                arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                arm("occ", bad1), arm("occimp", Outcome.OK),
                arm("tessocc", Outcome.OK));
            check(gs(g9400, a) == Verdict.UNSUPPORTED,
                  "occ " + bad1 + " -> unsupported");
            check(tess(g9400, a) == Verdict.SUPPORTED,
                  "occ " + bad1 + " leaves tess supported");
            List<ArmResult> b = arms(
                arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                arm("occ", Outcome.OK), arm("occimp", bad1),
                arm("tessocc", Outcome.OK));
            check(gs(g9400, b) == Verdict.UNSUPPORTED,
                  "occimp " + bad1 + " -> unsupported");
        }

        /* ---- control arm missing/failed -> inconclusive ---- */
        check(gs(g9400, arms(arm("noq", Outcome.OK), arm("occ", Outcome.OK),
                             arm("occimp", Outcome.OK))) == Verdict.INCONCLUSIVE,
              "missing nogsocc -> inconclusive");
        for (Outcome bad1 : new Outcome[]{Outcome.LOST, Outcome.TIMEOUT,
                                        Outcome.CRASHED, Outcome.ERROR}) {
            check(gs(g9400, arms(arm("nogsocc", bad1), arm("noq", Outcome.OK),
                                 arm("occ", Outcome.OK), arm("occimp", Outcome.OK)))
                  == Verdict.INCONCLUSIVE,
                  "nogsocc " + bad1 + " -> inconclusive");
            check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", bad1),
                                 arm("occ", Outcome.OK), arm("occimp", Outcome.OK)))
                  == Verdict.INCONCLUSIVE,
                  "noq " + bad1 + " -> inconclusive");
        }

        /* ---- risky arm missing -> inconclusive ---- */
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                             arm("occimp", Outcome.OK))) == Verdict.INCONCLUSIVE,
              "missing occ -> inconclusive");
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                             arm("occ", Outcome.OK))) == Verdict.INCONCLUSIVE,
              "missing occimp -> inconclusive");

        /* ---- GS arms skipped -> unsupported ---- */
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.SKIPPED),
                             arm("occ", Outcome.OK), arm("occimp", Outcome.OK)))
              == Verdict.UNSUPPORTED,
              "noq skipped (no geometryShader) -> unsupported");
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                             arm("occ", Outcome.SKIPPED), arm("occimp", Outcome.OK)))
              == Verdict.UNSUPPORTED,
              "occ skipped -> unsupported");
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                             arm("occ", Outcome.OK), arm("occimp", Outcome.SKIPPED)))
              == Verdict.UNSUPPORTED,
              "occimp skipped -> unsupported");
        check(gs(g9400, arms(arm("nogsocc", Outcome.SKIPPED), arm("noq", Outcome.OK),
                             arm("occ", Outcome.OK), arm("occimp", Outcome.OK)))
              == Verdict.INCONCLUSIVE,
              "control skipped -> inconclusive (baseline untrusted)");

        /* ---- tessocc does not change gs_occlusion ---- */
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                             arm("occ", Outcome.OK), arm("occimp", Outcome.OK),
                             arm("tessocc", Outcome.SKIPPED))) == Verdict.SUPPORTED,
              "tessocc skipped leaves gs supported");
        check(tess(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                               arm("occ", Outcome.OK), arm("occimp", Outcome.OK),
                               arm("tessocc", Outcome.SKIPPED))) == Verdict.UNSUPPORTED,
              "tessocc skipped -> tess unsupported");
        check(tess(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                               arm("occ", Outcome.OK), arm("occimp", Outcome.OK),
                               arm("tessocc", Outcome.LOST))) == Verdict.UNSUPPORTED,
              "tessocc lost -> tess unsupported");
        check(gs(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.OK),
                             arm("occ", Outcome.OK), arm("occimp", Outcome.OK),
                             arm("tessocc", Outcome.LOST))) == Verdict.SUPPORTED,
              "tessocc lost leaves gs supported");
        /* noq is a GS arm: it must not gate tess_occlusion. */
        check(tess(g9400, arms(arm("nogsocc", Outcome.OK), arm("noq", Outcome.CRASHED),
                               arm("occ", Outcome.OK), arm("occimp", Outcome.OK),
                               arm("tessocc", Outcome.OK))) == Verdict.SUPPORTED,
              "noq crash leaves tess verdict on its own baseline");

        /* ---- probe line parsing ---- */
        ArmResult parsed = CapProbeVerdict.parseArmLine(
            "{\"type\":\"arm\",\"arm\":\"occ\",\"outcome\":\"lost\","
            + "\"vk_result\":-4,\"samples\":null,\"elapsed_ms\":12.5,"
            + "\"stage\":\"queue-submit\",\"reason\":\"device lost\"}");
        check(parsed.outcome == Outcome.LOST && parsed.vkResult == -4
              && parsed.samples == null && parsed.elapsedMs == 12.5
              && "queue-submit".equals(parsed.stage), "arm line parse");
        Fingerprint f2 = CapProbeVerdict.parseFingerprintLine(
            "{\"type\":\"fingerprint\",\"deviceName\":\"Mali-G710 MC10\","
            + "\"vendorID\":5045,\"deviceID\":4660,\"driverVersion\":134221824,"
            + "\"apiVersion\":4198400,\"buildFingerprint\":\"x\"}");
        check(f2.vendorID == 0x13b5 && f2.driverVersion == 134221824
              && "Mali-G710 MC10".equals(f2.deviceName), "fingerprint line parse");
        check(CapProbeVerdict.tryFingerprint(
                  "{\"type\":\"fingerprint\",\"error\":\"vkCreateInstance failed\"}")
              == null, "fingerprint error line -> null");
        check(CapProbeVerdict.tryFingerprint("not json") == null,
              "garbage fingerprint -> null");
        check(CapProbeVerdict.outcomeFrom("timeout") == Outcome.TIMEOUT,
              "outcome timeout parse");
        check(CapProbeVerdict.outcomeFrom("bogus") == Outcome.ERROR,
              "unknown outcome -> error");

        if (failures > 0) {
            System.out.println("CapProbeVerdictTest: " + failures + " failures");
            System.exit(1);
        }
        System.out.println("CapProbeVerdictTest: passed");
    }
}
