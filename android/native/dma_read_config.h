#pragma once
#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* The R implementation preserves target reads by default; only the private
 * borrowed-read diagnostic disables it. Never report a requested disable as
 * applied when the production implementation does not support it. */
static inline int s2a_android_dma_preserve_read_request(int enabled) {
    const char *borrowed = getenv("S2A_DMA_BORROWED_READ");
    if (!enabled || (borrowed && strcmp(borrowed, "1") == 0)) return ENOTSUP;
    return 0;
}
