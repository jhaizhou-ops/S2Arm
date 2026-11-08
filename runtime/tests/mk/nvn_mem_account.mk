# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Standalone diagnostic object-graph fixture; does not build or run an ARM guest host.
NATIVE_TEST_OWN += nvn_mem_account
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_mem_account: graphics/nvn/tests/t_nvn_mem_account.m graphics/nvn/gfx/nvn/nvn_mem_account.inc
	@mkdir -p $(@D)
	$(CC) -std=gnu11 -fobjc-arc -DS2A_MEM_ACCOUNT_TEST -framework Foundation -framework Metal -o $@ $<
.PHONY: native-test-nvn_mem_account
native-test-nvn_mem_account: $(BUILD)/tests/t_nvn_mem_account
	timeout 60 $(BUILD)/tests/t_nvn_mem_account
TEST_TARGETS += native-test-nvn_mem_account
endif
