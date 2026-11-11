// Mac Joy-Con / Pro：GameController 对 Joy-Con 的 motion 恒为 nil，六轴走 HID 标准全报告（0x30）。
// 双人：L + R 两只真机各占一玩家槽时，按键 / 摇杆也从同一份 0x30 报告读（GC 看不到或只有一只时回退）。
// 与 front_mac.m 的 s2a_pad_read_motion / sample_input 对接。
#ifndef S2A_JOYCON_IMU_H
#define S2A_JOYCON_IMU_H
#include "../runtime/include/s2a_pad.h"
#include <stdint.h>

// 游戏要六轴时打开（发 enable IMU + input mode 0x30）；关掉恢复 0x3F（若按键回退仍需要 0x30 则保持）。
void s2a_joycon_imu_set_enabled(int enabled);

// 读左右最新六轴样本。返回位掩码：bit0=左、bit1=右（含 Pro 当「右」单源）。out_l / out_r 可为 NULL。
int s2a_joycon_imu_read(s2a_pad_motion *out_l, s2a_pad_motion *out_r);

// 按键回退：打开 HID 管理并切到 0x30（shared），供双人分槽读按键 / 摇杆。可重复调用。
void s2a_joycon_pad_ensure(void);

// 当前有按键样本的独立手柄数（1=仅 L 或仅 R/Pro；2=L 与 R 都在）。
int s2a_joycon_pad_count(void);

// 读第 slot 只手柄（0=左 / 仅一只时的那只；1=右）。buttons 位序同 ns2 / apply_ble_pad 的 16 源码：
//   east south north west leftStick rightStick leftShoulder rightShoulder
//   leftTrigger rightTrigger menu options dpadLeft dpadUp dpadRight dpadDown
// sticks[4] = LX LY RX RY，范围约 ±32767。成功返回 1。
int s2a_joycon_pad_read(int slot, uint32_t *buttons, int32_t sticks[4]);

#endif
