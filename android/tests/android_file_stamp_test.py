#!/usr/bin/env python3
"""Exercise the actual Android stat adapter with synthetic platform responses, including 1 ns differences."""
import subprocess
import tempfile
from pathlib import Path

android = Path(__file__).resolve().parents[1]
source = android / 'app/src/main/java/org/s2arm/android/AndroidFileStamp.java'
stubs = {
 'android/system/ErrnoException.java': '''package android.system; public class ErrnoException extends Exception {}''',
 'android/system/StructTimespec.java': '''package android.system; public class StructTimespec { public long tv_sec, tv_nsec; }''',
 'android/system/StructStat.java': '''package android.system; public class StructStat { public long st_dev,st_ino,st_size; public int st_mode; public StructTimespec st_mtim; }''',
 'android/system/OsConstants.java': '''package android.system; public class OsConstants { public static boolean S_ISREG(int m){return m==1;} }''',
 'android/system/Os.java': '''package android.system; public class Os { public static StructStat value; public static StructStat lstat(String p) throws ErrnoException {return value;} }''',
 'org/s2arm/android/GameFingerprint.java': '''package org.s2arm.android; final class GameFingerprint { static final class Stamp { final long size,dev,ino,seconds; final int nanos; Stamp(long s,long d,long i,long t,int n){size=s;dev=d;ino=i;seconds=t;nanos=n;} } }''',
 'org/s2arm/android/StampProbe.java': '''package org.s2arm.android;
 import android.system.*; import java.io.*;
 public class StampProbe { public static void main(String[] args) throws Exception {
  StructStat s=new StructStat(); s.st_dev=4; s.st_ino=5; s.st_size=8; s.st_mode=1; s.st_mtim=new StructTimespec();
  s.st_mtim.tv_sec=100; s.st_mtim.tv_nsec=123456001; Os.value=s;
  GameFingerprint.Stamp a=AndroidFileStamp.read(new File("fixture")); s.st_mtim.tv_nsec=123456002;
  GameFingerprint.Stamp b=AndroidFileStamp.read(new File("fixture"));
  if (a.nanos!=123456001 || b.nanos!=123456002 || a.seconds!=100 || a.dev!=4 || a.ino!=5 || a.size!=8)
   throw new AssertionError("stat precision or identity lost");
  s.st_mode=2; try { AndroidFileStamp.read(new File("fixture")); throw new AssertionError("symlink accepted"); } catch(IOException expected) {}
  s.st_mode=1; s.st_ino=0; if(AndroidFileStamp.read(new File("fixture"))!=null) throw new AssertionError("zero inode trusted");
  System.out.println("AndroidFileStamp: nanoseconds and nofollow PASS (synthetic host only)");
 } }''',
}
with tempfile.TemporaryDirectory(prefix='s2a-file-stamp-') as directory:
    root=Path(directory); files=[]
    for path, text in stubs.items():
        f=root/path; f.parent.mkdir(parents=True, exist_ok=True); f.write_text(text); files.append(str(f))
    classes=root/'classes'; classes.mkdir()
    subprocess.run(['javac','-encoding','UTF-8','-d',str(classes),str(source),*files],check=True)
    subprocess.run(['java','-cp',str(classes),'org.s2arm.android.StampProbe'],check=True)
