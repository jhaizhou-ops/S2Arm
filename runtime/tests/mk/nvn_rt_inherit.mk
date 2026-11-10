# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += nvn_rt_inherit
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_rt_inherit: graphics/nvn/tests/t_nvn_rt_inherit.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_rt_inherit.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rt_inherit
native-test-nvn_rt_inherit: $(BUILD)/tests/t_nvn_rt_inherit
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_rt_inherit
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_rt_inherit
TEST_TARGETS += native-test-nvn_rt_inherit
endif
