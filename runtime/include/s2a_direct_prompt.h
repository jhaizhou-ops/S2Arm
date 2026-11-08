// 通用 → 直连「就绪提示重启」的判定（双轨 docs/设计_双轨.md §11.1、docs/设计_直连架构.md §12.5；issue #148）：
//   平台无关的状态机放这里，iOS 壳（ios/dprompt.m）和 Mac 游戏窗口（macos/front_mac.m）只画横幅、转发按钮。
// 时机：通用模式下本款直连就绪后，等「刚存过档」（存档提交后 30 秒内没有新的提交）再提示；就绪后 15 分钟等不到存档，改普通提示（不催重启）。
//   每次运行最多提示一次：同意 → s2a_mode_request(S2A_GFX_DIRECT, "用户确认")；拒绝 / 没理会 → 本次运行不再打扰。
//   以下情况不提示：本次已是直连；下次起局已定为直连；本宿主没链直连图形层。
// 10-26 总指挥改定：直连运行中出错不切换（graphics/nvn/host_adapt.m s2a_direct_fail 只打红行），原「已切回通用」退回通知与直连失败确认弹窗一并删掉。
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
enum { S2A_DPROMPT_NONE = 0, S2A_DPROMPT_SAVED = 1, S2A_DPROMPT_PLAIN = 2 };
// 两端共用的文案（中文、短；「高性能模式」= 直连，§11.4 的叫法）。横幅 30 秒没理会按拒绝收起；回答后的确认 8 秒自动收起
#define S2A_DPROMPT_MENU_DIRECT    "切换到高性能模式（下次启动生效）"
#define S2A_DPROMPT_MENU_GENERIC   "切回通用模式（下次启动生效）"
#define S2A_DPROMPT_MENU_DIRECT_DONE  "已设好：下次打开游戏时用高性能模式。"
#define S2A_DPROMPT_MENU_GENERIC_DONE "已设好：下次打开游戏时用通用模式。"
#define S2A_DPROMPT_FAILED         "没写成，详情见日志。"
#define S2A_DPROMPT_OK             "知道了"
// 存档不能原子提交（审计 P2-13 / P2-45）的提示：标题两端相同；正文前半句同一口径，建议按平台给（Mac 能挪游戏库，iPhone 只能等存完再退）
#define S2A_DPROMPT_SAVE_ATOMIC_TITLE "存档提醒"
#define S2A_DPROMPT_SAVE_ATOMIC_MAC   "当前磁盘不能安全保存：请把游戏库挪到本机磁盘。保存过程中强退，可能留下写了一半的存档。"
#define S2A_DPROMPT_SAVE_ATOMIC_IOS   "当前存储不能安全保存：保存过程中强退，可能留下写了一半的存档。请等游戏存完再退出。"
// 「键 / 触」切换（ios/vpad.m，11-04 总指挥：脑锻炼标题页只认触屏）：游戏启用触屏后屏幕上方常驻小切换钮；首次提示条带「切到触屏」一点就切
#define S2A_DPROMPT_VPAD_TOUCH_TITLE   "这款游戏能用触屏"
#define S2A_DPROMPT_VPAD_TOUCH_BODY    "要点游戏自己的菜单，就切到触屏。屏幕上方的「键 / 触」随时可以切回按键。"
#define S2A_DPROMPT_VPAD_TOUCH_ACCEPT  "切到触屏"
#define S2A_DPROMPT_VPAD_TOUCH_DECLINE "先不用"
#define S2A_DPROMPT_VPAD_SEG_KEYS      "键"
#define S2A_DPROMPT_VPAD_SEG_TOUCH     "触"
// 游戏声明触屏配置时自动切到仅触屏（ios/touch_config.m，只改本次运行）：提示一条，指屏幕上方常驻的「键 / 触」钮
#define S2A_DPROMPT_VPAD_TOUCH_AUTO    "已切到触屏操作：这款游戏用触屏点菜单。屏幕上方「键 / 触」可切回按键。"
// 多款容器换游戏（ios/app_settings.m 设置页「换一款游戏」一栏，只在多款容器里出现；11-07 启动器线）：一个进程只跑一款、换游戏只能冷启动（不调 exit()），
//   放在玩家找「回游戏库」时会去的设置页。中英两行同屏显示；英文宏 <名>_EN 与规格的 en 逐字一致（launchers/shared/check_experience.py）
#define S2A_DPROMPT_SWITCH_GAME_TITLE    "换一款游戏"
#define S2A_DPROMPT_SWITCH_GAME_TITLE_EN "Switch games"
#define S2A_DPROMPT_SWITCH_GAME_BODY     "换一款游戏需要重新打开 S2Arm：先在游戏里存档，然后从屏幕底部上滑，把 S2Arm 划掉，再点开就回到游戏库。"
#define S2A_DPROMPT_SWITCH_GAME_BODY_EN  "To switch games, reopen S2Arm: save in the game first, then swipe up from the bottom of the screen, swipe S2Arm away, and tap it again to return to the game library."
// 游戏提交了存档（服务层 IFileSystem.Commit 钩子，FS 服务线程调）：只记时间戳，信号安全级别的轻
void s2a_dprompt_save_committed(void);
// 前端主线程每秒调一次：该弹提示时返回 S2A_DPROMPT_SAVED / S2A_DPROMPT_PLAIN（各只返回一次），否则 S2A_DPROMPT_NONE
int s2a_dprompt_poll(void);
// 横幅上玩家的回答：1 = 同意（写下次起局为直连），0 = 拒绝或超时没理会。返回 0 = 已写好（拒绝恒 0）
int s2a_dprompt_answer(int accept);
// 设置入口（iOS 四指菜单 / Mac 菜单栏）：S2A_GFX_DIRECT = 给「切换到高性能模式」，S2A_GFX_GENERIC = 给「切回通用模式」，-1 = 不给入口
int s2a_dprompt_menu(void);
// 设置入口被点：按 s2a_dprompt_menu() 的方向写下次起局的模式，返回 0 = 已写好
int s2a_dprompt_menu_pick(void);
// 存档不能原子提交（审计 P2-13 界面半边、P2-45 iPhone 半边；Mac 与 iOS 共用这一个判定）：服务层导出 S2A_SaveAtomicState（services SaveTransferExports.cs，
//   可写存档退回逐字节复制的原因位：1 没登记原语 / 2 卷不能克隆或原子交换 / 4 工作目录准备失败）。前端主线程每秒调一次；
//   游戏会话跑起来之前不问服务层（iOS 的提示定时器早于宿主线程起）；第一次读到非 0 返回原因位，只返回一次，之后恒 0。没链服务层恒 0
int s2a_save_atomic_poll(void);
#ifdef __cplusplus
}
#endif
