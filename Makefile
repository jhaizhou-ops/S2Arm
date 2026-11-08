# S2Arm 顶层构建入口。各目录在自己的 <目录>/build.mk 里往下列变量追加，顶层不写任何目录的细节：
#   HOST_SRCS   进 Mac 宿主 / iOS App 的源文件        HOST_LIBS  链接参数
#   TEST_TARGETS  `make test` 要跑的目标（每个目标自己编、自己跑、失败即非 0）
# 常用：make host（Mac 宿主 build/s2arm-host）、make test（全部单测）
# 统一工具链（tools/toolchain.env）：配方里的 clang / xcrun 都跟它走；$(shell xcrun …) 处显式带 DEVELOPER_DIR=$(DEVELOPER_DIR)（make 3.81 的 $(shell) 不继承 export）
# Xcode 按用户机器（10-25，不写死版本）：指定 S2A_DEVELOPER_DIR > 环境里的 DEVELOPER_DIR（tools/toolchain.sh 解析后导出）> tools/toolchain.sh 当场解析（缺省装着的最新 Xcode，11-07 Duo 定因）> xcode-select；
#   先在 include 之前记下环境值——toolchain.env 里那行不当缺省（make 里文件内赋值会盖过环境变量）。赋值行不带行尾注释：注释前的空格会进值
_S2A_ENV_DD := $(DEVELOPER_DIR)
include tools/toolchain.env
# 配方失败即删掉目标（10-24 着色器线：gfx 门禁「首跑红、重跑绿」是真失败被增量构建盖住——失败的配方先写出了目标，重跑时 make 判它已最新就跳过）。
#   */build.mk 都 include 进本文件，这一行覆盖它们；graphics/metal、graphics/nvn 下单独的 Makefile 各自另加
.DELETE_ON_ERROR:
# 前端 / 玩家机器用 S2A_DEVELOPER_DIR 指自己的 Xcode（同 tools/toolchain.sh，#49）：不设 = toolchain.env 那套（10-23 Air 全新机器实测：Makefile 不认，没装 27.1 的机器着色器键算不出）
DEVELOPER_DIR := $(or $(S2A_DEVELOPER_DIR),$(_S2A_ENV_DD),$(shell S2A_TC_QUIET=1 bash -c '. tools/toolchain.sh > /dev/null && printf %s "$$DEVELOPER_DIR"' 2>/dev/null),$(shell xcode-select -p 2>/dev/null))
export DEVELOPER_DIR MACOSX_DEPLOYMENT_TARGET MSBUILDDISABLENODEREUSE   # iOS 下限不导出（两个都导出时不带 -target 的宿主编译会当成 iOS，见 tools/toolchain.sh）
BUILD   ?= build
CC      ?= clang
CFLAGS  ?= -O1 -g -Wall -Wextra -Wno-unused-parameter
HOST_SRCS :=
HOST_LIBS :=
TEST_TARGETS :=
.DEFAULT_GOAL := host
-include $(sort $(wildcard */build.mk))

# 宿主依赖在全部 build.mk 读完之后才写：规则的依赖在读入那一刻展开，写在 runtime/build.mk 里时按字母序排在后面的 services/、tests/ 追加的源文件
# （自动玩家等）不在依赖里，改了 make host 不重编（10-20 服务接入线实测作废两局暗黑2、原生层一局八方2）。
# 构建配置戳：S2A_CS / CC / CFLAGS 变了也要重编（先不带 C# 编、再带 C# 编之类）；内容不变就不改写，不触发重编
HOST_CFG     := S2A_CS=$(S2A_CS) S2A_MAC_FRONTEND=$(S2A_MAC_FRONTEND) CC=$(CC) CFLAGS=$(CFLAGS)
HOST_CFG_STAMP := $(BUILD)/.host_cfg
$(shell mkdir -p $(BUILD); [ "$$(cat $(HOST_CFG_STAMP) 2>/dev/null)" = '$(HOST_CFG)' ] || printf '%s' '$(HOST_CFG)' > $(HOST_CFG_STAMP))
$(BUILD)/s2arm-host: $(HOST_SRCS) $(wildcard $(addsuffix *.h,$(sort $(dir $(HOST_SRCS)))) runtime/include/*.h) $(HOST_CFG_STAMP) Makefile $(wildcard */build.mk)

.PHONY: host test clean
host: $(BUILD)/s2arm-host
test: $(TEST_TARGETS)
	@echo "全部单测通过（$(words $(TEST_TARGETS)) 组）"
clean:
	rm -rf $(BUILD)
