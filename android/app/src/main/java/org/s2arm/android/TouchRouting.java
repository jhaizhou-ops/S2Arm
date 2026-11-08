package org.s2arm.android;

/** Shared production routing used by the View and host regression tests. */
final class TouchRouting {
    private TouchRouting() {}

    static void down(TouchPad pad, GameTouch game, boolean controlsVisible, int id, float x, float y) {
        if (controlsVisible && (!game.enabled() || pad.hit(x, y))) pad.down(id, x, y);
        else game.down(id, x, y);
    }

    static void move(TouchPad pad, GameTouch game, int id, float x, float y) {
        if (game.owns(id)) game.move(id, x, y);
        else pad.move(id, x, y);
    }

    static void up(TouchPad pad, GameTouch game, int id) {
        pad.up(id);
        game.up(id);
    }
}
