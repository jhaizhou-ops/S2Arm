using System;
using System.Buffers.Binary;

namespace Ryujinx.HLE.HOS.Services.Hid.Types
{
    // S2Arm 11-05：我方六轴的量程与传感器 IC 信息（IHidServer 88 GetSixAxisSensorIcInformation 的 SixAxisSensorIcInformation），只此一处定义：
    //   喂数路径（S2A.Services ControllerFeedback）按这里的量程饱和，88 按这里的数填，两边不会说两套话。
    //   单位与喂数一致：加速度 g、角速度 度/秒（交给游戏前 ControllerFeedback 再乘 0.0027 换成转/秒，那是共享内存的单位，不是 IC 信息的单位）。
    //   结构布局（0xC8 字节、50 个 float）：公开逆向资料中的结构布局，已与真机抓取核对（11-05 测试机2 Switch Sports：游戏给 88 的输出缓冲 200 字节 = 0xC8，存校准 86 的输入 1860 字节 = 0x744）——
    //     0x00 角速度量程 / 0x04 角速度零点容差 6 个（三轴各 下限、上限）/ 0x1C 角速度灵敏度下限 3×3 / 0x40 角速度灵敏度上限 3×3 /
    //     0x64 加速度量程 / 0x68 加速度零点容差 6 个 / 0x80 加速度灵敏度下限 3×3 / 0xA4 加速度灵敏度上限 3×3
    public static class SixAxisSensorIc
    {
        public const int Size = 0xC8;
        // 量程：取任天堂掌机 / Joy-Con 六轴 IC 的标称量程（±2000 度/秒、±8 g）。手机传感器超出的部分按真机同样饱和
        public const float AngularRateRangeDps = 2000f;
        public const float AccelerationRangeG = 8f;
        // 零点容差、灵敏度上下限（对角）与轴间串扰容差：我方虚拟 IC 本身是纯换算（零点 0、灵敏度 1），这几项描述的是「游戏校准时允许的偏差」；
        //   填 0 / 1 会让任何手机噪声都落在容差外，所以取公开资料中的真机 IC 标称值（零点 ±0.0612、灵敏度 0.95–1.05、串扰 ±0.003），单位同上
        public const float ZeroPointTolerance = 0.0612f;
        public const float SensitivityMin = 0.95f, SensitivityMax = 1.05f, CrossAxisTolerance = 0.003f;

        public static float ClampAngularRate(float dps) => Math.Clamp(dps, -AngularRateRangeDps, AngularRateRangeDps);
        public static float ClampAcceleration(float g) => Math.Clamp(g, -AccelerationRangeG, AccelerationRangeG);

        // 按上面的布局写 Size 字节（小端 float）
        public static void Write(Span<byte> dst)
        {
            if (dst.Length < Size) throw new ArgumentException("SixAxisSensorIcInformation needs 0xC8 bytes", nameof(dst));
            Span<float> f = stackalloc float[Size / 4];
            int o = 0;
            foreach (float range in new[] { AngularRateRangeDps, AccelerationRangeG })
            {
                f[o++] = range;
                for (int a = 0; a < 3; a++) { f[o++] = -ZeroPointTolerance; f[o++] = ZeroPointTolerance; }
                for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) f[o++] = r == c ? SensitivityMin : -CrossAxisTolerance;
                for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) f[o++] = r == c ? SensitivityMax : CrossAxisTolerance;
            }
            for (int i = 0; i < f.Length; i++) BinaryPrimitives.WriteSingleLittleEndian(dst.Slice(i * 4, 4), f[i]);
        }
    }
}
