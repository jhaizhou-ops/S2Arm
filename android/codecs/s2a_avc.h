#ifndef S2A_AVC_H
#define S2A_AVC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Owner-sequence only. No concurrent decode/planes/destroy. Borrowed planes are
 * invalidated by the next decode or destroy; caller must finish synchronous use.
 * A failed context stays failed. Reconfiguration requires an IDR access unit. */
#define S2A_AVC_ABI 1u
#define S2A_AVC_PROVENANCE "S2ARM_LIBAVC_d380d04a78c6c08702e36aca86d0fd4baee390f9"
typedef struct s2a_avc s2a_avc;
enum { S2A_AVC_ARGUMENT=-1, S2A_AVC_NOMEM=-2, S2A_AVC_UNSUPPORTED=-3,
       S2A_AVC_BITSTREAM=-4, S2A_AVC_CONTRACT=-5, S2A_AVC_RECONFIG=-6,
       S2A_AVC_STATE=-7, S2A_AVC_BACKEND=-8, S2A_AVC_LIMIT=-9 };
enum { S2A_AVC_CREATE=1, S2A_AVC_CONFIG=2, S2A_AVC_HEADER=3,
       S2A_AVC_INPUT=4, S2A_AVC_DECODE=5, S2A_AVC_PLANES=6, S2A_AVC_DELETE=7 };
typedef struct { uint32_t abi_version, struct_size, width, height; } s2a_avc_config;
typedef struct {
    uint32_t abi_version, struct_size, stage;
    int32_t code, ivd_status;
    uint32_t ivd_error, consumed, decoded, output, input_token, output_token;
    uint32_t width, height, generation;
} s2a_avc_diag;
typedef struct {
    const uint8_t *data;
    uint64_t capacity;
    uint32_t width, height, stride, reserved;
} s2a_avc_plane;
typedef struct {
    uint32_t abi_version, struct_size, format, progressive, token, generation;
    s2a_avc_plane plane[3];
} s2a_avc_planes_v1;
int32_t s2a_avc_create(const s2a_avc_config *, s2a_avc **, s2a_avc_diag *);
int32_t s2a_avc_decode(s2a_avc *, const uint8_t *, uint32_t,
                       const uint8_t *, uint32_t, const uint8_t *, uint32_t,
                       uint32_t, s2a_avc_diag *);
int32_t s2a_avc_planes(s2a_avc *, uint32_t, s2a_avc_planes_v1 *, s2a_avc_diag *);
int32_t s2a_avc_destroy(s2a_avc *, s2a_avc_diag *);
const char *s2a_avc_provenance(void);
#ifdef S2A_AVC_TESTING
void s2a_avc_test_fail_allocation(int64_t);
void s2a_avc_test_fault(uint32_t);
uint64_t s2a_avc_test_live_allocations(void);
uint64_t s2a_avc_test_allocation_calls(void);
#endif
#ifdef __cplusplus
}
#endif
#endif
