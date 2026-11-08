// 手机机身传感器 → NS2 原始坐标（phone_motion.m 用；纯函数，Mac 单测 t_phone_axes）。
// 机身坐标（CoreMotion）：x 竖屏右、y 竖屏上、z 出屏；加速度为重力方向（静止平放屏幕朝上 z = −1 g），角速度 rad/s。
// NS2 原始坐标（= Ryujinx 坐标）以手柄正面为基：x 右、y 前（上沿）、z 正面法线，加速度报支撑反力——真报文静止放平读 (−0.02, 0.14, 1.01) g
//   （runtime/ns2pro/tests/test_captured_reports.c report05）。掌机的正面就是屏幕，所以 raw =（屏幕右、屏幕上、出屏）：
//   横屏右（顶端朝左）：右 = −y、上 = x；横屏左（顶端朝右）：右 = y、上 = −x；出屏 = z。真旋转，加速度与角速度同一变换；输出单位 g、度/秒
#include "phone_axes.h"
void s2a_phone_axes(int landscape_right, const double acc_dev[3], const double gyr_dev[3], float acc_raw[3], float gyr_raw[3]) {
    const double deg = 57.29577951308232;
    double ax = landscape_right ? -acc_dev[1] : acc_dev[1], ay = landscape_right ? acc_dev[0] : -acc_dev[0], az = acc_dev[2];
    double rx = landscape_right ? -gyr_dev[1] : gyr_dev[1], ry = landscape_right ? gyr_dev[0] : -gyr_dev[0], rz = gyr_dev[2];
    acc_raw[0] = (float)-ax; acc_raw[1] = (float)-ay; acc_raw[2] = (float)-az;   // 重力方向 → 支撑反力
    gyr_raw[0] = (float)(rx * deg); gyr_raw[1] = (float)(ry * deg); gyr_raw[2] = (float)(rz * deg);
}
