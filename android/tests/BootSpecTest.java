package org.s2arm.android;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Collections;

/**
 * Plain Java checks of the shell's BootSpec (time zone and language rules, JSON). With an output
 * directory argument it writes boot-spec-region.json / boot-spec-noregion.json for
 * contracts/validate.py to check against boot-spec.v1.schema.json (test.sh does).
 */
public final class BootSpecTest {
    private static int failures;
    private static int checks;

    private static void check(boolean ok, String what) {
        checks++;
        if (!ok) { System.err.println("FAILED: " + what); failures++; }
    }

    private static void rejects(Runnable action, Class<? extends RuntimeException> type, String what) {
        try {
            action.run();
            check(false, what);
        } catch (RuntimeException error) {
            check(type.isInstance(error) && (error.getMessage().contains("Console mode")
                || error.getMessage().contains("s2arm.console_mode")), what);
        }
    }

    private static void rejectsMirror(Runnable action, Class<? extends RuntimeException> type, String what) {
        try {
            action.run();
            check(false, what);
        } catch (RuntimeException error) {
            check(type.isInstance(error) && (error.getMessage().contains("Mirror")
                || error.getMessage().contains("s2arm.mirror")), what);
        }
    }

    private static BootSpec spec() {
        BootSpec s = new BootSpec();
        s.sessionId = "3f2c1a9e-7b6d-4c8f-9a10-2d4e6f8a0b1c";
        String root = "sha256-" + "ab".repeat(32);
        s.game = new BootContract.Game("0100000000ABCDEF", root, "revisions/" + root, "game-build-artifact.json", "cd".repeat(32),
            BootContract.REWRITE_ABI, "0.1.0", "vulkan", "exefs/main.npdm", "ctl/control.nacp", "romfs", "modules", 8, 4096,
            Collections.emptyList(), null, null);
        s.gameRoot = "/data/user/10/org.s2arm.android/files/games/0100000000ABCDEF";
        s.userRoot = "/data/user/10/org.s2arm.android/files/user/0";
        s.saveRoot = s.userRoot + "/saves/0100000000ABCDEF";
        s.cacheRoot = "/data/user/10/org.s2arm.android/cache";
        s.logDir = "/data/user/10/org.s2arm.android/files/logs";
        s.screen.width = 2712; s.screen.height = 1220; s.screen.densityDpi = 520; s.screen.refreshHz = 120.0f;
        return s;
    }

