#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute the production JNI bridge on a host JVM. NSD/device/network are NOT tested here."""
import os
import pathlib
import runpy
import re
import sys
import subprocess
import tempfile

ANDROID = pathlib.Path(__file__).resolve().parents[1]
ROOT = ANDROID.parents[0]
loader = runpy.run_path(str(ANDROID / 'tests/native_bridge_load_test.py'))
JAVAC = loader['JAVAC']
JAVA = JAVAC.parent / 'java'
# javac/java may be workspace wrappers: query the selected VM, do not infer JNI headers from wrapper location.
settings = subprocess.run([str(JAVA), '-XshowSettings:properties', '-version'], text=True, capture_output=True, check=True)
JDK = pathlib.Path(re.search(r'java.home = (.+)', settings.stderr).group(1).strip())
SYSTEM = 'darwin' if sys.platform == 'darwin' else 'linux'
PROBE = r'''package org.s2arm.android;
public class Probe {
 static native int install(); static native int start(long program,int port); static native void stop();
 static native void hosting(int on); static native int calls(); static native String chosen();
 static native void failEnvironment(int mode);
 static native void reenter(); static native void block(boolean on); static native boolean entered();
 static class Provider {
  volatile long generation; int starts,stops,result; boolean hosting,throwStart;
  String deviceId(){return "dev9";}
  int start(long epoch,long program,int port){generation=epoch;starts++;if(throwStart)throw new IllegalStateException("test start failure");return result;}
  void setHosting(boolean on){hosting=on;}
  void stop(){stops++;}
 }
 static void check(boolean yes,String text){if(!yes)throw new AssertionError(text);}
 static void snapshot(long g,String own,String[] names,String[] ips,int[] ports){NativeBridge.lanSnapshot(g,own,names,ips,ports);}
 public static void main(String[] a)throws Exception {
  System.load(a[0]); check(install()==1,"ABI/getter"); check(start(0x123,31337)==-19,"missing Java context accepted");
  Provider p=new Provider();check(NativeBridge.configureLanDiscovery(p)==0,"configure");
  check(NativeBridge.configureLanDiscovery(p)==0,"same context idempotence");
  check(NativeBridge.configureLanDiscovery(new Provider())==-16,"context replacement accepted");
  hosting(0);stop();
  p.result=-95;check(start(0x123,31337)==-95,"provider failure");p.result=0;
  p.throwStart=true;check(start(0x123,31337)==-5,"JNI exception");p.throwStart=false;p.starts=0;
  check(start(0x123,0)==-22,"zero port");check(start(0x123,31337)==0,"start");long g=p.generation;
  check(start(0x123,31337)==0&&p.starts==1,"repeat start");
  String self="0000000000000123-dev9", remote="0000000000000123-!aaa";
  snapshot(g,null,new String[]{remote},new String[]{"192.0.2.1"},new int[]{31337});
  check(chosen().equals(""),"remote chosen without published self");
  snapshot(g,self,new String[]{remote},new String[]{"192.0.2.1"},new int[]{31337});
  check(chosen().equals("192.0.2.1"),"C elect hosting peer");int before=calls();
  snapshot(g,self,new String[]{remote},new String[]{"192.0.2.1"},new int[]{31337});check(calls()==before,"duplicate address callback");
  snapshot(g,self,new String[]{remote},new String[]{"192.0.2.1"},new int[]{31338});check(chosen().equals("127.0.0.1"),"foreign port accepted");
  snapshot(g,self,new String[]{"0000000000000123-!dev9",remote},new String[]{"192.0.2.9","::1"},new int[]{31337,31337});
  check(chosen().equals("127.0.0.1"),"old local name/IPv6 accepted");
  hosting(1);check(p.hosting,"hosting not forwarded");
  reenter();snapshot(g,self,new String[]{remote},new String[]{"192.0.2.2"},new int[]{31337});
  before=calls();snapshot(g,self,new String[]{remote},new String[]{"192.0.2.3"},new int[]{31337});check(calls()==before,"callback after reentrant stop");
  check(start(0x123,31337)==0,"restart");long fresh=p.generation;
  snapshot(g,self,new String[]{},new String[]{},new int[]{});check(calls()==before,"old generation accepted after restart");
  block(true); java.util.concurrent.atomic.AtomicReference<Throwable> failure=new java.util.concurrent.atomic.AtomicReference<>();
  Thread callback=new Thread(()->{try{snapshot(fresh,self,new String[]{},new String[]{},new int[]{});}catch(Throwable e){failure.set(e);}});
  callback.start();long deadline=System.nanoTime()+2_000_000_000L;
  while(!entered()&&System.nanoTime()<deadline)Thread.yield();check(entered(),"callback did not enter");
  java.util.concurrent.atomic.AtomicBoolean stopped=new java.util.concurrent.atomic.AtomicBoolean();
  java.util.concurrent.atomic.AtomicBoolean attempted=new java.util.concurrent.atomic.AtomicBoolean();
  Thread stopper=new Thread(()->{attempted.set(true);stop();stopped.set(true);});stopper.start();
  deadline=System.nanoTime()+2_000_000_000L;while(!attempted.get()&&System.nanoTime()<deadline)Thread.yield();check(attempted.get(),"stop thread not scheduled");Thread.sleep(20);
  boolean premature=stopped.get();block(false);callback.join(2000);stopper.join(2000);
  check(!premature,"stop returned while callback in flight");
  check(!callback.isAlive()&&!stopper.isAlive()&&failure.get()==null&&stopped.get(),"concurrent stop/callback deadlock or failure");
  before=calls();snapshot(fresh,self,new String[]{remote},new String[]{"192.0.2.4"},new int[]{31337});NativeBridge.lanUnavailable(fresh);
  check(calls()==before,"managed callback after stop");stop();
  for(int mode=1;mode<=2;mode++) {
   check(start(0x123,31337)==0,"failure probe restart");p.hosting=false;int stops=p.stops;
   failEnvironment(mode);hosting(1);stop();failEnvironment(0);
   check(!p.hosting&&p.stops==stops,"failed Env dispatched Java control");
  }
  System.out.println("PASS JNI: actual C election, port/self admission, duplicate suppression, generations, reentrant/concurrent stop");
 }
}'''
HARNESS = r'''
#include <jni.h>
#include <atomic>
#include <chrono>
#include <thread>
#include <string>
#include "s2a_lan_discovery.h"
extern "C" const s2a_lan_discovery_v1 *s2a_android_lan_provider(void (*)(const char*));
static const s2a_lan_discovery_v1 *provider;
static std::atomic<int> count{0}; static std::atomic<bool> reenter{false}, blocked{false}, entered{false};
static std::string address;
static void selected(const char *p){count++;address=p?p:"";entered=true;
 while(blocked)std::this_thread::sleep_for(std::chrono::milliseconds(1));
 if(reenter.exchange(false))provider->stop();}
extern "C" JNIEXPORT jint JNICALL Java_org_s2arm_android_Probe_install(JNIEnv*,jclass){provider=s2a_android_lan_provider(selected);return provider&&provider->abi==1;}
extern "C" JNIEXPORT jint JNICALL Java_org_s2arm_android_Probe_start(JNIEnv*,jclass,jlong p,jint port){return provider->start(p,port);}
extern "C" JNIEXPORT void JNICALL Java_org_s2arm_android_Probe_stop(JNIEnv*,jclass){provider->stop();}
extern "C" JNIEXPORT void JNICALL Java_org_s2arm_android_Probe_hosting(JNIEnv*,jclass,jint on){provider->set_hosting(on);}
extern "C" JNIEXPORT jint JNICALL Java_org_s2arm_android_Probe_calls(JNIEnv*,jclass){return count;}
extern "C" JNIEXPORT jstring JNICALL Java_org_s2arm_android_Probe_chosen(JNIEnv*e,jclass){return e->NewStringUTF(address.c_str());}
extern "C" JNIEXPORT void JNICALL Java_org_s2arm_android_Probe_reenter(JNIEnv*,jclass){reenter=true;}
extern "C" JNIEXPORT void JNICALL Java_org_s2arm_android_Probe_block(JNIEnv*,jclass,jboolean on){entered=false;blocked=on;}
extern "C" JNIEXPORT jboolean JNICALL Java_org_s2arm_android_Probe_entered(JNIEnv*,jclass){return entered;}
'''
with tempfile.TemporaryDirectory(prefix='s2a-lan-jni-') as tmp:
    out = pathlib.Path(tmp)
    stubs = dict(loader['STUBS']); stubs['org/s2arm/android/Probe.java'] = PROBE
    java = []
    for name, body in stubs.items():
        p = out / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(body); java.append(str(p))
    subprocess.run([str(JAVAC), '-d', str(out), *java, str(ANDROID/'app/src/main/java/org/s2arm/android/NativeBridge.java')], check=True)
    (out/'android').mkdir(exist_ok=True)
    (out/'android/log.h').write_text(r'''#include <cstdio>
#include <cstdarg>
#include <mutex>
#define ANDROID_LOG_ERROR 6
#define ANDROID_LOG_INFO 4
static inline int __android_log_print(int,const char*,const char*fmt,...){
 static std::mutex lock; std::lock_guard<std::mutex> hold(lock);
 va_list args;va_start(args,fmt);vfprintf(stdout,fmt,args);va_end(args);fputc('\n',stdout);fflush(stdout);return 0;
}
''')
    (out/'harness.cpp').write_text(HARNESS)
    source = (ANDROID/'native/lan_discovery.cpp').read_text().replace('../../runtime/include/', str(ROOT/'runtime/include')+'/')
    # Test-only JNI invocation table: execute the real Env failure paths without
    # adding a production hook or changing Android's JavaVM.
    source += r'''
namespace {
JavaVM *real_vm;
JNIInvokeInterface_ failing_functions;
JavaVM_ failing_vm;
int env_failure;
jint fail_get_env(JavaVM *, void **out, jint) { *out = nullptr; return env_failure == 2 ? JNI_EDETACHED : JNI_ERR; }
jint fail_attach(JavaVM *, void **out, void *) { *out = nullptr; return JNI_ERR; }
}
extern "C" JNIEXPORT void JNICALL Java_org_s2arm_android_Probe_failEnvironment(JNIEnv *, jclass, jint mode) {
    if (!mode) { vm = real_vm; return; }
    real_vm = vm; failing_functions = *vm->functions;
    failing_functions.GetEnv = fail_get_env;
    failing_functions.AttachCurrentThread = fail_attach;
    failing_vm.functions = &failing_functions; env_failure = mode; vm = &failing_vm;
}
'''
    for mutation in ("positive", "fence", "stop_gate", "late_timer", "missing_peers"):
        negative = mutation in ("fence", "stop_gate")
        text = source
        if mutation == "fence":
            old = 'if (!active || static_cast<uint64_t>(generation) != epoch'
            assert old in text
            text = text.replace(old, 'if ((static_cast<void>(generation), false)')
        elif mutation == 'stop_gate':
            text = text.replace('void stop() {\n    CallTrace trace("stop");\n    std::lock_guard<std::recursive_mutex> serial(gate);', 'void stop() {\n    CallTrace trace("stop");')
            text = text.replace('{ std::lock_guard<std::recursive_mutex> lock(gate); active = false; ++epoch; }', '{ active = false; ++epoch; }')
        elif mutation == 'late_timer':
            old = 'CallTrace trace("stop");\n    std::lock_guard<std::recursive_mutex> serial(gate);'
            assert old in text
            text = text.replace(old, 'std::lock_guard<std::recursive_mutex> serial(gate);\n    CallTrace trace("stop");')
        elif mutation == 'missing_peers':
            text = text.replace('LAN snapshot: accepted_peers=', 'unobserved: accepted_peers=')
        (out/'bridge.cpp').write_text(text)
        subprocess.run([os.environ.get('CC','cc'), '-fPIC', '-I',str(ROOT/'runtime/include'), '-c',str(ROOT/'runtime/src/lan_elect.c'),'-o',str(out/'elect.o')],check=True)
        lib=out/(mutation+'.so')
        subprocess.run([os.environ.get('CXX','c++'), '-std=c++17',('-dynamiclib' if SYSTEM == 'darwin' else '-shared'),'-fPIC','-pthread','-Wall','-Wextra','-Werror',
          '-I',str(out),'-I',str(JDK/'include'),'-I',str(JDK/'include'/SYSTEM),'-I',str(ROOT/'runtime/include'),
          str(out/'bridge.cpp'),str(out/'harness.cpp'),str(out/'elect.o'),'-o',str(lib)],check=True)
        result=subprocess.run([str(JAVA),'-cp',str(out),'org.s2arm.android.Probe',str(lib)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
        print(result.stdout,end='')
        if negative:
            expected = 'callback after reentrant stop' if mutation == 'fence' else 'stop returned while callback in flight'
            assert result.returncode != 0 and expected in result.stdout, 'negative control did not hit lifecycle assertion'
            print('PASS negative '+mutation+': '+expected)
        elif result.returncode: raise SystemExit(result.returncode)
        else:
            expected_diagnostic = {'late_timer': 'stop timing excludes callback lock wait',
                                   'missing_peers': 'missing accepted peer evidence'}.get(mutation)
            try:
                traces = re.findall(r'LAN call: op=(start|set_hosting|stop) seq=(\d+) elapsed_ns=(\d+) status=(-?\d+)', result.stdout)
                assert traces, 'missing LAN boundary timing'
                assert len({row[1] for row in traces}) == len(traces), 'duplicate call sequence'
                for code in ('-19', '-22', '-95', '-5', '0'):
                    assert any(op == 'start' and status == code for op, _, _, status in traces), 'missing start path '+code
                assert any(op == 'set_hosting' for op, _, _, _ in traces), 'missing hosting timing'
                for control in ('set_hosting', 'stop'):
                    assert sum(op == control and status == '-5' for op, _, _, status in traces) == 2, 'missing Env failure status '+control
                assert any(op == 'stop' and int(ns) >= 10_000_000 for op, _, ns, _ in traces), 'stop timing excludes callback lock wait'
                peers = re.findall(r'LAN snapshot: accepted_peers=(\d+) winner=(self|peer|none)', result.stdout)
                assert ('1', 'peer') in peers and ('0', 'self') in peers, 'missing accepted peer evidence'
                assert peers.count(('1', 'peer')) >= 2, 'unchanged winner suppressed peer evidence'
            except AssertionError as error:
                assert expected_diagnostic and str(error) == expected_diagnostic, str(error)
                print('PASS negative '+mutation+': '+str(error))
                continue
            assert expected_diagnostic is None, 'diagnostic negative control survived'
            print('PASS diagnostics: early/error/JNI/idempotent/control timing, concurrent wait, unchanged-winner peer snapshot')
