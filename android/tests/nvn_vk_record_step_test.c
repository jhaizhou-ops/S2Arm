#include <stdio.h>
#include <string.h>
#include "vk_record.h"
#include "nvn_obj.h"

static uint8_t g_mem[256];
static int rd(void *o, uint64_t a, void *b, size_t n) { (void)o; if (a + n > sizeof g_mem) return -1; memcpy(b, g_mem + a, n); return 0; }
static int wr(void *o, uint64_t a, const void *b, size_t n) { (void)o; if (a + n > sizeof g_mem) return -1; memcpy(g_mem + a, b, n); return 0; }

int main(void) {
    struct s2a_vk_device dev; char why[192] = "";
    if (s2a_vk_device_create(&dev, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct s2a_record_memory mem = { NULL, rd, wr };
    uint8_t pkt[40] = {0};   // 8 头 + 8 dst + 8 bytes + 8 数据（OP_UPDATE_UB 的 size 要 8 对齐）
    op_hdr h = { OP_UPDATE_UB, sizeof pkt }; memcpy(pkt, &h, sizeof h);
    uint64_t dst = 32, bytes = 4; memcpy(pkt + 8, &dst, 8); memcpy(pkt + 16, &bytes, 8);
    uint32_t word = 0xDEADBEEF; memcpy(pkt + 24, &word, 4);
    struct s2a_record_result r;
    int rc = s2a_record_exec_one(&dev, pkt, sizeof pkt, &mem, &r);
    uint32_t got = 0; memcpy(&got, g_mem + 32, 4);
    printf("exec-one: rc=%d code=%d executed=%lu opcode=%lu why=%s got=%08x\n", rc, (int)r.code, (unsigned long)r.executed, (unsigned long)r.opcode, r.why, got);
    s2a_vk_device_destroy(&dev, 0);
    int ok = rc == 0 && got == 0xDEADBEEF;
    printf("nvn-vk record step: %s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}
