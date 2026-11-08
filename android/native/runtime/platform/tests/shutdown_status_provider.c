// The actual runtime result validator, with only its preexisting startup facts
// seeded for this shutdown-only fixture. This is not a second result checker.
#ifndef S2A_SHUTDOWN_RUNTIME_SOURCE
#define S2A_SHUTDOWN_RUNTIME_SOURCE "../../runtime.c"
#endif
#include S2A_SHUTDOWN_RUNTIME_SOURCE

void s2a_shutdown_test_begin_services(uint64_t session, int attempted) {
    pthread_mutex_lock(&g_lock);
    g_used = 1;
    g_status.session_id = session;
    g_services_attempted = attempted;
    pthread_mutex_unlock(&g_lock);
}
