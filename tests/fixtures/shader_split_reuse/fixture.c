/* SPDX-License-Identifier: 0BSD */

__attribute__((used)) const unsigned long fixture_rodata = 0x534132414e534f31UL;
__attribute__((used)) volatile unsigned long fixture_data = 0x2026102600000001UL;

__attribute__((noreturn, used)) void _start(void) {
    unsigned long value = fixture_rodata ^ fixture_data;
    for (;;) {
        __asm__ volatile("yield" ::: "memory");
        fixture_data = value;
        value += 0x9e3779b97f4a7c15UL;
    }
}
