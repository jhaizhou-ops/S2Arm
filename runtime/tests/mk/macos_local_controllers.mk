# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += macos_local_controllers
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-macos_local_controllers
native-test-macos_local_controllers:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -o $(BUILD)/tests/t_macos_local_controllers runtime/tests/t_macos_local_controllers.c runtime/src/pad.c
	$(BUILD)/tests/t_macos_local_controllers
TEST_TARGETS += native-test-macos_local_controllers
endif
