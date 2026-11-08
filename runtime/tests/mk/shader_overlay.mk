# native-test-shader_overlay：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 外置着色器包的直连选择规则（graphics/nvn/gfx/nvn/shader_overlay.h，纯 C）：10-30 免费签名分发，着色器包放文档目录更新不必重签
NATIVE_TEST_OWN += shader_overlay
.PHONY: native-test-shader_overlay
native-test-shader_overlay:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_shader_overlay graphics/nvn/tests/t_shader_overlay.c
	timeout 30 $(BUILD)/tests/t_shader_overlay
TEST_TARGETS += native-test-shader_overlay
