// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;
public final class CapturePixelsTest {
    static int n;
    static void check(boolean ok) { if (!ok) throw new AssertionError("assertion " + n); ++n; }
    static void invalid(byte[] pixels, int w, int h, int q) {
        try { CapturePixels.toArgb(pixels,w,h,q); throw new AssertionError("accepted invalid input"); }
        catch (IllegalArgumentException expected) { ++n; }
    }
    public static void main(String[] args) {
        int[] a=CapturePixels.toArgb(new byte[]{(byte)255,0,0,(byte)255,0,(byte)255,0,(byte)255,
            0,0,(byte)255,(byte)255, 40,20,10,(byte)128, 0,0,0,0, (byte)255,(byte)255,(byte)255,(byte)255},3,2,80);
        check(a[0]==0xffff0000);check(a[1]==0xff00ff00);check(a[2]==0xff0000ff);
        check(a[3]==0x80502814);check(a[4]==0);check(a[5]==0xffffffff);
        for(int alpha=1;alpha<=255;++alpha) for(int c=0;c<=alpha;++c) {
            int value=CapturePixels.toArgb(new byte[]{(byte)c,(byte)c,(byte)c,(byte)alpha},1,1,80)[0];
            int straight=value&255;check((straight*alpha+127)/255==c);
        }
        invalid(null,1,1,80);invalid(new byte[4],0,1,80);invalid(new byte[4],1,-1,80);
        invalid(new byte[4],1,1,-1);invalid(new byte[4],1,1,101);invalid(new byte[3],1,1,80);
        invalid(new byte[4],Integer.MAX_VALUE,Integer.MAX_VALUE,80);invalid(new byte[4],4097,1,80);
        check(CapturePixels.toArgb(new byte[4],1,1,0).length==1);
        check(CapturePixels.toArgb(new byte[4],1,1,100).length==1);
        System.out.println("CapturePixels assertions="+n);
    }
}
