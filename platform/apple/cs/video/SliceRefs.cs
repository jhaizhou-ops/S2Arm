using Ryujinx.Graphics.Video;
using System;

namespace Ryujinx.Graphics.Nvdec.Apple
{
    // S2Arm: 自己从 inbuf 的 slice 头读 num_ref_idx_l0_active_minus1，取代读 PictureInfo.NumRefIdxL0ActiveMinus1。
    // 真机上那个字段不是这帧 slice 的 override 值：丝之歌 4 个变体里 60fps 版的 PPS num_ref_idx_l0_default_active_minus1
    // 正好是 2，与真机读数 2 一致，而 slice 里真正写的 override 值是 3（60fps）/ 8（30fps）。观测法失效不是公式错，是读数错。
    // inbuf 是 Annex B、slice 头完整；解析所需的 SPS/PPS 参数 PictureInfo 里都有（见 H264PictureInfo），不需要码流里的 SPS。
    // 位读取一律带越界检测：任何一步读不到就把原因交回调用方，绝不返回一个错位的值。
    internal static class SliceRefs
    {
        // slice 头实际不到 40 字节；只解前面这么多，大帧不必整块去 emulation-prevention
        private const int HeaderBytes = 192;

        // 一帧的解析结果。ActiveMinus1 / HasOverride 只在 Error == null 时有效：
        // HasOverride = false 表示本帧没有任何 slice 带 num_ref_idx_active_override_flag（IDR / I 帧，或 P 帧直接用 PPS 默认值）
        public readonly struct Result
        {
            public readonly int ActiveMinus1;
            public readonly bool HasOverride;
            public readonly string Error;

            public Result(int activeMinus1, bool hasOverride, string error)
            {
                ActiveMinus1 = activeMinus1;
                HasOverride = hasOverride;
                Error = error;
            }

            public bool Ok => Error == null;
        }

        public static Result Parse(ReadOnlySpan<byte> annexB, in H264PictureInfo info)
        {
            int pos = 0, slices = 0, max = -1;
            bool hasOverride = false;
            string error = null;

            while (VideoToolboxH264Decoder.NextNal(annexB, ref pos, out ReadOnlySpan<byte> nal))
            {
                if (nal.Length == 0)
                {
                    continue;
                }

                int type = nal[0] & 0x1F;

                if (type < 1 || type > 5)
                {
                    continue;   // 只看 VCL：切片数据都在 1（非 IDR）/ 5（IDR）里
                }

                slices++;

                if (type is 2 or 3 or 4)
                {
                    error ??= $"切片用了 slice 分区（NAL 类型 {type}），本实现不解析";
                    continue;
                }

                if (!TryParse(nal, type == 5, in info, out int active, out bool over, out string why))
                {
                    error ??= why;
                    continue;
                }

                if (over)
                {
                    hasOverride = true;

                    if (active > max)
                    {
                        max = active;
                    }
                }
            }

            if (error == null && slices == 0)
            {
                error = "inbuf 里没有 slice NAL（只有参数集 / SEI 或空）";
            }

            return new Result(max < 0 ? 0 : max, hasOverride, error);
        }

