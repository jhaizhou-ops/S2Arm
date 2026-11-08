// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.probe.savecommit.moongrant;

import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Process;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** Same-package, no-UI entry. Native status and unchanged suite assertions are authoritative. */
public abstract class ProbeInstrumentation extends Instrumentation {
    private static File evidenceFile;
    protected abstract String suiteName();
    protected abstract String libraryName();
    protected abstract int execute(String ownedRunDirectory);

    // JNI resolves this inherited static method on the concrete suite class.
    protected static synchronized void nativeEvidence(String message) {
        try (FileOutputStream out = new FileOutputStream(evidenceFile, true)) {
            out.write((message + "\n").getBytes(StandardCharsets.UTF_8));
            out.flush();
            out.getFD().sync();
        } catch (java.io.IOException error) {
            throw new IllegalStateException("Cannot persist own test evidence", error);
        }
    }

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start(); // Framework instrumentation thread, not an Activity/UI thread.
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        result.putString("suite", suiteName());
        result.putInt("uid", Process.myUid());
        try {
            if (!"org.s2arm.probe.savecommit.moongrant".equals(getTargetContext().getPackageName())) {
                throw new IllegalStateException("Unexpected instrumentation target");
            }
            File run = new File(getTargetContext().getFilesDir(), suiteName() + "-" + System.nanoTime());
            if (!run.mkdir()) throw new IllegalStateException("Cannot create own run directory");
            evidenceFile = new File(run, "harness.log");
            result.putString("run_directory", run.getAbsolutePath());
            nativeEvidence("state=JAVA_CREATED\nharness=instrumentation_no_ui\nuid=" + Process.myUid()
                + "\nabsolute=" + run.getAbsolutePath() + "\ncanonical=" + run.getCanonicalPath());
            System.loadLibrary(libraryName());
            nativeEvidence("state=JAVA_BEFORE_NATIVE");
            int rc = execute(run.getAbsolutePath());
            nativeEvidence("state=JAVA_RETURNED\nwrapper_return_code=" + rc);
            result.putString("harness_state", "JNI_RETURNED");
            result.putInt("wrapper_return_code", rc);
            finish(rc == 0 ? -1 : 0, result); // RESULT_OK / RESULT_CANCELED; rc also explicit.
        } catch (Throwable error) {
            String trace = android.util.Log.getStackTraceString(error);
            if (evidenceFile != null) {
                try { nativeEvidence("state=JAVA_EXCEPTION\nexception=" + trace); }
                catch (Throwable loggingError) { android.util.Log.e("S2ArmProbe", "Evidence write failed", loggingError); }
            }
            result.putString("harness_state", "EXCEPTION");
            result.putString("exception", trace);
            finish(0, result);
        }
    }
}
