#include "selftest.h"
#include "../../platform/plat.h"
#include "guest_signal.h"
#include "module.h"
#include "tsd.h"
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>

// Fixture functions (tools/selftest_nso.py), each `<instruction>; ret`.
enum {
    F_TPIDR_READ = 0x100,    // mrs x0, tpidr_el0
    F_TPIDR_WRITE = 0x108,   // msr tpidr_el0, x0
    F_TPIDRRO_READ = 0x110,  // mrs x0, tpidrro_el0
    F_X18_WRITE = 0x118,     // mov x18, x0
    F_X18_READ = 0x120,      // add x0, x18, #8
    F_SVC = 0x128,           // svc #1
};
#define NAME "selftest"

uint64_t s2a_selftest_gate(void);

struct ctx {
    struct s2a_module m;
    pthread_key_t key[S2A_KEY_N];
    uint64_t gate_ret;   // module offset of the svc block's return point (gates.tsv)
};

typedef uint64_t (*fn)(uint64_t);
static uint64_t call(const struct ctx *c, unsigned off, uint64_t x0) { return ((fn)(void *)(c->m.base + off))(x0); }
static uint64_t slot(const struct ctx *c, unsigned k) { return (uint64_t)(uintptr_t)pthread_getspecific(c->key[k]); }
static uint64_t tpidr(void) { uint64_t v; __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v)); return v; }
static uint64_t x18(void) { uint64_t v; __asm__ volatile("mov %0, x18" : "=r"(v)); return v; }

// Guest thread entry: stamp every key once (bionic records the key's seq), then
// rewritten code may access the slots directly.
static void stamp(const struct ctx *c, uint64_t tls, uint64_t tlr) {
    pthread_setspecific(c->key[S2A_KEY_K18], NULL);
    pthread_setspecific(c->key[S2A_KEY_KTLS], (void *)(uintptr_t)tls);
    pthread_setspecific(c->key[S2A_KEY_KTLR], (void *)(uintptr_t)tlr);
    pthread_setspecific(c->key[S2A_KEY_KGATE], (void *)(uintptr_t)s2a_selftest_gate);
}

static int bad(char *r, size_t n, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int k = snprintf(r, n, "Rewrite self-test: FAILED ");
    if (k >= 0 && (size_t)k < n) vsnprintf(r + k, n - (size_t)k, fmt, ap);
    va_end(ap);
    return EPROTO;
}

// Runs every rewrite kind on the calling thread; `tag` keeps the two threads' values apart.
static int run(const struct ctx *c, uint64_t tag, char *r, size_t n) {
    uint64_t tls = 0x7100 | tag, tlr = 0x7200 | tag, mine = tpidr(), hw18 = x18(), v;
    stamp(c, tls, tlr);
    if ((v = call(c, F_TPIDR_READ, 0)) != tls) return bad(r, n, "mrs tpidr_el0 -> %#llx, KTLS %#llx", (unsigned long long)v, (unsigned long long)tls);
    call(c, F_TPIDR_WRITE, 0x7300 | tag);
    if (slot(c, S2A_KEY_KTLS) != (0x7300 | tag) || tpidr() != mine) return bad(r, n, "msr tpidr_el0 missed KTLS or moved the real tpidr_el0");
    if ((v = call(c, F_TPIDR_READ, 0)) != (0x7300 | tag)) return bad(r, n, "mrs tpidr_el0 after msr -> %#llx", (unsigned long long)v);
    if ((v = call(c, F_TPIDRRO_READ, 0)) != tlr) return bad(r, n, "mrs tpidrro_el0 -> %#llx, KTLR %#llx", (unsigned long long)v, (unsigned long long)tlr);
    call(c, F_X18_WRITE, 0x7400 | tag);
    if (slot(c, S2A_KEY_K18) != (0x7400 | tag) || x18() != hw18) return bad(r, n, "x18 write missed K18 or touched the hardware x18");
    if ((v = call(c, F_X18_READ, 0)) != (0x7408 | tag)) return bad(r, n, "x18 read -> %#llx", (unsigned long long)v);
    uint64_t want = (uint64_t)(uintptr_t)(c->m.base + c->gate_ret);
    if ((v = call(c, F_SVC, 0)) != want) return bad(r, n, "svc gate returned %#llx, expected %#llx", (unsigned long long)v, (unsigned long long)want);
    return 0;
}

