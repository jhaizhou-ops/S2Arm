package org.s2arm.android;

public final class FrameRateSampleTest {
    static void check(boolean ok) { if (!ok) throw new AssertionError(); }
    public static void main(String[] args) {
        FrameRateSample sample = new FrameRateSample();
        check(Double.isNaN(sample.sample(100, 1_000_000_000L)));
        check(sample.sample(130, 2_000_000_000L) == 30.0);
        check(sample.sample(130, 3_000_000_000L) == 0.0);
        check(sample.sample(160, 5_000_000_000L) == 15.0);
        sample.reset();
        check(Double.isNaN(sample.sample(200, 8_000_000_000L)));
        check(Double.isNaN(sample.sample(0, 9_000_000_000L)));
        check(Double.isNaN(sample.sample(-1, 10_000_000_000L)));
        check(Double.isNaN(sample.sample(1, 11_000_000_000L)));
        check(Double.isNaN(sample.sample(2, 11_000_000_000L)));
        System.out.println("PASS FPS sampling: 9 checks including stall, pause, clock and producer reset");
    }
}
