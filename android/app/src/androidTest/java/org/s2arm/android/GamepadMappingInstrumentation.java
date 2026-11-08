package org.s2arm.android;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.InputDevice;
import android.view.KeyEvent;

/** Real diagnostic Activity / preferences; software events do not certify a physical controller. */
public final class GamepadMappingInstrumentation extends Instrumentation {
    private MainActivity activity;
    private int checks;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    private void check(boolean value, String why) {
        checks++;
        if (!value) throw new AssertionError(why);
    }

    private int buttons() throws Exception {
        java.lang.reflect.Field field = MainActivity.class.getDeclaredField("gamepad");
        field.setAccessible(true);
        GamepadState pad = (GamepadState) field.get(activity);
        int[] result = new int[1];
        runOnMainSync(() -> result[0] = pad.buttons());
        return result[0];
    }

    private void key(int code, boolean down) {
        runOnMainSync(() -> {
            KeyEvent event = new KeyEvent(0, 0, down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
                code, 0, 0, -1, 0, 0, InputDevice.SOURCE_GAMEPAD);
            check(activity.dispatchKeyEvent(event), "gamepad event consumed");
        });
    }

    private void deliver(Intent intent) {
        intent.setClass(getTargetContext(), MainActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        getTargetContext().startActivity(intent);
        waitForIdleSync();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        SharedPreferences prefs = getTargetContext().getSharedPreferences("s2a", 0);
        String original = prefs.getString("gamepadMapping", null);
        try {
            check(getTargetContext().getPackageName().equals("org.s2arm.android"), "diagnostic APK only");
            check(prefs.edit().remove("gamepadMapping").commit(), "clear only mapping preference");
            Intent launch = new Intent(getTargetContext(), MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("s2arm.touchlog", "on")
                .putExtra("s2arm.touchpad", "off");
            activity = (MainActivity) startActivitySync(launch);
            waitForIdleSync();
            int[] codes = {KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_B,
                KeyEvent.KEYCODE_BUTTON_X, KeyEvent.KEYCODE_BUTTON_Y};
            int[][] expected = {{2, 1, 8, 4}, {1, 2, 4, 8}};
            for (int mode = 0; mode < 2; mode++) {
                if (mode == 1) deliver(new Intent().putExtra("s2arm.gamemap", "label"));
                for (int i = 0; i < codes.length; i++) {
                    key(codes[i], true);
                    check(buttons() == expected[mode][i], "face button mode=" + mode + " index=" + i);
                    key(codes[i], false);
                    check(buttons() == 0, "released face button");
                }
            }
            key(codes[0], true);
            deliver(new Intent().putExtra("s2arm.gamemap", "position"));
            // Android pauses a resumed Activity before onNewIntent; onPause must release held input.
            check(buttons() == 0, "Intent pause clears held A");
            check("position".equals(prefs.getString("gamepadMapping", null)), "position saved while held");
            key(codes[0], false);
            key(codes[0], true);
            check(buttons() == 2, "new press uses position");
            deliver(new Intent().putExtra("s2arm.gamemap", "label"));
            check(buttons() == 0, "second Intent pause clears held A");
            key(codes[0], false);
            key(codes[0], true);
            check(buttons() == 1, "new press uses label");
            key(codes[0], false);
            check(buttons() == 0, "switch then release clears input");
            for (Intent invalid : new Intent[] {new Intent().putExtra("s2arm.gamemap", "LABEL"),
                    new Intent().putExtra("s2arm.gamemap", 1)}) {
                deliver(invalid);
                check("label".equals(prefs.getString("gamepadMapping", null)), "invalid request not saved");
                key(codes[0], true);
                check(buttons() == 1, "invalid request keeps mapping");
                key(codes[0], false);
            }
            check("label".equals(activity.getIntent().getStringExtra("s2arm.gamemap")), "launch intent updated");
            ActivityMonitor monitor = addMonitor(MainActivity.class.getName(), null, false);
            MainActivity previous = activity;
            runOnMainSync(() -> previous.recreate());
            Activity next = monitor.waitForActivityWithTimeout(10000);
            removeMonitor(monitor);
            check(next instanceof MainActivity && next != previous, "Activity recreated");
            activity = (MainActivity) next;
            waitForIdleSync();
            key(codes[0], true);
            check(buttons() == 1, "recreation retains label");
            key(codes[0], false);
            deliver(new Intent().putExtra("s2arm.touchlog", "on"));
            key(codes[0], true);
            check(buttons() == 1, "no mapping extra retains label");
            key(codes[0], false);
            result.putString("stream", "Gamepad mapping: " + checks + " checks passed; software events only\n");
            result.putBoolean("passed", true);
        } catch (Throwable error) {
            result.putString("stream", android.util.Log.getStackTraceString(error));
            result.putBoolean("passed", false);
        } finally {
            if (activity != null) runOnMainSync(() -> activity.finish());
            SharedPreferences.Editor restore = prefs.edit();
            if (original == null) restore.remove("gamepadMapping");
            else restore.putString("gamepadMapping", original);
            restore.commit();
        }
        finish(result.getBoolean("passed") ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }
}
