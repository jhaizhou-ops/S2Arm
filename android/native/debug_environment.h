// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <jni.h>
#include <cerrno>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>
#include "debug_gate.h"

namespace s2a {
// Process-wide one-shot configuration, sealed before any host/service entry.
// A failed setenv may leave a partial environment: poison startup rather than
// pretending rollback is atomic or letting a later Activity retry it.
class DebugEnvironment {
public:
    int apply(JNIEnv *env, jobjectArray entries, int (*write)(const char *, const char *, int) = ::setenv) {
#ifndef S2A_ANDROID_DEBUG_ENV
        (void)env; (void)entries; (void)write;
        return ENOTSUP; // Release does not inspect the input or call setenv.
#else
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_) return EBUSY;
        if (!entries) return EINVAL;
        jsize count = env->GetArrayLength(entries);
        if (count < 1 || count > 32) return EINVAL;
        std::vector<std::pair<std::string, std::string>> values;
        std::unordered_set<std::string> keys;
        size_t total = 0;
        try {
            for (jsize i = 0; i < count; ++i) {
                auto bytes = static_cast<jbyteArray>(env->GetObjectArrayElement(entries, i));
                if (!bytes || env->ExceptionCheck()) return EINVAL;
                jsize length = env->GetArrayLength(bytes);
                total += static_cast<size_t>(length);
                if (length < 6 || length > 8192 || total > 65536) {
                    env->DeleteLocalRef(bytes); return EINVAL;
                }
                std::string entry(static_cast<size_t>(length), '\0');
                env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte *>(entry.data()));
                env->DeleteLocalRef(bytes);
                if (env->ExceptionCheck()) return EINVAL;
                size_t equal = entry.find('=');
                if (entry.find('\0') != std::string::npos || equal == std::string::npos
                        || equal < 5 || entry.compare(0, 4, "S2A_") != 0) return EINVAL;
                for (size_t j = 4; j < equal; ++j) {
                    char c = entry[j];
                    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                            || (c >= '0' && c <= '9') || c == '_')) return EINVAL;
                }
                std::string key = entry.substr(0, equal);
                if (!keys.insert(key).second) return EINVAL;
                values.emplace_back(key, entry.substr(equal + 1));
            }
        } catch (const std::bad_alloc &) { return ENOMEM; }
        // Validation is all-or-nothing; system allocation failure is fail-closed.
        closed_ = true;
        for (const auto &value : values) {
            if (write(value.first.c_str(), value.second.c_str(), 1) != 0) {
                failed_ = true;
                return errno ? errno : EIO;
            }
        }
        return 0;
#endif
    }

    bool seal() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
        // #1456：调试条目门的判定只有原生这一份（编译期宏 + 系统属性两道，debug_gate.h）；
        // 门开时把结果注成 env 标记，托管侧（S2AGsDiag）只读这份结果，不再自写一份判定
        if (s2a_debug_entries_open()) ::setenv("S2A_DEBUG_ENTRIES", "1", 1);
        return !failed_;
    }
private:
    std::mutex mutex_;
    bool closed_ = false;
    bool failed_ = false;
};
}
