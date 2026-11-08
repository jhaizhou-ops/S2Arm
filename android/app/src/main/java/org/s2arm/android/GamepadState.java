package org.s2arm.android;

/** Npad bit order and signed stick range, matching InputPump / s2a_vpad_read. */
final class GamepadState {
    private boolean labelMapping;
    private int keys;
    private int hat;
    private int triggers;
    private int lx, ly, rx, ry;

    void setMapping(String mode) {
        if ("position".equals(mode)) labelMapping = false;
        else if ("label".equals(mode)) labelMapping = true;
        else throw new IllegalArgumentException("s2arm.gamemap must be position or label: " + mode);
    }

    void button(int bit, boolean down) {
        if (down) keys |= 1 << bit;
        else keys &= ~(1 << bit);
    }

    private static int axis(float value, float deadzone) {
        if (!Float.isFinite(value) || Math.abs(value) <= deadzone) return 0;
        return Math.round(Math.max(-1f, Math.min(1f, value)) * 32767f);
    }

    void motion(float x, float y, float z, float rz, float hatX, float hatY,
                float leftTrigger, float rightTrigger, float deadzone) {
        lx = axis(x, deadzone); ly = axis(-y, deadzone);
        rx = axis(z, deadzone); ry = axis(-rz, deadzone);
        hat = (hatX < -0.5f ? 1 << 12 : hatX > 0.5f ? 1 << 14 : 0)
            | (hatY < -0.5f ? 1 << 13 : hatY > 0.5f ? 1 << 15 : 0);
        triggers = (leftTrigger > 0.5f ? 1 << 8 : 0)
            | (rightTrigger > 0.5f ? 1 << 9 : 0);
    }

    void reset() { keys = hat = triggers = lx = ly = rx = ry = 0; }
    int buttons() {
        // Keep physical key state in positional order so changing modes while held cannot
        // leave the old mapped button stuck when its key-up event arrives.
        int mapped = labelMapping ? (keys & ~15) | ((keys & 5) << 1) | ((keys & 10) >> 1) : keys;
        return mapped | hat | triggers;
    }
    int leftX() { return lx; }
    int leftY() { return ly; }
    int rightX() { return rx; }
    int rightY() { return ry; }
}

