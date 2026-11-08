# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += widen_remember
.PHONY: native-test-widen_remember
native-test-widen_remember:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_widen_remember runtime/tests/t_widen_remember.c runtime/src/widen_remember.c
	$(BUILD)/tests/t_widen_remember
TEST_TARGETS += native-test-widen_remember
