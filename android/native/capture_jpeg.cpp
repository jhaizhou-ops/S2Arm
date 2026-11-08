// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "capture_jpeg.h"
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <mutex>

namespace {
std::atomic<JavaVM *> vm{nullptr};
jclass codec = nullptr;
jmethodID encode = nullptr;
std::mutex init_lock;
constexpr uint64_t max_image_bytes = 64ull * 1024 * 1024;

bool clear_exception(JNIEnv *env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionClear();
    return true;
}
struct EnvScope {
    JavaVM *owner;
    JNIEnv *env = nullptr;
    bool attached = false;
    explicit EnvScope(JavaVM *jvm) : owner(jvm) {
        jint rc = owner->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
        if (rc == JNI_EDETACHED) {
#ifdef __ANDROID__
            attached = owner->AttachCurrentThread(&env, nullptr) == JNI_OK;
#else
            attached = owner->AttachCurrentThread(reinterpret_cast<void **>(&env), nullptr) == JNI_OK;
#endif
            if (!attached) env = nullptr;
        } else if (rc != JNI_OK) env = nullptr;
    }
    ~EnvScope() { if (attached) owner->DetachCurrentThread(); }
};
struct LocalScope {
    JNIEnv *env;
    bool ready;
    explicit LocalScope(JNIEnv *e) : env(e), ready(e->PushLocalFrame(8) == JNI_OK) {
        if (!ready) clear_exception(env);
    }
    ~LocalScope() { if (ready) env->PopLocalFrame(nullptr); }
};
}

int s2a_android_capture_init(JNIEnv *env, jclass encoder) {
    if (!env || !encoder) return EINVAL;
    std::lock_guard<std::mutex> lock(init_lock);
    JavaVM *jvm = nullptr;
    if (env->GetJavaVM(&jvm) != JNI_OK || !jvm) return EIO;
    if (vm.load(std::memory_order_acquire))
        return vm.load(std::memory_order_relaxed) == jvm && env->IsSameObject(codec, encoder) ? 0 : EALREADY;
    jmethodID method = env->GetStaticMethodID(encoder, "encodeRgba", "([BIII)[B");
    if (clear_exception(env) || !method) return EINVAL;
    jclass reference = static_cast<jclass>(env->NewGlobalRef(encoder));
    if (clear_exception(env) || !reference) return ENOMEM;
    codec = reference; // One class ref for the process's JavaVM lifetime; no Activity retained.
    encode = method;
    vm.store(jvm, std::memory_order_release);
    return 0;
}

int s2a_android_encode_jpeg(const uint8_t *rgba, uint64_t bytes, int32_t width, int32_t height,
                          int32_t quality, uint8_t **jpeg, uint64_t *length) {
    if (!jpeg || !length) return EINVAL;
    *jpeg = nullptr;
    *length = 0;
    if (!rgba || width <= 0 || height <= 0 || width > 4096 || height > 4096 || quality < 0 || quality > 100
        || bytes != static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4 || bytes > max_image_bytes)
        return EINVAL;
    JavaVM *jvm = vm.load(std::memory_order_acquire);
    if (!jvm) return ENODEV;
    EnvScope thread(jvm);
    if (!thread.env) return EIO;
    JNIEnv *env = thread.env;
    LocalScope locals(env);
    if (!locals.ready) return ENOMEM;
    jbyteArray input = env->NewByteArray(static_cast<jsize>(bytes));
    if (clear_exception(env) || !input) return ENOMEM;
    env->SetByteArrayRegion(input, 0, static_cast<jsize>(bytes), reinterpret_cast<const jbyte *>(rgba));
    if (clear_exception(env)) return EIO;
    auto output = static_cast<jbyteArray>(env->CallStaticObjectMethod(codec, encode, input,
        static_cast<jint>(width), static_cast<jint>(height), static_cast<jint>(quality)));
    if (clear_exception(env) || !output) return EIO;
    jsize count = env->GetArrayLength(output);
    if (clear_exception(env) || count < 4 || static_cast<uint64_t>(count) > max_image_bytes) return EBADMSG;
    auto data = static_cast<uint8_t *>(std::malloc(static_cast<size_t>(count)));
    if (!data) return ENOMEM;
    env->GetByteArrayRegion(output, 0, count, reinterpret_cast<jbyte *>(data));
    if (clear_exception(env)) { std::free(data); return EIO; }
    if (data[0] != 0xff || data[1] != 0xd8 || data[count-2] != 0xff || data[count-1] != 0xd9) {
        std::free(data); return EBADMSG;
    }
    *jpeg = data;
    *length = static_cast<uint64_t>(count);
    return 0;
}

void s2a_android_free_jpeg(void *jpeg) { std::free(jpeg); }
