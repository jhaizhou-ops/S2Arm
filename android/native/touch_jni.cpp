#include <jni.h>
#include "touch_input.h"
#include "game_touch.h"

// Independent from W3's core bridge. No JNI array pinning across host calls.
extern "C" JNIEXPORT jint JNICALL
Java_org_s2arm_android_TouchInputBridge_touchEnable(JNIEnv *, jclass, jboolean enabled) {
#ifdef S2A_ANDROID_EXPERIMENTAL_TOUCH
    return s2a_android_touch_enable(enabled ? 1 : 0);
#else
    return enabled ? S2A_HOST_E_UNSUPPORTED : S2A_HOST_E_OK;
#endif
}

extern "C" JNIEXPORT jint JNICALL
Java_org_s2arm_android_TouchInputBridge_touchFrame(JNIEnv *env, jclass, jintArray packed,
                                            jint count, jint flags, jlong timestamp_ns,
                                            jlong generation, jlong revision) {
    if (timestamp_ns < 0 || count < 0 || count > static_cast<jint>(S2A_TOUCH_MAX_POINTS) ||
        !packed || env->GetArrayLength(packed) < count * 5 ||
        (flags != 0 && flags != S2A_TOUCH_CANCEL) || (flags && count))
        return S2A_HOST_E_ARGUMENT;
#ifdef S2A_ANDROID_EXPERIMENTAL_TOUCH
    jint values[S2A_TOUCH_MAX_POINTS * 5]{};
    if (count) env->GetIntArrayRegion(packed, 0, count * 5, values);
    if (env->ExceptionCheck()) return S2A_HOST_E_ARGUMENT;
    s2a_host_touch_point points[S2A_TOUCH_MAX_POINTS]{};
    for (jint i = 0; i < count; ++i) {
        points[i] = {static_cast<uint32_t>(values[i * 5]),
            static_cast<uint32_t>(values[i * 5 + 1]), static_cast<uint32_t>(values[i * 5 + 2]),
            static_cast<uint32_t>(values[i * 5 + 3]), static_cast<uint32_t>(values[i * 5 + 4])};
    }
    return s2a_android_game_touch_set(points, static_cast<uint32_t>(count), static_cast<uint32_t>(flags),
        static_cast<uint64_t>(timestamp_ns), static_cast<uint64_t>(generation), static_cast<uint64_t>(revision));
#else
    (void)generation; (void)revision;
    return S2A_HOST_E_UNSUPPORTED;
#endif
}

extern "C" JNIEXPORT jint JNICALL
Java_org_s2arm_android_TouchInputBridge_touchViewport(JNIEnv *env, jclass, jlongArray packed) {
    if (!packed || env->GetArrayLength(packed) < 8) return S2A_HOST_E_ARGUMENT;
    int64_t values[8]{};
    int result = s2a_android_game_touch_viewport_read(values);
    jlong output[8];
    for (int i = 0; i < 8; ++i) output[i] = values[i];
    env->SetLongArrayRegion(packed, 0, 8, output);
    return env->ExceptionCheck() ? S2A_HOST_E_ARGUMENT : result;
}

extern "C" JNIEXPORT void JNICALL
Java_org_s2arm_android_TouchInputBridge_touchViewportRevoke(JNIEnv *, jclass) {
    s2a_android_game_touch_revoke();
}

extern "C" JNIEXPORT void JNICALL
Java_org_s2arm_android_TouchInputBridge_touchViewportRetire(JNIEnv *, jclass) {
    s2a_android_game_touch_retire();
}

extern "C" JNIEXPORT void JNICALL
Java_org_s2arm_android_TouchInputBridge_touchTrace(JNIEnv *, jclass, jboolean enabled) {
    s2a_android_game_touch_trace_set(enabled);
}
