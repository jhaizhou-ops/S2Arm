/* The preparation adapter is independent of the game runtime/NativeBridge.
 * All bytes are copied into call-owned buffers; no JNI pointer escapes. */
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "rewriter.h"

#define PATH_BYTES_MAX 4095
#define MODULE_BYTES_MAX 64

/* Serializes every entry through this loaded DSO, not other copies/direct C callers. */
static pthread_mutex_t rewrite_mutex = PTHREAD_MUTEX_INITIALIZER;

static void throw_exception(JNIEnv* env, const char* type, const char* message) {
  if ((*env)->ExceptionCheck(env))
    return;
  jclass exception = (*env)->FindClass(env, type);
  if (!exception)
    return;
  (*env)->ThrowNew(env, exception, message);
  (*env)->DeleteLocalRef(env, exception);
}

/* UTF-8 scalar values only: reject NUL, overlong sequences, surrogates, values
 * above U+10FFFF, truncated sequences and isolated continuation bytes. */
static int valid_utf8(const unsigned char* bytes, size_t length) {
  size_t at = 0;
  while (at < length) {
    uint32_t value = bytes[at++], minimum;
    size_t extra;
    if (!value)
      return 0;
    if (value < 0x80)
      continue;
    if (value >= 0xc2 && value <= 0xdf) {
      value &= 0x1f; minimum = 0x80; extra = 1;
    } else if (value >= 0xe0 && value <= 0xef) {
      value &= 0x0f; minimum = 0x800; extra = 2;
    } else if (value >= 0xf0 && value <= 0xf4) {
      value &= 7; minimum = 0x10000; extra = 3;
    } else {
      return 0;
    }
    if (extra > length - at)
      return 0;
    for (size_t i = 0; i < extra; ++i) {
      unsigned char next = bytes[at++];
      if ((next & 0xc0) != 0x80)
        return 0;
      value = (value << 6) | (next & 0x3f);
    }
    if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff))
      return 0;
  }
  return 1;
}

static int copy_bytes(JNIEnv* env, jbyteArray source, int optional, int module, char** owned) {
  *owned = NULL;
  if (!source) {
    if (optional)
      return 0;
    throw_exception(env, "java/lang/IllegalArgumentException", "Required rewriter argument is null");
    return 1;
  }
  jsize length = (*env)->GetArrayLength(env, source);
  if ((*env)->ExceptionCheck(env))
    return 1;
  if (length < 1 || length > (module ? MODULE_BYTES_MAX : PATH_BYTES_MAX)) {
    throw_exception(env, "java/lang/IllegalArgumentException", "Invalid rewriter argument byte length");
    return 1;
  }
  char* buffer = malloc((size_t)length + 1);
  if (!buffer) {
    throw_exception(env, "java/lang/OutOfMemoryError", "Cannot copy rewriter argument");
    return 1;
  }
  (*env)->GetByteArrayRegion(env, source, 0, length, (jbyte*)buffer);
  if ((*env)->ExceptionCheck(env)) {
    free(buffer);
    return 1;
  }
  buffer[length] = 0;
  if (!valid_utf8((const unsigned char*)buffer, (size_t)length)) {
    free(buffer);
    throw_exception(env, "java/lang/IllegalArgumentException", "Rewriter arguments require UTF-8 without NUL");
    return 1;
  }
  if (module) {
    for (jsize i = 0; i < length; ++i) {
      unsigned char c = (unsigned char)buffer[i];
      if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-')) {
        free(buffer);
        throw_exception(env, "java/lang/IllegalArgumentException", "Invalid rewriter module identifier");
        return 1;
      }
    }
  }
  *owned = buffer;
  return 0;
}

JNIEXPORT jint JNICALL Java_org_s2arm_android_NativeRewriter_rewrite0(
    JNIEnv* env, jclass owner, jbyteArray input, jbyteArray output, jbyteArray module,
    jboolean spin, jboolean sdk_cut, jbyteArray widen, jbyteArray fps, jbyteArray log_path) {
  (void)owner;
  if ((*env)->ExceptionCheck(env))
    return 1;
  jbyteArray sources[6] = {input, output, module, widen, fps, log_path};
  char* owned[6] = {0};
  jint result = 1;
  for (int i = 0; i < 6; ++i)
    if (copy_bytes(env, sources[i], i == 3 || i == 4, i == 2, &owned[i]))
      goto cleanup;

  if (pthread_mutex_lock(&rewrite_mutex))
    goto cleanup;
  /* Java exclusively creates this private log (0600); do not redirect stdout.
   * Existing shared-core stderr warnings are intentionally not captured here. */
  FILE* log = fopen(owned[5], "wb");
  if (log) {
    /* Fields added by the shared core stay explicitly disabled until exposed
     * by this adapter's contract (for example, cpatch_tsv remains NULL). */
    s2a_rewrite_request request = {0};
    request.input = owned[0];
    request.output_dir = owned[1];
    request.module = owned[2];
    request.target = "android";
    request.widen_tsv = owned[3];
    request.spin = spin == JNI_TRUE;
    request.fps_tsv = owned[4];
    s2a_rewrite_options options = {.sdk_addr_cut = sdk_cut == JNI_TRUE, .signed_jt = 0};   /* signed_jt：适配层契约没开放，保持关（同上 cpatch_tsv） */
    result = s2a_rewrite_files_with_options(&request, &options, log);
    if (fclose(log))
      result = 1;
  }
  if (pthread_mutex_unlock(&rewrite_mutex))
    result = 1;
cleanup:
  for (int i = 5; i >= 0; --i)
    free(owned[i]);
  return result;
}
