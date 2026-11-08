package org.s2arm.android;

/** UI-thread contact routing. Viewport comes only from the final game compositor.
 * No Android types, game identities, allocations during motion, or gesture recognition.
 */
final class GameTouch {
    interface Sink { int publish(int[] points, int count, int flags, long timestampNs); }
    static final int CANCEL = 1, MAX_POINTS = 16;
    private final Sink sink;
    private final int[] ids = new int[MAX_POINTS];
    private final int[] points = new int[MAX_POINTS * 5];
    private int count;
    private boolean enabled, viewport;
    private float left, top, width, height;
    private long generation, revision;

    GameTouch(Sink sink) { this.sink = sink; }

    void enable(boolean value) {
        if (enabled == value) return;
        cancel();
        enabled = value;
    }

    boolean enabled() { return enabled; }
    boolean ready() { return enabled && viewport; }

    // View-local pixels, after rotation/composition, NOT the cutout-safe control area.
    void viewport(long generation, long revision, float left, float top, float width, float height) {
        if (generation <= 0 || revision <= 0 || !Float.isFinite(left) || !Float.isFinite(top)
                || !Float.isFinite(width) || !Float.isFinite(height) || width <= 0 || height <= 0)
            throw new IllegalArgumentException("invalid final game viewport");
        if (generation < this.generation || (generation == this.generation && revision < this.revision))
            return; // Delayed renderer notification.
        if (!viewport && generation == this.generation && revision == this.revision) return;
        if (viewport && generation == this.generation && revision == this.revision) {
            if (this.left != left || this.top != top || this.width != width || this.height != height)
                throw new IllegalArgumentException("viewport changed without revision");
            return;
        }
        cancel();
        this.generation = generation; this.revision = revision;
        this.left = left; this.top = top; this.width = width; this.height = height;
        viewport = true;
    }

    void revokeViewport() { cancel(); viewport = false; }

    boolean owns(int id) {
        for (int i = 0; i < count; i++) if (ids[i] == id) return true;
        return false;
    }

    // Ownership is chosen on DOWN and cannot migrate to a virtual control on MOVE.
    boolean down(int id, float x, float y) {
        if (!ready() || !Float.isFinite(x) || !Float.isFinite(y)
                || x < left || y < top || x >= left + width || y >= top + height) return false;
        if (count == MAX_POINTS || owns(id)) {
            cancel();
            throw new IllegalStateException("touch contact overflow or duplicate ID");
        }
        ids[count] = id;
        points[count * 5] = id;
        count++;
        move(id, x, y);
        return true;
    }

    void move(int id, float x, float y) {
        for (int i = 0; i < count; i++) if (ids[i] == id) {
            if (!Float.isFinite(x) || !Float.isFinite(y)) {
                cancel();
                throw new IllegalArgumentException("non-finite touch coordinate");
            }
            points[i * 5 + 1] = normalize(x, left, width);
            points[i * 5 + 2] = normalize(y, top, height);
        }
    }

    private static int normalize(float value, float start, float extent) {
        return Math.round(Math.max(0, Math.min(1, (value - start) / extent)) * 65535);
    }

    void up(int id) {
        for (int i = 0; i < count; i++) if (ids[i] == id) {
            count--;
            System.arraycopy(ids, i + 1, ids, i, count - i);
            System.arraycopy(points, (i + 1) * 5, points, i * 5, (count - i) * 5);
            return;
        }
    }

    void publish() { publish(0); }
    void publish(long timestampNs) { if (ready()) send(0, timestampNs); }
    void cancel() {
        boolean held = count != 0;
        count = 0;
        if (enabled && held) send(CANCEL, 0);
    }
    private void send(int flags, long timestampNs) {
        int result = sink.publish(points, count, flags, timestampNs);
        if (result != 0) {
            count = 0; enabled = false;
            throw new IllegalStateException("touch transport failed: " + result);
        }
    }
}
