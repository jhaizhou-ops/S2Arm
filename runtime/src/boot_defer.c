// UIKit initial activation shares this continuation owner with host_main.
#include "native.h"
#include "s2a_boot.h"
#include <pthread.h>

static pthread_mutex_t g_boot_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_boot_entry g_boot_entry;
static int g_boot_taken;

int s2a_host_boot_defer(s2a_boot_entry entry, int needs_import_ui) {
    if (!entry) return -1;
    if (!s2a_process_prewarmed() && !needs_import_ui) return 0;
    pthread_mutex_lock(&g_boot_mu);
    int result = g_boot_entry && g_boot_entry != entry ? -1 : 1;
    if (result == 1) g_boot_entry = entry;
    pthread_mutex_unlock(&g_boot_mu);
    return result;
}
int s2a_host_boot_deferred(void) {
    pthread_mutex_lock(&g_boot_mu);
    int deferred = g_boot_entry != NULL;
    pthread_mutex_unlock(&g_boot_mu);
    return deferred;
}
int s2a_host_boot_pending(void) {
    pthread_mutex_lock(&g_boot_mu);
    int pending = g_boot_entry && !g_boot_taken;
    pthread_mutex_unlock(&g_boot_mu);
    return pending;
}
s2a_boot_entry s2a_host_boot_take(void) {
    pthread_mutex_lock(&g_boot_mu);
    s2a_boot_entry entry = g_boot_taken ? NULL : g_boot_entry;
    if (entry) g_boot_taken = 1;
    pthread_mutex_unlock(&g_boot_mu);
    return entry;
}
