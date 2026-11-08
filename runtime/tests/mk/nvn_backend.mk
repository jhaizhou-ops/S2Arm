# native-test-nvn_backend：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_backend
# 回放后端契约 graphics/nvn/gfx/nvn/nvn_backend.h（W1 D0，docs/设计_回放核心共用.md）编译自洽：纯 C，不链任何后端，不需要 GPU。
#   1. C11 -Werror 编一次并运行（签名表 / 句柄互异 / 能力位全是编译期断言）；2. 当 Objective-C 再语法检查一次（Metal 后端在 .m 里 include 它）；
#   3. 去掉 // 与 /* */ 注释后不许出现 Metal / Vulkan / QuartzCore 的类型名或头文件（nvn_backend.h 与平台节拍接口 nvn_vsync.h 都扫）；
#   4. 两个头文件里声明的函数个数 = 单测签名表条数（漏登记即红）；5. 两条「必须编译失败」探针：nvn_gpu_rc 赋给 int、cast 成 int（错误域不许直接串用）。
NVN_BACKEND_H := graphics/nvn/gfx/nvn/nvn_backend.h
NVN_VSYNC_H := graphics/nvn/gfx/nvn/nvn_vsync.h
NVN_BACKEND_CODE = perl -0pe 's\#/\*.*?\*/\#\#gs; s\#//[^\n]*\#\#g' $(NVN_BACKEND_H) $(NVN_VSYNC_H)
.PHONY: native-test-nvn_backend
native-test-nvn_backend:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -o $(BUILD)/tests/t_nvn_backend graphics/nvn/tests/t_nvn_backend.c
	@if echo 'int x;' | $(CC) -x objective-c -fsyntax-only - >/dev/null 2>&1; then \
	  $(CC) -fsyntax-only -x objective-c -Wall -Wextra -Werror -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include graphics/nvn/tests/t_nvn_backend.c; \
	elif [ "$$(uname -s)" = Darwin ]; then echo "【红】 ObjC 语法检查：$(CC) 无 Objective-C 前端——macOS 上这一步必须跑（Metal 后端是 ObjC，换了编译器不许静默少跑）"; exit 1; \
	else echo "ObjC 语法检查跳过：$(CC) 无 Objective-C 前端（GCC 16 已移除 cc1obj；非 macOS 宿主）；macOS 门禁覆盖这一步"; fi
	@bad=$$($(NVN_BACKEND_CODE) | grep -nE '\b(MTL[A-Za-z0-9_]*|CAMetal[A-Za-z]*|id<|Vk[A-Z][A-Za-z0-9]*|VK_[A-Z0-9_]+|vk[A-Z][A-Za-z]*|ANativeWindow|NSObject)\b|#(include|import) *<(Metal|QuartzCore|vulkan|android)/' || true); \
	  if [ -n "$$bad" ]; then echo "【红】 nvn_backend.h 出现图形 API 类型（注释外）：$$bad"; exit 1; fi; \
	  nh=$$($(NVN_BACKEND_CODE) | grep -cE '^[a-z][a-z0-9_ ]*[ *]nvn_(gpu|vsync)_[a-z0-9_]+\('); \
	  nt=$$(grep -cE '^SIG\(nvn_(gpu|vsync)_' graphics/nvn/tests/t_nvn_backend.c); \
	  if [ "$$nh" != "$$nt" ]; then echo "【红】 nvn_backend.h + nvn_vsync.h 声明 $$nh 个函数，签名表登记 $$nt 个：同批补齐 t_nvn_backend.c"; exit 1; fi; \
	  echo "契约扫描：注释外 API 类型 0 处；声明 $$nh 个函数 = 签名表 $$nt 项"
	@printf '#include "nvn_backend.h"\nint f(void) { int r = nvn_gpu_fence_wait(1, 0, 0); return r; }\n' > $(BUILD)/tests/t_nvn_backend_probe1.c; \
	  printf '#include "nvn_backend.h"\nint f(nvn_gpu_rc r) { return (int)r; }\n' > $(BUILD)/tests/t_nvn_backend_probe2.c; \
	  for p in 1 2; do if $(CC) -std=c11 -fsyntax-only -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include $(BUILD)/tests/t_nvn_backend_probe$$p.c 2>/dev/null; then \
	    echo "【红】 探针 $$p 编译通过了：nvn_gpu_rc 能被当成 int（错误域可被直接 cast）"; exit 1; fi; done; \
	  echo "错误域探针：rc 赋给 int / cast 成 int 两条都编译失败（期望如此）"
	timeout 30 $(BUILD)/tests/t_nvn_backend
	@echo '✓ t_nvn_backend：契约头 C11 编译运行、ObjC 语法、注释外无图形 API 类型、声明数 = 签名表、错误域两条探针编译失败'
TEST_TARGETS += native-test-nvn_backend
