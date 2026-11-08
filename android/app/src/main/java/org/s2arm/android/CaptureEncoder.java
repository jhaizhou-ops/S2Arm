// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.graphics.Bitmap;
import java.io.ByteArrayOutputStream;
import java.io.IOException;

/** Platform JPEG codec for caps:su. Called on the requesting service thread; no Activity state. */
final class CaptureEncoder {
    private CaptureEncoder() {}
    static byte[] encodeRgba(byte[] rgba, int width, int height, int quality) throws IOException {
        int[] argb = CapturePixels.toArgb(rgba, width, height, quality);
        Bitmap bitmap = Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888);
        try {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output))
                throw new IOException("Android JPEG compression failed");
            byte[] jpeg = output.toByteArray();
            if (jpeg.length < 4 || (jpeg[0] & 255) != 255 || (jpeg[1] & 255) != 216
                    || (jpeg[jpeg.length - 2] & 255) != 255 || (jpeg[jpeg.length - 1] & 255) != 217)
                throw new IOException("Android JPEG compression returned incomplete data");
            return jpeg;
        } finally {
            bitmap.recycle();
        }
    }
}
