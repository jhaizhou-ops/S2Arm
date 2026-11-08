// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "../../runtime/include/s2a_lan_discovery.h"
#include "../../runtime/include/s2a_lan_elect.h"
#include <jni.h>
#include <android/log.h>
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>



namespace {
// Observe synchronous provider work, including mutex wait and JNI cleanup. The
// final diagnostic write itself is outside elapsed_ns; this is not NSD latency.
// No names, program IDs, addresses or device identifiers are added to these logs.
std::atomic<unsigned long long> call_sequence{0};
struct CallTrace {
    std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
    const char *operation;
    unsigned long long sequence = ++call_sequence;
    int status = 0;
    explicit CallTrace(const char *op) : operation(op) {}
    int result(int code) { status = code; return code; }
    ~CallTrace() {
        auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - begin).count();
        __android_log_print(ANDROID_LOG_INFO, "S2Arm", "LAN call: op=%s seq=%llu elapsed_ns=%lld status=%d",
            operation, sequence, static_cast<long long>(ns), status);
    }
};
// Control calls never wait for the platform thread. Callback gate synchronizes only the
// short managed address publication, so stop invalidates even already queued Java work.
std::recursive_mutex gate;
JavaVM *vm;
jobject bridge;
jmethodID start_method, hosting_method, stop_method;
std::string device, prefix, chosen;
uint64_t epoch;
uint16_t local_port;
bool active, have_chosen;
void (*set_server)(const char *);
struct Env {
    JNIEnv *value = nullptr;
    bool attached = false;
    Env() {
        if (!vm) return;
        if (vm->GetEnv(reinterpret_cast<void **>(&value), JNI_VERSION_1_6) == JNI_EDETACHED) {
#ifdef __ANDROID__
            attached = vm->AttachCurrentThread(&value, nullptr) == JNI_OK;
#else
            attached = vm->AttachCurrentThread(reinterpret_cast<void **>(&value), nullptr) == JNI_OK;
#endif
            if (!attached) value = nullptr;
        }
    }
    ~Env() { if (attached) vm->DetachCurrentThread(); }
};
bool exception(JNIEnv *env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionDescribe(); env->ExceptionClear();
    __android_log_print(ANDROID_LOG_ERROR, "S2Arm", "【红】LAN JNI call failed");
    return true;
}
void offline() {
    if (set_server && (!have_chosen || !chosen.empty())) set_server(nullptr);
    chosen.clear(); have_chosen = true;
}
int start(uint64_t program, uint16_t port) {
    CallTrace trace("start");
    std::lock_guard<std::recursive_mutex> serial(gate);
    if (!port) return trace.result(-EINVAL);
    if (!bridge) return trace.result(-ENODEV);
    Env env;
    if (!env.value) return trace.result(-EIO);
    uint64_t generation;
    {
        std::lock_guard<std::recursive_mutex> lock(gate);
        if (active) return trace.result(0);
        if (!set_server) return trace.result(-ENOTSUP);
        char text[18]; std::snprintf(text, sizeof text, "%016llx-", static_cast<unsigned long long>(program));
        prefix = text; local_port = port; chosen.clear(); have_chosen = false;
        generation = ++epoch; active = true;
    }
    int result = env.value->CallIntMethod(bridge, start_method, static_cast<jlong>(generation), static_cast<jlong>(program), static_cast<jint>(port));
    if (exception(env.value)) result = -EIO;
    if (result != 0) {
        std::lock_guard<std::recursive_mutex> lock(gate);
        if (epoch == generation) { active = false; offline(); }
    }
    return trace.result(result > 0 ? -EIO : result);
}
void hosting(int on) {
    CallTrace trace("set_hosting");
    std::lock_guard<std::recursive_mutex> serial(gate);
    { std::lock_guard<std::recursive_mutex> lock(gate); if (!active) return; }
    Env env;
    if (!env.value) trace.status = -EIO;
    else { env.value->CallVoidMethod(bridge, hosting_method, on ? JNI_TRUE : JNI_FALSE); if (exception(env.value)) trace.status = -EIO; }
}
void stop() {
    CallTrace trace("stop");
    std::lock_guard<std::recursive_mutex> serial(gate);
    { std::lock_guard<std::recursive_mutex> lock(gate); active = false; ++epoch; }
    // Java only posts cleanup, never waits for the handler or calls managed code.
    // One recursive gate avoids control/callback lock inversion during reentrancy.
    Env env;
    if (!env.value) trace.status = -EIO;
    else if (bridge) { env.value->CallVoidMethod(bridge, stop_method); if (exception(env.value)) trace.status = -EIO; }
}
std::string string(JNIEnv *env, jstring value) {
    if (!value) return {};
    const char *text = env->GetStringUTFChars(value, nullptr);
    if (!text) return {};
    std::string result(text); env->ReleaseStringUTFChars(value, text); return result;
}
bool valid_name(const std::string &name) {
    if (name.compare(0, prefix.size(), prefix) != 0) return false;
    size_t i = prefix.size();
    if (i < name.size() && name[i] == '!') ++i;
    if (i == name.size() || name.size() > 63) return false;
    for (; i < name.size(); ++i) {
        unsigned char c = name[i];
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
    }
    return true;
}
}
extern "C" const s2a_lan_discovery_v1 *s2a_android_lan_provider(void (*callback)(const char *)) {
    std::lock_guard<std::recursive_mutex> lock(gate);
    if (!callback || (set_server && set_server != callback)) return nullptr;
    set_server = callback;
    static const s2a_lan_discovery_v1 provider = {1, start, hosting, stop};
    return &provider;
}
extern "C" JNIEXPORT jint JNICALL
Java_org_s2arm_android_NativeBridge_configureLanDiscovery(JNIEnv *env, jclass, jobject object) {
    std::lock_guard<std::recursive_mutex> serial(gate);
    if (bridge) return env->IsSameObject(bridge, object) ? 0 : -EBUSY;
    if (!object || env->GetJavaVM(&vm) != JNI_OK) return -EINVAL;
    jclass type = env->GetObjectClass(object);
    start_method = env->GetMethodID(type, "start", "(JJI)I");
    hosting_method = env->GetMethodID(type, "setHosting", "(Z)V");
    stop_method = env->GetMethodID(type, "stop", "()V");
    jmethodID identity = env->GetMethodID(type, "deviceId", "()Ljava/lang/String;");
    env->DeleteLocalRef(type);
    if (exception(env) || !start_method || !hosting_method || !stop_method || !identity) return -EINVAL;
    auto id = static_cast<jstring>(env->CallObjectMethod(object, identity));
    if (exception(env)) return -EIO;
    device = string(env, id); env->DeleteLocalRef(id);
    if (exception(env) || device.empty() || device.size() > 32 || device.find_first_not_of("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") != std::string::npos) return -EINVAL;
    bridge = env->NewGlobalRef(object);
    return bridge ? 0 : -ENOMEM;
}
extern "C" JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_lanUnavailable(JNIEnv *, jclass, jlong generation) {
    std::lock_guard<std::recursive_mutex> lock(gate);
    if (!active || static_cast<uint64_t>(generation) != epoch) return;
    offline(); active = false;
    __android_log_print(ANDROID_LOG_ERROR, "S2Arm", "【红】LAN discovery unavailable; stopped session");
}
extern "C" JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_lanSnapshot(JNIEnv *env, jclass, jlong generation,
    jstring own, jobjectArray names, jobjectArray addresses, jintArray ports) {
    std::lock_guard<std::recursive_mutex> lock(gate);
    if (!active || static_cast<uint64_t>(generation) != epoch || !names || !addresses || !ports) return;
    jsize count = env->GetArrayLength(names);
    if (count != env->GetArrayLength(addresses) || count != env->GetArrayLength(ports)) return;
    std::vector<std::string> candidates, ips;
    std::string local = string(env, own);
    if (valid_name(local) && s2a_lan_is_self(prefix.c_str(), device.c_str(), local.c_str())) {
        candidates.push_back(local); ips.emplace_back("127.0.0.1");
    } else { offline(); return; }
    for (jsize i = 0; i < count; ++i) {
        jint port; env->GetIntArrayRegion(ports, i, 1, &port);
        auto n = static_cast<jstring>(env->GetObjectArrayElement(names, i));
        auto a = static_cast<jstring>(env->GetObjectArrayElement(addresses, i));
        std::string name = string(env, n), address = string(env, a);
        env->DeleteLocalRef(n); env->DeleteLocalRef(a);
        if (exception(env)) return;
        in_addr parsed{};
        if (port != local_port || !valid_name(name) || s2a_lan_is_self(prefix.c_str(), device.c_str(), name.c_str()) || inet_pton(AF_INET, address.c_str(), &parsed) != 1) continue;
        candidates.push_back(name); ips.push_back(address);
    }
    std::vector<const char *> pointers;
    for (const auto &name : candidates) pointers.push_back(name.c_str());
    int winner = s2a_lan_elect(prefix.c_str(), pointers.data(), static_cast<int>(pointers.size()));
    std::string ip = winner < 0 ? "" : ips[static_cast<size_t>(winner)];
    // Emit admitted peer count even when selection is unchanged: a local winner
    // alone does not prove that discovery accepted the other device.
    __android_log_print(ANDROID_LOG_INFO, "S2Arm", "LAN snapshot: accepted_peers=%zu winner=%s",
        candidates.size() - 1, winner < 0 ? "none" : winner == 0 ? "self" : "peer");
    if (have_chosen && ip == chosen) return;
    chosen = ip; have_chosen = true;
    __android_log_print(ANDROID_LOG_INFO, "S2Arm", "LAN relay: %s (%s)", winner < 0 ? "none" : candidates[static_cast<size_t>(winner)].c_str(), ip.c_str());
    set_server(ip.empty() ? nullptr : ip.c_str());
}
