#pragma once
#define ANDROID_LOG_INFO 4
#define PROP_VALUE_MAX 92
int __android_log_print(int,const char*,const char*,...);
int __system_property_get(const char*,char*);
