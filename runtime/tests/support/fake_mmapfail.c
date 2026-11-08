// t_vaguard「mmapfail」用：让窗口那次 mmap（0x70_0000_0000 起 64 GB）失败、errno = ENOMEM（12）；之后每次 write（打日志）把 errno 改成 99，
//   模拟「读 errno 之前又调了别的库函数」——errno 紧接 mmap 取才能打出 12（#100 作者指出的第 3 处）
#include <errno.h>
#include <sys/mman.h>
#include <unistd.h>
static void *f_mmap(void *a, size_t l, int p, int fl, int fd, off_t o) {
    if ((unsigned long long)a == 0x7000000000ull && l == (64ull << 30)) { errno = ENOMEM; return MAP_FAILED; }
    return mmap(a, l, p, fl, fd, o);
}
static ssize_t f_write(int fd, const void *b, size_t n) { ssize_t r = write(fd, b, n); errno = 99; return r; }
__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *r, *o; } g_ip[] = {
    {(const void *)f_mmap, (const void *)mmap}, {(const void *)f_write, (const void *)write} };
