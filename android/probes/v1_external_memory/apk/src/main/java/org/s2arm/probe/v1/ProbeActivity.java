package org.s2arm.probe.v1;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Runs the V1 probe sections (libv1probe.so) once on a background thread of this app process.
 * JSON lines land in files/v1probe.jsonl and are echoed to logcat (tag S2ArmV1); files/done holds
 * the return code when the run is over.
 */
public final class ProbeActivity extends Activity {
    private static final String TAG = "S2ArmV1";
    private static final String DEFAULT_SECTIONS = "device,ahb,dmabuf,heapcpu,swap_ahb,swap_heap";
    private static final AtomicBoolean STARTED = new AtomicBoolean();

    static {
        System.loadLibrary("v1probe");
    }

    private static native int nativeRun(String outPath, String sections);

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this);
        view.setText("S2Arm V1 probe: running");
        setContentView(view);
        if (!STARTED.compareAndSet(false, true)) return;
        String extra = getIntent().getStringExtra("sections");
        String sections = extra == null || extra.isEmpty() ? DEFAULT_SECTIONS : extra;
        File out = new File(getFilesDir(), "v1probe.jsonl");
        File done = new File(getFilesDir(), "done");
        done.delete();
        new Thread(() -> {
            Log.i(TAG, "START sections=" + sections);
            int rc = nativeRun(out.getPath(), sections);
            try (BufferedReader r = new BufferedReader(new FileReader(out, StandardCharsets.UTF_8))) {
                for (String line; (line = r.readLine()) != null; ) Log.i(TAG, line);
            } catch (IOException e) {
                Log.e(TAG, "read " + out + ": " + e);
            }
            try (FileOutputStream f = new FileOutputStream(done)) {
                f.write(("rc=" + rc + "\n").getBytes(StandardCharsets.UTF_8));
            } catch (IOException e) {
                Log.e(TAG, "write " + done + ": " + e);
            }
            Log.i(TAG, "DONE rc=" + rc);
            runOnUiThread(() -> view.setText("S2Arm V1 probe: done rc=" + rc));
        }, "v1probe").start();
    }
}
