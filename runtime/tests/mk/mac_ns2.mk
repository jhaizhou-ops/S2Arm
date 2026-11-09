# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += mac_ns2
.PHONY: native-test-mac_ns2
native-test-mac_ns2:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Werror -Wno-unused-parameter runtime/tests/t_mac_ns2.c macos/ns2_controller.c -o $(BUILD)/tests/t_mac_ns2
	$(BUILD)/tests/t_mac_ns2
TEST_TARGETS += native-test-mac_ns2
