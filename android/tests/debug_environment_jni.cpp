// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "debug_environment.h"
static s2a::DebugEnvironment state;
// Host-only adapters for the unrelated Android stderr/property hooks. The
// production JNI_OnLoad body is compiled verbatim and invoked by System.load.
[[maybe_unused]] static s2a::DebugEnvironment &g_debug_environment = state;
static void s2a_redirect_stderr_once() {}
static char g_exitlog_path[128];
static int __system_property_get(const char *, char *) { return 0; }
static void s2a_exit_probe() {}
#include "onload.inc"
static int writes_until_failure = -1;
static int set_value(const char *key, const char *value, int overwrite) {
    if (writes_until_failure == 0) { errno = ENOMEM; return -1; }
    if (writes_until_failure > 0) --writes_until_failure;
    return setenv(key, value, overwrite);
}
extern "C" JNIEXPORT jint JNICALL Java_org_s2arm_android_DebugEnvironmentTest_apply(JNIEnv *env, jclass, jobjectArray values) {
    return state.apply(env, values, set_value);
}
extern "C" JNIEXPORT jboolean JNICALL Java_org_s2arm_android_DebugEnvironmentTest_seal(JNIEnv *, jclass) { return state.seal(); }
extern "C" JNIEXPORT jstring JNICALL Java_org_s2arm_android_DebugEnvironmentTest_value(JNIEnv *env, jclass, jstring key) {
    const char *chars = env->GetStringUTFChars(key, nullptr);
    const char *value = getenv(chars);
    env->ReleaseStringUTFChars(key, chars);
    return value ? env->NewStringUTF(value) : nullptr;
}
extern "C" JNIEXPORT void JNICALL Java_org_s2arm_android_DebugEnvironmentTest_failSetenv(JNIEnv *, jclass) { writes_until_failure = 1; }
