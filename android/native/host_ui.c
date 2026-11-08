#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "host_ui.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// All storage is bounded per broker; IDs are process-wide and never recycled,
// including after a session is destroyed. Exhaustion fails instead of wrapping.
static _Atomic uint64_t next_id = 1;
enum request_state { FREE, QUEUED, DELIVERED, ANSWERED };
struct request {
  uint64_t id;
  enum request_state state;
  size_t length;
  char bytes[S2A_UI_REPLY_LIMIT + 1];
};
struct s2a_ui_broker {
  pthread_mutex_t mutex;
  pthread_cond_t changed;
  uint64_t session;
  int available, stopped;
  struct request requests[S2A_UI_PENDING_LIMIT];
};

// Reject invalid UTF-8 without interpreting or publishing a UI wire schema.
static int text_length(const char *text, size_t limit, size_t *length) {
  if (!text) return S2A_HOST_E_ARGUMENT;
  size_t size = strnlen(text, limit + 1);
  if (!size) return S2A_HOST_E_ARGUMENT;
  if (size > limit) return S2A_HOST_E_RANGE;
  const unsigned char *p = (const unsigned char *)text;
  for (size_t i = 0; i < size;) {
    unsigned c = p[i++], count, value, minimum;
    if (c < 0x80) continue;
    if (c >= 0xc2 && c <= 0xdf) { count = 1; value = c & 31; minimum = 0x80; }
    else if (c >= 0xe0 && c <= 0xef) { count = 2; value = c & 15; minimum = 0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { count = 3; value = c & 7; minimum = 0x10000; }
    else return S2A_HOST_E_ARGUMENT;
    if (count > size - i) return S2A_HOST_E_ARGUMENT;
    while (count--) {
      unsigned tail = p[i++];
      if ((tail & 0xc0) != 0x80) return S2A_HOST_E_ARGUMENT;
      value = (value << 6) | (tail & 63);
    }
    if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff))
      return S2A_HOST_E_ARGUMENT;
  }
  *length = size;
  return S2A_HOST_E_OK;
}
static struct request *find(s2a_ui_broker *b, uint64_t id) {
  for (size_t i = 0; i < S2A_UI_PENDING_LIMIT; i++)
    if (b->requests[i].state != FREE && b->requests[i].id == id) return &b->requests[i];
  return NULL;
}
static int active(s2a_ui_broker *b) { return b->available && !b->stopped; }
static void cancel_all(s2a_ui_broker *b) {
  memset(b->requests, 0, sizeof b->requests);
  pthread_cond_broadcast(&b->changed);
}
static int copy_text(struct request *r, char *out, size_t capacity, size_t *length) {
  *length = r->length + 1;
  if (capacity < *length) return S2A_HOST_E_RANGE;
  if (!out) return S2A_HOST_E_ARGUMENT;
  memcpy(out, r->bytes, *length);
  *length = r->length;
  return S2A_HOST_E_OK;
}
static int begin(void *host, const char *text, uint64_t *id) {
  if (!host || !id) return S2A_HOST_E_ARGUMENT;
  *id = 0;
  size_t length;
  int rc = text_length(text, S2A_UI_REQUEST_LIMIT, &length);
  if (rc) return rc;
  s2a_ui_broker *b = host;
  pthread_mutex_lock(&b->mutex);
  rc = S2A_HOST_E_UNSUPPORTED;
  if (active(b)) {
    rc = S2A_HOST_E_INTERNAL;
    for (size_t i = 0; i < S2A_UI_PENDING_LIMIT; i++) {
      struct request *r = &b->requests[i];
      if (r->state != FREE) continue;
      uint64_t value = atomic_load_explicit(&next_id, memory_order_relaxed);
      while (value != UINT64_MAX &&
             !atomic_compare_exchange_weak_explicit(&next_id, &value, value + 1,
                                                    memory_order_relaxed, memory_order_relaxed)) {}
      if (value == UINT64_MAX) break;
      r->id = value;
      r->state = QUEUED;
      r->length = length;
      memcpy(r->bytes, text, length + 1);
      *id = value;
      rc = S2A_HOST_E_OK;
      break;
    }
  }
  pthread_mutex_unlock(&b->mutex);
  return rc;
}
static struct timespec now(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return value;
}
static int wait_reply(void *host, uint64_t id, int timeout_ms, char *out,
                      size_t capacity, size_t *length) {
  if (!host || !id || timeout_ms < 0 || !length || (!out && capacity)) return S2A_HOST_E_ARGUMENT;
  *length = 0;
  struct timespec deadline = now();
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000;
  if (deadline.tv_nsec >= 1000000000) { deadline.tv_nsec -= 1000000000; deadline.tv_sec++; }
  s2a_ui_broker *b = host;
  pthread_mutex_lock(&b->mutex);
  int rc = active(b) ? S2A_HOST_E_ARGUMENT : S2A_HOST_E_UNSUPPORTED;
  struct request *r = find(b, id);
  if (active(b) && r) {
    int timed_out = 0;
    for (;;) {
      if (!active(b) || !(r = find(b, id))) { rc = S2A_HOST_E_UNSUPPORTED; break; }
      if (r->state == ANSWERED) {
        rc = copy_text(r, out, capacity, length);
        if (!rc) memset(r, 0, sizeof *r);
        break;
      }
      // A timeout can race a signal and mutex reacquisition. Only report
      // pending after rechecking the protected predicates above, exactly as
      // after a normal/spurious wake. Do not consume a reply on RANGE.
      if (timed_out) { rc = S2A_HOST_E_TIMEOUT; break; }
      int error;
#if defined(__APPLE__)
      // Darwin's condvar clock is realtime; use its monotonic relative wait.
      struct timespec current = now();
      struct timespec remaining = {deadline.tv_sec - current.tv_sec, deadline.tv_nsec - current.tv_nsec};
      if (remaining.tv_nsec < 0) { remaining.tv_nsec += 1000000000; remaining.tv_sec--; }
      if (remaining.tv_sec < 0) { rc = S2A_HOST_E_TIMEOUT; break; }
      error = pthread_cond_timedwait_relative_np(&b->changed, &b->mutex, &remaining);
#else
      error = pthread_cond_timedwait(&b->changed, &b->mutex, &deadline);
#endif
      if (error == ETIMEDOUT) { timed_out = 1; continue; }
      if (error) { rc = S2A_HOST_E_INTERNAL; break; }
    }
  }
  pthread_mutex_unlock(&b->mutex);
  return rc;
}
static int cancel(void *host, uint64_t id) {
  if (!host || !id) return S2A_HOST_E_ARGUMENT;
  s2a_ui_broker *b = host;
  pthread_mutex_lock(&b->mutex);
  struct request *r = find(b, id);
  if (r) memset(r, 0, sizeof *r);
  pthread_cond_broadcast(&b->changed);
  pthread_mutex_unlock(&b->mutex);
  return S2A_HOST_E_OK;
}
static const s2a_host_ui_v1 table = {
  {sizeof(s2a_host_ui_v1), S2A_HOST_API_ABI_VERSION}, begin, wait_reply, cancel,
};
const s2a_host_ui_v1 *s2a_ui_broker_table(void) { return &table; }

