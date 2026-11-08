// 安全缺省对象：录像 / 防护层在真渲染器某个创建调用还没实现时用它们顶上；桩渲染器也用。
using Ryujinx.Graphics.GAL;
using System;

namespace RyuJudge
{
    public sealed class StubSampler : ISampler
    {
        public SamplerCreateInfo Info { get; }
        public StubSampler(SamplerCreateInfo info) => Info = info;
        public void Dispose() { }
    }

    public sealed class StubProgram : IProgram
    {
        public readonly ShaderSource[] Sources;
        public StubProgram(ShaderSource[] sources) => Sources = sources;
        public ProgramLinkStatus CheckProgramLink(bool blocking) => ProgramLinkStatus.Success;
        /// <summary>伪二进制：「S2ASTUB1」+ 各阶段源码 / SPIR-V 的 SHA-1，可回读（LoadProgramBinary 收到同样字节即可建回程序）。</summary>
        public byte[] GetBinary()
        {
            System.IO.MemoryStream m = new();
            m.Write("S2ASTUB1"u8);
            foreach (ShaderSource s in Sources ?? Array.Empty<ShaderSource>())
            {
                m.Write(System.Security.Cryptography.SHA1.HashData(s.BinaryCode ?? System.Text.Encoding.UTF8.GetBytes(s.Code ?? "")));
            }

            return m.ToArray();
        }
        public void Dispose() { }
    }

    public sealed class StubCounterEvent : ICounterEvent
    {
        public bool Invalid { get; set; }
        public bool ReserveForHostAccess() => true;
        public void Flush() { }
        public void Dispose() { }
    }

    public sealed class StubArray : ITextureArray, IImageArray
    {
        public void SetSamplers(int index, ISampler[] samplers) { }
        public void SetTextures(int index, ITexture[] textures) { }
        public void SetImages(int index, ITexture[] images) { }
        public void Dispose() { }
    }
}
