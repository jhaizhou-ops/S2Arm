package org.s2arm.android;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * On-screen gamepad state: layout and multi-touch tracking, no Android types (unit-tested).
 * Same Npad bits and signed stick range as GamepadState. A pointer that lands on a stick
 * keeps it until lifted; other pointers press whatever button or D-pad sector they are over,
 * so a finger can slide between face buttons as on a physical pad.
 */
final class TouchPad {
    static final int BUTTON = 0, DPAD = 1, STICK = 2;
    static final float STICK_DEADZONE = 0.12f;
    static final float DPAD_DEADZONE = 0.25f;

    static final class Control {
        final int kind, bit;   // bit: Npad button (BUTTON); unused for DPAD; 0 = left, 1 = right (STICK)
        final String label;
        float x, y, radius;    // view pixels
        boolean pressed;       // drawing only
        float knobX, knobY;    // STICK: deflection in [-1, 1], y down (drawing only)
        Control(int kind, int bit, String label) { this.kind = kind; this.bit = bit; this.label = label; }
        boolean hit(float px, float py) {
            float slack = kind == STICK ? 1.25f : kind == DPAD ? 1.2f : 1.15f;
            float dx = px - x, dy = py - y, r = radius * slack;
            return dx * dx + dy * dy <= r * r;
        }
    }

    private final List<Control> controls = new ArrayList<>();
    private final Map<Integer, float[]> pointers = new HashMap<>();   // id -> {x, y}
    private final Map<Integer, Control> sticks = new HashMap<>();     // id -> captured stick
    private int buttons;
    private final int[] axes = new int[4];   // lx, ly, rx, ry

    TouchPad() {
        controls.add(new Control(STICK, 0, "L"));
        controls.add(new Control(STICK, 1, "R"));
        controls.add(new Control(DPAD, 0, ""));
        controls.add(new Control(BUTTON, 0, "A"));
        controls.add(new Control(BUTTON, 1, "B"));
        controls.add(new Control(BUTTON, 2, "X"));
        controls.add(new Control(BUTTON, 3, "Y"));
        controls.add(new Control(BUTTON, 4, "LS"));
        controls.add(new Control(BUTTON, 5, "RS"));
        controls.add(new Control(BUTTON, 6, "L"));
        controls.add(new Control(BUTTON, 7, "R"));
        controls.add(new Control(BUTTON, 8, "ZL"));
        controls.add(new Control(BUTTON, 9, "ZR"));
        controls.add(new Control(BUTTON, 10, "+"));
        controls.add(new Control(BUTTON, 11, "−"));
    }

    List<Control> controls() { return controls; }

    boolean hit(float x, float y) {
        for (Control c : controls) if (c.hit(x, y)) return true;
        return false;
    }

    /**
     * Lay the controls out in the area left, top, width x height (view pixels, inside the system
     * bars). Landscape uses the whole area; portrait puts the pad in a landscape-shaped box at
     * the bottom.
     */
    int layouts;   // how many times layout() ran (debug logging)

    void layout(float left, float top, float width, float height) {
        layouts++;
        float bw = width, bh = height, by = top;
        if (height > width) { bh = width * 0.56f; by = top + height - bh; }
        float u = Math.min(bw, bh) / 10f;
        for (Control c : controls) {
            float rx, ry, r;
            switch (c.kind == BUTTON ? c.label : c.kind == DPAD ? "DPAD" : c.bit == 0 ? "LSTICK" : "RSTICK") {
                case "LSTICK": rx = 0.13f; ry = 0.56f; r = 1.45f; break;
                case "RSTICK": rx = 0.73f; ry = 0.80f; r = 1.20f; break;
                case "DPAD":   rx = 0.27f; ry = 0.82f; r = 1.20f; break;
                case "A":      rx = 0.93f; ry = 0.56f; r = 0.55f; break;
                case "B":      rx = 0.87f; ry = 0.56f + 1.15f * u / bh; r = 0.55f; break;
                case "X":      rx = 0.87f; ry = 0.56f - 1.15f * u / bh; r = 0.55f; break;
                case "Y":      rx = 0.81f; ry = 0.56f; r = 0.55f; break;
                case "LS":     rx = 0.13f + 1.9f * u / bw; ry = 0.56f - 1.3f * u / bh; r = 0.38f; break;
                case "RS":     rx = 0.73f - 1.7f * u / bw; ry = 0.80f - 1.1f * u / bh; r = 0.38f; break;
                case "L":      rx = 0.17f; ry = 0.15f; r = 0.50f; break;
                case "ZL":     rx = 0.07f; ry = 0.15f; r = 0.50f; break;
                case "R":      rx = 0.83f; ry = 0.15f; r = 0.50f; break;
                case "ZR":     rx = 0.93f; ry = 0.15f; r = 0.50f; break;
                case "+":      rx = 0.58f; ry = 0.12f; r = 0.40f; break;
                default:       rx = 0.42f; ry = 0.12f; r = 0.40f; break;   // minus
            }
            c.x = left + rx * bw;
            c.y = by + ry * bh;
            c.radius = r * u;
        }
        update();
    }

