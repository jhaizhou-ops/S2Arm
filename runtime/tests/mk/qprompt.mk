# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += qprompt
.PHONY: native-test-qprompt
native-test-qprompt:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_qprompt runtime/tests/t_qprompt.c runtime/src/qprompt.c
	$(BUILD)/tests/t_qprompt
TEST_TARGETS += native-test-qprompt
