#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Capture the first valid surface revision as one coherent aspect snapshot.
// Returns 0 until the registered HostApi reports nonzero surface dimensions.
// Values are normalized to at least 1920 x 1080, matching widen's contract.
int s2a_android_screen_metrics(int *width, int *height);
#ifdef __cplusplus
}
#endif
