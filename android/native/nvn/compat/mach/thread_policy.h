#pragma once
#ifndef S2A_THREAD_POLICY_T
#define S2A_THREAD_POLICY_T
typedef void *thread_policy_t;
#endif
typedef int integer_t;
#define THREAD_AFFINITY_POLICY 4
static inline int thread_policy_set(unsigned t, int f, void *p, int c) { (void)t; (void)f; (void)p; (void)c; return 0; }
