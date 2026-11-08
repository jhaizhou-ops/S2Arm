// Host fixture: fake Android API, but exercise the production open and reconnect paths.
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <aaudio/AAudio.h>
#include "../native/aaudio_sink.h"
#include "../native/pcm_ring.h"
#include "../native/capacity_affinity.h"
// This fixture exercises AAudio format/reconnect with default split behavior.
int s2a_capacity_call_wide(int (*operation)(void *), void *argument, int *result) {
    (void)operation; (void)argument; (void)result; return 0;
}
static AAudioStream stream;
static AAudioStreamBuilder builder;
static int actual_format, actual_rate = 48000, actual_channels = 2, closed, starts;
static void (*error_callback)(AAudioStream *, void *, aaudio_result_t);
static void *error_user;
int eventfd(unsigned int v, int flags) { (void)v; (void)flags; return open("/dev/null", O_RDWR); }
int __android_log_print(int level, const char *tag, const char *fmt, ...) { (void)level; (void)tag; (void)fmt; return 0; }
aaudio_result_t AAudio_createStreamBuilder(AAudioStreamBuilder **b) { *b=&builder; return 0; }
#define SETTER(name) void AAudioStreamBuilder_set##name(AAudioStreamBuilder *b, int v) { (void)b; (void)v; }
SETTER(Direction) SETTER(Format) SETTER(SampleRate) SETTER(ChannelCount) SETTER(PerformanceMode) SETTER(SharingMode) SETTER(Usage) SETTER(ContentType)
void AAudioStreamBuilder_setDataCallback(AAudioStreamBuilder *b, aaudio_data_callback_result_t (*cb)(AAudioStream *, void *, void *, int32_t), void *u) { (void)b; (void)cb; (void)u; }
void AAudioStreamBuilder_setErrorCallback(AAudioStreamBuilder *b, void (*cb)(AAudioStream *, void *, aaudio_result_t), void *u) { (void)b; error_callback=cb; error_user=u; }
int AAudioStreamBuilder_openStream(AAudioStreamBuilder *b, AAudioStream **s) { (void)b; *s=&stream; return 0; }
void AAudioStreamBuilder_delete(AAudioStreamBuilder *b) { (void)b; }
#define GETTER(name, value) int AAudioStream_get##name(AAudioStream *s) { (void)s; return (value); }
GETTER(Format, actual_format) GETTER(SampleRate, actual_rate) GETTER(ChannelCount, actual_channels) GETTER(FramesPerBurst, 128) GETTER(XRunCount, 0) GETTER(BufferSizeInFrames, 256) GETTER(SharingMode, 0)
int AAudioStream_close(AAudioStream *s) { (void)s; closed++; return 0; }
int AAudioStream_setBufferSizeInFrames(AAudioStream *s, int n) { (void)s; return n; }
int AAudioStream_requestStart(AAudioStream *s) { (void)s; starts++; return 0; }
int AAudioStream_requestPause(AAudioStream *s) { (void)s; return 0; }
int AAudioStream_requestStop(AAudioStream *s) { (void)s; return 0; }
int main(void) {
    s2a_aaudio *a = NULL;
    actual_format=AAUDIO_FORMAT_PCM_FLOAT;
    assert(s2a_aaudio_open(S2A_PCM_I16, 48000, 2, 10, &a)==AAUDIO_ERROR_INVALID_FORMAT);
    assert(a==NULL && closed==1);
    actual_format=AAUDIO_FORMAT_PCM_I16;
    assert(s2a_aaudio_open(S2A_PCM_I16, 48000, 2, 10, &a)==0 && a);
    assert(s2a_aaudio_start(a)==0 && starts==1);
    actual_format=AAUDIO_FORMAT_PCM_FLOAT;
    error_callback(&stream,error_user,AAUDIO_ERROR_DISCONNECTED);
    s2a_aaudio_service(a);
    assert(closed==3 && starts==1);
    assert(s2a_aaudio_start(a)==AAUDIO_ERROR_DISCONNECTED);
    actual_format=AAUDIO_FORMAT_PCM_I16;
    s2a_aaudio_service(a);
    assert(starts==2);
    s2a_aaudio_close(a);
    actual_format=AAUDIO_FORMAT_PCM_FLOAT;
    assert(s2a_aaudio_open(S2A_PCM_F32, 48000, 2, 10, &a)==0);
    s2a_aaudio_close(a);
    puts("AAudio format: mismatch rejected and closed on open/reopen; matching i16/f32 accepted");
}
