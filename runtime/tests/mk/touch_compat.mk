# native-test-touch_compat：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += touch_compat
native-test-touch_compat:
	python3 runtime/tests/support/touch_baseline_compare.py
TEST_TARGETS += native-test-touch_compat
