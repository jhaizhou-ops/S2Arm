package org.s2arm.android;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Decision contract for the GS+occlusion capability probe (#1456). The
 * probe emits one flat JSON object per line: a {"type":"fingerprint"}
 * line and one {"type":"arm"} line per arm. This class turns those lines
 * into the two cached verdicts (gs_occlusion, tess_occlusion) written to
 * files/capprobe/<fingerprint-hash>.json. Plain JDK — host unit tests run
 * without an Android runtime.
 *
 * gs_occlusion rules (in order):
 *   1. fingerprint matches the known-bad list (vendorID + driverVersion,
 *      exact) -> UNSUPPORTED and the probe never runs.
 *   2. occ / occimp reported LOST / TIMEOUT / CRASHED / ERROR ->
 *      UNSUPPORTED (definitive for the combination).
 *   3. a control arm (nogsocc, noq) is missing or failed -> INCONCLUSIVE
 *      (the probe baseline itself cannot be trusted); SKIPPED on a
 *      control arm means the feature is absent -> UNSUPPORTED.
 *   4. occ / occimp SKIPPED (geometryShader absent) -> UNSUPPORTED;
 *      a missing occ / occimp line -> INCONCLUSIVE.
 *   5. otherwise -> SUPPORTED.
 *
 * tess_occlusion is decided from the tessocc arm the same way against the
 * same control baseline; it never affects gs_occlusion, and noq (a GS
 * arm) never affects tess_occlusion.
 */
public final class CapProbeVerdict {

    public enum Verdict { SUPPORTED, UNSUPPORTED, INCONCLUSIVE }
    public enum Outcome { OK, SKIPPED, ERROR, LOST, TIMEOUT, CRASHED }

    public static final String[] ARMS_IN_ORDER =
            {"nogsocc", "noq", "occ", "occimp", "tessocc"};
    public static final String CONTROL_BASELINE = "nogsocc";
    public static final String CONTROL_GS = "noq";
    public static final String[] GS_ARMS = {"occ", "occimp"};
    public static final String TESS_ARM = "tessocc";

    public static final class Fingerprint {
        public String deviceName = "";
        public long vendorID;
        public long deviceID;
        public long driverVersion;
        public long apiVersion;
        public String buildFingerprint = "";
    }

    public static final class ArmResult {
        public String arm;
        public Outcome outcome;
        public Long vkResult;    // VkResult int, may be null
        public Long samples;     // query samples, may be null
        public double elapsedMs;
        public String stage;     // failing stage, may be null
        public String reason;    // detail, may be null

        public static ArmResult of(String arm, Outcome outcome) {
            ArmResult r = new ArmResult();
            r.arm = arm;
            r.outcome = outcome;
            return r;
        }
    }

    public static final class KnownBad {
        public final long vendorID;
        public final long driverVersion;
        public KnownBad(long vendorID, long driverVersion) {
            this.vendorID = vendorID;
            this.driverVersion = driverVersion;
        }
    }

    /* ---------------- known-bad list ---------------- */

    /** Parses the known-bad file format: "vendorID driverVersion" per
     *  line, vendorID hex (0x…) or decimal, driverVersion decimal;
     *  blanks and #-comments ignored. */
    public static List<KnownBad> parseKnownBad(String text) {
        List<KnownBad> out = new ArrayList<KnownBad>();
        for (String raw : text.split("\n")) {
            int hash = raw.indexOf('#');
            String line = hash >= 0 ? raw.substring(0, hash) : raw;
            line = line.trim();
            if (line.isEmpty()) continue;
            String[] f = line.split("\\s+");
            if (f.length < 2)
                throw new IllegalArgumentException("bad known-bad line: " + raw);
            long vendor = Long.decode(f[0]);
            long driver = Long.parseLong(f[1]);
            out.add(new KnownBad(vendor, driver));
        }
        return out;
    }

    public static boolean matchesKnownBad(Fingerprint fp, List<KnownBad> list) {
        for (KnownBad b : list)
            if (b.vendorID == fp.vendorID && b.driverVersion == fp.driverVersion)
                return true;
        return false;
    }

    /* ---------------- verdict ---------------- */

    private static Verdict armVerdict(Map<String, ArmResult> byArm,
                                      String[] riskyArms,
                                      boolean gsBaselineRequired) {
        for (String name : riskyArms) {
            ArmResult r = byArm.get(name);
            if (r != null && (r.outcome == Outcome.LOST ||
                              r.outcome == Outcome.TIMEOUT ||
                              r.outcome == Outcome.CRASHED ||
                              r.outcome == Outcome.ERROR))
                return Verdict.UNSUPPORTED;
        }
        ArmResult baseline = byArm.get(CONTROL_BASELINE);
        if (baseline == null || baseline.outcome != Outcome.OK)
            return Verdict.INCONCLUSIVE;
        if (gsBaselineRequired) {
            ArmResult gsControl = byArm.get(CONTROL_GS);
            if (gsControl == null ||
                (gsControl.outcome != Outcome.OK && gsControl.outcome != Outcome.SKIPPED))
                return Verdict.INCONCLUSIVE;
            if (gsControl.outcome == Outcome.SKIPPED)
                return Verdict.UNSUPPORTED;   // no geometryShader at all
        }
        for (String name : riskyArms) {
            ArmResult r = byArm.get(name);
            if (r == null) return Verdict.INCONCLUSIVE;
            if (r.outcome == Outcome.SKIPPED) return Verdict.UNSUPPORTED;
        }
        return Verdict.SUPPORTED;
    }

    public static Verdict gsOcclusion(Fingerprint fp, List<ArmResult> arms,
                                      List<KnownBad> knownBad) {
        if (fp != null && matchesKnownBad(fp, knownBad))
            return Verdict.UNSUPPORTED;
        Map<String, ArmResult> byArm = new LinkedHashMap<String, ArmResult>();
        for (ArmResult r : arms) byArm.put(r.arm, r);
        return armVerdict(byArm, GS_ARMS, true);
    }

    public static Verdict tessOcclusion(Fingerprint fp, List<ArmResult> arms,
                                        List<KnownBad> knownBad) {
        if (fp != null && matchesKnownBad(fp, knownBad))
            return Verdict.UNSUPPORTED;
        Map<String, ArmResult> byArm = new LinkedHashMap<String, ArmResult>();
        for (ArmResult r : arms) byArm.put(r.arm, r);
        return armVerdict(byArm, new String[]{TESS_ARM}, false);
    }

    /* ---------------- probe line parsing ---------------- */

    public static ArmResult parseArmLine(String line) {
        Map<String, Object> obj = parseObject(line);
        if (!"arm".equals(obj.get("type")))
            throw new IllegalArgumentException("not an arm line: " + line);
        return armFromMap(obj);
    }

    public static Fingerprint parseFingerprintLine(String line) {
        Map<String, Object> obj = parseObject(line);
        if (!"fingerprint".equals(obj.get("type")))
            throw new IllegalArgumentException("not a fingerprint line: " + line);
        return fingerprintFromMap(obj);
    }

    /** A fingerprint line without a device identity (probe instance
     *  failure reports {"type":"fingerprint","error":...}) parses to
     *  null. */
    public static Fingerprint tryFingerprint(String line) {
        try {
            Map<String, Object> obj = parseObject(line);
            if (!"fingerprint".equals(obj.get("type")) || obj.get("error") != null)
                return null;
            return fingerprintFromMap(obj);
        } catch (RuntimeException e) {
            return null;
        }
    }

    static ArmResult armFromMap(Map<String, Object> obj) {
        ArmResult r = new ArmResult();
        r.arm = str(obj.get("arm"));
        r.outcome = outcomeFrom(str(obj.get("outcome")));
        r.vkResult = numOrNull(obj.get("vk_result"));
        r.samples = numOrNull(obj.get("samples"));
        Object e = obj.get("elapsed_ms");
        r.elapsedMs = e instanceof Number ? ((Number) e).doubleValue() : 0;
        r.stage = str(obj.get("stage"));
        r.reason = str(obj.get("reason"));
        return r;
    }

    static Fingerprint fingerprintFromMap(Map<String, Object> obj) {
        Fingerprint fp = new Fingerprint();
        fp.deviceName = str(obj.get("deviceName"));
        fp.vendorID = num(obj.get("vendorID"));
        fp.deviceID = num(obj.get("deviceID"));
        fp.driverVersion = num(obj.get("driverVersion"));
        fp.apiVersion = num(obj.get("apiVersion"));
        fp.buildFingerprint = str(obj.get("buildFingerprint"));
        return fp;
    }

    static Outcome outcomeFrom(String s) {
        if (s == null) return Outcome.ERROR;
        switch (s) {
        case "ok": return Outcome.OK;
        case "skipped": return Outcome.SKIPPED;
        case "lost": return Outcome.LOST;
        case "timeout": return Outcome.TIMEOUT;
        case "crashed": return Outcome.CRASHED;
        default: return Outcome.ERROR;
        }
    }

    static String outcomeName(Outcome o) {
        switch (o) {
        case OK: return "ok";
        case SKIPPED: return "skipped";
        case LOST: return "lost";
        case TIMEOUT: return "timeout";
        case CRASHED: return "crashed";
        default: return "error";
        }
    }

    public static String verdictName(Verdict v) {
        switch (v) {
        case SUPPORTED: return "supported";
        case UNSUPPORTED: return "unsupported";
        default: return "inconclusive";
        }
    }

    public static Verdict verdictFrom(String s) {
        if ("supported".equals(s)) return Verdict.SUPPORTED;
        if ("unsupported".equals(s)) return Verdict.UNSUPPORTED;
        return Verdict.INCONCLUSIVE;
    }

    static String str(Object o) { return o instanceof String ? (String) o : null; }

    static long num(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : 0;
    }

    static Long numOrNull(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : null;
    }

    /* ---------------- minimal JSON ---------------- */
    /* Flat JSON objects with string / number / boolean / null scalars.
     * Enough for the probe contract lines and the result file. */

    public static Map<String, Object> parseObject(String line) {
        Parser p = new Parser(line);
        Map<String, Object> obj = p.object();
        p.ws();
        if (!p.end()) throw new IllegalArgumentException("trailing data: " + line);
        return obj;
    }

    static final class Parser {
        private final String s;
        private int i;
        Parser(String s) { this.s = s; }
        boolean end() { return i >= s.length(); }
        char peek() { return end() ? 0 : s.charAt(i); }
        void ws() { while (!end() && Character.isWhitespace(s.charAt(i))) i++; }
        void expect(char c) {
            ws();
            if (end() || s.charAt(i) != c)
                throw new IllegalArgumentException("expected '" + c + "' at " + i + " of " + s);
            i++;
        }
        Map<String, Object> object() {
            Map<String, Object> out = new LinkedHashMap<String, Object>();
            expect('{');
            ws();
            if (peek() == '}') { i++; return out; }
            for (;;) {
                String key = (String) value();
                if (!(key instanceof String)) throw new IllegalArgumentException("bad key");
                expect(':');
                out.put(key, value());
                ws();
                if (peek() == ',') { i++; continue; }
                expect('}');
                return out;
            }
        }
        Object value() {
            ws();
            char c = peek();
            if (c == '"') return string();
            if (c == '{') return object();
            if (c == '[') return array();
            if (c == 't' || c == 'f') return bool();
            if (c == 'n') { literal("null"); return null; }
            return number();
        }
        List<Object> array() {
            List<Object> out = new ArrayList<Object>();
            expect('[');
            ws();
            if (peek() == ']') { i++; return out; }
            for (;;) {
                out.add(value());
                ws();
                if (peek() == ',') { i++; continue; }
                expect(']');
                return out;
            }
        }
        String string() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (!end()) {
                char c = s.charAt(i++);
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    if (end()) break;
                    char e = s.charAt(i++);
                    switch (e) {
                    case 'u':
                        sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                        i += 4;
                        break;
                    case 'n': sb.append('\n'); break;
                    case 't': sb.append('\t'); break;
                    case 'r': sb.append('\r'); break;
                    case 'b': sb.append('\b'); break;
                    case 'f': sb.append('\f'); break;
                    default: sb.append(e);
                    }
                } else {
                    sb.append(c);
                }
            }
            throw new IllegalArgumentException("unterminated string");
        }
        void literal(String lit) {
            if (!s.startsWith(lit, i)) throw new IllegalArgumentException("bad literal at " + i);
            i += lit.length();
        }
        Boolean bool() {
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            literal("false");
            return Boolean.FALSE;
        }
        Number number() {
            int start = i;
            while (!end() && "-+.eE0123456789".indexOf(s.charAt(i)) >= 0) i++;
            if (i == start) throw new IllegalArgumentException("bad value at " + i + " of " + s);
            String text = s.substring(start, i);
            try {
                if (text.indexOf('.') < 0 && text.indexOf('e') < 0 && text.indexOf('E') < 0)
                    return Long.valueOf(text);
                return Double.valueOf(text);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("bad number " + text);
            }
        }
    }

    /* ---------------- JSON writing helpers ---------------- */

    public static void strField(StringBuilder sb, String k, String v) {
        sb.append('"').append(k).append("\":");
        quote(sb, v);
    }

    public static void quote(StringBuilder sb, String s) {
        if (s == null) { sb.append("null"); return; }
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') { sb.append('\\').append(c); }
            else if (c < 0x20) {
                sb.append(String.format("\\u%04x", (int) c));
            } else sb.append(c);
        }
        sb.append('"');
    }
}