    public static void main(String[] args) throws Exception {
        BootSpec s = spec();
        check(s.consoleMode == BootSpec.ConsoleMode.HANDHELD, "product default remains handheld");
        check(BootSpec.ConsoleMode.forLaunch(true, true, false, null) == BootSpec.ConsoleMode.HANDHELD,
            "missing cold extra uses handheld");
        for (BootSpec.ConsoleMode mode : BootSpec.ConsoleMode.values()) {
            BootSpec.ConsoleMode selected = BootSpec.ConsoleMode.forLaunch(true, true, true, mode.value);
            check(selected == mode && selected.nativeValue == (mode == BootSpec.ConsoleMode.DOCKED ? 1 : 0),
                "exact cold mode accepted: " + mode.value);
            rejects(() -> BootSpec.ConsoleMode.forLaunch(false, true, true, mode.value), IllegalStateException.class,
                "hot extra rejected even when unchanged: " + mode.value);
            rejects(() -> BootSpec.ConsoleMode.forLaunch(true, false, true, mode.value), IllegalArgumentException.class,
                "diagnostic extra rejected: " + mode.value);
        }
        for (Object bad : new Object[] {null, "", "Docked", "DOCKED", " handheld", "docked ", "auto", 0, 1, true,
                new StringBuilder("docked")}) {
            rejects(() -> BootSpec.ConsoleMode.forLaunch(true, true, true, bad), IllegalArgumentException.class,
                "invalid cold mode rejected: " + bad);
        }
        check(BootSpec.ConsoleMode.forLaunch(false, true, false, null) == BootSpec.ConsoleMode.HANDHELD,
            "ordinary new intent has no mode request");
        // Interface v2.15 runtime switch: forRuntime shares forLaunch's strict value parsing; the
        // session-running gate lives in MainActivity (Android-side, not unit-testable here).
        for (BootSpec.ConsoleMode mode : BootSpec.ConsoleMode.values()) {
            check(BootSpec.ConsoleMode.forRuntime(true, mode.value) == mode
                && mode.nativeValue == (mode == BootSpec.ConsoleMode.DOCKED ? 1 : 0),
                "runtime mode accepted: " + mode.value);
        }
        for (Object bad : new Object[] {null, "", "Docked", "DOCKED", " handheld", "docked ", "auto", 0, 1, true,
                new StringBuilder("docked")}) {
            rejects(() -> BootSpec.ConsoleMode.forRuntime(true, bad), IllegalArgumentException.class,
                "invalid runtime mode rejected: " + bad);
        }
        rejects(() -> BootSpec.ConsoleMode.forRuntime(false, "docked"), IllegalArgumentException.class,
            "runtime mode without a game rejected");
        check(BootSpec.Mirror.forLaunch(true, true, false, null) == BootSpec.Mirror.OFF,
            "missing s2arm.mirror stays off (production default)");
        check(BootSpec.Mirror.forLaunch(true, true, true, "off") == BootSpec.Mirror.OFF
            && BootSpec.Mirror.forLaunch(true, true, true, "on") == BootSpec.Mirror.ON,
            "cold s2arm.mirror on/off accepted");
        check(BootSpec.Mirror.forLaunch(false, true, false, null) == BootSpec.Mirror.OFF,
            "ordinary new intent has no mirror request");
        rejectsMirror(() -> BootSpec.Mirror.forLaunch(false, true, true, "on"), IllegalStateException.class,
            "hot mirror extra rejected even when unchanged");
        rejectsMirror(() -> BootSpec.Mirror.forLaunch(true, false, true, "on"), IllegalArgumentException.class,
            "mirror extra rejected outside a game cold start");
        for (Object bad : new Object[] {null, "", "ON", "On", " on", "on ", "1", 0, 1, true,
                new StringBuilder("on")}) {
            rejectsMirror(() -> BootSpec.Mirror.forLaunch(true, true, true, bad), IllegalArgumentException.class,
                "invalid s2arm.mirror rejected: " + bad);
        }
        BootSpec invalid = spec(); invalid.consoleMode = null;
        rejects(invalid::toJson, IllegalArgumentException.class, "null serialized mode rejected");
        check(s.timezone("Asia/Shanghai").equals("Asia/Shanghai"), "IANA kept");
        check(s.timezone("America/Argentina/Buenos_Aires").equals("America/Argentina/Buenos_Aires"), "three-part IANA kept");
        check(s.timezone("America/Port-au-Prince").equals("America/Port-au-Prince"), "hyphen kept");
        check(s.timezone("UTC").equals("UTC") && s.timezone("GMT").equals("UTC") && s.timezone("GMT+00:00").equals("UTC"), "UTC forms");
        check(s.timezone("GMT+08:00").equals("Etc/GMT-8"), "GMT+08:00 -> Etc/GMT-8 (POSIX sign)");
        check(s.timezone("GMT-05:00").equals("Etc/GMT+5") && s.timezone("GMT-5").equals("Etc/GMT+5"), "GMT-05:00 -> Etc/GMT+5");
        check(s.diagnostics.isEmpty(), "no diagnostics yet: " + s.diagnostics);
        check(s.timezone("GMT+05:30").equals("UTC") && s.diagnostics.size() == 1, "half-hour offset -> UTC with a diagnostic");
        check(s.timezone(null).equals("UTC") && s.timezone("").equals("UTC") && s.timezone("Local Time").equals("UTC"), "unusable ids -> UTC");
        check(s.language("zh-Hans-CN").equals("zh-Hans-CN") && s.language("en").equals("en"), "BCP 47 kept");
        check(s.language("und").equals("en") && s.language("").equals("en"), "unusable language -> en");
        check("CN".equals(BootSpec.region("CN")) && BootSpec.region("") == null && BootSpec.region("419") == null, "region");
        check(BootSpec.quote("a\"b\\c\n").equals("\"a\\\"b\\\\c\\u000a\""), "JSON escaping");

        BootSpec with = spec();
        with.user.language = "zh-Hans-CN"; with.user.region = "CN"; with.user.timezone = "Asia/Shanghai";
        BootSpec without = spec();
        without.user.language = "en"; without.user.timezone = "Etc/GMT-8";
        without.consoleMode = BootSpec.ConsoleMode.DOCKED;
        check(with.toJson().contains("\"region\": \"CN\"") && !without.toJson().contains("region"), "region only when the locale has one");
        check("handheld".equals(Json.object(Json.parse(with.toJson()), "BootSpec").get("consoleMode"))
            && "docked".equals(Json.object(Json.parse(without.toJson()), "BootSpec").get("consoleMode")),
            "both actual JSON modes match the wire contract");
        with.runtimeLibrary = "{\"kind\": \"apk\"}";
        BootSpec dev = spec();
        dev.runtimeLibrary = "{\"kind\": \"dev-override\", \"sha256\": \"" + "1a".repeat(32) + "\", \"baseApkSha256\": \""
            + "2b".repeat(32) + "\", \"sourceCommit\": \"" + "3c".repeat(20) + "\", \"dirty\": true, \"diffSha256\": \""
            + "4d".repeat(32) + "\", \"ilcConfig\": \"Release\", \"aotHost\": \"linux-arm64\"}";
        java.util.Map<String, Object> diagnostics = Json.object(Json.object(Json.parse(dev.toJson()), "BootSpec").get("diagnostics"), "diagnostics");
        java.util.Map<String, Object> library = Json.object(diagnostics.get("runtimeLibrary"), "runtimeLibrary");
        check("dev-override".equals(library.get("kind")) && Boolean.TRUE.equals(library.get("dirty"))
            && dev.logDir.equals(diagnostics.get("logDir")), "diagnostics carries the runtime library object next to logDir");
        check("apk".equals(Json.object(Json.object(Json.object(Json.parse(with.toJson()), "BootSpec").get("diagnostics"),
            "diagnostics").get("runtimeLibrary"), "runtimeLibrary").get("kind")), "the APK's library is named too");
        check(!without.toJson().contains("runtimeLibrary"), "no runtime library when none was set");
        if (args.length == 1) {
            File out = new File(args[0]);
            out.mkdirs();
            Files.write(new File(out, "boot-spec-region.json").toPath(), with.toJson().getBytes(StandardCharsets.UTF_8));
            Files.write(new File(out, "boot-spec-noregion.json").toPath(), without.toJson().getBytes(StandardCharsets.UTF_8));
            Files.write(new File(out, "boot-spec-dev-override.json").toPath(), dev.toJson().getBytes(StandardCharsets.UTF_8));
        }
        if (failures > 0) System.exit(1);
        System.out.println("BootSpec: " + checks + " checks PASS (host only; no Activity/runtime execution)");
    }
}
