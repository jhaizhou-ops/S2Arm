package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/** Cross-process exclusion: installation/sweep and a live game cannot retire each other's revision. */
final class GameStorage implements AutoCloseable {
    private static final java.util.Set<Path> HELD = new java.util.HashSet<>();
    private final FileChannel channel;
    private final FileLock lock;
    private final Path key;
    private boolean closed;

    private GameStorage(FileChannel channel, FileLock lock, Path key) { this.channel = channel; this.lock = lock; this.key = key; }

    static synchronized GameStorage acquire(File privateRoot) throws IOException {
        Path games = privateRoot.getCanonicalFile().toPath().resolve("games");
        if (Files.isSymbolicLink(games)) throw new IOException("games directory is a symbolic link");
        Files.createDirectories(games);
        Path key = games.resolve(".session.lock");
        // POSIX locks belong to the process: even closing an unsuccessful second fd can release the
        // first channel's OS lock. Refuse local contention BEFORE opening another descriptor.
        if (HELD.contains(key)) throw new IOException("game storage is busy; wait for the previous game process to exit");
        FileChannel channel = FileChannel.open(key, StandardOpenOption.CREATE,
            StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
        try {
            FileLock lock = channel.tryLock();
            if (lock == null) throw new IOException("game storage is busy; wait for the previous game process to exit");
            HELD.add(key);
            return new GameStorage(channel, lock, key);
        } catch (IOException | RuntimeException error) {
            channel.close();
            if (error instanceof OverlappingFileLockException)
                throw new IOException("game storage is busy; wait for the previous game process to exit");
            throw error;
        }
    }

    @Override public void close() throws IOException {
        synchronized (GameStorage.class) {
            if (closed) return;
            closed = true;
            try { try { lock.release(); } finally { channel.close(); } }
            finally { HELD.remove(key); }
        }
    }
}
