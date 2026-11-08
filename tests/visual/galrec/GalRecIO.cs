// GAL 调用流录像（galrec）的字节层：写 / 读原语。格式说明见 ryu_judge/README.md「GAL 调用流录像」。
// 全部小端。结构体按「本 GAL 程序集里的内存布局」原样写（blit），读端必须用同一份 GAL 程序集（sw/third_party/ryujinx_gpu）。
using Ryujinx.Graphics.GAL;
using System;
using System.Buffers;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace RyuJudge.GalRec
{
    public static class GalRecFormat
    {
        public const ulong Magic = 0x3130_4C41_4741_3253; // "S2AGAL01"
        public const uint Version = 2; // v2：头里加 GAL 接口签名哈希与录制时的能力表

        // 特殊记录（不对应 GAL 方法）
        public const uint OpFrame = 0xFF00;          // u64 帧号
        public const uint OpPrologueBegin = 0xFF01;  // 帧窗口开录：先重建窗口开始时活着的对象与管线状态
        public const uint OpPrologueEnd = 0xFF02;
        public const uint OpCounterResult = 0xFF03;  // u32 计数器事件编号, u64 值（渲染器回调结果）
        public const uint OpStop = 0xFF04;           // u64 已写字节数：到顶停录
        public const uint OpNote = 0xFF05;           // UTF-8 文本
    }

    /// <summary>记录体写入（追加到 ArrayBufferWriter）。</summary>
    public static class W
    {
        static Span<byte> Get(IBufferWriter<byte> w, int n) => w.GetSpan(n)[..n];

        public static void U8(IBufferWriter<byte> w, byte v) { Get(w, 1)[0] = v; w.Advance(1); }
        public static void Bool(IBufferWriter<byte> w, bool v) => U8(w, v ? (byte)1 : (byte)0);
        public static void I32(IBufferWriter<byte> w, int v) { BinaryPrimitives.WriteInt32LittleEndian(Get(w, 4), v); w.Advance(4); }
        public static void U32(IBufferWriter<byte> w, uint v) { BinaryPrimitives.WriteUInt32LittleEndian(Get(w, 4), v); w.Advance(4); }
        public static void U64(IBufferWriter<byte> w, ulong v) { BinaryPrimitives.WriteUInt64LittleEndian(Get(w, 8), v); w.Advance(8); }
        public static void I64(IBufferWriter<byte> w, long v) { BinaryPrimitives.WriteInt64LittleEndian(Get(w, 8), v); w.Advance(8); }
        public static void F32(IBufferWriter<byte> w, float v) { BinaryPrimitives.WriteSingleLittleEndian(Get(w, 4), v); w.Advance(4); }

        public static void Blit<T>(IBufferWriter<byte> w, in T v) where T : unmanaged
        {
            ReadOnlySpan<byte> b = MemoryMarshal.AsBytes(new ReadOnlySpan<T>(in v));
            b.CopyTo(Get(w, b.Length));
            w.Advance(b.Length);
        }

        public static void Span<T>(IBufferWriter<byte> w, ReadOnlySpan<T> v) where T : unmanaged
        {
            U32(w, (uint)v.Length);
            ReadOnlySpan<byte> b = MemoryMarshal.AsBytes(v);
            if (b.Length != 0)
            {
                b.CopyTo(Get(w, b.Length));
                w.Advance(b.Length);
            }
        }

        public static void Bytes(IBufferWriter<byte> w, ReadOnlySpan<byte> v) => Span(w, v);

        public static void Str(IBufferWriter<byte> w, string s)
        {
            if (s == null)
            {
                U32(w, uint.MaxValue);
                return;
            }

            Bytes(w, Encoding.UTF8.GetBytes(s));
        }

        public static void Shaders(IBufferWriter<byte> w, ShaderSource[] s)
        {
            U32(w, (uint)(s?.Length ?? 0));
            if (s == null)
            {
                return;
            }

            foreach (ShaderSource x in s)
            {
                I32(w, (int)x.Stage);
                I32(w, (int)x.Language);
                Str(w, x.Code);
                if (x.BinaryCode == null)
                {
                    U32(w, uint.MaxValue);
                }
                else
                {
                    Bytes(w, x.BinaryCode);
                }
            }
        }

        public static void ShaderInfo(IBufferWriter<byte> w, in ShaderInfo info)
        {
            I32(w, info.FragmentOutputMap);
            Bool(w, info.FromCache);
            Bool(w, info.State.HasValue);
            if (info.State.HasValue)
            {
                ProgramPipelineState st = info.State.Value;
                Blit(w, st);
            }

            ResourceLayout l = info.ResourceLayout;
            U32(w, (uint)(l.Sets?.Count ?? 0));
            if (l.Sets != null)
            {
                foreach (ResourceDescriptorCollection set in l.Sets)
                {
                    U32(w, (uint)set.Descriptors.Count);
                    foreach (ResourceDescriptor d in set.Descriptors)
                    {
                        Blit(w, d);
                    }
                }
            }

            U32(w, (uint)(l.SetUsages?.Count ?? 0));
            if (l.SetUsages != null)
            {
                foreach (ResourceUsageCollection set in l.SetUsages)
                {
                    U32(w, (uint)set.Usages.Count);
                    foreach (ResourceUsage u in set.Usages)
                    {
                        Blit(w, u);
                    }
                }
            }
        }

        /// <summary>读回数据的指纹：长度 + 前 8 字节 SHA-1（只作逐条比对，不用于回放）。</summary>
        public static void Digest(IBufferWriter<byte> w, ReadOnlySpan<byte> data)
        {
            U32(w, (uint)data.Length);
            Span<byte> h = stackalloc byte[20];
            System.Security.Cryptography.SHA1.HashData(data, h);
            h[..8].CopyTo(Get(w, 8));
            w.Advance(8);
        }
    }

    /// <summary>记录体读取游标。</summary>
    public ref struct R
    {
        ReadOnlySpan<byte> _b;
        public int Pos;

        public R(ReadOnlySpan<byte> b)
        {
            _b = b;
            Pos = 0;
        }

        /// <summary>从录像数据的一段（记录体起点、长度）建游标。</summary>
        public R(byte[] data, int start, int len) : this(data.AsSpan(start, len))
        {
        }

        public readonly int Remaining => _b.Length - Pos;

        ReadOnlySpan<byte> Take(int n)
        {
            ReadOnlySpan<byte> s = _b.Slice(Pos, n);
            Pos += n;
            return s;
        }

        public byte U8() => Take(1)[0];
        public bool Bool() => U8() != 0;
        public int I32() => BinaryPrimitives.ReadInt32LittleEndian(Take(4));
        public uint U32() => BinaryPrimitives.ReadUInt32LittleEndian(Take(4));
        public ulong U64() => BinaryPrimitives.ReadUInt64LittleEndian(Take(8));
        public long I64() => BinaryPrimitives.ReadInt64LittleEndian(Take(8));
        public float F32() => BinaryPrimitives.ReadSingleLittleEndian(Take(4));
        public T Blit<T>() where T : unmanaged => MemoryMarshal.Read<T>(Take(Unsafe.SizeOf<T>()));

        public T[] Span<T>() where T : unmanaged
        {
            uint n = U32();
            return MemoryMarshal.Cast<byte, T>(Take((int)n * Unsafe.SizeOf<T>())).ToArray();
        }

        public byte[] Bytes()
        {
            uint n = U32();
            return n == uint.MaxValue ? null : Take((int)n).ToArray();
        }

        public string Str()
        {
            byte[] b = Bytes();
            return b == null ? null : Encoding.UTF8.GetString(b);
        }

        /// <summary>回放时替换程序的 SPIR-V（galplay --spv-sub）：给原字节，返回替换字节（不换返回原数组）。</summary>
        public static System.Func<byte[], byte[]> ShaderSubstitute;

        public ShaderSource[] Shaders()
        {
            uint n = U32();
            ShaderSource[] s = new ShaderSource[n];
            for (int i = 0; i < n; i++)
            {
                Ryujinx.Graphics.Shader.ShaderStage stage = (Ryujinx.Graphics.Shader.ShaderStage)I32();
                Ryujinx.Graphics.Shader.Translation.TargetLanguage lang = (Ryujinx.Graphics.Shader.Translation.TargetLanguage)I32();
                string code = Str();
                byte[] bin = Bytes();
                if (bin != null && ShaderSubstitute != null)
                {
                    bin = ShaderSubstitute(bin);
                }

                s[i] = new ShaderSource(code, bin, stage, lang);
            }

            return s;
        }

        public ShaderInfo ShaderInfo()
        {
            int map = I32();
            bool fromCache = Bool();
            bool hasState = Bool();
            ProgramPipelineState st = hasState ? Blit<ProgramPipelineState>() : default;
            uint nsets = U32();
            List<ResourceDescriptorCollection> sets = new();
            for (int i = 0; i < nsets; i++)
            {
                uint n = U32();
                List<ResourceDescriptor> d = new();
                for (int j = 0; j < n; j++)
                {
                    d.Add(Blit<ResourceDescriptor>());
                }

                sets.Add(new ResourceDescriptorCollection(d.AsReadOnly()));
            }

            uint nus = U32();
            List<ResourceUsageCollection> us = new();
            for (int i = 0; i < nus; i++)
            {
                uint n = U32();
                List<ResourceUsage> u = new();
                for (int j = 0; j < n; j++)
                {
                    u.Add(Blit<ResourceUsage>());
                }

                us.Add(new ResourceUsageCollection(u.AsReadOnly()));
            }

            ResourceLayout layout = new(sets.AsReadOnly(), us.AsReadOnly());
            return hasState ? new ShaderInfo(map, layout, st, fromCache) : new ShaderInfo(map, layout, fromCache);
        }

        public (uint len, ulong hash) Digest()
        {
            uint n = U32();
            return (n, U64());
        }
    }
}
