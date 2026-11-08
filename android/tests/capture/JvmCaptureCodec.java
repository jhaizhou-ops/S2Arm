// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;
import java.awt.image.BufferedImage;
import java.io.*;
import javax.imageio.*;
import javax.imageio.stream.ImageOutputStream;
// Real host JVM JPEG adapter for JNI/ownership testing. Production uses Android Bitmap.
public final class JvmCaptureCodec {
    private static volatile int mode;
    static void setMode(int next) {mode=next;}
    static byte[] encodeRgba(byte[] rgba,int width,int height,int quality) throws IOException {
        int[] pixels=CapturePixels.toArgb(rgba,width,height,quality);
        if(mode==1)throw new IOException("injected codec failure");
        if(mode==2)return null;
        if(mode==3)return new byte[]{1,2,3,4};
        BufferedImage image=new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);
        image.setRGB(0,0,width,height,pixels,0,width);
        ImageIO.setUseCache(false);
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        ImageWriter writer=ImageIO.getImageWritersByFormatName("JPEG").next();
        try(ImageOutputStream output=ImageIO.createImageOutputStream(bytes)) {
            writer.setOutput(output);ImageWriteParam p=writer.getDefaultWriteParam();
            p.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);p.setCompressionQuality(quality/100f);
            writer.write(null,new IIOImage(image,null,null),p);
        }finally{writer.dispose();}
        return bytes.toByteArray();
    }
    static boolean verify(byte[] jpeg,int width,int height) throws IOException {
        BufferedImage image=ImageIO.read(new ByteArrayInputStream(jpeg));
        if(image==null||image.getWidth()!=width||image.getHeight()!=height)return false;
        int[] expected={0xff0000,0x00ff00,0x0000ff,0xffffff};
        for(int i=0;i<4;i++) {
            int pixel=image.getRGB((i%2)*width/2+width/4,(i/2)*height/2+height/4);
            for(int shift:new int[]{0,8,16})if(Math.abs(((pixel>>shift)&255)-((expected[i]>>shift)&255))>12)return false;
        }
        return true;
    }
}
