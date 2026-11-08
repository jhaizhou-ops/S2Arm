# native-test-prov_expiry：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 签名到期提示的描述文件解析（ios/prov_expiry.m，只用 Foundation，Mac 上跑）：10-30 免费签名 7 天过期，剩不到 48 小时提示
#   本机有 Xcode 描述文件时多验一份真文件：期望到期日由系统 security cms -D + plutil 读，不经被测解析
NATIVE_TEST_OWN += prov_expiry
.PHONY: native-test-prov_expiry
native-test-prov_expiry:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_prov_expiry runtime/tests/t_prov_expiry.m ios/prov_expiry.m
	@f=$$(ls "$$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision 2> /dev/null | head -1); \
	 e=$$( [ -n "$$f" ] && security cms -D -i "$$f" 2> /dev/null | plutil -extract ExpirationDate raw - 2> /dev/null); \
	 if [ -n "$$e" ]; then timeout 30 $(BUILD)/tests/t_prov_expiry "$$f" "$$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$$e" +%s)"; else timeout 30 $(BUILD)/tests/t_prov_expiry; fi
TEST_TARGETS += native-test-prov_expiry
