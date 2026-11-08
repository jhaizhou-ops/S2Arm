package org.s2arm.android;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The shell's half of BootSpec v1 (implementation plan §4.1, android/contracts/
 * boot-spec.v1.schema.json): the values only Android knows, put into the one document the
 * runtime freezes before the guest starts. The injection rules agreed in #18:
 * <ul>
 * <li>paths come from Context at run time (multi-user /data/user/&lt;n&gt;, adoptable storage);</li>
 * <li>the cache entry is only the root: the backend derives shader / pipeline domains itself;</li>
 * <li>language is the first system locale's BCP 47 tag; region only when that locale has one;</li>
 * <li>timezone is an IANA name: whole-hour GMT offsets become Etc/GMT∓h, anything else UTC with
 *     a diagnostic;</li>
 * <li>screen is the game surface in pixels, landscape, with the display's density and refresh rate.</li>
 * </ul>
 * No Android types, so the unit test runs on a plain JDK; BootSpecs (in GameLibrary) fills it.
 */
final class BootSpec {
    enum ConsoleMode {
        HANDHELD("handheld", 0), DOCKED("docked", 1);

        final String value;
        final int nativeValue;

        ConsoleMode(String value, int nativeValue) {
            this.value = value;
            this.nativeValue = nativeValue;
        }

        /** Only the original game launch may supply this optional, strictly typed extra. */
        static ConsoleMode forLaunch(boolean coldStart, boolean game, boolean present, Object value) {
            if (!present) return HANDHELD;
            if (!coldStart) throw new IllegalStateException("Console mode is frozen; use a cold start");
            if (!game) throw new IllegalArgumentException("Console mode requires a game cold start");
            return parse(value);
        }

        /** A warm-start extra while a session may run (interface v2.15): same strict values; the
         *  caller decides between the runtime push and deferring to the next cold start. */
        static ConsoleMode forRuntime(boolean game, Object value) {
            if (!game) throw new IllegalArgumentException("Console mode requires a game session");
            return parse(value);
        }

        private static ConsoleMode parse(Object value) {
            if (value instanceof String) {
                for (ConsoleMode mode : values()) if (mode.value.equals(value)) return mode;
            }
            throw new IllegalArgumentException("s2arm.console_mode must be handheld or docked");
        }
    }

    /**
     * 冷启动生产开关 s2arm.mirror=on|off（#1184，owner #1285）：镜像写跟踪是运行时语义改动，
     * 按 docs/协作循环.md 缺省关合入；同包 A/B 只差这一个启动参数。只在游戏冷启动接受，
     * 局内冻结；缺省（没带这个 extra）是 off。
     */
    enum Mirror {
        OFF("off"), ON("on");

        final String value;

        Mirror(String value) {
            this.value = value;
        }

        static Mirror forLaunch(boolean coldStart, boolean game, boolean present, Object value) {
            if (!present) return OFF;
            if (!coldStart) throw new IllegalStateException("Mirror switch is frozen; use a cold start");
            if (!game) throw new IllegalArgumentException("Mirror switch requires a game cold start");
            if (value instanceof String) {
                for (Mirror mirror : values()) if (mirror.value.equals(value)) return mirror;
            }
            throw new IllegalArgumentException("s2arm.mirror must be on or off");
        }
    }

    static final class User {
        String id = "0", language = "en", region, timezone = "UTC";   // region null: none
    }

    static final class Screen {
        int width, height, densityDpi;
        float refreshHz;
    }

    String sessionId;
    BootContract.Game game;
    String gameRoot, userRoot, saveRoot, cacheRoot, logDir;
    /** RuntimeLibrary.json() of this process (diagnostics.runtimeLibrary, a JSON object): which libs2arm_android.so runs. */
    String runtimeLibrary;
    User user = new User();
    Screen screen = new Screen();
    String mode = "diagnostic", network = "offline";
    ConsoleMode consoleMode = ConsoleMode.HANDHELD;
    /** What the normalisation changed or could not keep (logged; not part of the document). */
    final List<String> diagnostics = new ArrayList<>();

    private static final Pattern LANGUAGE = Pattern.compile("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$");
    private static final Pattern REGION = Pattern.compile("^[A-Z]{2}$");
    private static final Pattern IANA = Pattern.compile("^(UTC|[A-Za-z]+(/[A-Za-z0-9_+-]+)+)$");
    private static final Pattern GMT_OFFSET = Pattern.compile("^GMT([+-])(\\d{1,2}):?(\\d{2})?$");

