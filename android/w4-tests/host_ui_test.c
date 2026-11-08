#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "host_ui.h"
#include "wait_probe.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static const s2a_host_ui_v1 *ui;
static uint64_t begin(s2a_ui_broker *b, const char *text) {
  uint64_t id = 0;
  CHECK(ui->begin(b, text, &id) == S2A_HOST_E_OK && id != 0);
  return id;
}
static void take(s2a_ui_broker *b, uint64_t session, uint64_t expected, const char *text) {
  char out[S2A_UI_REQUEST_LIMIT + 1]; size_t n = 0; uint64_t id = 0;
  CHECK(s2a_ui_broker_take(b, session, &id, out, sizeof out, &n) == 0);
  CHECK(id == expected && n == strlen(text) && !strcmp(out, text));
}
static void answer(s2a_ui_broker *b, uint64_t id, const char *text) {
  char out[S2A_UI_REPLY_LIMIT + 1]; size_t n = 0;
  CHECK(ui->wait(b, id, 0, out, sizeof out, &n) == 0);
  CHECK(n == strlen(text) && !strcmp(out, text));
  CHECK(ui->wait(b, id, 0, out, sizeof out, &n) == S2A_HOST_E_ARGUMENT);
}
static void limits_and_lifetime(void) {
  CHECK(!s2a_ui_broker_create(0));
  s2a_ui_broker *b = s2a_ui_broker_create(1); CHECK(b);
  uint64_t id = 99; size_t n; char out[64];
  CHECK(ui->begin(b, "{}", &id) == S2A_HOST_E_UNSUPPORTED && id == 0);
  CHECK(s2a_ui_broker_available(b, 2, 1) == S2A_HOST_E_ARGUMENT);
  CHECK(s2a_ui_broker_available(b, 1, 1) == 0);
  char request[] = "{\"text\":\"你好\"}";
  id = begin(b, request); request[2] = 'X';
  CHECK(ui->wait(b, id, 0, out, sizeof out, &n) == S2A_HOST_E_TIMEOUT);
  CHECK(ui->wait(b, id, -1, out, sizeof out, &n) == S2A_HOST_E_ARGUMENT);
  CHECK(s2a_ui_broker_complete(b, 1, id, "{}") == S2A_HOST_E_ARGUMENT);
  uint64_t delivered = 99;
  CHECK(s2a_ui_broker_take(b, 1, &delivered, NULL, 0, &n) == S2A_HOST_E_RANGE && delivered == 0);
  CHECK(n == strlen("{\"text\":\"你好\"}") + 1);
  take(b, 1, id, "{\"text\":\"你好\"}");
  char reply[] = "{\"answer\":\"😀\"}";
  CHECK(s2a_ui_broker_complete(b, 2, id, reply) == S2A_HOST_E_ARGUMENT);
  CHECK(s2a_ui_broker_complete(b, 1, id, reply) == 0); reply[2] = 'X';
  CHECK(s2a_ui_broker_complete(b, 1, id, "{}") == S2A_HOST_E_ARGUMENT);
  CHECK(ui->wait(b, id, 0, NULL, 0, &n) == S2A_HOST_E_RANGE);
  size_t capacity = n; CHECK(capacity == strlen("{\"answer\":\"😀\"}") + 1);
  CHECK(ui->wait(b, id, 0, out, capacity - 1, &n) == S2A_HOST_E_RANGE && n == capacity);
  answer(b, id, "{\"answer\":\"😀\"}");
  CHECK(s2a_ui_broker_stop(b, 1) == 0);
  CHECK(s2a_ui_broker_stop(b, 1) == 0);
  CHECK(s2a_ui_broker_available(b, 1, 1) == S2A_HOST_E_UNSUPPORTED);
  CHECK(ui->begin(b, "{}", &id) == S2A_HOST_E_UNSUPPORTED);
  CHECK(ui->cancel(b, 55) == 0);
  s2a_ui_broker_destroy(b);
}
static void invalid_and_capacity(void) {
  s2a_ui_broker *b = s2a_ui_broker_create(3); CHECK(b);
  CHECK(s2a_ui_broker_available(b, 3, 1) == 0);
  uint64_t id; const char *bad[] = {NULL, "", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\x80"};
  for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) CHECK(ui->begin(b, bad[i], &id) == S2A_HOST_E_ARGUMENT);
  char large[S2A_UI_REPLY_LIMIT + 2]; memset(large, 'x', sizeof large); large[sizeof large - 1] = 0;
  CHECK(ui->begin(b, large, &id) == S2A_HOST_E_RANGE);
  uint64_t ids[S2A_UI_PENDING_LIMIT];
  for (size_t i = 0; i < S2A_UI_PENDING_LIMIT; i++) ids[i] = begin(b, "{}");
  CHECK(ui->begin(b, "{}", &id) == S2A_HOST_E_INTERNAL && id == 0);
  CHECK(ui->cancel(b, ids[0]) == 0 && ui->cancel(b, ids[0]) == 0);
  id = begin(b, "{\"new\":true}"); CHECK(id > ids[S2A_UI_PENDING_LIMIT - 1]);
  take(b, 3, ids[1], "{}");
  CHECK(s2a_ui_broker_complete(b, 3, ids[1], large) == S2A_HOST_E_RANGE);
  CHECK(s2a_ui_broker_complete(b, 3, ids[1], "\xed\xa0\x80") == S2A_HOST_E_ARGUMENT);
  CHECK(s2a_ui_broker_complete(b, 3, ids[1], "{}") == 0);
  answer(b, ids[1], "{}");
  CHECK(s2a_ui_broker_available(b, 3, 0) == 0);
  CHECK(s2a_ui_broker_available(b, 3, 1) == 0);
  CHECK(s2a_ui_broker_complete(b, 3, ids[1], "{}") == S2A_HOST_E_ARGUMENT);
  size_t n; char out[8];
  CHECK(ui->wait(b, id, 0, out, sizeof out, &n) == S2A_HOST_E_ARGUMENT);
  CHECK(s2a_ui_broker_stop(b, 3) == 0); s2a_ui_broker_destroy(b);
}
static void old_session(void) {
  s2a_ui_broker *old = s2a_ui_broker_create(10); CHECK(old);
  CHECK(s2a_ui_broker_available(old, 10, 1) == 0);
  uint64_t old_id = begin(old, "{}"); take(old, 10, old_id, "{}");
  CHECK(s2a_ui_broker_stop(old, 10) == 0); s2a_ui_broker_destroy(old);
  s2a_ui_broker *fresh = s2a_ui_broker_create(11); CHECK(fresh);
  CHECK(s2a_ui_broker_available(fresh, 11, 1) == 0);
  uint64_t id = begin(fresh, "{}"); take(fresh, 11, id, "{}");
  CHECK(id != old_id);
  CHECK(s2a_ui_broker_complete(fresh, 10, old_id, "{}") == S2A_HOST_E_ARGUMENT);
  CHECK(s2a_ui_broker_complete(fresh, 11, old_id, "{}") == S2A_HOST_E_ARGUMENT);
  CHECK(ui->cancel(fresh, old_id) == 0);
  CHECK(s2a_ui_broker_complete(fresh, 11, id, "{}") == 0); answer(fresh, id, "{}");
  CHECK(s2a_ui_broker_stop(fresh, 11) == 0); s2a_ui_broker_destroy(fresh);
}
struct waiter {s2a_ui_broker *b; uint64_t id; atomic_int ready; int result;};
static void *waiting(void *opaque) {
  struct waiter *w = opaque; char out[32]; size_t n;
  s2a_ui_test_observe_wait(&w->ready);
  w->result = ui->wait(w->b, w->id, 2000, out, sizeof out, &n);
  return NULL;
}
static void wake_cancel_stop(void) {
  for (int mode = 0; mode < 3; mode++) {
    s2a_ui_broker *b = s2a_ui_broker_create(20); CHECK(b);
    CHECK(s2a_ui_broker_available(b, 20, 1) == 0);
    struct waiter w = {.b = b, .id = begin(b, "{}")};
    pthread_t thread; CHECK(pthread_create(&thread, NULL, waiting, &w) == 0);
    while (!atomic_load(&w.ready)) { struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL); }
    if (mode == 0) CHECK(ui->cancel(b, w.id) == 0);
    if (mode == 1) CHECK(s2a_ui_broker_available(b, 20, 0) == 0);
    if (mode == 2) CHECK(s2a_ui_broker_stop(b, 20) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(w.result == S2A_HOST_E_UNSUPPORTED);
    CHECK(s2a_ui_broker_complete(b, 20, w.id, "{}") != 0);
    CHECK(s2a_ui_broker_stop(b, 20) == 0); s2a_ui_broker_destroy(b);
  }
}
static void concurrent_answer(void) {
  s2a_ui_broker *b = s2a_ui_broker_create(40); CHECK(b);
  CHECK(s2a_ui_broker_available(b, 40, 1) == 0);
  uint64_t id = begin(b, "{}");
  struct waiter first = {.b = b, .id = id}, second = {.b = b, .id = id};
  pthread_t one, two;
  CHECK(pthread_create(&one, NULL, waiting, &first) == 0);
  CHECK(pthread_create(&two, NULL, waiting, &second) == 0);
  while (!atomic_load(&first.ready) || !atomic_load(&second.ready)) {
    struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
  }
  take(b, 40, id, "{}"); CHECK(s2a_ui_broker_complete(b, 40, id, "{}") == 0);
  CHECK(pthread_join(one, NULL) == 0 && pthread_join(two, NULL) == 0);
  CHECK((first.result == 0 && second.result == S2A_HOST_E_UNSUPPORTED) ||
        (second.result == 0 && first.result == S2A_HOST_E_UNSUPPORTED));
  CHECK(s2a_ui_broker_stop(b, 40) == 0); s2a_ui_broker_destroy(b);
}
struct timeout_case {s2a_ui_broker *b; uint64_t id; int mode, calls;};
static void publish_at_timeout(void *opaque) {
  struct timeout_case *test = opaque;
  test->calls++;
  if (test->mode == 1 || test->mode == 4)
    CHECK(s2a_ui_broker_complete(test->b, 50, test->id, "{}") == 0);
  if (test->mode == 2) CHECK(ui->cancel(test->b, test->id) == 0);
  if (test->mode == 3) CHECK(s2a_ui_broker_stop(test->b, 50) == 0);
  if (test->mode == 5) CHECK(s2a_ui_broker_available(test->b, 50, 0) == 0);
}
static void timeout_rechecks_state(int mode) {
  s2a_ui_broker *b = s2a_ui_broker_create(50); CHECK(b);
  CHECK(s2a_ui_broker_available(b, 50, 1) == 0);
  uint64_t id = begin(b, "{}"); take(b, 50, id, "{}");
  struct timeout_case test = {.b = b, .id = id, .mode = mode};
  s2a_ui_test_timeout_action(publish_at_timeout, &test);
  char out[8] = "guard"; size_t length = 99;
  int result = ui->wait(b, id, 2000, out, mode == 4 ? 1 : sizeof out, &length);
  CHECK(test.calls == 1); // The real OS returned ETIMEDOUT; the controlled peer then acted.
  if (mode == 0) {
    CHECK(result == S2A_HOST_E_TIMEOUT && length == 0 && !strcmp(out, "guard"));
    CHECK(s2a_ui_broker_complete(b, 50, id, "{}") == 0); answer(b, id, "{}");
  } else if (mode == 1) {
    CHECK(result == 0 && length == 2 && !strcmp(out, "{}"));
    CHECK(ui->wait(b, id, 0, out, sizeof out, &length) == S2A_HOST_E_ARGUMENT);
  } else if (mode == 4) {
    CHECK(result == S2A_HOST_E_RANGE && length == 3 && !strcmp(out, "guard"));
    answer(b, id, "{}");
  } else {
    CHECK(result == S2A_HOST_E_UNSUPPORTED && length == 0 && !strcmp(out, "guard"));
    // There are no tombstones: a new call after cancel is unknown (ARGUMENT),
    // whereas stop/unavailability is checked before lookup (UNSUPPORTED).
    int subsequent = mode == 2 ? S2A_HOST_E_ARGUMENT : S2A_HOST_E_UNSUPPORTED;
    CHECK(ui->wait(b, id, 0, out, sizeof out, &length) == subsequent);
  }
  CHECK(s2a_ui_broker_stop(b, 50) == 0); s2a_ui_broker_destroy(b);
}
static void public_table(void) {
  // The same public HostApi table/validator a concrete Android producer will
  // use; no UI schema or actual Activity is claimed by this controlled peer.
  s2a_ui_broker *b = s2a_ui_broker_create(30); CHECK(b);
  s2a_host_api_v1 api = {.hdr = {sizeof api, S2A_HOST_API_ABI_VERSION}, .capabilities = S2A_HOST_CAP_UI, .host = b, .ui = ui};
  CHECK(s2a_host_register(&api) == 0);
  CHECK(s2a_ui_broker_available(b, 30, 1) == 0);
  const s2a_host_api_v1 *registered = s2a_host_get(); CHECK(registered == &api);
  uint64_t id; CHECK(registered->ui->begin(registered->host, "{}", &id) == 0);
  take(b, 30, id, "{}"); CHECK(s2a_ui_broker_complete(b, 30, id, "{}") == 0); answer(b, id, "{}");
  CHECK(s2a_ui_broker_stop(b, 30) == 0);
  // Registration is process-lived. Clear to a still-valid table before freeing.
  static const s2a_host_api_v1 empty = {.hdr = {sizeof empty, S2A_HOST_API_ABI_VERSION}};
  CHECK(s2a_host_register(&empty) == 0); s2a_ui_broker_destroy(b);
}
int main(int argc, char **argv) {
  alarm(10);
  ui = s2a_ui_broker_table();
  CHECK(ui->hdr.size == sizeof *ui && ui->hdr.abi_version == S2A_HOST_API_ABI_VERSION);
  if (argc == 2) {
    int mode = atoi(argv[1]); CHECK(mode >= 0 && mode <= 5);
    timeout_rechecks_state(mode);
  } else {
    CHECK(argc == 1);
    limits_and_lifetime(); invalid_and_capacity(); old_session(); wake_cancel_stop(); concurrent_answer(); public_table();
    for (int mode = 0; mode <= 5; mode++) timeout_rechecks_state(mode);
  }
  printf("UI broker: %d host assertions passed; no Android producer or game acceptance\n", checks);
  return 0;
}
