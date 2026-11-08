package org.s2arm.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Handler;
import android.os.Looper;
import android.text.InputFilter;
import android.text.InputType;
import android.view.WindowManager;
import android.widget.EditText;
import org.json.JSONObject;
import org.json.JSONException;
import java.nio.charset.StandardCharsets;

/** Foreground keyboard producer. No guest wait or reply text logging on the UI thread. */
final class HostKeyboard {
    private final Activity activity;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final long[] requestId = new long[1];
    private long generation;
    private AlertDialog dialog;
    private final Runnable poll = new Runnable() {
        @Override public void run() {
            if (generation == 0) return;
            if (dialog == null) {
                byte[] request = NativeBridge.takeHostUi(generation, requestId);
                if (request != null) show(requestId[0], request);
            }
            if (generation != 0) handler.postDelayed(this, 100);
        }
    };
    HostKeyboard(Activity activity) { this.activity = activity; }
    void resume() {
        if (generation != 0) return;
        generation = NativeBridge.attachHostUi();
        if (generation != 0) handler.post(poll);
    }
    void pause() {
        handler.removeCallbacks(poll);
        long old = generation;
        generation = 0;
        if (old != 0) NativeBridge.detachHostUi(old);
        if (dialog != null) { dialog.setOnCancelListener(null); dialog.dismiss(); dialog = null; }
    }
    private void reply(long owner, long id, String status, String text) {
        if (generation == 0 || generation != owner) return;
        try {
            JSONObject response = new JSONObject();
            response.put("version", 1); response.put("type", "software-keyboard");
            response.put("status", status);
            if (text != null) response.put("text", text);
            int result = NativeBridge.completeHostUi(owner, id, response.toString().getBytes(StandardCharsets.UTF_8));
            android.util.Log.i("S2Arm", "Keyboard request completed: " + status + ", result=" + result);
        } catch (JSONException impossible) { throw new IllegalStateException(impossible); }
    }
    private void show(long id, byte[] bytes) {
        long owner = generation;
        final boolean[] completed = {false};
        java.util.function.BiConsumer<String, String> complete = (status, text) -> {
            if (!completed[0]) { completed[0] = true; reply(owner, id, status, text); }
        };
        try {
            JSONObject request = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            if (request.getInt("version") != 1 || !request.getString("type").equals("software-keyboard"))
                throw new IllegalArgumentException("unsupported UI request");
            int mode = request.getInt("mode"), min = request.getInt("min"), max = request.getInt("max");
            if (mode < 0 || (mode > 3 && mode != 5) || min < 0 || max < min || max > 1024)
                throw new IllegalArgumentException("unsupported keyboard constraints");
            EditText input = new EditText(activity);
            input.setSingleLine(true);
            input.setInputType(mode == 1 ? InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL
                : InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
            // A language request is an IME hint, not a global keyboard/locale change.
            if (mode == 5) input.setImeHintLocales(android.os.LocaleList.forLanguageTags("zh-Hans"));
            input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(max)});
            input.setHint(request.getString("guide"));
            input.setText(request.getString("initial"));
            input.setSelection(input.length());
            String title = request.getString("header"), subtitle = request.getString("subtitle");
            String submit = request.getString("submit");
            AlertDialog created = new AlertDialog.Builder(activity)
                .setTitle(title.isEmpty() ? "输入文字" : title).setMessage(subtitle)
                .setView(input).setPositiveButton(submit.isEmpty() ? "确定" : submit, null)
                .setNegativeButton("取消", (which, button) -> complete.accept("cancel", null)).create();
            dialog = created;
            created.setCanceledOnTouchOutside(false);
            created.setOnCancelListener(which -> complete.accept("cancel", null));
            created.setOnDismissListener(which -> { android.util.Log.i("S2Arm", "Keyboard dialog dismissed id=" + id); if (dialog == created) dialog = null; complete.accept("cancel", null); });
            created.setOnShowListener(which -> {
                created.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
                    String text = input.getText().toString();
                    if (!valid(text, min, max, mode)) { input.setError("请检查字数和允许输入的字符"); return; }
                    complete.accept("ok", text);
                    created.dismiss();
                });
                input.requestFocus();
                if (created.getWindow() != null)
                    created.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE);
            });
            try {
                created.show();
            } catch (RuntimeException error) {
                if (dialog == created) dialog = null;
                complete.accept("cancel", null);
                android.util.Log.e("S2Arm", "Keyboard dialog could not be shown", error);
                return;
            }
            android.util.Log.i("S2Arm", "Keyboard request shown: mode=" + mode + ", min=" + min + ", max=" + max);
        } catch (JSONException | IllegalArgumentException error) {
            complete.accept("unsupported", null);
        }
    }
    static boolean valid(String text, int min, int max, int mode) {
        if (text.length() < min || text.length() > max) return false;
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (ch == 0 || (mode == 1 && !(ch >= '0' && ch <= '9') && ch != '.') || (mode == 2 && ch > 127)) return false;
            if (Character.isHighSurrogate(ch)) {
                if (++i >= text.length() || !Character.isLowSurrogate(text.charAt(i))) return false;
            } else if (Character.isLowSurrogate(ch)) return false;
        }
        return true;
    }
}
