package org.s2arm.android;

import java.util.ArrayList;
import java.util.List;

public final class LanDiscoverySessionTest {
    private static void require(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    public static void main(String[] args) throws Exception {
        List<LanDiscoverySession.Peer[]> changes = new ArrayList<>();
        LanDiscoverySession s = new LanDiscoverySession(changes::add);
        long a = s.start();
        var first = s.found(a, "0123-peer");
        require(first != null, "first discovery must resolve");
        require(s.found(a, "0123-peer") == null, "duplicate discovery must not queue second resolve");
        s.lost(a, "0123-peer");
        var again = s.found(a, "0123-peer");
        s.resolved(first, "192.0.2.1", 31337);
        require(changes.isEmpty(), "lost/refound rejects old resolve within same session");
        s.resolved(again, "192.0.2.2", 31337);
        require(changes.size() == 1 && changes.get(0)[0].address.equals("192.0.2.2"), "new resolve published");
        s.resolved(again, "192.0.2.2", 31337);
        require(changes.size() == 1, "same address must not notify twice");
        s.lost(a, "0123-peer");
        require(changes.size() == 2 && changes.get(1).length == 0, "resolved service loss updates peers");
        var stale = s.found(a, "0123-late");
        s.stop();
        s.resolved(stale, "192.0.2.3", 31337);
        require(changes.size() == 2, "stop must suppress queued results");
        long b = s.start();
        require(a != b, "restart must change generation");
        require(s.found(a, "0123-old") == null, "old discovery cannot enter new session");
        var live = s.found(b, "0123-live");
        s.lost(a, "0123-live");
        s.resolved(live, "192.0.2.4", 31337);
        require(changes.size() == 3, "old loss cannot delete new service");
        s.failed(live);
        require(s.found(b, "0123-live") == null, "late failure must not remove resolved peer");
        var failed = s.found(b, "0123-retry");
        s.failed(failed);
        require(s.found(b, "0123-retry") != null, "failure permits later discovery retry");
        s.stop(); s.stop();
        // A callback already in flight and stop share one barrier. No timed sleeps.
        var entered = new java.util.concurrent.CountDownLatch(1);
        var release = new java.util.concurrent.CountDownLatch(1);
        var stopCalled = new java.util.concurrent.CountDownLatch(1);
        var stopped = new java.util.concurrent.atomic.AtomicBoolean();
        LanDiscoverySession guarded = new LanDiscoverySession(peers -> {
            entered.countDown();
            try { release.await(); } catch (InterruptedException e) { throw new AssertionError(e); }
            require(!stopped.get(), "stop returned before callback completed");
        });
        var ticket = guarded.found(guarded.start(), "0123-concurrent");
        Thread callback = new Thread(() -> guarded.resolved(ticket, "192.0.2.9", 31337));
        Thread stopper = new Thread(() -> { stopCalled.countDown(); guarded.stop(); stopped.set(true); });
        var failure = new java.util.concurrent.atomic.AtomicReference<Throwable>();
        callback.setUncaughtExceptionHandler((thread, error) -> failure.compareAndSet(null, error));
        stopper.setUncaughtExceptionHandler((thread, error) -> failure.compareAndSet(null, error));
        callback.start(); entered.await(); stopper.start(); stopCalled.await();
        long deadline = System.nanoTime() + 2_000_000_000L;
        while (!stopped.get() && stopper.getState() != Thread.State.BLOCKED && System.nanoTime() < deadline)
            Thread.yield();
        boolean premature = stopped.get();
        boolean observed = premature || stopper.getState() == Thread.State.BLOCKED;
        release.countDown(); callback.join(); stopper.join();
        require(observed, "stop admission was not observed");
        require(!premature, "stop returned while callback was still in flight");
        if (failure.get() != null) throw new AssertionError("worker failed", failure.get());
        require(stopped.get(), "stop must eventually complete");
        System.out.println("PASS: duplicate, lost/refound, stale session, stop, restart, failure retry");
    }
}
