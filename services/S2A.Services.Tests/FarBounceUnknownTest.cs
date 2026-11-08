using LibHac.Fs;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Path = System.IO.Path;

namespace S2A.Services.Tests
{
    // 11-01 审计 P2-21（上午 P1-17 落空的一支）：读盘目标页写保护（pread 回 EFAULT）改中转读时，远端开着、目标又不在本线程取过的区域里，
    //   给不出游戏地址 → 报不了写（解不开保护、跟踪器不知道这次写）。期望：不往目标拷、读盘回失败、写钩子 0 次、报红 1 次。
    //   目标直接取影子页（不经 GetWritableRegion，故不在区域里）并设只读。旧代码只报红照拷：往只读页写，宿主崩溃（本模式进程异常退出即红）
    public static unsafe partial class Program
    {
        private static readonly List<(ulong Va, ulong Size)> _unknownWrites = new();
        private static void RecordUnknownWrite(ulong va, ulong size) => _unknownWrites.Add((va, size));

        [SoloTest("--far-bounce-unknown")]
        private static int FarBounceUnknown()
        {
            const int Chunk = 2 << 20;
            byte* g = (byte*)NativeMemory.AlignedAlloc(Chunk, 0x4000), sh = (byte*)NativeMemory.AlignedAlloc(Chunk, 0x4000);
            long* dir = (long*)NativeMemory.AllocZeroed(1 << 15, sizeof(long));
            FarDesc* desc = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));
            FarDesc* farWas = Native.Far;
            bool strictWas = Red.Strict;
            string tf = Path.Combine(Path.GetTempPath(), $"s2a_farbounce_unknown_{Environment.ProcessId}.bin");
            byte[] data = new byte[0x4000];
            for (int i = 0; i < data.Length; i++) data[i] = (byte)(i * 7 + 3);
            File.WriteAllBytes(tf, data);

            try
            {
                dir[0] = (long)((ulong)sh - (ulong)g);
                desc->Lo = (ulong)g;
                desc->Dir = (nint)dir;
                Native.Far = desc;
                Red.Strict = false;
                new Span<byte>(sh + 0x4000, 0x4000).Fill(0xEE);
                mprotect((nint)(sh + 0x4000), 0x4000, 1 /* READ */);
                _unknownWrites.Clear();
                GuestMemory.WriteHook = &RecordUnknownWrite;
                long red0 = Red.Total;
                var lf = new LazyHostFile(tf, data.Length);
                LibHac.Result lr = lf.Read(out long got, 0, new Span<byte>(sh + 0x4000, 0x4000), ReadOption.None);
                GuestMemory.WriteHook = null;
                long reds = Red.Total - red0;
                bool untouched = new Span<byte>(sh + 0x4000, 0x4000).IndexOfAnyExcept((byte)0xEE) < 0;
                lf.Dispose();
                string expect = "失败 / 0x0 / 目标没动 / 钩子 0 次 / 报红 1 次";
                string actual = $"{(lr.IsSuccess() ? "成功" : "失败")} / 0x{got:X} / {(untouched ? "目标没动" : "目标被写")} / 钩子 {_unknownWrites.Count} 次 / 报红 {reds} 次";
                bool ok = expect == actual;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 远端读盘中转给不出游戏地址（结果 / 读到 / 目标 / 写钩子 / 报红）：{expect} → {actual}");
                return ok ? 0 : 1;
            }
            finally
            {
                GuestMemory.WriteHook = null;
                Native.Far = farWas;
                Red.Strict = strictWas;
                mprotect((nint)(sh + 0x4000), 0x4000, 3);
                NativeMemory.AlignedFree(g);
                NativeMemory.AlignedFree(sh);
                NativeMemory.Free(dir);
                NativeMemory.Free(desc);
                File.Delete(tf);
            }
        }
    }
}
