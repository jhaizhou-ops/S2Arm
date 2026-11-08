/* Exercise the public C ABI in-process: repeated calls, independent threads,
 * and rejection paths. Inputs are generated NSOs supplied by the Python test. */
#include "rewriter.h"
#include <pthread.h>
#include <stdio.h>

typedef struct {
  s2a_rewrite_request request;
  int rc;
  int sdk_cut;
} Job;
static void* run(void* data) {
  Job* job = data;
  for (int i = 0; i < 8; i++) {
    s2a_rewrite_options options = {job->sdk_cut};
    job->rc = job->sdk_cut < 0 ? s2a_rewrite_files(&job->request, NULL) :
        s2a_rewrite_files_with_options(&job->request, &options, NULL);
    if (job->rc)
      break;
  }
  return NULL;
}
int main(int argc, char** argv) {
  if ((argc != 4 && argc != 5) || s2a_rewrite_files(NULL, NULL) != 1 ||
      s2a_rewrite_files_with_options(NULL, NULL, NULL) != 1)
    return 1;
  const char* module = argc == 5 ? argv[4] : "main";
  Job jobs[2] = {{{argv[1], argv[2], module, "apple", NULL, 0}, 0, -1},
                 {{argv[1], argv[3], module, "android", NULL, 1}, 0, 0}};
  pthread_t threads[2];
  if (pthread_create(&threads[0], NULL, run, &jobs[0]))
    return 1;
  if (pthread_create(&threads[1], NULL, run, &jobs[1])) {
    pthread_join(threads[0], NULL);
    return 1;
  }
  for (int i = 0; i < 2; i++)
    if (pthread_join(threads[i], NULL))
      return 1;
  if (jobs[0].rc || jobs[1].rc)
    return 1;
  s2a_rewrite_request invalid = jobs[0].request;
  invalid.target = "linux";
  if (s2a_rewrite_files(&invalid, NULL) != 1)
    return 1;
  invalid.target = "apple";
  invalid.module = "../escape";
  if (s2a_rewrite_files(&invalid, NULL) != 1)
    return 1;
  puts("C API：双线程各 8 次调用、失败隔离通过");
  return 0;
}
