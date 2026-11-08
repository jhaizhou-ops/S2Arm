#include "dma_read_config.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    unsetenv("S2A_DMA_BORROWED_READ");
    unsetenv("S2A_DMA_PRESERVE_READ");
    assert(s2a_android_dma_preserve_read_request(1) == 0);
    assert(s2a_android_dma_preserve_read_request(0) == ENOTSUP);
    assert(getenv("S2A_DMA_PRESERVE_READ") == NULL);
    assert(setenv("S2A_DMA_BORROWED_READ", "1", 1) == 0);
    assert(s2a_android_dma_preserve_read_request(1) == ENOTSUP);
    assert(strcmp(getenv("S2A_DMA_BORROWED_READ"), "1") == 0);
    puts("DMA preserve-read request: default, disable refusal and borrowed diagnostic passed");
    return 0;
}
