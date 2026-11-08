#define _GNU_SOURCE 1
#include <aaudio/AAudio.h>
#include <sched.h>
#include <pthread.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
struct AAudioStream { int rate,channels,format; void (*error)(AAudioStream *,void *,aaudio_result_t); void *user; };
struct AAudioStreamBuilder { int rate,channels,format; void (*error)(AAudioStream *,void *,aaudio_result_t); void *user; };
static cpu_set_t expected;
static int count, fail;
static AAudioStream *latest;
extern int __real_pthread_create(pthread_t *,const pthread_attr_t *,void *(*)(void *),void *);
static void *internal_thread(void *unused) { (void)unused; cpu_set_t mask; CPU_ZERO(&mask); assert(!sched_getaffinity(0,sizeof(mask),&mask)); assert(CPU_EQUAL(&mask,&expected)); return NULL; }
void fake_expect(const cpu_set_t *mask) { expected=*mask; }
void fake_fail(int enabled) { fail=enabled; }
int fake_count(void) { return count; }
void fake_disconnect(void) { assert(latest); latest->error(latest,latest->user,AAUDIO_ERROR_DISCONNECTED); }
int __android_log_print(int a,const char *b,const char *c,...) { (void)a;(void)b;(void)c;return 0; }
aaudio_result_t AAudio_createStreamBuilder(AAudioStreamBuilder **b) { *b=calloc(1,sizeof(**b)); return *b ? AAUDIO_OK: AAUDIO_ERROR_NO_MEMORY; }
#define SETTER(name) void name(AAudioStreamBuilder *b,int v) { (void)b;(void)v; }
SETTER(AAudioStreamBuilder_setDirection) SETTER(AAudioStreamBuilder_setPerformanceMode) SETTER(AAudioStreamBuilder_setSharingMode) SETTER(AAudioStreamBuilder_setUsage) SETTER(AAudioStreamBuilder_setContentType)
void AAudioStreamBuilder_setFormat(AAudioStreamBuilder *b,int v) { b->format=v; }
void AAudioStreamBuilder_setSampleRate(AAudioStreamBuilder *b,int32_t v) { b->rate=v; }
void AAudioStreamBuilder_setChannelCount(AAudioStreamBuilder *b,int32_t v) { b->channels=v; }
void AAudioStreamBuilder_setDataCallback(AAudioStreamBuilder *b, aaudio_data_callback_result_t (*f)(AAudioStream *,void *,void *,int32_t),void *u) { (void)b;(void)f;(void)u; }
void AAudioStreamBuilder_setErrorCallback(AAudioStreamBuilder *b,void (*f)(AAudioStream *,void *,aaudio_result_t),void *u) { b->error=f;b->user=u; }
aaudio_result_t AAudioStreamBuilder_openStream(AAudioStreamBuilder *b,AAudioStream **s) {
 ++count; cpu_set_t mask; CPU_ZERO(&mask); assert(!sched_getaffinity(0,sizeof(mask),&mask)); assert(CPU_EQUAL(&mask,&expected));
 pthread_t t; assert(!__real_pthread_create(&t,NULL,internal_thread,NULL)); assert(!pthread_join(t,NULL));
 if(fail) return AAUDIO_ERROR_INTERNAL;
 *s=calloc(1,sizeof(**s));assert(*s);(*s)->rate=b->rate;(*s)->channels=b->channels;(*s)->format=b->format;(*s)->error=b->error;(*s)->user=b->user;latest=*s;return AAUDIO_OK;
}
aaudio_result_t AAudioStreamBuilder_delete(AAudioStreamBuilder *b) { free(b);return AAUDIO_OK; }
int32_t AAudioStream_getFormat(AAudioStream *s) { return s->format; }
int32_t AAudioStream_getSampleRate(AAudioStream *s) { return s->rate; }
int32_t AAudioStream_getChannelCount(AAudioStream *s) { return s->channels; }
int32_t AAudioStream_getFramesPerBurst(AAudioStream *s) { (void)s;return 192; }
int32_t AAudioStream_setBufferSizeInFrames(AAudioStream *s,int32_t n) { (void)s;return n; }
int32_t AAudioStream_getXRunCount(AAudioStream *s) { (void)s;return 0; }
int32_t AAudioStream_getBufferSizeInFrames(AAudioStream *s) { (void)s;return 384; }
int32_t AAudioStream_getSharingMode(AAudioStream *s) { (void)s;return 1; }
aaudio_result_t AAudioStream_requestStart(AAudioStream *s) { (void)s;return AAUDIO_OK; }
aaudio_result_t AAudioStream_requestPause(AAudioStream *s) { (void)s;return AAUDIO_OK; }
aaudio_result_t AAudioStream_requestStop(AAudioStream *s) { (void)s;return AAUDIO_OK; }
aaudio_result_t AAudioStream_close(AAudioStream *s) { if(s==latest)latest=NULL;free(s);return AAUDIO_OK; }
