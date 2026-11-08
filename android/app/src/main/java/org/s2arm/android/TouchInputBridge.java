package org.s2arm.android;

/** Experimental touch transport, independent of the core/HostApi bridge; bound to the library NativeBridge.load loaded. */
final class TouchInputBridge {
    private TouchInputBridge() { }
    static native int touchEnable(boolean enabled);
    static native int touchFrame(int[] points, int count, int flags, long timestampNs,
                                 long generation, long revision);
    static native int touchViewport(long[] geometry);
    static native void touchViewportRevoke();
    static native void touchViewportRetire();
    static native void touchTrace(boolean enabled);
}
