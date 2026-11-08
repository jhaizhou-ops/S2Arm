# native-test-nvn_blend：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_blend
# 高级混合状态位布局（#270 N12 BlendState 组）：blend_st 长在游戏对象（8 字节）里、又被 PSO 键按 8 份收进去，
# 只许在同一个 uint64_t 内加位。本测盯 sizeof、adv_* 与既有字段是否别名、adv_mode/adv_overlap 是否装得下规范取值。
.PHONY: native-test-nvn_blend
native-test-nvn_blend:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -o $(BUILD)/tests/t_nvn_blend graphics/nvn/tests/t_nvn_blend.c
	timeout 30 $(BUILD)/tests/t_nvn_blend
TEST_TARGETS += native-test-nvn_blend
