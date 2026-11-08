#include "NS2Transport.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// Pure codec contracts, not device reports or evidence of physical haptic output.
static uint64_t operation(const uint8_t packet[42], unsigned side) {
    uint64_t result = 0;
    for (unsigned byte = 0; byte < 5; byte++) result |= (uint64_t)packet[2 + side * 16 + byte] << (byte * 8);
    return result;
}

static void verify_codes(ns2_vibration value, float gain, unsigned low, unsigned high) {
    ns2_rumble_amplitudes codes = ns2_rumble_amplitude_codes(value, gain);
    assert(codes.low == low && codes.high == high);
    ns2_vibration values[2] = {value, {0}};
    uint8_t packet[42];
    ns2_encode_rumble(values, 0, gain, packet);
    uint64_t op = operation(packet, 0);
    assert(((op >> 10) & 1023) == low && ((op >> 30) & 1023) == high);
    assert(packet[1] == (low || high ? 0x50 : 0x10));
    if (!low) assert((op & 1023) == 0);
    if (!high) assert(((op >> 20) & 1023) == 0);
}

int main(void) {
    // Values seen in host-rumble-working.log, preserving the existing gain=2 mapping.
    verify_codes((ns2_vibration){.0001f, 170.74f, .0002f, 287.15f}, 2, 0, 0);
    verify_codes((ns2_vibration){.0002f, 160, .0038f, 320}, 2, 0, 1);
    verify_codes((ns2_vibration){.0547f, 160, .0935f, 320}, 2, 21, 36);
    verify_codes((ns2_vibration){.0059f, 236.29f, .0047f, 257.68f}, 2, 2, 2);

    float half_step = .5f / 384.f;
    verify_codes((ns2_vibration){nextafterf(half_step, 0), 160, half_step, 320}, 2, 0, 1);
    verify_codes((ns2_vibration){nextafterf(half_step, INFINITY), 160, 1, 320}, 2, 1, 384);
    verify_codes((ns2_vibration){-1, 160, 2, 320}, 4, 0, 768);
    verify_codes((ns2_vibration){NAN, 160, INFINITY, 320}, 2, 0, 0);
    verify_codes((ns2_vibration){1, NAN, 1, 0}, 2, 0, 0);
    verify_codes((ns2_vibration){1, -1, 1, INFINITY}, 2, 0, 0);
    const float invalid_gains[] = {-1, 4.01f, NAN, INFINITY};
    for (unsigned i = 0; i < sizeof invalid_gains / sizeof invalid_gains[0]; i++)
        verify_codes((ns2_vibration){1, 160, 1, 320}, invalid_gains[i], 0, 0);
    verify_codes((ns2_vibration){1, 160, 1, 320}, 0, 0, 0);

    // A fixed single-operation vector: code96 @160Hz and code69 @320Hz.
    ns2_vibration values[2] = {{.25f, 160, .18f, 320}, {0}};
    uint8_t packet[42], expected[42] = {0};
    expected[1] = 0x5f;
    expected[2] = 0x81; expected[3] = 0x81; expected[4] = 0x11;
    expected[5] = 0x5e; expected[6] = 0x11; expected[17] = 0x1f;
    ns2_encode_rumble(values, 31, 2, packet);
    assert(memcmp(packet, expected, sizeof packet) == 0);

    // Swapping sides must preserve the complete operation and leave the other side silent.
    values[1] = values[0]; values[0] = (ns2_vibration){0};
    ns2_encode_rumble(values, 0, 2, packet);
    assert(packet[1] == 0x10 && operation(packet, 0) == 0 && packet[17] == 0x50);
    assert(memcmp(packet + 18, expected + 2, 5) == 0);
    values[1] = (ns2_vibration){0};
    ns2_encode_rumble(values, 1, 2, packet);
    assert(packet[1] == 0x11 && packet[17] == 0x11);
    assert(operation(packet, 0) == 0 && operation(packet, 1) == 0);

    // Quantization never changes either carrier; clamp boundaries remain 40..1252Hz.
    values[0] = (ns2_vibration){.25f, 1, .18f, 2000};
    ns2_encode_rumble(values, 0, 2, packet);
    assert((operation(packet, 0) & 1023) == 193);
    assert(((operation(packet, 0) >> 20) & 1023) == 670);
    puts("rumble codec contracts passed (no device access)");
    return 0;
}
