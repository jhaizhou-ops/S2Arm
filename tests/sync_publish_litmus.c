/* sync_publish / sync_published：未发布读不到值；发布后 acquire 看到的是这次写入的 fence。
   x86 TSO 不会重排普通 store，这里证的是发布契约和编译器不能把两条写拆开。 */
#include "nvn_obj.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static int bad;

static void ck(int cond, const char *what) {
    if (cond) { printf("通 %s\n", what); return; }
    fprintf(stderr, "不通 %s\n", what);
    bad = 1;
}

typedef struct { sync_t s; atomic_int stop; atomic_ullong seen_bad; } sh_t;

static void *reader(void *arg) {
    sh_t *sh = arg;
    uint64_t last = 0;
    while (!atomic_load_explicit(&sh->stop, memory_order_acquire)) {
        uint64_t f = 0;
        if (!sync_published(&sh->s, &f)) continue;
        if (f == 0 || f < last) {
            atomic_store(&sh->seen_bad, f == 0 ? UINT64_MAX : f);
            break;
        }
        last = f;
    }
    return NULL;
}

int main(void) {
    sync_t s;
    memset(&s, 0, sizeof s);
    uint64_t f = 99;
    ck(!sync_published(&s, &f) && f == 99, "未发布：不读 fence");
    ck(!sync_published(&s, NULL), "未发布：只要标志也是 0");
    sync_publish(&s, 0);
    f = 7;
    ck(sync_published(&s, &f) && f == 0, "发布 0：已发布且 fence 为 0（主机侧完成）");
    sync_publish(&s, 42);
    f = 0;
    ck(sync_published(&s, &f) && f == 42, "再发布 42：读到 42，不是 0");
    ck(sync_published(&s, NULL) == 1, "只要标志");

    sh_t sh;
    memset(&sh.s, 0, sizeof sh.s);
    atomic_init(&sh.stop, 0);
    atomic_init(&sh.seen_bad, 0);
    pthread_t th;
    if (pthread_create(&th, NULL, reader, &sh)) { fprintf(stderr, "不通 起读者线程\n"); return 1; }
    for (uint64_t i = 1; i <= 200000; i++) sync_publish(&sh.s, i);
    atomic_store_explicit(&sh.stop, 1, memory_order_release);
    pthread_join(th, NULL);
    uint64_t got = atomic_load(&sh.seen_bad);
    ck(got == 0, "两线程：看不到「已发布但 fence 仍是 0」，也看不到回退的 fence");
    f = 0;
    ck(sync_published(&sh.s, &f) && f == 200000, "写完最后一次：读者侧能看到的发布值是 200000");
    return bad ? 1 : 0;
}
