using System;
using System.Buffers.Binary;

namespace S2A.Services
{
    // Switch 2 的 npdm：ACID 段开头的签名区比 Switch 1 多 0x100 字节（ACID 魔数在段内 +0x300，Switch 1 是 +0x200），
    //   段内 FAC / SAC / KC 偏移跟着大 0x100，「签名数据长」字段是段长 − 0x180（Switch 1 是段长 − 0x100）；META 与 ACI0 布局没变
    //   （11-02 出包线 Pokopia 0400A3A01EE4C000：LibHac MetaLoader 按 +0x200 找魔数，回 ResultLoaderInvalidMeta 2009-0004，服务会话起不来）。
    // LibHac 是钉版 NuGet 包，改不了解析器：交给它之前把 ACID 换成 Switch 1 的布局——去掉签名区多出的前 0x100 字节、段内偏移与长度字段减 0x100，
    //   META 里 ACID 长度减 0x100、排在 ACID 之后的 ACI0 偏移减 0x100。签名不校验（宿主不验证 ACID 签名），其余字段原样。
    static class NpdmCompat
    {
        const int MetaAciOffset = 0x70, MetaAcidOffset = 0x78, Extra = 0x100;

        public static byte[] Normalize(byte[] npdm)
        {
            if (npdm.Length < 0x80) return npdm;
            int aciOff = (int)BinaryPrimitives.ReadUInt32LittleEndian(npdm.AsSpan(MetaAciOffset));
            int acidOff = (int)BinaryPrimitives.ReadUInt32LittleEndian(npdm.AsSpan(MetaAcidOffset));
            int acidSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(npdm.AsSpan(MetaAcidOffset + 4));
            if (acidOff < 0x80 || acidSize < 0x340 || acidOff + acidSize > npdm.Length) return npdm;
            ReadOnlySpan<byte> acid = npdm.AsSpan(acidOff, acidSize);
            if (acid.Slice(0x200, 4).SequenceEqual("ACID"u8) || !acid.Slice(0x300, 4).SequenceEqual("ACID"u8)) return npdm;

            byte[] o = new byte[npdm.Length - Extra];
            npdm.AsSpan(0, acidOff).CopyTo(o);
            acid.Slice(Extra).CopyTo(o.AsSpan(acidOff));
            npdm.AsSpan(acidOff + acidSize).CopyTo(o.AsSpan(acidOff + acidSize - Extra));
            Span<byte> a = o.AsSpan(acidOff, acidSize - Extra);
            BinaryPrimitives.WriteUInt32LittleEndian(a.Slice(0x204), (uint)(acidSize - Extra - 0x100));
            foreach (int f in new[] { 0x220, 0x228, 0x230 })   // FAC / SAC / KC 段内偏移（相对 ACID 段首）；长度 0 的块偏移可能是 0，不动
            {
                uint v = BinaryPrimitives.ReadUInt32LittleEndian(a.Slice(f));
                if (v >= Extra) BinaryPrimitives.WriteUInt32LittleEndian(a.Slice(f), v - Extra);
            }
            BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(MetaAcidOffset + 4), (uint)(acidSize - Extra));
            if (aciOff > acidOff) BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(MetaAciOffset), (uint)(aciOff - Extra));
            Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.Loader, "S2Arm npdm：Switch 2 布局（ACID 签名区多 0x100），已按 Switch 1 布局交 LibHac 解析");
            return o;
        }
    }
}
