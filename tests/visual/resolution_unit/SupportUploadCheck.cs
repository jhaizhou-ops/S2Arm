// 真实游戏 GAL 回放 → WidenPipeline 绘制 → Metal 缓冲读回；不替换着色器、绘制或渲染器。
// 在实际写出非零 s2a_widen 的绘制后，用生产 SupportBufferUpdater 连续上传覆盖它，再重复该笔真实绘制。
using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using NxGal;
using RyuJudge.GalRec;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Shader;
using S2Arm.Gfx.Widen.Gal;

static class SupportUploadCheck
{
    static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    static byte[] Read(NxRenderer nx, BufferHandle buffer, int offset, int length)
    {
        using var data = nx.GetBufferData(buffer, offset, length);
        return data.Get().ToArray();
    }

    public static int Run(string recording)
    {
        using GalRecFile file = GalRecFile.Load(recording);
        Check(file.Truncation == null, $"真实录像截断：{file.Truncation}");
        using var nx = new NxRenderer(); nx.Initialize(GraphicsDebugLevel.None);
        var widen = new WidenRenderer(nx, 2868f / 1320) { CpuPeek = nx.S2APeekBufferCpu };
        var replay = new GalRecReplayer(widen);
        replay.CheckCompatible(file);
        Check(SupportBuffer.S2AWidenOffset + 16 < Marshal.SizeOf<SupportBuffer>(), "测试需要 s2a_widen 后面存在 render_scale_y");
        foreach (GalRecRecord record in file.Records())
        {
            var reader = new R(file.Payload(record));
            Check(replay.ReplayOne(record.Op, ref reader), $"未知录像操作：{file.Name(record.Op)}");
            Check(replay.MissingRefs == 0, $"真实录像对象引用缺失：记录 {record.Index} {file.Name(record.Op)}");
            if (record.Op == GalOps.IPipeline_SetProgram)
            {
                reader = new R(file.Payload(record));
                IProgram program = replay.Obj<IProgram>(reader.U32());
                Check(program == null || program.CheckProgramLink(true) == ProgramLinkStatus.Success, $"真实录像程序链接失败：记录 {record.Index}");
            }
            if (record.Op != GalOps.IPipeline_Draw && record.Op != GalOps.IPipeline_DrawIndexed) continue;
            if (!widen.TryUniform(SupportBuffer.Binding, out ulong raw, out int offset, out int size) || size < SupportBuffer.S2AWidenOffset + 16) continue;
            BufferHandle original = Unsafe.As<ulong, BufferHandle>(ref raw);
            byte[] expected = Read(nx, original, offset + SupportBuffer.S2AWidenOffset, 16);
            foreach (float value in MemoryMarshal.Cast<byte, float>(expected)) Check(float.IsFinite(value), "真实绘制的 s2a_widen 不是有限值");
            // 真正遇到外推 / 收缩参数才测；全零绘制不能证明连续上传覆盖了包装层自写的非零值。
            if (MemoryMarshal.Cast<byte, float>(expected).IndexOfAnyExcept(0f) < 0) continue;

            Type type = typeof(GpuContext).Assembly.GetType("Ryujinx.Graphics.Gpu.Memory.SupportBufferUpdater", throwOnError: true);
            using var updater = (IDisposable)Activator.CreateInstance(type, widen);
            void Call(string name, params object[] values) => type.GetMethod(name)!.Invoke(updater, values);
            Call("SetViewportTransformDisable", 1920f, 1080f, 1f, true);
            Call("Commit");
            BufferHandle buffer = (BufferHandle)type.GetProperty("Handle")!.GetValue(updater)!;
            // 新缓冲先完成一次真实绘制，使以下检查必须依赖同一缓冲的 NoteSupportWrite。
            reader = new R(file.Payload(record));
            Check(replay.ReplayOne(record.Op, ref reader), "第一次重复真实绘制失败");
            Check(Read(nx, buffer, SupportBuffer.S2AWidenOffset, 16).AsSpan().SequenceEqual(expected), "首次绘制未写出原有外推参数");
            for (int attempt = 0; attempt < 2; attempt++)
            {
                float scale = attempt == 0 ? 0.75f : 1f;
                // 脏区从首成员到最后一个逐纹理 Y 倍率，Commit 走生产 BufferUpdater 的连续整段上传。
                Call("SetViewportTransformDisable", 1920f, 1080f, 1f, true);
                Call("UpdateRenderScale", SupportBuffer.RenderScaleMaxCount - 2, scale);
                Call("Commit");
                Check(Read(nx, buffer, SupportBuffer.S2AWidenOffset, 16).AsSpan().IndexOfAnyExcept((byte)0) < 0, "生产连续上传未覆盖 s2a_widen，测试没有复现条件");
                int tail = SupportBuffer.RenderScaleYOffset + (SupportBuffer.RenderScaleMaxCount - 1) * 16;
                Check(BitConverter.ToSingle(Read(nx, buffer, tail, 4)) == scale, "连续上传未到达支持缓冲最后一个 Y 倍率");
                reader = new R(file.Payload(record));
                Check(replay.ReplayOne(record.Op, ref reader), "连续上传后的真实绘制失败");
                Check(Read(nx, buffer, SupportBuffer.S2AWidenOffset, 16).AsSpan().SequenceEqual(expected), "连续上传后下一笔绘制没有恢复 s2a_widen");
            }
            Console.WriteLine($"PASS 真实录像 {Path.GetFileName(recording)} 记录 {record.Index}：生产整段上传两次覆盖 s2a_widen，下一笔真实绘制均恢复，Metal 读回逐字节相同");
            return 0;
        }
        throw new InvalidOperationException("真实录像没有写出非零 s2a_widen 的绘制，不能证明覆盖后重写");
    }
}
