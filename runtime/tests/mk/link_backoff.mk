# native-test-link_backoff：显示链路低频档降档退避（纯状态机，不连宿主 / Metal）
NATIVE_TEST_OWN += link_backoff
$(BUILD)/tests/t_link_backoff: graphics/nvn/tests/t_link_backoff.c graphics/nvn/gfx/nvn/nvn_link_backoff.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Igraphics/nvn/gfx/nvn -o $@ graphics/nvn/tests/t_link_backoff.c
.PHONY: native-test-link_backoff
native-test-link_backoff: $(BUILD)/tests/t_link_backoff
	$(BUILD)/tests/t_link_backoff
TEST_TARGETS += native-test-link_backoff
