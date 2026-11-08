// Manual variant: run t_thread's tests with the real Apple plat implementation
// (platform/apple/plat_apple.c), not the zero-base TSD / signal stubs.
// Built by `make native-test-thread_plat` (Darwin only, part of runtime/gate.sh).
int t_thread_main(void);
int main(void) { return t_thread_main(); }
