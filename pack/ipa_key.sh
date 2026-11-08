#!/bin/bash
# iOS 包键包含实际地址需求表；不再按游戏名或手动布局开关选宿主。
# 进包输入（审计 P1-54）：包键要覆盖包里的每一样东西，否则同一提交、同一产物根换了它，ipa.sh 报「现行已是包」、装上旧包。
#   res = pack/resource_input_key.py（romfs / aoc / exefs/main 首尾 64 KiB 抽样，与抽取 / 直连同一份）；各阶段戳覆盖改写 / 能力 / 着色器 / 直连库 / 索引；
#   in = pack/pkg_inputs_key.py：资源包源清单（ipa_pkg_srcs，pack.py 打的就是这一份）里不归上面两类的每一项（字体与时区、Mii 0802、屏蔽词 0823 等 systemdata、
#   main.npdm、control.nacp、aoc.tsv、romfs 索引）按全内容，加上包外进 App 的文件（ipa_app_files：随包表、图标、宽屏自动表）。
#   11-03 审计 #1417：原先只有 .stage_sysdata（时区来源一句），换字体 / 0802 / 0823 包键不变。算不出就失败（不拿缺项的键当命中）。

IPA_KEY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # source 时记下本目录：函数经 eval / 命令替换调用时 BASH_SOURCE 不可靠

# 三个函数的实现都在 pack/pkg_srcs.py（唯一实现，Windows 的 Python 编排直接 import；11-04 #1100）：这里只是 bash 调用口
# 资源包源清单：一行「包内路径=源路径」。pack.py 打的、包键算的都是这一份——新加进包的源加在 pkg_srcs.py srcs()，自动进键
ipa_pkg_srcs() { "${S2A_PY:-python3}" "$IPA_KEY_DIR/pkg_srcs.py" srcs "$1"; }
# 包外进 App 的文件：一行「名=路径」（ipa_app_files <款> <产物根>）：宽屏表、随包表（宿主源码「随包表：」声明）、图标
ipa_app_files() { "${S2A_PY:-python3}" "$IPA_KEY_DIR/pkg_srcs.py" app-files "$1" "$2"; }
# 包键串：ipa_pkg_key <前缀> <产物根> [<款>]
ipa_pkg_key() { "${S2A_PY:-python3}" "$IPA_KEY_DIR/pkg_srcs.py" key "$@"; }
