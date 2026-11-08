#include "../../platform/plat.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int read_error, calls, write_results[3];
static uint64_t expected_address;
static uint32_t expected_value;

int s2a_android_copy_guest_readonly(uint64_t address, void *out, uint64_t size) {
    assert(address == expected_address && size == 4);
    memset(out, 0x5a, (size_t)size); // Even a partial/failed copy must not escape.
    return read_error;
}
int s2a_mem_write32_checked(uint64_t address, uint32_t value) {
    assert(address == expected_address && value == expected_value && calls < 3);
    return write_results[calls++];
}

int main(void) {
    expected_address = 0x1000; expected_value = 42;
    uint32_t value = 7;
    assert(plat_mem_read32(expected_address, NULL) == EINVAL);
    read_error = EFAULT;
    assert(plat_mem_read32(expected_address, &value) == EFAULT && value == 7);
    read_error = 0;
    assert(!plat_mem_read32(expected_address, &value) && value == 0x5a5a5a5a);
    // 裁定口径：provider 内部不自旋；checked 返回什么就透传什么，竞争失败由 fps.c 下一帧再试。
    write_results[0] = 0;
    assert(!plat_mem_write32(expected_address, expected_value) && calls == 1);
    calls = 0; write_results[0] = -EAGAIN;
    assert(plat_mem_write32(expected_address, expected_value) == EAGAIN && calls == 1);
    calls = 0; write_results[0] = -EACCES;
    assert(plat_mem_write32(expected_address, expected_value) == EACCES && calls == 1);
    assert(plat_thread_name(NULL) == EINVAL);
    assert(plat_thread_name("s2a-fps-test") == 0);
    uint64_t module_word = UINT64_C(0x1020304050607080);
    expected_address = (uintptr_t)&module_word;
    assert(plat_guest_load8(expected_address) == 0x80);
    assert(plat_guest_load32(expected_address) == UINT32_C(0x50607080));
    assert(plat_guest_load64(expected_address) == module_word);
    calls = 0; write_results[0] = 0;
    plat_guest_store32(expected_address, expected_value);
    assert(calls == 1);
    calls = 0; write_results[0] = -EAGAIN;   // 必须落路径遇瞬时竞争也不自旋不杀：丢一拍返回
    plat_guest_store32(expected_address, expected_value);
    assert(calls == 1);
    puts("fps provider read publication and bounded retries: ok");
    return 0;
}