        private static bool TryParse(ReadOnlySpan<byte> nal, bool idr, in H264PictureInfo info, out int activeMinus1, out bool hasOverride, out string error)
        {
            activeMinus1 = 0;
            hasOverride = false;
            error = null;

            if (info.ChromaFormatIdc >= 3)
            {
                // 4:4:4 的 separate_colour_plane_flag 决定有没有 colour_plane_id u(2)，nvdec 元数据不带这个标志，
                // 猜错就整条 slice 头错位，宁可不解析
                error = $"色度格式 {info.ChromaFormatIdc}（4:4:4）的分平面标志不在元数据里，slice 头布局不确定";
                return false;
            }

            if (nal.Length < 2)
            {
                error = "slice NAL 只有头字节";
                return false;
            }

            Span<byte> header = stackalloc byte[HeaderBytes];
            int len = 0, zeros = 0, source = Math.Min(nal.Length - 1, HeaderBytes);

            for (int i = 1; i <= source; i++)   // 跳过 NAL 头，去掉 emulation-prevention 字节
            {
                byte b = nal[i];

                if (zeros >= 2 && b == 3)
                {
                    zeros = 0;
                    continue;
                }

                header[len++] = b;
                zeros = b == 0 ? zeros + 1 : 0;
            }

            Bits bits = new(header[..len]);

            if (!bits.Ue(out int _))
            {
                return Fail("first_mb_in_slice 读不到（slice 头被截断）", out error);
            }

            if (!bits.Ue(out int sliceTypeRaw))
            {
                return Fail("slice_type 读不到", out error);
            }

            if (sliceTypeRaw > 9)
            {
                return Fail($"slice_type={sliceTypeRaw} 超出 0..9", out error);
            }

            int sliceType = sliceTypeRaw % 5;   // 0=P 1=B 2=I 3=SP 4=SI

            if (!bits.Ue(out int _))
            {
                return Fail("pic_parameter_set_id 读不到", out error);
            }

            if (!bits.U((int)info.Log2MaxFrameNumMinus4 + 4, out int _))
            {
                return Fail("frame_num 读不到", out error);
            }

            bool fieldPic = false;

            if (!info.FrameMbsOnlyFlag)
            {
                if (!bits.U(1, out int f))
                {
                    return Fail("field_pic_flag 读不到", out error);
                }

                fieldPic = f != 0;

                if (fieldPic && !bits.U(1, out int _))
                {
                    return Fail("bottom_field_flag 读不到", out error);
                }
            }

            if (idr && !bits.Ue(out int _))
            {
                return Fail("idr_pic_id 读不到", out error);
            }

            int pocType = (int)info.PicOrderCntType;

            if (pocType == 0)
            {
                if (!bits.U((int)info.Log2MaxPicOrderCntLsbMinus4 + 4, out int _))
                {
                    return Fail("pic_order_cnt_lsb 读不到", out error);
                }

                if (info.PicOrderPresentFlag && !fieldPic && !bits.Se(out int _))
                {
                    return Fail("delta_pic_order_cnt_bottom 读不到", out error);
                }
            }
            else if (pocType == 1 && !info.DeltaPicOrderAlwaysZeroFlag)
            {
                if (!bits.Se(out int _))
                {
                    return Fail("delta_pic_order_cnt[0] 读不到", out error);
                }

                if (info.PicOrderPresentFlag && !fieldPic && !bits.Se(out int _))
                {
                    return Fail("delta_pic_order_cnt[1] 读不到", out error);
                }
            }

            if (info.RedundantPicCntPresentFlag && !bits.Ue(out int _))
            {
                return Fail("redundant_pic_cnt 读不到", out error);
            }

            if (sliceType == 1 && !bits.U(1, out int _))   // B
            {
                return Fail("direct_spatial_mv_pred_flag 读不到", out error);
            }

            if (sliceType is 0 or 1 or 3)   // P / B / SP 才有 num_ref_idx_active_override_flag
            {
                if (!bits.U(1, out int overrideFlag))
                {
                    return Fail("num_ref_idx_active_override_flag 读不到", out error);
                }

                if (overrideFlag != 0)
                {
                    if (!bits.Ue(out int l0))
                    {
                        return Fail("num_ref_idx_l0_active_minus1 读不到", out error);
                    }

                    if (l0 > 31)
                    {
                        return Fail($"num_ref_idx_l0_active_minus1={l0} 超出 0..31", out error);
                    }

                    activeMinus1 = l0;
                    hasOverride = true;

                    if (sliceType == 1 && !bits.Ue(out int _))
                    {
                        return Fail("num_ref_idx_l1_active_minus1 读不到", out error);
                    }
                }
            }

            return true;
        }

        private static bool Fail(string reason, out string error)
        {
            error = reason;
            return false;
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

            public bool U(int count, out int value)
            {
                value = 0;

                if (count < 0 || count > 32 || _bit + count > _data.Length * 8)
                {
                    _bit += count;
                    return false;
                }

                for (int i = 0; i < count; i++)
                {
                    int index = _bit >> 3;
                    int offset = 7 - (_bit & 7);
                    value = (value << 1) | ((_data[index] >> offset) & 1);
                    _bit++;
                }

                return true;
            }

            public bool Ue(out int value)
            {
                value = 0;
                int zeros = 0;

                while (true)
                {
                    if (!U(1, out int bit))
                    {
                        return false;
                    }

                    if (bit != 0)
                    {
                        break;
                    }

                    if (++zeros > 31)
                    {
                        return false;
                    }
                }

                if (zeros == 0)
                {
                    return true;
                }

                if (!U(zeros, out int suffix))
                {
                    return false;
                }

                long v = ((1L << zeros) - 1) + suffix;

                if (v > int.MaxValue)
                {
                    return false;
                }

                value = (int)v;

                return true;
            }

            public bool Se(out int value)
            {
                if (!Ue(out int v))
                {
                    value = 0;
                    return false;
                }

                value = (v & 1) != 0 ? (v + 1) / 2 : -(v / 2);

                return true;
            }
        }
    }
}
