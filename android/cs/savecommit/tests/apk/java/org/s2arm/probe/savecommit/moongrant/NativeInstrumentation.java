// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.probe.savecommit.moongrant;

public final class NativeInstrumentation extends ProbeInstrumentation {
    private static native int nativeRun(String ownedRunDirectory);
    @Override protected String suiteName() { return "Native"; }
    @Override protected String libraryName() { return "native_suite"; }
    @Override protected int execute(String path) { return nativeRun(path); }
}
