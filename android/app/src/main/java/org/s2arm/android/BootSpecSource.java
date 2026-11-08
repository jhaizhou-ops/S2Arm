package org.s2arm.android;

import android.content.Context;
import android.graphics.Point;
import android.hardware.display.DisplayManager;
import android.os.LocaleList;
import android.view.Display;
import java.io.File;
import java.util.Locale;
import java.util.TimeZone;
import java.util.UUID;

/**
 * Fills BootSpec from the system: private paths from Context, the first system locale, the
 * system time zone (ICU's canonical id), the default display. Until the session start path
 * freezes it with the prepared surface (§8.2), the screen is the display's full size in landscape.
 */
final class BootSpecSource {
    private BootSpecSource() { }

    static BootSpec build(Context context, File gamesDir, BootContract.Game game) {
        BootSpec spec = new BootSpec();
        spec.sessionId = UUID.randomUUID().toString();
        spec.game = game;
        spec.gameRoot = new File(gamesDir, game.titleId).getAbsolutePath();
        File user = new File(context.getFilesDir(), "user/0");
        spec.userRoot = user.getAbsolutePath();
        spec.saveRoot = new File(user, "saves/" + game.titleId).getAbsolutePath();
        spec.cacheRoot = context.getCacheDir().getAbsolutePath();
        spec.logDir = new File(context.getFilesDir(), "logs").getAbsolutePath();
        spec.runtimeLibrary = NativeBridge.loaded().json();
        spec.mode = context.getPackageName().startsWith("org.s2arm.game.") ? "game" : "diagnostic";
        user(spec);

        Display display = context.getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY);
        Point size = new Point();
        display.getRealSize(size);   // the whole panel; the real surface comes with the session start
        spec.screen.width = Math.max(size.x, size.y);
        spec.screen.height = Math.min(size.x, size.y);
        spec.screen.densityDpi = context.getResources().getDisplayMetrics().densityDpi;
        spec.screen.refreshHz = display.getRefreshRate();
        return spec;
    }

    /** The user values (first system locale, system time zone) by BootSpec's rules: also what HostApi's user table freezes. */
    static void user(BootSpec spec) {
        Locale locale = LocaleList.getDefault().get(0);
        spec.user.language = spec.language(locale.toLanguageTag());
        spec.user.region = BootSpec.region(locale.getCountry());
        String zone = TimeZone.getDefault().getID();
        String canonical = android.icu.util.TimeZone.getCanonicalID(zone);
        spec.user.timezone = spec.timezone(canonical != null ? canonical : zone);
    }
}
