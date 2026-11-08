#include "wsi_lease.h"
#include <stddef.h>
#include <stdio.h>

#ifdef LAYOUT_ONLY
int main(void) {
  printf("%zu %zu %zu %zu %zu %zu %zu %zu\n", sizeof(struct s2a_wsi_state),
         sizeof(struct s2a_wsi_api), offsetof(struct s2a_wsi_state, window),
         offsetof(struct s2a_wsi_state, insets), offsetof(struct s2a_wsi_state, wake_seq),
         offsetof(struct s2a_wsi_api, lease), offsetof(struct s2a_wsi_api, wait),
         offsetof(struct s2a_wsi_api, wake));
  return 0;
}
#else
#include <assert.h>
#include <stdatomic.h>

// Opaque synthetic window identities, only the reference-count callbacks are synthetic.
// All lease operations/function pointers are the unchanged production C implementation.
static atomic_int refs[3];
static unsigned index_of(void *window) {
  uintptr_t index = (uintptr_t)window;
  assert(index > 0 && index < 3);
  return (unsigned)index;
}
static void retain(void *window) { atomic_fetch_add(&refs[index_of(window)], 1); }
static void release(void *window) {
  assert(atomic_fetch_sub(&refs[index_of(window)], 1) > 0);
}
void *fixture_create(uint64_t session) {
  const struct s2a_wsi_window_ops ops = {retain, release};
  return s2a_wsi_create(session, &ops);
}
int fixture_refs(uintptr_t window) { return atomic_load(&refs[index_of((void *)window)]); }
#endif
