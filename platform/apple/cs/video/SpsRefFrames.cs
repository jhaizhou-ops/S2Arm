using System;

namespace Ryujinx.Graphics.Nvdec.Apple
{
    // S2Arm: 从码流里的 SPS（Annex B）取 max_num_ref_frames。nvdec 元数据不带这个字段（上游 Types/H264/PictureInfo.cs 恒填 0），
    // 重建 SPS 时它决定 VideoToolbox 的 DPB 上限；上限比真实值大时，frame_num 回绕后参考列表会取到旧帧，P 帧整段解错而且不报错
    // （丝之歌过场：真实值 4，写死 16 时 260 帧里 118 帧 PSNR 20-24，用真实值 4 时 260 帧全部与 FFmpeg 逐像素一致）
    internal static class SpsRefFrames
    {
        public static int TryRead(ReadOnlySpan<byte> annexB)
        {
            int pos = 0;

            while (VideoToolboxH264Decoder.NextNal(annexB, ref pos, out ReadOnlySpan<byte> nal))
            {
                if (nal.Length > 1 && (nal[0] & 0x1F) == 7)
                {
                    int value = Parse(nal);

                    if (value > 0)
                    {
                        return value;
                    }
                }
            }

            return 0;
        }

        private static int Parse(ReadOnlySpan<byte> nal)
        {
            Span<byte> rbsp = nal.Length <= 0x400 ? stackalloc byte[nal.Length] : new byte[nal.Length];
            int len = 0, zeros = 0;

            for (int i = 1; i < nal.Length; i++)   // 跳过 NAL 头
            {
                byte b = nal[i];

                if (zeros >= 2 && b == 3)
                {
                    zeros = 0;
                    continue;
                }

                rbsp[len++] = b;
                zeros = b == 0 ? zeros + 1 : 0;
            }

            Bits bits = new(rbsp[..len]);

            int profile = bits.U(8);
            bits.U(8);   // constraint flags + reserved
            bits.U(8);   // level_idc
            bits.Ue();   // seq_parameter_set_id

            switch (profile)
            {
                case 100 or 110 or 122 or 244 or 44 or 83 or 86 or 118 or 128 or 138 or 139 or 134 or 135:
                    int chromaFormat = bits.Ue();

                    if (chromaFormat == 3)
                    {
                        bits.U(1);   // separate_colour_plane_flag
                    }

                    bits.Ue();   // bit_depth_luma_minus8
                    bits.Ue();   // bit_depth_chroma_minus8
                    bits.U(1);   // qpprime_y_zero_transform_bypass_flag

                    if (bits.U(1) != 0)   // seq_scaling_matrix_present_flag
                    {
                        return 0;   // scaling list 少见，遇到就退回兜底值
                    }

                    break;
            }

            bits.Ue();   // log2_max_frame_num_minus4

            int pocType = bits.Ue();

            if (pocType == 0)
            {
                bits.Ue();   // log2_max_pic_order_cnt_lsb_minus4
            }
            else if (pocType == 1)
            {
                bits.U(1);    // delta_pic_order_always_zero_flag
                bits.Se();    // offset_for_non_ref_pic
                bits.Se();    // offset_for_top_to_bottom_field
                int cycle = bits.Ue();

                for (int i = 0; i < cycle; i++)
                {
                    bits.Se();
                }
            }

            return bits.Ue();   // max_num_ref_frames
        }

        private ref struct Bits
        {
            private readonly ReadOnlySpan<byte> _data;
            private int _bit;

            public Bits(ReadOnlySpan<byte> data)
            {
                _data = data;
                _bit = 0;
            }

            public int U(int count)
            {
                int value = 0;

                for (int i = 0; i < count; i++)
                {
                    int index = _bit >> 3;
                    int offset = 7 - (_bit & 7);
                    int bit = index < _data.Length ? (_data[index] >> offset) & 1 : 0;

                    value = (value << 1) | bit;
                    _bit++;
                }

                return value;
            }

            public int Ue()
            {
                int zeros = 0;

                while (U(1) == 0 && zeros < 31)
                {
                    zeros++;
                }

                return zeros == 0 ? 0 : (1 << zeros) - 1 + U(zeros);
            }

            public int Se()
            {
                int value = Ue();

                return (value & 1) != 0 ? (value + 1) / 2 : -(value / 2);
            }
        }
    }
}
