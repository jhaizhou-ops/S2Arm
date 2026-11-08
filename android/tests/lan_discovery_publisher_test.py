#!/usr/bin/env python3
"""Production NSD publisher callback tests; fake API, not device evidence."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
JAVAC = pathlib.Path(subprocess.check_output(['bash', str(ROOT / 'tools/jdk17.sh')], text=True).strip())
JAVA = JAVAC.parent / 'java'
STUBS = {
'android/os/Handler.java': '''package android.os;
public class Handler { private final java.util.ArrayDeque<Runnable> q=new java.util.ArrayDeque<>();
 public boolean post(Runnable r){q.add(r);return true;} public void drain(){while(!q.isEmpty())q.remove().run();} }
''',
'android/util/Log.java': '''package android.util; public class Log { public static int e(String t,String s){return 0;} }''',
'android/net/nsd/NsdServiceInfo.java': '''package android.net.nsd; public class NsdServiceInfo {
 private String name,type; private int port;
 public void setServiceName(String n){name=n;} public String getServiceName(){return name;}
 public void setServiceType(String t){type=t;} public void setPort(int p){port=p;}
 public int getPort(){return port;}}
''',
'android/net/nsd/NsdManager.java': '''package android.net.nsd; public class NsdManager {
 public static final int PROTOCOL_DNS_SD=1;
 public interface RegistrationListener {void onServiceRegistered(NsdServiceInfo s);void onRegistrationFailed(NsdServiceInfo s,int e);
 void onServiceUnregistered(NsdServiceInfo s);void onUnregistrationFailed(NsdServiceInfo s,int e);}
 public RegistrationListener listener; public NsdServiceInfo service;public int registers,unregisters;
 public void registerService(NsdServiceInfo s,int p,RegistrationListener l){service=s;listener=l;registers++;}
 public void unregisterService(RegistrationListener l){unregisters++;}}
''',
'org/s2arm/android/LanDiscoveryBrowser.java': '''package org.s2arm.android; final class LanDiscoveryBrowser {static final String TYPE="_s2arm-ldn._tcp.";}''',
'org/s2arm/android/PublisherProbe.java': '''package org.s2arm.android;
import android.net.nsd.*; import android.os.Handler;
public class PublisherProbe {
 static void check(boolean b,String why){if(!b)throw new AssertionError(why);}
 public static void main(String[] args) {
 NsdManager m=new NsdManager();Handler h=new Handler();
 LanDiscoveryPublisher p=new LanDiscoveryPublisher(m,h,"0123-","dev9",31337);
 p.start();h.drain();check(m.registers==1&&m.service.getPort()==31337,"port must not be hardcoded");
 check(m.service.getServiceName().equals("0123-dev9"),"initial name");
 p.setHosting(true);h.drain();check(m.unregisters==0,"unregister before registered callback");
 var old=m.listener;var service=m.service;old.onServiceRegistered(service);h.drain();
 check(m.unregisters==1&&m.registers==1,"must await unregister before hosting publication");
 p.setHosting(false);p.setHosting(true);h.drain();check(m.unregisters==1,"duplicate unregister");
 old.onServiceUnregistered(service);h.drain();check(m.registers==2&&m.service.getServiceName().equals("0123-!dev9"),"hosting name missing");
 old.onServiceUnregistered(service);h.drain();check(m.registers==2,"old unregister callback corrupted new publication");
 p.stop();h.drain();check(m.unregisters==1,"stop must await registration acceptance");
 m.listener.onServiceRegistered(m.service);h.drain();check(m.unregisters==2,"pending registration escaped stop");
 m.listener.onServiceUnregistered(m.service);h.drain();p.setHosting(false);h.drain();check(m.registers==2,"stopped publisher restarted");
 NsdManager retry=new NsdManager();LanDiscoveryPublisher rp=new LanDiscoveryPublisher(retry,h,"0123-","other",1234);
 rp.start();h.drain();retry.listener.onServiceRegistered(retry.service);h.drain();rp.stop();h.drain();
 retry.listener.onUnregistrationFailed(retry.service,3);h.drain();rp.stop();h.drain();
 check(retry.unregisters==2,"explicit stop cannot retry failed unregister");
 System.out.println("PASS: publisher port, hosting rename, callback serialization, stale callbacks, stop during register");}}
''',
}

with tempfile.TemporaryDirectory(prefix='s2a-lan-nsd-') as tmp:
    out = pathlib.Path(tmp)
    paths = []
    for name, body in STUBS.items():
        p = out / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
        paths.append(str(p))
    source = ROOT / 'app/src/main/java/org/s2arm/android'
    subprocess.run([str(JAVAC), '-Xlint:all', '-Werror', '-d', str(out), *paths,
                    str(source / 'LanDiscoveryPublisher.java')], check=True)
    subprocess.run([str(JAVA), '-cp', str(out), 'org.s2arm.android.PublisherProbe'], check=True, timeout=15)
