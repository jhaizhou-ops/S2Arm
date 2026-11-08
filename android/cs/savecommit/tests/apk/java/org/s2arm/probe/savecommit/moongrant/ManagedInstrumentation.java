// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.probe.savecommit.moongrant;

/** Separate APP-domain managed primitive test, not the two native suites. */
public final class ManagedInstrumentation extends ProbeInstrumentation {
    private static native int nativeRun(String ownedRunDirectory);
    @Override protected String suiteName() { return "Managed"; }
    @Override protected String libraryName() { return "managed_bridge"; }
    @Override protected int execute(String path) { return nativeRun(path); }
}
