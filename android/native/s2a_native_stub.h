#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Host side of the link stand-ins in s2a_native_stub.c (single-library build only).
void s2a_android_set_screen_w(int width);
const char *s2a_android_last_boot_mark(void);

// Exported by the linked NativeAOT composition (cs/aot/AndroidSelfTest.cs).
int s2a_android_cs_selftest(char *report, int length);
void s2a_ap_audio_mark(void);
int s2a_android_audio_selftest(char *report, int length);
int s2a_android_codec_selftest(char *report, int length);   // cs/aot/AndroidCodecs.cs

#ifdef __cplusplus
}
#endif
