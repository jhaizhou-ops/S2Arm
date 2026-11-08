#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "wait_probe.h"
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

static _Thread_local atomic_int *observer;
static _Thread_local void (*timeout_action)(void *);
static _Thread_local void *timeout_context;
void s2a_ui_test_timeout_action(void (*action)(void *), void *context) {
  timeout_action = action;
  timeout_context = context;
}
void s2a_ui_test_observe_wait(atomic_int *entered) { observer = entered; }
#if defined(__APPLE__)
#define WAIT_FUNCTION pthread_cond_timedwait_relative_np
#define WAIT_SYMBOL "pthread_cond_timedwait_relative_np"
#else
#define WAIT_FUNCTION pthread_cond_timedwait
#define WAIT_SYMBOL "pthread_cond_timedwait"
#endif
int WAIT_FUNCTION(pthread_cond_t *condition, pthread_mutex_t *mutex, const struct timespec *timeout) {
  typedef int (*Wait)(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
  Wait real_wait = (Wait)dlsym(RTLD_NEXT, WAIT_SYMBOL);
  if (!real_wait) abort();
  if (observer) atomic_store(observer, 1);
  if (!timeout_action) return real_wait(condition, mutex, timeout);
  void (*action)(void *) = timeout_action;
  void *context = timeout_context;
  timeout_action = NULL;
  timeout_context = NULL;
  // Force a real OS timeout without a sleep or a scheduler-dependent race.
  struct timespec expired = {0, 0};
#if !defined(__APPLE__)
  if (clock_gettime(CLOCK_MONOTONIC, &expired)) abort();
  expired.tv_sec--;
#endif
  int result = real_wait(condition, mutex, &expired);
  if (result != ETIMEDOUT) abort();
  if (pthread_mutex_unlock(mutex)) abort();
  action(context);
  if (pthread_mutex_lock(mutex)) abort();
  return result;
}
