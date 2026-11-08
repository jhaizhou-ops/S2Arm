package org.s2arm.android;

public final class ThreadedRendererConfigTest {
    private static void expect(String expected, boolean present, Object value) {
        String actual = ThreadedRendererConfig.resolve(present, value);
        if (!expected.equals(actual)) throw new AssertionError("expected " + expected + ", got " + actual);
    }

    private static void reject(Object value) {
        try {
            ThreadedRendererConfig.resolve(true, value);
        } catch (IllegalStateException expected) {
            return;
        }
        throw new AssertionError("accepted invalid value: " + value);
    }

    public static void main(String[] args) {
        expect("1", false, null);
        expect("0", true, false);
        expect("0", true, "false");
        expect("0", true, "0");
        expect("1", true, true);
        expect("1", true, "true");
        expect("1", true, "1");
        expect("auto", true, "auto");
        reject(null);
        reject(0);
        reject("");
        reject(" 0");
        reject("yes");
        System.out.println("ThreadedRendererConfigTest: passed");
    }
}
