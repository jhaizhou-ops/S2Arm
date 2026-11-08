package org.s2arm.android;
import android.app.Activity;
import android.app.AlertDialog;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
public final class LegacyTextInputTest {
    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static Thread request(LegacyTextInput bridge, AtomicReference<String> result) {
        Thread t = new Thread(() -> result.set(bridge.request("title", "hello", 8)));
        t.start(); return t;
    }
    static void shown() throws Exception { check(AlertDialog.shown.await(2, TimeUnit.SECONDS), "dialog not shown"); }
    static void done(Thread t) throws Exception { t.join(2000); check(!t.isAlive(), "guest thread stuck"); }
    public static void main(String[] args) throws Exception {
        Activity a = new Activity(); LegacyTextInput bridge = new LegacyTextInput(a, 1000); bridge.resume();
        AtomicReference<String> value = new AtomicReference<>();
        AlertDialog.shown = new CountDownLatch(1); Thread t=request(bridge,value); shown(); AlertDialog.last.positive(); done(t);
        check("hello".equals(value.get()), "confirm value");
        value.set("sentinel"); AlertDialog.shown = new CountDownLatch(1); t=request(bridge,value); shown(); AlertDialog.last.dismiss(); done(t);
        check(value.get()==null, "dismiss cancels");
        value.set("sentinel"); AlertDialog.shown = new CountDownLatch(1); t=request(bridge,value); shown(); bridge.pause(); done(t);
        check(value.get()==null, "pause cancels");
        bridge.resume(); AlertDialog.throwOnShow = true; value.set("sentinel"); t=request(bridge,value); done(t); AlertDialog.throwOnShow=false;
        check(value.get()==null, "show failure cancels");
        a.queue=true; a.posted=new CountDownLatch(1); value.set("sentinel"); t=request(bridge,value);
        check(a.posted.await(2,TimeUnit.SECONDS), "request not posted"); Runnable stale=a.queued; bridge.pause(); done(t); bridge.resume();
        AlertDialog previous=AlertDialog.last; stale.run(); check(AlertDialog.last==previous, "stale UI task opened dialog");
        a.queue=false; a.finishing=true; value.set("sentinel"); t=request(bridge,value); done(t); check(value.get()==null, "finishing activity must cancel");
        a.finishing=false; LegacyTextInput shortWait = new LegacyTextInput(a, 250); shortWait.resume();
        value.set("sentinel"); AlertDialog.shown = new CountDownLatch(1); t=request(shortWait,value); shown();
        AlertDialog timedOut=AlertDialog.last; done(t); check(value.get()==null, "timeout cancels");
        timedOut.positive(); check(value.get()==null, "late positive after timeout cannot accept");
        System.out.println("LegacyTextInput lifecycle: confirm, dismiss, pause, show failure, stale UI and finishing passed");
    }
}
