// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include <inttypes.h>
#include <libkern/OSCacheControl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

__attribute__((naked)) static uint64_t call_leaf(const void* entry) {
  __asm__("sub sp, sp, #256\n"
          "stp x29, x30, [sp, #224]\n"
          "str x18, [sp, #240]\n"
          "add x29, sp, #224\n"
          "str xzr, [sp]\n"
          "mov x9, x0\n"
          "mov x0, #0x1234\n"
          "mov x1, #0x5678\n"
          "blr x9\n"
          // Check guest SP before restoring the caller's frame.
          "sub x9, x29, #224\n"
          "mov x10, sp\n"
          "cmp x9, x10\n"
          "csel x0, x0, xzr, eq\n"
          "mov sp, x9\n"
          "ldr x18, [sp, #240]\n"
          "ldp x29, x30, [sp, #224]\n"
          "add sp, sp, #256\n"
          "ret");
}

int main(int argc, char** argv) {
  if (argc != 4)
    return 2;
  size_t entry = strtoull(argv[2], NULL, 0), key = strtoull(argv[3], NULL, 0);
  FILE* file = fopen(argv[1], "rb");
  if (!file || fseek(file, 0, SEEK_END))
    return 2;
  long length = ftell(file);
  if (length < 8 || entry >= (size_t)length || key > (size_t)length - 8 || fseek(file, 0, SEEK_SET))
    return 2;
  size_t size = (size_t)length;
  uint8_t* image = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (image == MAP_FAILED || fread(image, 1, size, file) != size) {
    perror("mmap/fread");
    return 2;
  }
  fclose(file);
  static uint64_t guest_x18;
  if (key) {
    uintptr_t tp;
    __asm__("mrs %0, tpidrro_el0" : "=r"(tp));
    *(uint64_t*)(image + key) = (uintptr_t)&guest_x18 - tp;
  }
  sys_icache_invalidate(image, size);
  if (mprotect(image, size, PROT_READ | PROT_EXEC)) {
    perror("mprotect");
    return 2;
  }
  printf("0x%" PRIx64 "\n", call_leaf(image + entry));
  munmap(image, size);
  return 0;
}
