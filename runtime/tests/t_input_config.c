// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_input_config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
static unsigned checks;
#define CHECK(x, why) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %u: %s\n", checks, why); exit(1); } } while (0)
static const char valid[] = "{\"schema\":1,\"keyboard\":{\"A\":{\"code\":14}},\"mouse\":{\"Y\":0},\"gamepad\":{\"A\":\"east\"},\"axes\":{\"LX\":{\"source\":\"leftX\"}},\"deadzone\":0.15,\"mouseOptions\":{\"mode\":\"camera\",\"sensitivityX\":1,\"sensitivityY\":1}}";
static void bad(const char *json, size_t n, int expected, const char *why) {
    s2a_input_config c, saved; memset(&c, 0x5a, sizeof c); saved = c;
    int rc = s2a_input_config_parse(json, n, &c);
    CHECK(rc == expected, why); CHECK(!memcmp(&c, &saved, sizeof c), "failure never publishes a partial config");
}
static void replace_bad(const char *from, const char *to, int rc, const char *why) {
    const char *at = strstr(valid, from); CHECK(at != NULL, "fixture replacement anchor");
    size_t left = (size_t)(at - valid), n = strlen(valid) - strlen(from) + strlen(to);
    char *p = malloc(n + 1); CHECK(p != NULL, "fixture allocation");
    memcpy(p, valid, left); memcpy(p + left, to, strlen(to)); strcpy(p + left + strlen(to), at + strlen(from));
    bad(p, n, rc, why); free(p);
}
int main(void) {
    s2a_input_config c;
    CHECK(s2a_input_config_parse(valid, strlen(valid), &c) == 0, "valid schema1 optional fields omitted");
    CHECK(c.keyboard[0].code == 14 && c.keyboard[0].modifiers == 0, "A is Mac code14 with no modifiers");
    CHECK(c.keyboard[1].code == -1 && c.mouse[3] == 0 && c.mouse[0] == -1, "explicit config preserves unbound keys and leftmouse Y");
    CHECK(c.gamepad[0] == 0 && c.axes[0].source == 0 && !c.axes[0].invert, "east and leftX are canonical sources");
    CHECK(c.mouse_camera && c.recenter && !c.invert_x && !c.invert_y, "schema1 option defaults are camera/recenter/no inversion");
    CHECK(c.deadzone == .15 && c.sensitivity_x == 1 && c.sensitivity_y == 1, "numeric values retained");
    CHECK(c.back_buttons[0] == -1 && c.back_buttons[1] == -1, "older mappings leave both back buttons unbound");
    char with_back[sizeof valid + 80];
    snprintf(with_back, sizeof with_back, "%.*s,\"backButtons\":{\"GL\":\"east\",\"GR\":\"south\"}}", (int)strlen(valid) - 1, valid);
    CHECK(!s2a_input_config_parse(with_back, strlen(with_back), &c), "launcher back-button mappings accepted");
    CHECK(c.back_buttons[0] == 0 && c.back_buttons[1] == 1 && c.gamepad[0] == 0, "back mappings supplement original gamepad mappings");
    replace_bad("\"schema\":1", "\"schema\":1,\"backButtons\":{\"GL\":\"unknown\"}", S2A_INPUT_CONFIG_BINDING, "invalid back-button source rejected");
    replace_bad("\"schema\":1", "\"schema\":1,\"backButtons\":{\"XX\":\"east\"}", S2A_INPUT_CONFIG_BINDING, "invalid paddle rejected");
    const char custom[] = "{\"schema\":1,\"keyboard\":{\"A\":{\"code\":49,\"modifiers\":3},\"B\":{\"code\":49}},\"mouse\":{\"ZL\":4},\"gamepad\":{\"PLUS\":\"options\"},\"axes\":{\"RY\":{\"source\":\"leftY\",\"invert\":true}},\"deadzone\":0,\"mouseOptions\":{\"mode\":\"off\",\"sensitivityX\":0.1,\"sensitivityY\":10,\"invertX\":true,\"invertY\":true,\"recenter\":false}}";
    CHECK(!s2a_input_config_parse(custom, sizeof custom - 1, &c), "custom keyboard chord and edge values");
    CHECK(c.keyboard[0].code == 49 && c.keyboard[0].modifiers == 3 && c.keyboard[1].code == 49 && !c.keyboard[1].modifiers, "same key with different modifiers remains distinct");
    CHECK(c.mouse[8] == 4 && c.gamepad[10] == 11 && c.axes[3].source == 1 && c.axes[3].invert, "custom mouse/gamepad/axis map matches hand-written values");
    CHECK(!c.mouse_camera && !c.recenter && c.invert_x && c.invert_y && c.sensitivity_x == .1 && c.sensitivity_y == 10, "custom options and boundaries match");
    s2a_input_config_default(&c);
    // Oracle: original Mac default key table. These are key identities, not output
    // obtained by parsing/serializing the implementation under test.
    const int expected_keys[] = {14,56,49,-1,59,8,12,5,-1,15,48,46,123,126,124,125,0,13,2,1,-1,-1,-1,-1};
    for (int i = 0; i < 24; i++) {
        CHECK(c.keyboard[i].code == expected_keys[i] && !c.keyboard[i].modifiers, "frozen default keyboard identity");
        CHECK(c.mouse[i] == (i == 3 ? 0 : i == 8 ? 1 : -1), "frozen default mouse identity");
        CHECK(c.gamepad[i] == (i < 16 ? i : -1), "frozen default controller identity");
    }
    for (int i = 0; i < 4; i++) CHECK(c.axes[i].source == i && !c.axes[i].invert, "default axes unchanged");
    CHECK(!strcmp(s2a_input_target_name(0), "A") && !strcmp(s2a_input_target_name(23), "RS_DOWN"), "target names");
    CHECK(!s2a_input_target_name(-1) && !s2a_input_target_name(24) && !s2a_input_pad_name(16) && !s2a_input_axis_name(4), "name lookup bounds");
    bad(NULL, 0, S2A_INPUT_CONFIG_JSON, "missing bytes"); bad("", 0, S2A_INPUT_CONFIG_JSON, "empty JSON");
    bad("{", 1, S2A_INPUT_CONFIG_JSON, "truncated JSON"); bad("[]", 2, S2A_INPUT_CONFIG_JSON, "root array");
    replace_bad("\"schema\":1", "\"schema\":2", S2A_INPUT_CONFIG_SCHEMA, "unknown schema");
    replace_bad("\"schema\":1", "\"schema\":\"1\"", S2A_INPUT_CONFIG_SCHEMA, "schema string is not a version number");
    replace_bad("\"schema\":1", "\"schema\":true", S2A_INPUT_CONFIG_SCHEMA, "schema bool is not a version number");
    replace_bad("\"schema\":1", "\"schema\":1,\"\\u0073chema\":1", S2A_INPUT_CONFIG_JSON, "escaped duplicate root key");
    replace_bad("\"schema\":1", "\"schema\\u0000tail\":1", S2A_INPUT_CONFIG_JSON, "NUL in field name cannot alias schema");
    replace_bad("\"keyboard\":{\"A\":{\"code\":14}}", "\"keyboard\":\"bad\"", S2A_INPUT_CONFIG_FIELDS, "keyboard must be object");
    replace_bad("\"code\":14", "\"code\":\"14\"", S2A_INPUT_CONFIG_BINDING, "key code string");
    replace_bad("\"code\":14", "\"code\":true", S2A_INPUT_CONFIG_BINDING, "key code boolean");
    replace_bad("\"code\":14", "\"code\":14.0", S2A_INPUT_CONFIG_BINDING, "key code floating JSON type");
    replace_bad("\"code\":14", "\"code\":128", S2A_INPUT_CONFIG_BINDING, "key code upper bound");
    replace_bad("\"code\":14", "\"code\":-1", S2A_INPUT_CONFIG_BINDING, "key code lower bound");
    replace_bad("\"code\":14", "\"code\":14,\"modifiers\":8", S2A_INPUT_CONFIG_BINDING, "modifier upper bound");
    replace_bad("\"A\":{\"code\":14}", "\"BAD\":{\"code\":14}", S2A_INPUT_CONFIG_TARGET, "unknown target");
    replace_bad("\"A\":{\"code\":14}", "\"A\":{\"code\":14},\"B\":{\"code\":14}", S2A_INPUT_CONFIG_DUPLICATE, "duplicate key chord");
    replace_bad("\"A\":{\"code\":14}", "\"A\":{\"code\":14},\"A\":{\"code\":15}", S2A_INPUT_CONFIG_JSON, "nested duplicate object key");
    replace_bad("\"Y\":0", "\"Y\":5", S2A_INPUT_CONFIG_BINDING, "mouse index upper bound");
    replace_bad("\"Y\":0", "\"Y\":0,\"B\":0", S2A_INPUT_CONFIG_DUPLICATE, "duplicate mouse button");
    replace_bad("\"A\":\"east\"", "\"A\":\"other\"", S2A_INPUT_CONFIG_BINDING, "unknown gamepad source");
    replace_bad("\"A\":\"east\"", "\"A\":\"east\",\"B\":\"east\"", S2A_INPUT_CONFIG_DUPLICATE, "duplicate gamepad source");
    replace_bad("\"source\":\"leftX\"", "\"source\":\"leftX\\u0000tail\"", S2A_INPUT_CONFIG_BINDING, "NUL in source cannot alias known name");
    replace_bad("\"source\":\"leftX\"", "\"source\":\"leftX\",\"invert\":\"yes\"", S2A_INPUT_CONFIG_BINDING, "axis invert must be bool");
    replace_bad("\"LX\":{\"source\":\"leftX\"}", "\"LX\":{\"source\":\"leftX\"},\"RX\":{\"source\":\"leftX\"}", S2A_INPUT_CONFIG_DUPLICATE, "duplicate axis source");
    replace_bad("\"deadzone\":0.15", "\"deadzone\":1", S2A_INPUT_CONFIG_RANGE, "deadzone upper bound");
    replace_bad("\"deadzone\":0.15", "\"deadzone\":-0.1", S2A_INPUT_CONFIG_RANGE, "deadzone lower bound");
    replace_bad("\"sensitivityX\":1", "\"sensitivityX\":0", S2A_INPUT_CONFIG_RANGE, "sensitivity lower bound");
    replace_bad("\"sensitivityY\":1", "\"sensitivityY\":11", S2A_INPUT_CONFIG_RANGE, "sensitivity upper bound");
    replace_bad("\"mode\":\"camera\"", "\"mode\":\"camera\\u0000tail\"", S2A_INPUT_CONFIG_BINDING, "NUL in mode cannot alias camera");
    replace_bad("\"sensitivityY\":1", "\"sensitivityY\":1,\"recenter\":1", S2A_INPUT_CONFIG_BINDING, "recenter must be bool");
    bad(valid, sizeof valid, S2A_INPUT_CONFIG_JSON, "trailing NUL is not JSON whitespace");
    bad(valid, S2A_INPUT_CONFIG_MAX_BYTES + (size_t)1, S2A_INPUT_CONFIG_JSON, "length bound checked before reading");
    CHECK(s2a_input_config_parse(valid, sizeof valid - 1, NULL) == S2A_INPUT_CONFIG_JSON, "null output rejected");
    char saved_locale[128]; snprintf(saved_locale, sizeof saved_locale, "%s", setlocale(LC_NUMERIC, NULL));
    const char *locales[] = {"fr_FR.UTF-8", "de_DE.UTF-8"};
    for (int i = 0; i < 2; i++) {
        if (!setlocale(LC_NUMERIC, locales[i])) { printf("locale unavailable: %s (not exercised)\n", locales[i]); continue; }
        CHECK(!s2a_input_config_parse(valid, sizeof valid - 1, &c), "JSON decimal independent of process locale");
        CHECK(c.deadzone == .15 && c.sensitivity_x == 1, "locale conversion preserves numeric values");
    }
    CHECK(setlocale(LC_NUMERIC, saved_locale) != NULL, "restore this test process locale");
    CHECK(!strcmp(s2a_input_config_error_message(S2A_INPUT_CONFIG_SCHEMA), "unsupported input schema"), "shared schema error text");
    printf("✓ t_input_config: %u/%u checks (schema1, hand-written maps, errors, defaults, no partial publish)\n", checks, checks);
    return 0;
}
