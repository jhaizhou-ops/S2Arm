// NS2 Pro 双频编码；频率经实机频谱核对，绝对力度尚未与 Switch 主机校准。
// NS2 Pro dual-band encoding; frequencies were checked acoustically, absolute force is not console-calibrated.
#include "NS2Transport.h"
#include <math.h>
#include <string.h>

// 以实测幅码192为单位线性调节；保留两频段比例，不做 RSS 合并或感知曲线放大。
// Adjust linearly in units of measured code192, preserving band ratios without RSS mixing or perceptual boosting.
static unsigned amplitude_code(float amplitude, float gain) {
    return isfinite(amplitude) ? (unsigned)lroundf(192.f * gain * fminf(1.f, fmaxf(0.f, amplitude))) : 0;
}
ns2_rumble_amplitudes ns2_rumble_amplitude_codes(ns2_vibration value, float gain) {
    if (!isfinite(gain) || gain < 0 || gain > 4) return (ns2_rumble_amplitudes){0};
    return (ns2_rumble_amplitudes){
        isfinite(value.low_freq) && value.low_freq > 0 ? amplitude_code(value.low_amp, gain) : 0,
        isfinite(value.high_freq) && value.high_freq > 0 ? amplitude_code(value.high_amp, gain) : 0
    };
}
static unsigned frequency_code(float hz) {
    // 10 bit 对数频率；577 已实测为 640 Hz，bit9 不是独立的使能位。
    // Ten-bit logarithmic frequency; code 577 measured 640 Hz, so bit9 is not a separate enable flag.
    return (unsigned)lroundf(1.f + 96.f * log2f(fminf(1252.f, fmaxf(40.f, hz)) / 10.f));
}
void ns2_encode_rumble(const ns2_vibration values[2], uint8_t sequence, float gain, uint8_t out[42]) {
    memset(out, 0, 42);
    for (unsigned side = 0; side < 2; side++) {
        ns2_vibration v = values[side];
        // 非法载频不能生成有效震动；零幅度频段的载频也归零。
        // Invalid carriers cannot produce active rumble; zero-amplitude bands also have zero carrier codes.
        ns2_rumble_amplitudes codes = ns2_rumble_amplitude_codes(v, gain);
        unsigned la = codes.low, ha = codes.high;
        unsigned lf = la ? frequency_code(v.low_freq) : 0;
        unsigned hf = ha ? frequency_code(v.high_freq) : 0;
        uint64_t op = lf | ((uint64_t)la << 10) | ((uint64_t)hf << 20) | ((uint64_t)ha << 30);
        unsigned offset = 1 + side * 16;
        out[offset] = (la || ha ? 0x50 : 0x10) | (sequence & 15);
        for (unsigned byte = 0; byte < 5; byte++) out[offset + 1 + byte] = (uint8_t)(op >> (8 * byte));
    }
}