    /** A BCP 47 language tag the schema accepts, or "en" (recorded) when the system gave none usable. */
    String language(String tag) {
        if (tag != null && LANGUAGE.matcher(tag).matches() && !tag.equals("und")) return tag;
        diagnostics.add("language '" + tag + "' unusable, en");
        return "en";
    }

    /** The locale's region when it has one (ISO 3166 alpha-2); otherwise none, and the shared layer defaults it. */
    static String region(String country) {
        return country != null && REGION.matcher(country).matches() ? country : null;
    }

    /**
     * An IANA name for the system time zone (already canonicalised by the caller where the
     * platform can). A custom "GMT+08:00" id becomes "Etc/GMT-8" (POSIX sign: east of Greenwich is
     * negative); a non-whole-hour or unrecognised id becomes "UTC", recorded as a diagnostic.
     */
    String timezone(String id) {
        if (id != null && IANA.matcher(id).matches()) return id;
        if ("GMT".equals(id)) return "UTC";
        Matcher m = id == null ? null : GMT_OFFSET.matcher(id);
        if (m != null && m.matches()) {
            int hours = Integer.parseInt(m.group(2));
            boolean whole = m.group(3) == null || m.group(3).equals("00");
            if (hours == 0 && whole) return "UTC";
            if (whole && hours <= 14) return "Etc/GMT" + (m.group(1).equals("+") ? "-" : "+") + hours;
        }
        diagnostics.add("time zone '" + id + "' has no IANA name, UTC");
        return "UTC";
    }

    String toJson() {
        if (consoleMode == null) throw new IllegalArgumentException("Console mode is required");
        StringBuilder j = new StringBuilder("{\n");
        field(j, 1, "version", 1);
        field(j, 1, "sessionId", sessionId);
        field(j, 1, "titleId", game.titleId);
        field(j, 1, "contentRoot", game.contentRoot);
        field(j, 1, "gameRoot", gameRoot);
        field(j, 1, "revisionDir", game.revisionDir);
        field(j, 1, "artifact", game.artifact);
        field(j, 1, "artifactSha256", game.artifactSha256);
        j.append(" \"user\": {\n");
        field(j, 2, "id", user.id);
        field(j, 2, "language", user.language);
        if (user.region != null) field(j, 2, "region", user.region);
        last(j, 2, "timezone", quote(user.timezone));
        j.append(" },\n \"screen\": {\n");
        field(j, 2, "width", screen.width);
        field(j, 2, "height", screen.height);
        field(j, 2, "densityDpi", screen.densityDpi);
        last(j, 2, "refreshHz", String.format(Locale.ROOT, "%.3f", screen.refreshHz));
        j.append(" },\n \"paths\": {\n");
        field(j, 2, "userRoot", userRoot);
        field(j, 2, "saveRoot", saveRoot);
        last(j, 2, "cacheRoot", quote(cacheRoot));
        j.append(" },\n");
        field(j, 1, "mode", mode);
        if (logDir != null || runtimeLibrary != null) {
            j.append(" \"diagnostics\": {\n");
            if (logDir != null) {
                if (runtimeLibrary == null) last(j, 2, "logDir", quote(logDir));
                else field(j, 2, "logDir", logDir);
            }
            if (runtimeLibrary != null) last(j, 2, "runtimeLibrary", runtimeLibrary);
            j.append(" },\n");
        }
        field(j, 1, "consoleMode", consoleMode.value);
        last(j, 1, "network", quote(network));
        return j.append("}\n").toString();
    }

    private static void field(StringBuilder j, int indent, String key, Object value) {
        indent(j, indent).append('"').append(key).append("\": ")
         .append(value instanceof String ? quote((String) value) : String.valueOf(value)).append(",\n");
    }

    private static void last(StringBuilder j, int indent, String key, String json) {
        indent(j, indent).append('"').append(key).append("\": ").append(json).append('\n');
    }

    private static StringBuilder indent(StringBuilder j, int n) {   // String.repeat needs API 33
        for (int i = 0; i < n; i++) j.append(' ');
        return j;
    }

    static String quote(String s) {
        StringBuilder q = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') q.append('\\').append(c);
            else if (c < 0x20) q.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
            else q.append(c);
        }
        return q.append('"').toString();
    }
}
