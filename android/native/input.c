#include "input.h"
#include <pthread.h>
#include <string.h>
#include <time.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t current_buttons;
static int32_t current_sticks[4];
static uint64_t current_ns;

void s2a_android_input_set(uint32_t buttons, const int32_t sticks[4]) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    pthread_mutex_lock(&lock);
    current_buttons = buttons;
    memcpy(current_sticks, sticks, sizeof current_sticks);
    current_ns = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
    pthread_mutex_unlock(&lock);
}
void s2a_android_input_reset(void) {
    const int32_t zero[4] = {0}; s2a_android_input_set(0, zero);
}
uint32_t s2a_android_input_read(int32_t sticks[4], uint64_t *timestamp_ns) {
    pthread_mutex_lock(&lock);
    uint32_t buttons = current_buttons;
    memcpy(sticks, current_sticks, sizeof current_sticks);
    if (timestamp_ns) *timestamp_ns = current_ns;
    pthread_mutex_unlock(&lock);
    return buttons;
}
uint32_t s2a_vpad_read(int32_t sticks[4]) { return s2a_android_input_read(sticks, NULL); }

