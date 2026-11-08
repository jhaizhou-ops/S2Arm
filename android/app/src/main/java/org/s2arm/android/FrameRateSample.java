package org.s2arm.android;

/** Rolling interval rate; a stopped producer becomes zero instead of retaining stale FPS. */
final class FrameRateSample {
    private long previousCount = -1, previousNanos;

    void reset() { previousCount = -1; previousNanos = 0; }

    double sample(long count, long nowNanos) {
        if (count < 0) { reset(); return Double.NaN; }
        double value = previousCount >= 0 && count >= previousCount && nowNanos > previousNanos
            ? (count - previousCount) * 1_000_000_000.0 / (nowNanos - previousNanos) : Double.NaN;
        previousCount = count;
        previousNanos = nowNanos;
        return value;
    }
}
