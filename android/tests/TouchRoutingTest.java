package org.s2arm.android;

/** Exercises the same routing methods that TouchPadView calls, without Android mocks. */
public final class TouchRoutingTest {
    static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        for (boolean enabled : new boolean[] {false, true}) {
            for (boolean viewport : new boolean[] {false, true}) {
                TouchPad pad = new TouchPad();
                pad.layout(0, 0, 2400, 1080);
                int[] contacts = {0};
                GameTouch game = new GameTouch((points, count, flags, time) -> { contacts[0] += count; return 0; });
                game.enable(enabled);
                if (viewport) game.viewport(1, 1, 0, 0, 2400, 1080);
                for (TouchPad.Control c : pad.controls()) {
                    // Check the expanded edge, not just the visible disc.
                    float scale = c.kind == TouchPad.DPAD ? 1.19f : c.kind == TouchPad.STICK ? 1.24f : 1.1f;
                    float x = c.x + scale * c.radius;
                    TouchRouting.down(pad, game, true, 42, x, c.y);
                    check(!game.owns(42), "edge leaked to game: " + c.label);
                    if (c.kind == TouchPad.BUTTON) check((pad.buttons() & (1 << c.bit)) != 0, "button edge: " + c.label);
                    if (c.kind == TouchPad.DPAD) check((pad.buttons() & (1 << 14)) != 0, "dpad edge");
                    if (c.kind == TouchPad.STICK) check((c.bit == 0 ? pad.leftX() : pad.rightX()) == 32767, "stick edge");
                    game.publish(1);
                    TouchRouting.move(pad, game, 42, 1200, 540);
                    check(!game.owns(42), "control ownership changed on move");
                    TouchRouting.up(pad, game, 42);
                    check(!pad.active() && pad.buttons() == 0, "control not released");
                }
                check(contacts[0] == 0, "control edge entered published touch history");
                TouchRouting.down(pad, game, true, 7, 1200, 540);
                check(game.owns(7) == (enabled && viewport), "free region/viewport routing");
                TouchRouting.up(pad, game, 7);
                TouchPad.Control a = null;
                for (TouchPad.Control c : pad.controls()) if (c.kind == TouchPad.BUTTON && c.bit == 0) a = c;
                TouchRouting.down(pad, game, false, 9, a.x, a.y);
                check(!pad.active(), "hidden control captured DOWN");
                check(game.owns(9) == (enabled && viewport), "hidden controls game ownership");
                TouchRouting.up(pad, game, 9);
                if (enabled && viewport) {
                    TouchRouting.down(pad, game, true, 7, 1200, 540);
                    TouchRouting.down(pad, game, true, 42, a.x + a.radius * 1.1f, a.y);
                    TouchRouting.move(pad, game, 7, a.x, a.y);
                    TouchRouting.up(pad, game, 42);
                    check(game.owns(7) && !game.owns(42) && pad.buttons() == 0, "multi-pointer release/ownership");
                    TouchRouting.up(pad, game, 7);
                }
            }
        }
        System.out.println("TouchRouting: ok");
    }
}