// Guest threads, never ART's: thread entry installs the alternate signal stack
// (rewritten blocks borrow 112 bytes below sp) and stamps the keys, as
// runtime/src/thread.c does. Thread 1 runs, starts thread 2, then re-checks that
// its own slots survived thread 2.
struct guest { const struct ctx *c; uint64_t tag; char report[200]; int error; int blocked; char kept[64]; };
static void *guest_main(void *arg) {
    struct guest *g = arg;
    if ((g->error = plat_fault_altstack_init())) { bad(g->report, sizeof g->report, "plat_fault_altstack_init errno %d", g->error); return NULL; }
    g->blocked = s2a_android_guest_sigmask(g->kept, sizeof g->kept);
    if (g->blocked < 0) { g->error = bad(g->report, sizeof g->report, "pthread_sigmask errno %d", -g->blocked); return NULL; }
    g->error = run(g->c, g->tag, g->report, sizeof g->report);
    if (!g->error && g->tag == 0x1) {
        struct guest peer = {g->c, 0x2, "", 0, 0, ""};
        pthread_t t;
        if ((g->error = pthread_create(&t, NULL, guest_main, &peer))) bad(g->report, sizeof g->report, "pthread_create errno %d", g->error);
        else {
            pthread_join(t, NULL);
            if (peer.error) { snprintf(g->report, sizeof g->report, "%s (second thread)", peer.report); g->error = peer.error; }
            else if (slot(g->c, S2A_KEY_K18) != 0x7401 || slot(g->c, S2A_KEY_KTLS) != 0x7301)
                g->error = bad(g->report, sizeof g->report, "second thread changed the first thread's slots");
        }
    }
    for (unsigned k = 0; k < S2A_KEY_N; k++) pthread_setspecific(g->c->key[k], NULL);
    plat_fault_altstack_free();
    return NULL;
}

static int read_gate(const char *dir, uint64_t *ret, char *r, size_t n) {
    char path[1024], line[256], kind[16];
    snprintf(path, sizeof path, "%s/" NAME ".gates.tsv", dir);
    FILE *f = fopen(path, "re");
    if (!f) return bad(r, n, "cannot open %s", path);
    unsigned long rt, orig; int arg, found = 0;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "%lx %15s %d %lx", &rt, kind, &arg, &orig) == 4 && orig == F_SVC) { *ret = rt; found++; }
    fclose(f);
    return found == 1 ? 0 : bad(r, n, "gates.tsv has %d entries for the svc at %#x", found, F_SVC);
}

static int with_keys(struct ctx *c, const char *dir, char *r, size_t n) {
    uint64_t off[S2A_KEY_N];
    int e = plat_tsd_init();
    // No fallback: a wrong slot offset would make rewritten code read another key's data.
    if (e) return bad(r, n, "plat_tsd_init errno %d", e);
    for (unsigned k = 0; k < S2A_KEY_N; k++) {
        if ((e = plat_tsd_offset((uint32_t)c->key[k], &off[k]))) return bad(r, n, "plat_tsd_offset key %u errno %d", k, e);
    }
    char err[256];
    if ((e = s2a_module_map(dir, NAME, off, &c->m, err, sizeof err))) return bad(r, n, "%s", err);
    struct guest g = {c, 0x1, "", 0, 0, ""};
    if ((e = read_gate(dir, &c->gate_ret, r, n)) == 0) {
        pthread_t t;
        if ((e = pthread_create(&t, NULL, guest_main, &g))) e = bad(r, n, "pthread_create errno %d", e);
        else { pthread_join(t, NULL); if ((e = g.error)) snprintf(r, n, "%s", g.report); }
    }
    if (!e) snprintf(r, n, "Rewrite self-test (S2A_TARGET=android): 6 rewrite kinds x 2 guest threads ok, key offsets via plat_tsd_offset; "
                     "guest mask blocked %d non-SA_ONSTACK signals, libc kept unblocked: %s", g.blocked, *g.kept ? g.kept : "none");
    s2a_module_unmap(&c->m);
    return e;
}

int s2a_android_rewrite_selftest(const char *dir, char *r, size_t n) {
    char path[1024];
    struct stat st;
    snprintf(path, sizeof path, "%s/" NAME ".patched.bin", dir);
    if (stat(path, &st)) {
        snprintf(r, n, "Rewrite self-test: no module imported (android/tools/device_selftest.sh)");
        return ENOENT;
    }
    struct ctx c = {0};
    unsigned made = 0;
    int e = 0;
    while (made < S2A_KEY_N && !(e = pthread_key_create(&c.key[made], NULL))) made++;
    e = e ? bad(r, n, "pthread_key_create errno %d", e) : with_keys(&c, dir, r, n);
    while (made) pthread_key_delete(c.key[--made]);
    return e;
}