s2a_ui_broker *s2a_ui_broker_create(uint64_t session) {
  if (!session) return NULL;
  s2a_ui_broker *b = calloc(1, sizeof *b);
  if (!b) return NULL;
  if (pthread_mutex_init(&b->mutex, NULL)) { free(b); return NULL; }
  pthread_condattr_t attributes;
  int error = pthread_condattr_init(&attributes);
  if (error) { pthread_mutex_destroy(&b->mutex); free(b); return NULL; }
#if !defined(__APPLE__)
  error = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC);
#endif
  if (!error) error = pthread_cond_init(&b->changed, &attributes);
  pthread_condattr_destroy(&attributes);
  if (error) { pthread_mutex_destroy(&b->mutex); free(b); return NULL; }
  b->session = session;
  return b;
}
void s2a_ui_broker_destroy(s2a_ui_broker *b) {
  if (!b) return;
  // The owner has quiesced all callers; wake/join belongs before destruction.
  pthread_cond_destroy(&b->changed);
  pthread_mutex_destroy(&b->mutex);
  memset(b, 0, sizeof *b);
  free(b);
}
int s2a_ui_broker_active(s2a_ui_broker *b) {
  if (!b) return 0;
  pthread_mutex_lock(&b->mutex);
  int result = active(b);
  pthread_mutex_unlock(&b->mutex);
  return result;
}
int s2a_ui_broker_pending(s2a_ui_broker *b) {
  if (!b) return 0;
  pthread_mutex_lock(&b->mutex);
  int result = 0;
  for (size_t i = 0; i < S2A_UI_PENDING_LIMIT; i++)
    if (b->requests[i].state == QUEUED || b->requests[i].state == DELIVERED) result = 1;
  pthread_mutex_unlock(&b->mutex);
  return result;
}
int s2a_ui_broker_available(s2a_ui_broker *b, uint64_t session, int available) {
  if (!b || session != b->session) return S2A_HOST_E_ARGUMENT;
  pthread_mutex_lock(&b->mutex);
  int rc = b->stopped ? S2A_HOST_E_UNSUPPORTED : S2A_HOST_E_OK;
  if (!rc) { b->available = !!available; if (!available) cancel_all(b); }
  pthread_mutex_unlock(&b->mutex);
  return rc;
}
int s2a_ui_broker_stop(s2a_ui_broker *b, uint64_t session) {
  if (!b || session != b->session) return S2A_HOST_E_ARGUMENT;
  pthread_mutex_lock(&b->mutex);
  b->stopped = 1;
  cancel_all(b);
  pthread_mutex_unlock(&b->mutex);
  return S2A_HOST_E_OK;
}
int s2a_ui_broker_take(s2a_ui_broker *b, uint64_t session, uint64_t *id,
                     char *out, size_t capacity, size_t *length) {
  if (!b || session != b->session || !id || !length || (!out && capacity)) return S2A_HOST_E_ARGUMENT;
  *id = 0; *length = 0;
  pthread_mutex_lock(&b->mutex);
  int rc = S2A_HOST_E_UNSUPPORTED;
  if (active(b)) {
    struct request *first = NULL;
    for (size_t i = 0; i < S2A_UI_PENDING_LIMIT; i++) {
      struct request *r = &b->requests[i];
      if (r->state == QUEUED && (!first || r->id < first->id)) first = r;
    }
    rc = S2A_HOST_E_TIMEOUT;
    if (first) {
      rc = copy_text(first, out, capacity, length);
      if (!rc) { *id = first->id; first->state = DELIVERED; memset(first->bytes, 0, sizeof first->bytes); first->length = 0; }
    }
  }
  pthread_mutex_unlock(&b->mutex);
  return rc;
}
int s2a_ui_broker_complete(s2a_ui_broker *b, uint64_t session, uint64_t id, const char *reply) {
  if (!b || session != b->session || !id) return S2A_HOST_E_ARGUMENT;
  size_t length;
  int rc = text_length(reply, S2A_UI_REPLY_LIMIT, &length);
  if (rc) return rc;
  pthread_mutex_lock(&b->mutex);
  struct request *r = find(b, id);
  rc = active(b) ? S2A_HOST_E_ARGUMENT : S2A_HOST_E_UNSUPPORTED;
  if (active(b) && r && r->state == DELIVERED) {
    memcpy(r->bytes, reply, length + 1);
    r->length = length; r->state = ANSWERED;
    pthread_cond_broadcast(&b->changed);
    rc = S2A_HOST_E_OK;
  }
  pthread_mutex_unlock(&b->mutex);
  return rc;
}
