package org.s2arm.android;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import java.io.File;
import java.io.IOException;

/** Android's NIO FileTime may truncate nanoseconds; use the public stat timespec directly. */
final class AndroidFileStamp {
    private AndroidFileStamp() { }

    // Diagnostic replay only: no path canonicalization and no application Stamp allocation.
    static void probe(File file) throws IOException {
        try { Os.lstat(file.getPath()); }
        catch (ErrnoException error) { throw new IOException("cannot stat indexed file", error); }
    }

    static GameFingerprint.Stamp read(File file) throws IOException {
        try {
            // BootContract has already resolved the permitted revision/CAS target. lstat
            // refuses a new final-component symlink if that target was swapped meanwhile.
            StructStat stat = Os.lstat(file.getPath());
            if (!OsConstants.S_ISREG(stat.st_mode)) throw new IOException("indexed target is not a regular file");
            if (stat.st_ino == 0 || stat.st_mtim == null || stat.st_mtim.tv_nsec < 0 || stat.st_mtim.tv_nsec >= 1_000_000_000L)
                return null;
            return new GameFingerprint.Stamp(stat.st_size, stat.st_dev, stat.st_ino,
                    stat.st_mtim.tv_sec, (int)stat.st_mtim.tv_nsec);
        } catch (ErrnoException error) {
            throw new IOException("cannot stat indexed file", error);
        }
    }
}
