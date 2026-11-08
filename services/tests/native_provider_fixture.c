#include <stdint.h>
typedef struct { uint64_t lo; void *dir; } far_desc;
#if defined(FULL) || defined(HALF)
int s2a_det_mode(void) { return 37; }
#endif
#if defined(FULL)
void s2a_det_host_write(uint64_t address, void *data, uint64_t size) { (void)address; (void)data; (void)size; }
uint64_t s2a_guest_tick(void) { return 0xABC; }
static far_desc desc = { 0x5000, (void *)0x9876 };
void *s2a_far_desc_get(void) { return &desc; }
int s2a_ldn_lan_start(uint64_t program_id) { return program_id == 42 ? 19 : 0; }
static int hosting;
void s2a_ldn_lan_hosting(int value) { hosting = value; }
int fixture_hosting(void) { return hosting; }
#endif
