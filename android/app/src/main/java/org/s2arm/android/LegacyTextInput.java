package org.s2arm.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.text.InputFilter;
import android.widget.EditText;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Legacy JNI keyboard bridge. Dialog callbacks run on the Activity UI thread. */
final class LegacyTextInput {
    private final Activity activity;
    private final long timeoutMillis;
    private final Set<Request> pending = new HashSet<>();
    private boolean active;

    private static final class Request {
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicBoolean finished = new AtomicBoolean();
        volatile String result;
        AlertDialog dialog; // UI thread only
    }

    LegacyTextInput(Activity activity) { this(activity, TimeUnit.MINUTES.toMillis(10)); }
    LegacyTextInput(Activity activity, long timeoutMillis) { this.activity = activity; this.timeoutMillis = timeoutMillis; }
    synchronized void resume() { active = true; }
    void pause() {
        ArrayList<Request> requests;
        synchronized (this) { active = false; requests = new ArrayList<>(pending); }
        for (Request request : requests) {
            finish(request, null);
            if (request.dialog != null) request.dialog.dismiss();
        }
    }
    private void finish(Request request, String text) {
        if (!request.finished.compareAndSet(false, true)) return;
        request.result = text;
        synchronized (this) { pending.remove(request); }
        request.done.countDown();
    }
    String request(String title, String initial, int maxChars) {
        Request request = new Request();
        synchronized (this) {
            if (!active) return null;
            pending.add(request);
        }
        try {
            activity.runOnUiThread(() -> show(request, title, initial, maxChars));
            if (!request.done.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
                finish(request, null);
                request.done.await(); // another terminal callback may have won the race
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            finish(request, null);
        } catch (RuntimeException error) {
            finish(request, null);
            android.util.Log.e("S2Arm", "Legacy keyboard request failed", error);
        }
        if (request.result == null) try {
            activity.runOnUiThread(() -> { if (request.dialog != null) request.dialog.dismiss(); });
        } catch (RuntimeException error) {
            android.util.Log.e("S2Arm", "Legacy keyboard dismissal could not be posted", error);
        }
        return request.result;
    }
    private void show(Request request, String title, String initial, int maxChars) {
        synchronized (this) {
            if (!active || request.finished.get() || activity.isFinishing() || activity.isDestroyed()) {
                finish(request, null);
                return;
            }
        }
        try {
            EditText input = new EditText(activity);
            String seed = initial == null ? "" : initial;
            input.setText(seed); input.setSelection(seed.length());
            if (maxChars > 0) input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(maxChars)});
            AlertDialog dialog = new AlertDialog.Builder(activity)
                .setTitle(title == null || title.isEmpty() ? "Enter text" : title)
                .setView(input)
                .setPositiveButton("OK", (which, button) -> finish(request, input.getText().toString()))
                .setNegativeButton("Cancel", (which, button) -> finish(request, null)).create();
            request.dialog = dialog;
            dialog.setOnCancelListener(which -> finish(request, null));
            dialog.setOnDismissListener(which -> { request.dialog = null; finish(request, null); });
            dialog.show();
        } catch (RuntimeException error) {
            request.dialog = null;
            finish(request, null);
            android.util.Log.e("S2Arm", "Legacy keyboard dialog could not be shown", error);
        }
    }
}
