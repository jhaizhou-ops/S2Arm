# native-test-ios_root_ready：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += ios_root_ready
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-ios_root_ready
native-test-ios_root_ready:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -x objective-c -fobjc-arc -fblocks -Iios runtime/tests/t_ios_root_ready.c ios/root_ready.m -framework Foundation -o $(BUILD)/tests/t_ios_root_ready
	@for mode in ready-first timeout render-first many-waiters main-wait notify; do $(BUILD)/tests/t_ios_root_ready $$mode || exit 1; done
	$(CC) $(CFLAGS) -fblocks -Iios runtime/tests/t_ios_root_ready.c runtime/tests/support/ios_root_ready_no_wait.c -framework CoreFoundation -o $(BUILD)/tests/t_ios_root_ready_no_wait
	@for mode in render-first many-waiters; do \
	  log=$(BUILD)/tests/ios_root_ready_no_wait-$$mode.log; \
	  if $(BUILD)/tests/t_ios_root_ready_no_wait $$mode > $$log 2>&1; then cat $$log; echo "FAIL: no-wait counterexample passed $$mode"; exit 1; fi; \
	  grep -q '^FAIL .*waiters\[i\].result == 0 && waiters\[i\].saw_ready' $$log || { cat $$log; exit 1; }; \
	  echo "PASS no-wait counterexample rejected $$mode"; \
	done
	@for mode in main-wait notify; do \
	  log=$(BUILD)/tests/ios_root_ready_no_wait-$$mode.log; \
	  if $(BUILD)/tests/t_ios_root_ready_no_wait $$mode > $$log 2>&1; then cat $$log; echo "FAIL: old no-wait UI path passed $$mode"; exit 1; fi; \
	  grep -q -e '^FAIL .*atomic_load(&g_signalled) == 1' -e '^FAIL .*ran == 0' $$log || { cat $$log; exit 1; }; \
	  echo "PASS old UI path rejected $$mode"; \
	done
	@echo "✓ t_ios_root_ready"
TEST_TARGETS += native-test-ios_root_ready
endif
