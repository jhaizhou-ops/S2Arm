// Switch 2（NVN2）着色器控制段：魔数 0x98761234、+4 版本 0xc9（Switch 1 的 NVN 是版本 1、≥ 0x848 字节）。字段与键规则见 translator/ns2_shaders.py
using System;

namespace S2A.Dsh
{
    static class Nvn2
    {
        public static bool Is(byte[] ctl) => ctl != null && ctl.Length >= 0x48 && BitConverter.ToUInt32(ctl, 0) == 0x98761234u && BitConverter.ToUInt32(ctl, 4) == 0xc9u;

        /// <summary>域着色器的曲面模式，打成 Maxwell TessMode 的形状（dmsh_xlate tess_mode：位 0–1 域、4–5 分区、8 顺时针）。
        /// NVN2 控制段 +0x58 / +0x5c / +0x60 是 GL 枚举：域 GL_ISOLINES 0x8e7a / GL_TRIANGLES 4 / GL_QUADS 7，分区 GL_EQUAL 0x202 / GL_FRACTIONAL_ODD 0x8e7b / GL_FRACTIONAL_EVEN 0x8e7c，
        /// 绕向 GL_CW 0x900 / GL_CCW 0x901（0 = 逆时针）；认不出的给缺省 1（三角、等距、逆时针）</summary>
        public static uint TessMode(byte[] ctl)
        {
            if (ctl.Length < 0x64) return 1;
            return TessCtl.Gl(BitConverter.ToUInt32(ctl, 0x58), BitConverter.ToUInt32(ctl, 0x5c), BitConverter.ToUInt32(ctl, 0x60));
        }
    }

    /// <summary>域着色器控制段里的曲面模式（GL 枚举）→ dmsh_xlate tess_mode（Maxwell TessMode 的形状：位 0–1 域、4–5 分区、8 顺时针）。</summary>
    static class TessCtl
    {
        /// <summary>域 GL_ISOLINES 0x8e7a / GL_TRIANGLES 4 / GL_QUADS 7，分区 GL_EQUAL 0x202 / GL_FRACTIONAL_ODD 0x8e7b / GL_FRACTIONAL_EVEN 0x8e7c，绕向 GL_CW 0x900 / GL_CCW 0x901（0 = 逆时针）；
        /// 认不出的给缺省 1（三角、等距、逆时针）</summary>
        public static uint Gl(uint dom, uint sp, uint wind)
        {
            uint d = dom switch { 0x8e7a => 0u, 4 => 1u, 7 => 2u, _ => 99u };
            uint s = sp switch { 0x202 => 0u, 0x8e7b => 1u, 0x8e7c => 2u, _ => 99u };
            uint w = wind switch { 0x901 or 0 => 0u, 0x900 => 1u, _ => 99u };   // Pokopia 的 527 支域、50 支外壳全是 0：按 GL 缺省逆时针读（未在真机核）
            return d == 99 || s == 99 || w == 99 ? 1u : d | s << 4 | w << 8;
        }

        /// <summary>Switch 1（NVN）控制段：+0x738 域、+0x73c 分区、+0x744 绕向，同是 GL 枚举（与 NVN2 的 +0x58 / +0x5c / +0x60 同一组）。+0x744 不是打包好的 TessMode：
        /// 11-05 巫师3 13 支域着色器 +0x738 / +0x73c / +0x744 = 7 / 0x8e7c / 0x900（GL_QUADS / GL_FRACTIONAL_EVEN / GL_CW），通用模式真机局 Ryujinx 收到的寄存器是 0x322（四边形、分区 2、顺时针，
        /// 位 9 是硬件的「相连」位）；把 0x900 当寄存器读成了等值线，地形画成一道道线（白条纹）。控制段不足 0x748 字节给缺省 1</summary>
        public static uint Nvn1(byte[] ctl) => ctl.Length < 0x748 ? 1u : Gl(BitConverter.ToUInt32(ctl, 0x738), BitConverter.ToUInt32(ctl, 0x73c), BitConverter.ToUInt32(ctl, 0x744));
    }
}
