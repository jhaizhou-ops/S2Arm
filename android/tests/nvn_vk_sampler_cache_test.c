#include <stdio.h>
#include <string.h>
#include "nvn_vk_sampler_cache.h"

int main(void) {
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct nvn_vk_sampler_cache c; nvn_vk_sampler_cache_init(&c, &d);
    samp_par p; memset(&p, 0, sizeof p); p.minf = NVN_MIN_FILTER_LINEAR; p.magf = NVN_MAG_FILTER_LINEAR;
    p.ws = p.wt = p.wr = NVN_WRAP_MODE_REPEAT; p.lod_max = 10; p.border[3] = 1;
    VkSampler a = nvn_vk_sampler_cache_get(&c, &p, why, sizeof why);
    VkSampler b = nvn_vk_sampler_cache_get(&c, &p, why, sizeof why);
    samp_par q = p; q.magf = NVN_MAG_FILTER_NEAREST;
    VkSampler c2 = nvn_vk_sampler_cache_get(&c, &q, why, sizeof why);
    samp_par bad = p; bad.minf = 0xf; /* invalid 4-bit value, without compile-time truncation */ char w2[160] = "";
    VkSampler bads = nvn_vk_sampler_cache_get(&c, &bad, w2, sizeof w2);
    int ok = a && a == b && c2 && c2 != a && !bads && strstr(w2, "unsupported") && c.created == 2 && c.reused == 1;
    printf("a=%p b=%p c=%p bad=%p created=%u reused=%u why=%s\n", (void*)a, (void*)b, (void*)c2, (void*)bads, c.created, c.reused, w2);
    printf("nvn-vk-sampler-cache: %s\n", ok ? "ok" : "FAIL");
    nvn_vk_sampler_cache_destroy(&c); s2a_vk_device_destroy(&d, 0);
    return ok ? 0 : 1;
}
