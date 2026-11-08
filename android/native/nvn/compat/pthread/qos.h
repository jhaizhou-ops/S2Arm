#pragma once
typedef int pthread_qos_class_t;
#define QOS_CLASS_USER_INTERACTIVE 0x21
#define QOS_CLASS_UNSPECIFIED 0
static inline int pthread_set_qos_class_self_np(pthread_qos_class_t c, int p) { (void)c; (void)p; return 0; }
