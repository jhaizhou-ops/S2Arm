#ifndef S2A_PHONE_AXES_H
#define S2A_PHONE_AXES_H
// 手机机身传感器 → NS2 原始坐标（见 runtime/src/phone_axes.c）
void s2a_phone_axes(int landscape_right, const double acc_dev[3], const double gyr_dev[3], float acc_raw[3], float gyr_raw[3]);
#endif
