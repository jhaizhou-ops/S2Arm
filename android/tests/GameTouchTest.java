package org.s2arm.android;

/** Exercises the actual routing state and transport snapshots without an Android runtime. */
public final class GameTouchTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        int[] last = new int[80];
        int[] state = new int[3];
        GameTouch touch = new GameTouch((points, count, flags, timestampNs) -> {
            System.arraycopy(points, 0, last, 0, count * 5);
            state[0] = count; state[1] = flags; state[2]++;
            return 0;
        });
        touch.viewport(1, 1, 100, 50, 1000, 500);
        check(!touch.down(42, 600, 300), "default off");
        touch.enable(true);
        check(!touch.down(42, 99, 300), "letterbox rejected");
        check(touch.down(42, 600, 300), "center accepted");
        touch.publish();
        check(last[0] == 42 && last[1] == 32768 && last[2] == 32768, "viewport-relative coordinates");
        touch.down(7, 100, 50);
        touch.move(42, 2000, -50);
        touch.publish();
        check(state[0] == 2 && last[1] == 65535 && last[2] == 0 && last[5] == 7, "stable ownership and clamp");
        touch.up(42); touch.publish();
        check(state[0] == 1 && last[0] == 7, "pointer ID, not pointer index");
        touch.up(7); touch.publish();
        check(state[0] == 0 && state[1] == 0, "normal release");
        touch.down(3, 600, 300); touch.publish();
        touch.viewport(1, 2, 200, 100, 800, 400);
        check(state[0] == 0 && state[1] == GameTouch.CANCEL && !touch.owns(3), "resize cancels");
        touch.revokeViewport();
        touch.viewport(1, 2, 200, 100, 800, 400);
        check(!touch.ready(), "revoked revision cannot resurrect");
        touch.viewport(2, 1, 0, 0, 100, 100);
        touch.viewport(1, 99, 0, 0, 1000, 1000);
        check(!touch.down(3, 200, 200), "old generation ignored");
        touch.down(3, 50, 50); touch.enable(false);
        check(state[1] == GameTouch.CANCEL && !touch.owns(3), "disable cancels");
        touch.enable(true); touch.publish();
        check(state[0] == 0, "re-enable does not replay contacts");
        for (int i = 0; i < 16; i++) touch.down(i, 50, 50);
        try { touch.down(99, 50, 50); throw new AssertionError("overflow accepted"); }
        catch (IllegalStateException expected) { check(state[1] == GameTouch.CANCEL, "overflow cancels explicitly"); }
        GameTouch failed = new GameTouch((points, count, flags, timestampNs) -> -4);
        failed.viewport(1, 1, 0, 0, 100, 100); failed.enable(true); failed.down(1, 50, 50);
        try { failed.publish(); throw new AssertionError("unsupported hidden"); }
        catch (IllegalStateException expected) { check(!failed.enabled(), "transport failure disarms"); }
        System.out.println("GameTouch: viewport, multi-contact, cancel, overflow, failure checks passed");
    }
}