    void down(int id, float x, float y) {
        pointers.put(id, new float[] {x, y});
        for (Control c : controls)
            if (c.kind == STICK && c.hit(x, y) && !sticks.containsValue(c)) { sticks.put(id, c); break; }
        update();
    }

    void move(int id, float x, float y) {
        float[] p = pointers.get(id);
        if (p == null) return;
        p[0] = x; p[1] = y;
        update();
    }

    void up(int id) {
        pointers.remove(id);
        sticks.remove(id);
        update();
    }

    void cancel() {
        pointers.clear();
        sticks.clear();
        update();
    }

    boolean active() { return !pointers.isEmpty(); }
    int buttons() { return buttons; }
    int leftX() { return axes[0]; }
    int leftY() { return axes[1]; }
    int rightX() { return axes[2]; }
    int rightY() { return axes[3]; }

    private static int axis(float v) { return Math.round(Math.max(-1f, Math.min(1f, v)) * 32767f); }

    private static int dpadBits(Control d, float x, float y) {
        float dx = (x - d.x) / d.radius, dy = (y - d.y) / d.radius;
        if (dx * dx + dy * dy < DPAD_DEADZONE * DPAD_DEADZONE) return 0;
        double angle = Math.toDegrees(Math.atan2(-dy, dx));   // 0 = right, 90 = up
        int sector = (int) Math.floor(((angle + 360 + 22.5) % 360) / 45);   // 0 = right, counter-clockwise
        final int left = 1 << 12, up = 1 << 13, right = 1 << 14, down = 1 << 15;
        switch (sector) {
            case 0: return right;
            case 1: return right | up;
            case 2: return up;
            case 3: return up | left;
            case 4: return left;
            case 5: return left | down;
            case 6: return down;
            default: return down | right;
        }
    }

    private void update() {
        buttons = 0;
        java.util.Arrays.fill(axes, 0);
        for (Control c : controls) { c.pressed = false; c.knobX = c.knobY = 0; }
        for (Map.Entry<Integer, float[]> e : pointers.entrySet()) {
            float x = e.getValue()[0], y = e.getValue()[1];
            Control stick = sticks.get(e.getKey());
            if (stick != null) {
                float dx = (x - stick.x) / stick.radius, dy = (y - stick.y) / stick.radius;
                float len = (float) Math.sqrt(dx * dx + dy * dy);
                if (len > 1) { dx /= len; dy /= len; len = 1; }
                stick.pressed = true; stick.knobX = dx; stick.knobY = dy;
                if (len > STICK_DEADZONE) {
                    axes[2 * stick.bit] = axis(dx);
                    axes[2 * stick.bit + 1] = axis(-dy);   // up is positive
                }
                continue;
            }
            for (Control c : controls) {
                if (c.kind == BUTTON && c.hit(x, y)) { buttons |= 1 << c.bit; c.pressed = true; break; }
                if (c.kind == DPAD && c.hit(x, y)) {
                    int bits = dpadBits(c, x, y);
                    buttons |= bits; c.pressed = bits != 0;
                    c.knobX = (x - c.x) / c.radius; c.knobY = (y - c.y) / c.radius;
                    break;
                }
            }
        }
    }
}
