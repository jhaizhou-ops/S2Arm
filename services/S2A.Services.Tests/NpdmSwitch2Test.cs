using System;
using System.Buffers.Binary;
using System.IO;
using LibHac.Loader;

namespace S2A.Services.Tests
{
    // Switch 2 的 npdm 布局（NpdmCompat.cs，11-02 Pokopia）：把 Switch 1 夹具 Homebrew.npdm 按 Switch 2 的写法手工展开——
    //   ACID 段开头插入 0x100 字节（签名区多出的部分）、段内 FAC / SAC / KC 偏移各加 0x100、「签名数据长」改成段长 − 0x180、
    //   META 里 ACID 长度加 0x100、排在 ACID 之后的 ACI0 偏移加 0x100。期望（不跑被测实现推得出）：
    //   ① 展开后的字节交 LibHac 直接解析失败（复现 2009-0004）；② Normalize 后与原夹具逐字节相同；③ Normalize 后 LibHac 解析成功、程序号与原夹具相同；
    //   ④ Switch 1 布局原样返回（同一个数组对象）
    public static partial class Program
    {
        [SoloTest("--npdm-switch2")]
        private static int NpdmSwitch2()
        {
            byte[] s1 = File.ReadAllBytes(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")));
            int aci = (int)BinaryPrimitives.ReadUInt32LittleEndian(s1.AsSpan(0x70)), acid = (int)BinaryPrimitives.ReadUInt32LittleEndian(s1.AsSpan(0x78));
            int acidSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(s1.AsSpan(0x7C));
            byte[] s2 = new byte[s1.Length + 0x100];
            s1.AsSpan(0, acid).CopyTo(s2);
            s1.AsSpan(acid, acidSize).CopyTo(s2.AsSpan(acid + 0x100));
            s1.AsSpan(acid + acidSize).CopyTo(s2.AsSpan(acid + acidSize + 0x100));
            Span<byte> a = s2.AsSpan(acid, acidSize + 0x100);
            BinaryPrimitives.WriteUInt32LittleEndian(a.Slice(0x304), (uint)(acidSize + 0x100 - 0x180));
            foreach (int f in new[] { 0x320, 0x328, 0x330 })
            {
                uint v = BinaryPrimitives.ReadUInt32LittleEndian(a.Slice(f));
                if (v >= 0x100) BinaryPrimitives.WriteUInt32LittleEndian(a.Slice(f), v + 0x100);
            }
            BinaryPrimitives.WriteUInt32LittleEndian(s2.AsSpan(0x7C), (uint)(acidSize + 0x100));
            if (aci > acid) BinaryPrimitives.WriteUInt32LittleEndian(s2.AsSpan(0x70), (uint)(aci + 0x100));

            bool rawFails = new MetaLoader().Load(s2).IsFailure();
            byte[] norm = S2A.Services.NpdmCompat.Normalize(s2);
            bool same = norm.AsSpan().SequenceEqual(s1);
            MetaLoader ml = new();
            bool loads = ml.Load(norm).IsSuccess() && ml.GetNpdm(out Npdm n).IsSuccess() && Pid(s1) == n.Aci.ProgramId.Value;
            bool s1Untouched = ReferenceEquals(S2A.Services.NpdmCompat.Normalize(s1), s1);

            string expect = "True / True / True / True", actual = $"{rawFails} / {same} / {loads} / {s1Untouched}";
            bool ok = expect == actual;
            Console.WriteLine($"{(ok ? "✓" : "✗")} Switch 2 npdm（展开后直接解析失败 / 规整后与原夹具逐字节同 / 规整后解析成功且程序号同 / Switch 1 原样返回）：{expect} → {actual}");
            return ok ? 0 : 1;
        }

        private static ulong Pid(byte[] npdm)
        {
            MetaLoader ml = new();
            ml.Load(npdm).ThrowIfFailure();
            ml.GetNpdm(out Npdm n).ThrowIfFailure();
            return n.Aci.ProgramId.Value;
        }
    }
}
