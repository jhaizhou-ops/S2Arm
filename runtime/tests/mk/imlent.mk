# native-test-imlent：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 合成 Mach-O 之外，再用本程序自身验内存里的真签名段：链接器自签（没有权限槽 → -1）、codesign 带 get-task-allow（查它 → 1、查 IML → 0）。
#   不签带 IML 的那份去跑：macOS AMFI 不让 ad-hoc 签名带受限键的程序启动（实测 Killed: 9）
NATIVE_TEST_OWN += imlent
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-imlent
native-test-imlent:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_imlent runtime/tests/t_imlent.c runtime/src/imlent.c
	$(BUILD)/tests/t_imlent com.apple.developer.kernel.increased-memory-limit -1 com.apple.security.get-task-allow -1
	@d=$$(mktemp -d) || exit 1; trap 'rm -rf "$$d"' EXIT; \
	  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n' > $$d/e.plist; \
	  cp $(BUILD)/tests/t_imlent $$d/t && /usr/bin/codesign -f -s - --entitlements $$d/e.plist $$d/t 2> /dev/null && \
	  $$d/t com.apple.security.get-task-allow 1 com.apple.developer.kernel.increased-memory-limit 0
TEST_TARGETS += native-test-imlent
endif
