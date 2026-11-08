#define main existing_lowva_main
#include "runtime/tests/t_lowva.c"
#undef main
#include <errno.h>

int __real_pthread_mutexattr_settype(pthread_mutexattr_t *, int);
int __wrap_pthread_mutexattr_settype(pthread_mutexattr_t *attr, int type) {
    if (getenv("S2A_TEST_MUTEX_INIT_FAIL")) return ENOMEM;
    return __real_pthread_mutexattr_settype(attr, type);
}
int main(void) {
    pthread_mutex_t *mutex = s2a_lowva_test_mutex();
    if (pthread_mutex_lock(mutex)) return 1;
    // 同线程重入必须成功；普通 mutex 只靠「没死锁」不能证明等价。
    int second = pthread_mutex_trylock(mutex);
    if (!second) pthread_mutex_unlock(mutex);
    pthread_mutex_unlock(mutex);
    if (second) { fprintf(stderr, "FAIL recursive mutex: %d\n", second); return 2; }
    puts("recursive lock 2/2 acquired");
    return existing_lowva_main();
}
