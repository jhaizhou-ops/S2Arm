#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute real Java composition with fake Android services; not real NSD/device evidence."""
import ast
import pathlib
import subprocess
import tempfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
JAVAC=pathlib.Path(subprocess.check_output(['bash',str(ROOT/'tools/jdk17.sh')],text=True).strip())
JAVA=JAVAC.parent/'java'
def fixtures(name):
    tree=ast.parse((ROOT/'tests'/name).read_text())
    return ast.literal_eval(next(n.value for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='STUBS' for t in n.targets)))
stubs=fixtures('lan_discovery_browser_test.py')
pub=fixtures('lan_discovery_publisher_test.py')
stubs.pop('org/s2arm/android/BrowserProbe.java')
stubs['android/net/nsd/NsdServiceInfo.java']=pub['android/net/nsd/NsdServiceInfo.java'].replace('private String name,type;', 'private String name,type; public java.net.InetAddress host; public java.net.InetAddress getHost(){return host;}')
# One service manager exposes both production NSD listener surfaces.
browser=stubs['android/net/nsd/NsdManager.java']
publisher=pub['android/net/nsd/NsdManager.java']
stubs['android/net/nsd/NsdManager.java']=browser[:browser.rfind('}')]+publisher[publisher.index(' public interface RegistrationListener'):]
stubs.update({
'android/os/Handler.java': '''package android.os; public class Handler {
 static final java.util.ArrayDeque<Runnable> q=new java.util.ArrayDeque<>();
 public Handler(Looper l){} public boolean post(Runnable r){q.add(r);return true;}
 public static void drain(){while(!q.isEmpty())q.remove().run();}}
''',
'android/os/Looper.java':'package android.os; public class Looper {}',
'android/os/HandlerThread.java':'package android.os; public class HandlerThread { public HandlerThread(String s){} public void start(){} public Looper getLooper(){return new Looper();}}',
'android/content/SharedPreferences.java':'''package android.content; public class SharedPreferences {
 public String value; public int commits; public String getString(String key,String fallback){return value==null?fallback:value;}
 public Editor edit(){return new Editor();} public class Editor { public Editor putString(String k,String v){value=v;return this;}
 public boolean commit(){commits++;return true;}}}''',
'android/content/Context.java':'''package android.content; public class Context {
 public static final int MODE_PRIVATE=0;public static final String NSD_SERVICE="nsd",WIFI_SERVICE="wifi";
 public final SharedPreferences prefs=new SharedPreferences(); public final android.net.nsd.NsdManager nsd=new android.net.nsd.NsdManager();
 public final android.net.wifi.WifiManager wifi=new android.net.wifi.WifiManager(); public Context application=this;
 public Context getApplicationContext(){return application;}
 public SharedPreferences getSharedPreferences(String n,int m){if(application!=this)throw new AssertionError("Activity retained");return prefs;}
 public Object getSystemService(String n){if(application!=this)throw new AssertionError("Activity retained");return n.equals(NSD_SERVICE)?nsd:wifi;}}
''',
'android/net/wifi/WifiManager.java':'''package android.net.wifi;public class WifiManager {
 public final MulticastLock lock=new MulticastLock();public MulticastLock createMulticastLock(String tag){return lock;}
 public static class MulticastLock { public boolean held;public int acquires,releases;public boolean deny;
 public void setReferenceCounted(boolean on){if(on)throw new AssertionError();}
 public void acquire(){if(deny)throw new SecurityException("denied");held=true;acquires++;}
 public boolean isHeld(){return held;}public void release(){if(!held)throw new AssertionError("double release");held=false;releases++;}}}
''',
'org/s2arm/android/NativeBridge.java':'''package org.s2arm.android;final class NativeBridge {
 static LanDiscovery provider;static String own;static int snapshots,failures;
 static int configureLanDiscovery(Object o){provider=(LanDiscovery)o;return 0;}
 static void lanSnapshot(long g,String name,String[] n,String[] a,int[] p){own=name;snapshots++;}
 static void lanUnavailable(long g){failures++;}}
''',
'org/s2arm/android/ProviderProbe.java':'''package org.s2arm.android;
import android.content.Context;import android.os.Handler;
public class ProviderProbe {
 static void check(boolean b,String why){if(!b)throw new AssertionError(why);}
 public static void main(String[] args){
 Context app=new Context(),activity=new Context();activity.application=app;
 LanDiscovery.bind(activity);LanDiscovery p=NativeBridge.provider;check(p!=null,"provider not bound");
 String device=p.deviceId();check(device.matches("[A-Za-z0-9]+")&&app.prefs.commits==1,"stable persisted device");
 LanDiscovery.bind(activity);check(NativeBridge.provider==p&&app.prefs.commits==1,"duplicate context/provider");
 check(p.start(1,0x123,31337)==0&&!app.wifi.lock.held,"start blocked on platform work");Handler.drain();
 check(app.wifi.lock.held&&app.nsd.service.getPort()==31337,"multicast/port not real supplied values");
 var discovery=app.nsd.discovery;var registration=app.nsd.listener;var service=app.nsd.service;
 registration.onServiceRegistered(service);Handler.drain();
 check(NativeBridge.own.equals("0000000000000123-"+device),"published identity not forwarded");
 p.setHosting(true);Handler.drain();check(app.nsd.unregisters==1,"hosting did not unregister");
 registration.onServiceUnregistered(service);Handler.drain();
 registration=app.nsd.listener;service=app.nsd.service;registration.onServiceRegistered(service);Handler.drain();
 check(NativeBridge.own.equals("0000000000000123-!"+device),"hosting identity not reflected");
 p.stop();Handler.drain();check(app.wifi.lock.held,"lock released before NSD cleanup callbacks");
 discovery.onDiscoveryStopped("");Handler.drain();check(app.wifi.lock.held,"lock released before publication cleanup");
 registration.onUnregistrationFailed(service,3);Handler.drain();p.stop();Handler.drain();
 check(app.nsd.unregisters==3,"failed unregister was not retained for retry");
 registration.onServiceUnregistered(service);Handler.drain();check(!app.wifi.lock.held&&app.wifi.lock.releases==1,"cleanup failed to release lock exactly once");
 int before=NativeBridge.snapshots;registration.onServiceRegistered(service);discovery.onServiceFound(service);Handler.drain();
 check(NativeBridge.snapshots==before,"stale callbacks published after cleanup");
 app.wifi.lock.deny=true;check(p.start(2,0x123,31337)==0,"queue admission");Handler.drain();
 check(NativeBridge.failures==1&&!app.wifi.lock.held,"async permission failure falsely successful");
 app.wifi.lock.deny=false;p.start(3,0x123,31337);Handler.drain();
 check(app.nsd.service.getServiceName().equals("0000000000000123-"+device),"restart lost stable identity");
 app.nsd.discovery.onStartDiscoveryFailed("",3);Handler.drain();check(NativeBridge.failures==2,"discovery failure not propagated");
 System.out.println("PASS provider: Application context, persisted identity, queue admission, hosting, async lock cleanup/retry, permission/discovery failures");
 }}'''
})
with tempfile.TemporaryDirectory(prefix='s2a-lan-provider-') as temp:
    out=pathlib.Path(temp); paths=[]
    for name,body in stubs.items():
        p=out/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body);paths.append(str(p))
    sources=sorted((ROOT/'app/src/main/java/org/s2arm/android').glob('LanDiscovery*.java'))
    subprocess.run([str(JAVAC),'-Xlint:all','-Werror','-d',str(out),*paths,*map(str,sources)],check=True)
    subprocess.run([str(JAVA),'-cp',str(out),'org.s2arm.android.ProviderProbe'],check=True,timeout=15)
