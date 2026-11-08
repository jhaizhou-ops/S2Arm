// H02 的独立 C 参考实现，只做文件中的着色器键覆盖，不接运行时。
// 函数消费调用方提供的两个 FILE 流，不关闭它们；out 必须是尚未持有结果的对象。
// seen_input 可为 NULL，明确表示 seen 文件不存在；keys_input 必须为有效流。
// 返回 0 已覆盖 / 1 未就绪（含空 seen） / 2 输入或内存错误；结果用 direct_ready_result_free 释放。
// 参考实现允许分配和排序，不承诺渲染热路径零分配。CLI: -DDIRECT_READY_MAIN。
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

typedef struct {
  unsigned char *key;  // seen 保留任意坏行，不能截断或把大写折成小写。
  size_t length;
  size_t input_rows;
} DirectReadyKey;

typedef struct {
  size_t seen;
  size_t covered;
  size_t missing;
  DirectReadyKey *missing_rows;
} DirectReadyResult;

typedef struct {
  DirectReadyKey *items;
  size_t count;
  size_t capacity;
} KeyList;

static int hex_byte(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

static int key_valid(const unsigned char *line, size_t length) {
  if (length != 16) return 0;
  for (size_t i = 0; i < length; ++i) {
    if (!hex_byte((unsigned char)line[i])) return 0;
  }
  return 1;
}

static int compare_key(const void *a, const void *b) {
  const DirectReadyKey *left = a, *right = b;
  size_t common = left->length < right->length ? left->length : right->length;
  int order = memcmp(left->key, right->key, common);
  if (order) return order;
  return (left->length > right->length) - (left->length < right->length);
}

static int compare_missing(const void *a, const void *b) {
  const DirectReadyKey *left = a, *right = b;
  if (left->input_rows != right->input_rows) return left->input_rows > right->input_rows ? -1 : 1;
  return compare_key(a, b);
}

static void key_list_free(KeyList *list) {
  for (size_t i = 0; i < list->count; ++i) free(list->items[i].key);
  free(list->items);
}

static int read_keys(FILE *stream, int is_seen, KeyList *list, char *error, size_t error_size) {
  char *line = NULL;
  size_t capacity = 0, number = 0;
  ssize_t length;
  int rc = 2;
  while ((length = getline(&line, &capacity, stream)) >= 0) {
    ++number;
    size_t size = (size_t)length;
    while (size && (line[size - 1] == ' ' || line[size - 1] == '\t' ||
                    line[size - 1] == '\r' || line[size - 1] == '\n')) --size;
    if (!size) continue;
    if (!is_seen && !key_valid((const unsigned char *)line, size)) {
      snprintf(error, error_size, "keys line %zu: expected one lowercase hex key", number);
      goto done;
    }
    if (list->count == list->capacity) {
      if (list->capacity > SIZE_MAX / 2 / sizeof(*list->items)) {
        snprintf(error, error_size, "input too large");
        goto done;
      }
      size_t next = list->capacity ? list->capacity * 2 : 256;
      DirectReadyKey *items = realloc(list->items, next * sizeof(*items));
      if (!items) {
        snprintf(error, error_size, "out of memory");
        goto done;
      }
      list->items = items;
      list->capacity = next;
    }
    unsigned char *key = malloc(size);
    if (!key) {
      snprintf(error, error_size, "out of memory");
      goto done;
    }
    DirectReadyKey *item = &list->items[list->count++];
    item->key = key;
    memcpy(item->key, line, size);
    item->length = size;
    item->input_rows = 1;
  }
  if (!feof(stream) || ferror(stream)) {
    snprintf(error, error_size, "%s read failed", is_seen ? "seen" : "keys");
    goto done;
  }
  if (list->count > 1) qsort(list->items, list->count, sizeof(*list->items), compare_key);
  size_t unique = 0;
  for (size_t i = 0; i < list->count; ++i) {
    if (unique && !compare_key(&list->items[unique - 1], &list->items[i])) {
      ++list->items[unique - 1].input_rows;
      free(list->items[i].key);
    } else {
      list->items[unique++] = list->items[i];
    }
  }
  list->count = unique;
  rc = 0;
done:
  free(line);
  return rc;
}

void direct_ready_result_free(DirectReadyResult *result) {
  if (!result) return;
  for (size_t i = 0; i < result->missing; ++i) free(result->missing_rows[i].key);
  free(result->missing_rows);
  memset(result, 0, sizeof(*result));
}

int direct_ready_reference(FILE *seen_input, FILE *keys_input, DirectReadyResult *out,
                           char *error, size_t error_size) {
  KeyList seen = {0}, keys = {0};
  if (!out || !error || !error_size) return 2;
  memset(out, 0, sizeof(*out));
  error[0] = 0;
  if (!keys_input) {
    snprintf(error, error_size, "keys input stream is required");
    return 2;
  }
  int rc = 2;
  if ((seen_input && read_keys(seen_input, 1, &seen, error, error_size)) ||
      read_keys(keys_input, 0, &keys, error, error_size)) goto done;
  if (seen.count) {
    out->missing_rows = malloc(seen.count * sizeof(*out->missing_rows));
    if (!out->missing_rows) {
      snprintf(error, error_size, "out of memory");
      goto done;
    }
  }
  out->seen = seen.count;
  size_t k = 0;
  for (size_t s = 0; s < seen.count; ++s) {
    while (k < keys.count && compare_key(&keys.items[k], &seen.items[s]) < 0) ++k;
    int covered = key_valid(seen.items[s].key, seen.items[s].length) && k < keys.count &&
                  !compare_key(&keys.items[k], &seen.items[s]);
    if (covered) ++out->covered;
    else {
      out->missing_rows[out->missing++] = seen.items[s];
      seen.items[s].key = NULL;  // 缺口字节的所有权交给 out。
    }
  }
  if (out->missing > 1) {
    qsort(out->missing_rows, out->missing, sizeof(*out->missing_rows), compare_missing);
  }
  rc = out->seen && !out->missing ? 0 : 1;
done:
  key_list_free(&seen);
  key_list_free(&keys);
  if (rc == 2) direct_ready_result_free(out);
  return rc;
}

#ifdef DIRECT_READY_MAIN
static void print_result(const DirectReadyResult *out) {
  printf("ready=%d seen=%zu covered=%zu missing=%zu\n", out->seen > 0 && !out->missing,
         out->seen, out->covered, out->missing);
  if (out->seen) {
    printf("coverage=%zu/%zu (%.6f%%)\n", out->covered, out->seen, 100.0 * out->covered / out->seen);
  } else {
    puts("coverage=0/0 (no samples; not ready)");
  }
  puts("# input_rows = occurrences in seen input; not gameplay call frequency");
  puts("missing_key\tinput_rows");
  for (size_t i = 0; i < out->missing; ++i) {
    const DirectReadyKey *key = &out->missing_rows[i];
    for (size_t j = 0; j < key->length; ++j) {
      unsigned char byte = key->key[j];
      if (byte >= 32 && byte < 127 && byte != '\\') putchar(byte);
      else printf("\\x%02x", (unsigned int)byte);
    }
    printf("\t%zu\n", key->input_rows);
  }
}

int main(int argc, char **argv) {
  const char *seen_path = NULL, *keys_path = NULL;
  for (int i = 1; i < argc; ++i) {
    if (i + 1 < argc && !strcmp(argv[i], "--seen") && !seen_path) seen_path = argv[++i];
    else if (i + 1 < argc && !strcmp(argv[i], "--keys") && !keys_path) keys_path = argv[++i];
    else {
      fputs("usage: direct_ready_ref --seen FILE --keys FILE\n", stderr);
      return 2;
    }
  }
  if (!seen_path || !keys_path) {
    fputs("usage: direct_ready_ref --seen FILE --keys FILE\n", stderr);
    return 2;
  }
  FILE *seen = fopen(seen_path, "rb");
  int seen_missing = !seen && errno == ENOENT;
  FILE *keys = fopen(keys_path, "rb");
  if ((!seen && !seen_missing) || !keys) {
    fputs("direct_ready_ref: cannot open input\n", stderr);
    if (seen) fclose(seen);
    if (keys) fclose(keys);
    return 2;
  }
  DirectReadyResult out;
  char error[256];
  int rc = direct_ready_reference(seen, keys, &out, error, sizeof(error));
  if (seen) fclose(seen);
  fclose(keys);
  if (rc == 2) fprintf(stderr, "direct_ready_ref: input error: %s\n", error);
  else print_result(&out);
  direct_ready_result_free(&out);
  return rc;
}
#endif
