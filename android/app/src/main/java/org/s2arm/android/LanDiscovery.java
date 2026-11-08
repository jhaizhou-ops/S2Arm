// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.nsd.NsdManager;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import java.util.ArrayList;
import java.util.Locale;
import java.util.UUID;

/** Process-owned NSD composition. Only the handler owns platform state; no Activity is retained. */
final class LanDiscovery {
    private static LanDiscovery instance;
    private final String device;
    private final Handler handler;
    private final NsdManager manager;
    private final WifiManager.MulticastLock multicast;
    private final LanDiscoveryBrowser browser;
    private final ArrayList<LanDiscoveryPublisher> retiring = new ArrayList<>();
    private LanDiscoveryPublisher publisher;
    private LanDiscoverySession.Peer[] peers = new LanDiscoverySession.Peer[0];
    private long generation;

    static synchronized void bind(Context context) {
        if (instance != null) return;
        try {
            LanDiscovery next = new LanDiscovery(context.getApplicationContext());
            int status = NativeBridge.configureLanDiscovery(next);
            if (status != 0) throw new IllegalStateException("JNI provider binding: " + status);
            instance = next;
        } catch (RuntimeException e) {
            Log.e("S2Arm", "【红】LAN discovery unavailable: " + e);
        }
    }

    private LanDiscovery(Context app) {
        if (app == null) throw new IllegalArgumentException("Application context required");
        SharedPreferences prefs = app.getSharedPreferences("s2arm-lan", Context.MODE_PRIVATE);
        String id = prefs.getString("device", null);
        if (id == null || !id.matches("[A-Za-z0-9]+")) {
            id = UUID.randomUUID().toString().replace("-", "");
            if (!prefs.edit().putString("device", id).commit())
                throw new IllegalStateException("cannot persist LAN identity");
        }
        device = id;
        manager = (NsdManager) app.getSystemService(Context.NSD_SERVICE);
        WifiManager wifi = (WifiManager) app.getSystemService(Context.WIFI_SERVICE);
        if (manager == null || wifi == null) throw new IllegalStateException("NSD/Wi-Fi unavailable");
        multicast = wifi.createMulticastLock("S2Arm-LAN");
        multicast.setReferenceCounted(false);
        HandlerThread thread = new HandlerThread("S2Arm-LAN");
        thread.start();
        handler = new Handler(thread.getLooper());
        browser = new LanDiscoveryBrowser(manager, handler, snapshot -> { peers = snapshot; publish(); });
        browser.cleaned = this::releaseIfIdle;
        browser.failed = this::fail;
    }

    // Called by JNI on LAN service threads. Queue admission, not a claim of discovery success.
    String deviceId() { return device; }
    int start(long epoch, long program, int port) {
        if (port < 1 || port > 65535) return -22;
        return handler.post(() -> begin(epoch, program, port)) ? 0 : -32;
    }
    void setHosting(boolean on) { handler.post(() -> { if (publisher != null) publisher.setHosting(on); }); }
    void stop() { handler.post(this::end); }

    private void begin(long epoch, long program, int port) {
        end();
        generation = epoch;
        try {
            multicast.acquire();
            String prefix = String.format(Locale.ROOT, "%016x-", program);
            LanDiscoveryPublisher next = new LanDiscoveryPublisher(manager, handler, prefix, device, port);
            publisher = next;
            next.changed = () -> { if (publisher == next) publish(); };
            next.failed = () -> { if (publisher == next) fail(); };
            next.cleaned = () -> { retiring.remove(next); releaseIfIdle(); };
            next.start();
            browser.start(prefix);
        } catch (RuntimeException e) {
            Log.e("S2Arm", "【红】LAN start failed: " + e);
            fail();
        }
    }
    private void publish() {
        if (generation == 0 || publisher == null) return;
        String[] names = new String[peers.length], addresses = new String[peers.length];
        int[] ports = new int[peers.length];
        for (int i = 0; i < peers.length; i++) {
            names[i] = peers[i].name; addresses[i] = peers[i].address; ports[i] = peers[i].port;
        }
        NativeBridge.lanSnapshot(generation, publisher.publishedName(), names, addresses, ports);
    }
    private void fail() {
        if (generation != 0) NativeBridge.lanUnavailable(generation);
        end();
    }
    private void end() {
        generation = 0;
        peers = new LanDiscoverySession.Peer[0];
        browser.stop();
        if (publisher != null) { retiring.add(publisher); publisher = null; }
        for (LanDiscoveryPublisher old : new ArrayList<>(retiring)) old.stop();
        releaseIfIdle();
    }
    private void releaseIfIdle() {
        // Keep the lock until real platform unregister/stop callbacks finish. Failed cleanup
        // remains retained for explicit stop/restart retry; never claim synchronous NSD teardown.
        if (generation == 0 && browser.idle() && retiring.isEmpty() && multicast.isHeld()) multicast.release();
    }
}
