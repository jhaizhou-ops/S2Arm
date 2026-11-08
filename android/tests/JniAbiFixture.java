package org.s2arm.android;

/** Native declarations in the shapes NativeBridge uses, for RuntimeLibraryTest: jni_abi.py (source) == jniAbi (reflection). */
final class JniAbiFixture {
    private JniAbiFixture() { }
    // a comment that mentions static native void notADeclaration(int x); must not count
    /* static native int alsoNot(); */
    static native long plain();
    private static native String hidden();
    static native int many(long host, java.nio.ByteBuffer assets, String[] names,
                           byte[] bytes, long[] ids, final boolean flag, float hz, java.io.File file);
    static native byte[] array(long generation, long[] requestId);
    native static int reordered(int value);
    public static native int varargs(String... names);
    native long instanceNative();
    static native int cStyle(int values[], byte[] rows[]);
    static String text() { return "a string mentioning static native int notOne(); stays out"; }
    static void notNative(int value) { }
}
