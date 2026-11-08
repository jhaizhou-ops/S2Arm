#pragma once
#include "s2a_hostapi.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Android's bounded UI transport. JSON is opaque here: the eventual producer
// must validate the W11 request/reply schema before displaying/completing it.
// This module does not register HostApi or advertise S2A_HOST_CAP_UI.
#define S2A_UI_PENDING_LIMIT 8u
#define S2A_UI_REQUEST_LIMIT 4096u
#define S2A_UI_REPLY_LIMIT 8192u

typedef struct s2a_ui_broker s2a_ui_broker;

// session must be nonzero. Created unavailable; only a ready, schema-aware UI
// producer may enable it. Allocation failure returns NULL. No callback borrows
// caller strings after returning. Ordinary threads only, never signal handlers.
s2a_ui_broker *s2a_ui_broker_create(uint64_t session);
// The owner must stop and join all callers before destroy. No blocking operation
// on an Activity/UI or renderer thread; wait() is for core worker threads only.
void s2a_ui_broker_destroy(s2a_ui_broker *broker);
int s2a_ui_broker_available(s2a_ui_broker *broker, uint64_t session, int available);
int s2a_ui_broker_active(s2a_ui_broker *broker);
int s2a_ui_broker_pending(s2a_ui_broker *broker);
// Terminal; cancels queued/delivered/answered requests and wakes every waiter.
int s2a_ui_broker_stop(s2a_ui_broker *broker, uint64_t session);

// Existing s2a_host_ui_v1 callbacks; their host argument is this broker. A host
// with another HostApi context must delegate with its broker, not cast that host.
// wait(): stopped/unavailable returns E_UNSUPPORTED, regardless of ID. When
// available, an ID absent at entry returns E_ARGUMENT (unknown, canceled, or
// already consumed). Once admitted, losing that ID during wait returns
// E_UNSUPPORTED (cancel or a competing successful consumer). No tombstones or
// terminal-reason history are retained; these codes do not identify that cause.
// No new public error/JSON is invented. Queue full or exhausted IDs return
// E_INTERNAL. cancel(nonzero) is idempotent, even after stop.
// Timeout must be >=0 ms; zero polls. RANGE retains the answer and returns the
// required buffer capacity INCLUDING NUL; success length EXCLUDES NUL.
const s2a_host_ui_v1 *s2a_ui_broker_table(void);

// Nonblocking producer handoff, FIFO by begin admission. RANGE retains the same
// queued request; length rules match wait(). Success copies the request, never a
// borrowed pointer. No request returns E_TIMEOUT. Only a taken ID can complete.
int s2a_ui_broker_take(s2a_ui_broker *broker, uint64_t session, uint64_t *id,
                     char *request, size_t capacity, size_t *length);
int s2a_ui_broker_complete(s2a_ui_broker *broker, uint64_t session, uint64_t id,
                         const char *reply);

#ifdef __cplusplus
}
#endif
