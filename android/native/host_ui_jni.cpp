#include "host_ui_android.h"
#include <jni.h>
#include <cstring>

extern "C" JNIEXPORT jlong JNICALL
Java_org_s2arm_android_NativeBridge_attachHostUi(JNIEnv *, jclass) {
    return static_cast<jlong>(s2a_android_ui_attach());
}
extern "C" JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_detachHostUi(JNIEnv *, jclass, jlong owner) {
    s2a_android_ui_detach(static_cast<uint64_t>(owner));
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_s2arm_android_NativeBridge_takeHostUi(JNIEnv *env, jclass, jlong owner, jlongArray output) {
    if (!output || env->GetArrayLength(output) != 1) return nullptr;
    char text[S2A_UI_REQUEST_LIMIT + 1]; size_t length = 0; uint64_t id = 0;
    int error = s2a_android_ui_take(static_cast<uint64_t>(owner), &id, text, sizeof text, &length);
    if (error) return nullptr;
    jbyteArray result = env->NewByteArray(static_cast<jsize>(length));
    if (!result) {
        s2a_android_ui_complete(static_cast<uint64_t>(owner), id,
            "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"allocation-failed\"}");
        return nullptr;
    }
    jlong request = static_cast<jlong>(id);
    env->SetLongArrayRegion(output, 0, 1, &request);
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(length), reinterpret_cast<const jbyte *>(text));
    return result;
}
extern "C" JNIEXPORT jint JNICALL
Java_org_s2arm_android_NativeBridge_completeHostUi(JNIEnv *env, jclass, jlong owner, jlong id, jbyteArray input) {
    if (!input) return S2A_HOST_E_ARGUMENT;
    jsize length = env->GetArrayLength(input);
    if (length <= 0 || length > static_cast<jsize>(S2A_UI_REPLY_LIMIT)) return S2A_HOST_E_RANGE;
    char text[S2A_UI_REPLY_LIMIT + 1];
    env->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte *>(text));
    if (env->ExceptionCheck()) return S2A_HOST_E_INTERNAL;
    if (std::memchr(text, 0, static_cast<size_t>(length))) return S2A_HOST_E_ARGUMENT;
    text[length] = 0;
    return s2a_android_ui_complete(static_cast<uint64_t>(owner), static_cast<uint64_t>(id), text);
}

extern "C" JNIEXPORT jint JNICALL
Java_org_s2arm_android_NativeBridge_uiSelftest(JNIEnv *, jclass, jint mode, jint min, jint max) {
    return static_cast<jint>(s2a_android_ui_selftest(static_cast<int>(mode),
                                                     static_cast<int>(min),
                                                     static_cast<int>(max)));
}
