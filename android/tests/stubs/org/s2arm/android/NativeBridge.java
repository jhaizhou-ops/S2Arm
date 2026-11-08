package org.s2arm.android;

/**
 * Host-test stub of the JNI surface CapProbe.java references, so the
 * orchestration class compiles on a plain JDK. The unit tests inject
 * their own Runner/Publisher; these methods are never invoked and throw
 * if they are.
 */
final class NativeBridge {
    private NativeBridge() { }

    static void configureCapProbe(String dir, String badlist, String appVersion, String helperPath) {
        throw new UnsupportedOperationException("host-test stub");
    }

    static String capProbeArm(String arm, int timeoutMs) {
        throw new UnsupportedOperationException("host-test stub");
    }

    static void capProbePublish(String resultPath) {
        throw new UnsupportedOperationException("host-test stub");
    }
}
