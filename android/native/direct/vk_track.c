#include "vk_track.h"

#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct entry {
    VkFence fence;
    uint64_t batch;
    s2a_vk_track_retire_fn retire;
    void *user;
};

struct s2a_vk_track {
    struct s2a_vk_device *device;
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    struct entry *queue;
    size_t capacity, head, count;
    int stopping, failed;
    uint64_t submitted, retired;
};

static int push(struct s2a_vk_track *track, struct entry entry) {
    pthread_mutex_lock(&track->lock);
    if (track->count == track->capacity) {
        pthread_mutex_unlock(&track->lock);
        return -1;
    }
    track->queue[(track->head + track->count) % track->capacity] = entry;
    track->count++;
    track->submitted++;
    pthread_cond_signal(&track->cond);
    pthread_mutex_unlock(&track->lock);
    return 0;
}

static void *consumer(void *opaque) {
    struct s2a_vk_track *track = opaque;
    for (;;) {
        pthread_mutex_lock(&track->lock);
        while (!track->count && !track->stopping)
            pthread_cond_wait(&track->cond, &track->lock);
        if (!track->count && track->stopping) {
            pthread_mutex_unlock(&track->lock);
            return NULL;
        }
        struct entry entry = track->queue[track->head];
        pthread_mutex_unlock(&track->lock);

        int rc = -1;
        for (;;) {
            VkResult result = vkWaitForFences(track->device->device, 1, &entry.fence, VK_TRUE, 100000000ull);
            if (result == VK_SUCCESS) { rc = 0; break; }
            if (result != VK_TIMEOUT) break;
        }
        if (rc == 0 && entry.retire) entry.retire(entry.user, entry.batch);

        pthread_mutex_lock(&track->lock);
        vkDestroyFence(track->device->device, entry.fence, NULL);
        track->head = (track->head + 1) % track->capacity;
        track->count--;
        if (rc == 0) track->retired++; else track->failed = 1;
        pthread_cond_broadcast(&track->cond);
        pthread_mutex_unlock(&track->lock);
        if (rc) return NULL;
    }
}

int s2a_vk_track_create(struct s2a_vk_device *device, struct s2a_vk_track **out) {
    if (!device || !device->device || !out) return -1;
    struct s2a_vk_track *track = calloc(1, sizeof *track);
    if (!track) return -1;
    track->device = device;
    track->capacity = 1024;
    track->queue = calloc(track->capacity, sizeof *track->queue);
    if (!track->queue) { free(track); return -1; }
    pthread_mutex_init(&track->lock, NULL);
    pthread_cond_init(&track->cond, NULL);
    if (pthread_create(&track->thread, NULL, consumer, track)) {
        free(track->queue); free(track); return -1;
    }
    *out = track;
    return 0;
}

int s2a_vk_track_submit(struct s2a_vk_track *track, VkCommandBuffer command, uint64_t batch,
                        s2a_vk_track_retire_fn retire, void *user) {
    if (!track || !command) return -1;
    VkFenceCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence = VK_NULL_HANDLE;
    if (vkCreateFence(track->device->device, &info, NULL, &fence) != VK_SUCCESS) return -1;
    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    if (vkQueueSubmit(track->device->queue, 1, &submit, fence) != VK_SUCCESS) {
        vkDestroyFence(track->device->device, fence, NULL);
        return -1;
    }
    struct entry entry = {fence, batch, retire, user};
    if (push(track, entry)) {
        vkDestroyFence(track->device->device, fence, NULL);
        return -1;
    }
    return 0;
}

int s2a_vk_track_present_fence(struct s2a_vk_track *track, VkFence fence, uint64_t batch,
                               s2a_vk_track_retire_fn retire, void *user) {
    if (!track || !fence) return -1;
    struct entry entry = {fence, batch, retire, user};
    return push(track, entry);
}

int s2a_vk_track_wait_all(struct s2a_vk_track *track, uint64_t timeout_ms) {
    if (!track) return -1;
    pthread_mutex_lock(&track->lock);
    if (timeout_ms == 0) {
        int pending = track->count != 0 || track->failed;
        pthread_mutex_unlock(&track->lock);
        return pending ? 1 : 0;
    }
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_ms / 1000);
    deadline.tv_nsec += (long)((timeout_ms % 1000) * 1000000);
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    while (track->count && !track->failed) {
        if (pthread_cond_timedwait(&track->cond, &track->lock, &deadline) == ETIMEDOUT) break;
    }
    int result = track->failed ? -1 : (track->count ? 1 : 0);
    pthread_mutex_unlock(&track->lock);
    return result;
}

int s2a_vk_track_destroy(struct s2a_vk_track *track) {
    if (!track) return -1;
    pthread_mutex_lock(&track->lock);
    if (track->count) {
        pthread_mutex_unlock(&track->lock);
        return -1;
    }
    track->stopping = 1;
    pthread_cond_signal(&track->cond);
    pthread_mutex_unlock(&track->lock);
    pthread_join(track->thread, NULL);
    pthread_mutex_destroy(&track->lock);
    pthread_cond_destroy(&track->cond);
    free(track->queue);
    free(track);
    return 0;
}

void s2a_vk_track_stats(struct s2a_vk_track *track, uint64_t *submitted, uint64_t *retired,
                        uint64_t *pending, uint64_t *failed) {
    if (!track) return;
    pthread_mutex_lock(&track->lock);
    if (submitted) *submitted = track->submitted;
    if (retired) *retired = track->retired;
    if (pending) *pending = track->count;
    if (failed) *failed = track->failed ? 1 : 0;
    pthread_mutex_unlock(&track->lock);
}
