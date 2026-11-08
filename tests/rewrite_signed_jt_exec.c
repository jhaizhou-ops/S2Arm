/* 在 qemu-aarch64 里调用改写前 / 改写后的合成函数。改写后的苹果桩经 tpidrro_el0 取 K18 槽；
 * qemu-user 里这个寄存器是 0，键页项写成槽的绝对地址即可。调用前把 sp 下移 256，盖住苹果红区暂存。 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
static uint32_t call(void* fn, uint64_t idx) {
  uint32_t r;
  asm volatile("sub sp, sp, #256\n"
               "mov x0, %[idx]\n"
               "blr %[fn]\n"
               "mov %w[r], w0\n"
               "add sp, sp, #256\n"
               : [r] "=r"(r)
               : [idx] "r"(idx), [fn] "r"(fn)
               : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x16", "x17", "x18", "x30", "memory", "cc");
  return r;
}
int main(int argc, char** argv) {
  if (argc != 5) {
    fprintf(stderr, "用法：%s <映像> <派发偏移> <键页偏移或-> <下标>\n", argv[0]);
    return 2;
  }
  FILE* f = fopen(argv[1], "rb");
  if (!f)
    return 2;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 16)
    return 2;
  uint8_t* img = mmap(NULL, (size_t)n, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (img == MAP_FAILED)
    return 2;
  if (fread(img, 1, (size_t)n, f) != (size_t)n)
    return 2;
  fclose(f);
  unsigned long disp = strtoul(argv[2], NULL, 0);
  unsigned long idx = strtoul(argv[4], NULL, 0);
  if (strcmp(argv[3], "-") != 0) {
    unsigned long key = strtoul(argv[3], NULL, 0);
    uint64_t tp = 0, slot = 0;
    asm volatile("mrs %0, tpidrro_el0" : "=r"(tp));
    if (key + 8 > (unsigned long)n)
      return 2;
    *(uint64_t*)(img + key) = (uint64_t)&slot - tp;
  }
  uint32_t r = call(img + disp, idx);
  printf("%u\n", r);
  return 0;
}
