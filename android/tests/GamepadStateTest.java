package org.s2arm.android;

public final class GamepadStateTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Gamepad state mismatch");
    }
    public static void main(String[] args) {
        GamepadState pad = new GamepadState();
        pad.button(0, true); pad.button(6, true);
        pad.motion(0.05f, -1f, 2f, Float.NaN, -1f, 1f, 1f, 0f, 0.15f);
        check(pad.leftX() == 0 && pad.leftY() == 32767);
        check(pad.rightX() == 32767 && pad.rightY() == 0);
        check(pad.buttons() == ((1 << 0) | (1 << 6) | (1 << 8) | (1 << 12) | (1 << 15)));
        // Releasing a key must not clear an independently held hat or trigger.
        pad.button(12, true); pad.button(12, false);
        check((pad.buttons() & (1 << 12)) != 0);
        pad.motion(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0.15f);
        check(pad.buttons() == ((1 << 0) | (1 << 6)));
        pad.reset();
        check(pad.buttons() == 0 && pad.leftX() == 0 && pad.leftY() == 0
            && pad.rightX() == 0 && pad.rightY() == 0);

        // MainActivity passes Android A/B/X/Y as positional Npad bits 1/0/3/2.
        int[] faceBits = {1, 0, 3, 2};
        for (int bit : faceBits) {
            pad.button(bit, true); check(pad.buttons() == 1 << bit);
            pad.button(bit, false); check(pad.buttons() == 0);
        }
        pad.setMapping("label");
        for (int i = 0; i < faceBits.length; i++) {
            pad.button(faceBits[i], true); check(pad.buttons() == 1 << i);
            pad.button(faceBits[i], false); check(pad.buttons() == 0);
        }
        for (int bit = 4; bit < 16; bit++) {
            pad.button(bit, true); check(pad.buttons() == 1 << bit);
            pad.button(bit, false); check(pad.buttons() == 0);
        }
        pad.button(1, true); pad.button(3, true); pad.button(6, true);
        pad.motion(-1f, 1f, 1f, -1f, -1f, 0f, 0f, 1f, 0.15f);
        check(pad.buttons() == (1 | 4 | 64 | 512 | 4096));
        check(pad.leftX() == -32767 && pad.leftY() == -32767
            && pad.rightX() == 32767 && pad.rightY() == 32767);
        pad.setMapping("position");
        check(pad.buttons() == (2 | 8 | 64 | 512 | 4096));
        pad.setMapping("label");
        pad.button(1, false); pad.button(3, false);
        check(pad.buttons() == (64 | 512 | 4096));
        pad.reset();
        pad.button(1, true); check(pad.buttons() == 1); // focus reset retains mapping
        pad.setMapping("label"); check(pad.buttons() == 1); // repeated request retains held keys
        for (String invalid : new String[] {null, "", "labels", "LABEL", " label", "position "}) {
            try {
                pad.setMapping(invalid);
                throw new AssertionError("Invalid mapping accepted: " + invalid);
            } catch (IllegalArgumentException expected) {
                check(pad.buttons() == 1);
            }
        }
        pad.setMapping("position");
        pad.button(1, false); check(pad.buttons() == 0);
        System.out.println("Android gamepad: Npad mapping, axis direction, clamping, independent sources, reset passed");
    }
}
