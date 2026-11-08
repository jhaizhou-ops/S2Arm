package org.s2arm.android;

import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.util.Log;

/** Serializes Bonjour name changes: unregister completes before hosting name is republished. */
final class LanDiscoveryPublisher {
    private final NsdManager manager;
    private final Handler handler;
    private final String prefix;
    private final String device;
    private final int port;
    private boolean stopped;
    private boolean hosting;
    private Registration registration;
    Runnable changed = () -> {};
    Runnable cleaned = () -> {};
    Runnable failed = () -> {};
    String publishedName() { return registration != null && registration.registered && !registration.removing ? registration.name : null; }

    LanDiscoveryPublisher(NsdManager manager, Handler handler, String prefix, String device, int port) {
        if (port < 1 || port > 65535) throw new IllegalArgumentException("LAN port");
        if (!device.matches("[A-Za-z0-9]+")) throw new IllegalArgumentException("LAN device ID");
        this.manager = manager; this.handler = handler; this.prefix = prefix;
        this.device = device; this.port = port;
    }

    void start() { handler.post(this::reconcile); }
    void setHosting(boolean on) { handler.post(() -> { hosting = on; reconcile(); }); }
    void stop() { handler.post(() -> { stopped = true; reconcile(); }); }
    private String name() { return prefix + (hosting ? "!" : "") + device; }

    private void reconcile() {
        if (registration != null) {
            if ((stopped || !registration.name.equals(name())) && registration.registered && !registration.removing) {
                registration.removing = true;
                changed.run();
                try { manager.unregisterService(registration); }
                catch (RuntimeException e) {
                    registration.removing = false;
                    Log.e("S2Arm", "NSD unregister: " + e);
                }
            }
            return;
        }
        if (stopped) { cleaned.run(); return; }
        Registration next = new Registration(name());
        registration = next;
        NsdServiceInfo service = new NsdServiceInfo();
        service.setServiceName(next.name);
        service.setServiceType(LanDiscoveryBrowser.TYPE);
        service.setPort(port);
        try { manager.registerService(service, NsdManager.PROTOCOL_DNS_SD, next); }
        catch (RuntimeException e) {
            registration = null;
            Log.e("S2Arm", "NSD register: " + e);
            failed.run();
            if (stopped) cleaned.run();
        }
    }

    private final class Registration implements NsdManager.RegistrationListener {
        final String name;
        boolean registered;
        boolean removing;
        Registration(String name) { this.name = name; }
        public void onServiceRegistered(NsdServiceInfo service) {
            handler.post(() -> {
                if (registration != this) return;
                registered = true;
                // A collision-renamed instance would no longer match s2a_lan_is_self.
                if (!name.equals(service.getServiceName())) {
                    stopped = true;
                    Log.e("S2Arm", "NSD renamed local service; discovery identity unavailable");
                    failed.run();
                }
                changed.run();
                reconcile();
            });
        }
        public void onRegistrationFailed(NsdServiceInfo service, int error) {
            handler.post(() -> {
                if (registration != this) return;
                registration = null;
                Log.e("S2Arm", "NSD registration failed: " + error);
                failed.run();
                if (stopped) cleaned.run();
            });
        }
        public void onServiceUnregistered(NsdServiceInfo service) {
            handler.post(() -> {
                if (registration != this) return;
                registration = null;
                changed.run();
                reconcile();
            });
        }
        public void onUnregistrationFailed(NsdServiceInfo service, int error) {
            handler.post(() -> {
                if (registration == this) removing = false;
                Log.e("S2Arm", "NSD unregistration failed: " + error);
                // Retry only on an explicit stop/hosting request, never a hot failure loop.
            });
        }
    }
}
