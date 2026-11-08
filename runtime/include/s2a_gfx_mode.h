// 图形模式开关（双轨，docs/设计_直连架构.md §12.1）：通用 = 游戏随包 NVN 驱动 + Ryujinx 显卡模拟 + graphics/metal；
// 直连 = NVN→Metal（graphics/nvn）。只在起局时判定一次（装载器重定位之前），同一次运行内不切换；两套图形永不并存。
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { S2A_GFX_GENERIC = 0, S2A_GFX_DIRECT = 1 };
// 本次运行的图形模式。判定（先到先得）：环境变量 S2A_GFX=direct|generic → Documents/wire/<程序号>/mode（内容 direct / generic）
//   → 缺省：包里带本链直连库 → 直连（10-25），否则通用。判定时 host.log 打一行「图形模式：…（依据 …）」。
//   10-26 起运行中出错不切换、旧的 wire/<程序号>/fail 起局时删掉不作依据；兼容（通用）路线按款在出包时定（docs/设计_双轨.md §11.5）
int s2a_gfx_mode(void);
void s2a_gfx_mode_data_ready(void);   // 资源包闸门放行后、装载前调（iOS）；之前 s2a_gfx_mode 只给临时的「通用」、不落定
int s2a_gfx_mode_settled(void);       // 模式能落定了没有（提示类按它等，别拿临时值判）
// 本次判定的依据（同 host.log「图形模式：…（依据 …）」，字符串常量，不用释放）
const char *s2a_gfx_mode_why(void);
const char *s2a_gfx_mode_brief(void);   // 判定依据短写（开发浮层）
// 写下次起局的选择（Documents/wire/<程序号>/mode），本次运行不切换；reason 记进 host.log。返回 0 成功
int s2a_mode_request(int mode, const char *reason);
// 下次起局按文件会选的模式（不看 S2A_GFX）：mode 文件在按它，否则包里有本链直连库 → 直连、没有 → 通用。提示重启界面用
int s2a_mode_next(void);
// 包里带着本宿主翻译链版本的直连库（<游戏数据>/shaders/direct/b-<链版本>/）且链进了直连图形层：没有环境变量、mode 文件时据此直连起手（10-25）
int s2a_direct_packaged(void);
// 本款直连是否就绪（给界面提示重启用）：资源包里有直连着色器库键清单（S2A_GAME_DATA/shaders/direct/keys.tsv），
//   且通用模式下见过的键（Documents/wire/<程序号>/seen_shaders.tsv）全在清单里。1 = 就绪
//   S2A_FAKE_DIRECT_READY=1：直接回 1（界面开发 / 测试用）
int s2a_direct_ready(void);
// 直连模式已上屏的帧数（vi GetLatestFrameNumber 读）；通用模式恒 0
unsigned long long s2a_direct_frame_count(void);
// App 进 / 出后台（ios/app.m）：直连模式下暂停 / 恢复图形提交；通用模式空操作
void s2a_direct_suspend(int on);
// 重启的新 provider 已就绪、guest 尚未启动：只关直连提交 gate 并确认没有在途调用，不排空或提交 Metal 命令。
int s2a_direct_guest_start_hold(void);
#ifdef __cplusplus
}
#endif
