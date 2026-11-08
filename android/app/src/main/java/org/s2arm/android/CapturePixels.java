// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

/** Packed premultiplied RGBA8888, top row first, to Android's public ARGB int contract. */
final class CapturePixels {
    private CapturePixels() {}
    static int[] toArgb(byte[] rgba, int width, int height, int quality) {
        if (rgba == null || width <= 0 || height <= 0 || width > 4096 || height > 4096
                || quality < 0 || quality > 100 || (long) width * height * 4 != rgba.length)
            throw new IllegalArgumentException("Invalid packed RGBA screenshot");
        int[] colors = new int[width * height];
        for (int i = 0; i < colors.length; ++i) {
            int at = i * 4, alpha = rgba[at + 3] & 255;
            int red = straight(rgba[at] & 255, alpha);
            int green = straight(rgba[at + 1] & 255, alpha);
            int blue = straight(rgba[at + 2] & 255, alpha);
            colors[i] = alpha << 24 | red << 16 | green << 8 | blue;
        }
        return colors;
    }
    private static int straight(int component, int alpha) {
        return alpha == 0 ? 0 : Math.min(255, (component * 255 + alpha / 2) / alpha);
    }
}
