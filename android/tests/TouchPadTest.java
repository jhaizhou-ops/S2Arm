package org.s2arm.android;

/** Plain Java checks for the on-screen pad (no Android runtime). */
public final class TouchPadTest {
    private static int failures;

    private static void check(boolean ok, String what) {
        if (!ok) { System.err.println("FAILED: " + what); failures++; }
    }

    private static TouchPad.Control find(TouchPad pad, int kind, String label, int bit) {
        for (TouchPad.Control c : pad.controls())
            if (c.kind == kind && (kind == TouchPad.BUTTON ? c.label.equals(label) : c.bit == bit)) return c;
        throw new AssertionError(label);
    }

    public static void main(String[] args) {
        TouchPad pad = new TouchPad();
        pad.layout(0, 0, 2400, 1080);
        TouchPad.Control a = find(pad, TouchPad.BUTTON, "A", 0), b = find(pad, TouchPad.BUTTON, "B", 0);
        TouchPad.Control dpad = find(pad, TouchPad.DPAD, "", 0), left = find(pad, TouchPad.STICK, "", 0);

        // Every control inside the view, none overlapping another.
        for (TouchPad.Control c : pad.controls()) {
            check(c.x - c.radius >= 0 && c.x + c.radius <= 2400 && c.y - c.radius >= 0 && c.y + c.radius <= 1080, "inside " + c.label);
            for (TouchPad.Control o : pad.controls())
                if (o != c) check(Math.hypot(c.x - o.x, c.y - o.y) >= c.radius + o.radius, "no overlap " + c.label + "/" + o.label);
        }

        // A press, slide to B (a finger moves between face buttons), release.
        pad.down(1, a.x, a.y);
        check(pad.buttons() == 1, "A pressed");
        pad.move(1, b.x, b.y);
        check(pad.buttons() == 2, "slid to B");
        pad.up(1);
        check(pad.buttons() == 0, "released");

        // D-pad: centre is neutral, up-right presses two directions.
        pad.down(2, dpad.x, dpad.y);
        check(pad.buttons() == 0, "dpad dead zone");
        pad.move(2, dpad.x + dpad.radius * 0.6f, dpad.y - dpad.radius * 0.6f);
        check(pad.buttons() == ((1 << 13) | (1 << 14)), "dpad up-right");
        pad.move(2, dpad.x - dpad.radius * 0.8f, dpad.y);
        check(pad.buttons() == (1 << 12), "dpad left");
        pad.up(2);

        // Left stick: full right, full up (positive), clamped, dead zone; captured while it crosses buttons.
        pad.down(3, left.x, left.y);
        check(pad.leftX() == 0 && pad.leftY() == 0, "stick dead zone");
        pad.move(3, left.x + left.radius, left.y);
        check(pad.leftX() == 32767 && pad.leftY() == 0, "stick right");
        pad.move(3, left.x, left.y - 3 * left.radius);
        check(pad.leftX() == 0 && pad.leftY() == 32767, "stick up, clamped");
        pad.move(3, left.x + left.radius * 0.05f, left.y);
        check(pad.leftX() == 0, "stick small move stays in dead zone");

        // Second finger on A while the stick is held; the stick finger over A does not press it.
        pad.down(4, a.x, a.y);
        check(pad.buttons() == 1 && pad.leftX() == 0, "stick + A");
        pad.move(3, a.x, a.y);
        check(pad.leftX() == 32767 && pad.buttons() == 1, "stick finger keeps the stick");
        pad.cancel();
        check(pad.buttons() == 0 && pad.leftX() == 0 && !pad.active(), "cancel releases everything");

        // Portrait and insets: everything stays inside the area given.
        pad.layout(40, 100, 1080, 2276);
        for (TouchPad.Control c : pad.controls())
            check(c.x - c.radius >= 40 && c.x + c.radius <= 1120 && c.y - c.radius >= 100 && c.y + c.radius <= 2376, "portrait inside " + c.label);

        if (failures > 0) System.exit(1);
        System.out.println("TouchPad: ok");
    }
}
