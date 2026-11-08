// 宿主回归用的系统属性头桩（见同目录 android/native_window.h）。
#pragma once

#define PROP_VALUE_MAX 92

#ifdef __cplusplus
extern "C" {
#endif
int __system_property_get(const char *name, char *value);
#ifdef __cplusplus
}
#endif
