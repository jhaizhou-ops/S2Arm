// Included after unmodified vpad recording/read functions by touch_baseline_compare.py.
// Recording uses real stdio and the real production frame/build-id accessors.
static void check_read(void) {
    int32_t axes[4]; uint32_t buttons = s2a_vpad_read(axes);
    printf("%04x %d %d %d %d\n", buttons, axes[0], axes[1], axes[2], axes[3]);
}
int main(int argc, const char **argv) {
    assert(argc == 2);
    g_rec = fopen(argv[1], "w"); assert(g_rec);
    assert(strlcpy(g_rpath, argv[1], sizeof g_rpath) < sizeof g_rpath);
    g_rt0 = rec_ms();
    s2a_pad_set_active(1);
    const int16_t neutral[4] = {0};
    const int16_t full[4] = {-32767, 32767, -1, 1};
    const int16_t moved[4] = {32767, -32767, 12345, -23456};
    check_read(); check_read();
    for (unsigned bit = 0; bit < 16; bit++) {
        publish(1u << bit, full); publish(0, full);
        check_read(); check_read();
    }
    publish(0x8421, full); publish(0, full);
    publish(0x1248, moved); publish(0, moved);
    check_read(); check_read();
    publish(0xffff, moved); check_read(); check_read();
    publish(0xffff, moved); check_read();
    publish(0, neutral); check_read(); check_read();
    // Actual save-marker code, no snapshot hook is linked in this host-only test.
    const char *save = s2a_padrec_mark(); assert(save);
    assert(strstr(save, ".save1") && !s2a_pad_has_controller());
    assert(s2a_padrec_mark() && strstr(g_rsave, ".save2"));
    assert(!fclose(g_rec)); g_rec = NULL;
    return 0;
}
