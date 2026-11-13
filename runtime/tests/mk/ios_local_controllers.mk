# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += ios_local_controllers
.PHONY: native-test-ios_local_controllers
native-test-ios_local_controllers:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_ios_local_controllers runtime/tests/t_ios_local_controllers.c runtime/src/pad.c -lm -lpthread
	$(BUILD)/tests/t_ios_local_controllers ios/local_controllers.m
TEST_TARGETS += native-test-ios_local_controllers
