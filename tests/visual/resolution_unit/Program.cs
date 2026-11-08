// 生产纯判据 + 真实 Metal 纹理 / 录像往返；输入为已有真实游戏捕获 RGBA，不生成替身图像、不用 mock renderer。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using NxGal;
using RyuJudge.GalRec;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen;
using S2Arm.Gfx.Widen.Gal;

static class Program
{
    static int checks;
    static void Check(string name, bool ok) { checks++; if (!ok) throw new InvalidOperationException(name); }
    static TextureCreateInfo Info(int w, int h) => new(w, h, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
        SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
    static double MeanRgb(ReadOnlySpan<byte> bytes, int pixels)
    {
        long sum = 0; for (int p = 0; p < pixels * 4; p += 4) sum += bytes[p] + bytes[p + 1] + bytes[p + 2];
        return sum / (pixels * 3.0);
    }
    sealed class ReplayScaleCheck : GalRecReplayer.IReplayHook
    {
        public void Before(GalRecReplayer replay, uint op, R reader) { }
        public void After(GalRecReplayer replay, uint op, R reader)
        {
            if (op != ObjOps.CreateTextureScaled && op != GalOps.IRenderer_CreateTexture) return;
            reader.Blit<TextureCreateInfo>(); float scale = op == ObjOps.CreateTextureScaled ? reader.F32() : 1f;
            Check("回放后的真实纹理保留逐纹理倍率", replay.Obj<WidenTexture>(reader.U32()).ResolutionScale == scale);
        }
    }
    static int Main(string[] args)
    {
        LoadFailureCheck.Run();
        if (args.Length == 1 && args[0] == "--load-failure") return 0;
        if (args.Length == 2 && args[0] == "--support-upload") return SupportUploadCheck.Run(args[1]);
        if (args.Length != 4) throw new ArgumentException("resolution_unit <真实捕获.rgba> <宽> <高> <输出目录>");
        byte[] pixels = File.ReadAllBytes(args[0]); int sourceW = int.Parse(args[1]), sourceH = int.Parse(args[2]);
        Check("真实捕获长度", pixels.Length == sourceW * sourceH * 4);
        Directory.CreateDirectory(args[3]);
        float[] scales = [0.5f, 0.75f, 1f, 1.5f, 2f];
        int[] wideWidths = [782, 1173, 1564, 2346, 3128];
        // 八方2真实景深布局：896x504 的半宽层为 448x252，两层加护边竖拼成 448x544。
        // 输入画面与图集可独立被 Ryujinx 缩放黑名单保留在 1x，不能按两张图的物理宽认家族。
        int[] layerWidths = [274, 410, 548, 822, 1094];
        foreach (float sourceScale in scales)
            for (int i = 0; i < scales.Length; i++)
            {
                float targetScale = scales[i];
                var layered = new WidenFrame(new WidenRewriter(2868f / 1320));
                layered.OnCreateTexture(1, (int)MathF.Ceiling(896 * sourceScale), (int)MathF.Ceiling(504 * sourceScale), sourceScale);
                int layerW = (int)MathF.Ceiling(448 * targetScale), layerH = (int)MathF.Ceiling(544 * targetScale);
                Check($"景深图集 {sourceScale}x→{targetScale}x：客体家族匹配、实际宽度按目标倍率", layered.LayerWiden(2, layerW, layerH, targetScale) == layerWidths[i]);
                Check($"景深图集 {sourceScale}x→{targetScale}x：保存实际原宽和放宽宽", layered.TryWide(2, out int w0, out int w1) && w0 == layerW && w1 == layerWidths[i]);
                Check($"景深图集 {sourceScale}x→{targetScale}x：方形目标仍不放宽", layered.LayerWiden(3, layerW, layerW, targetScale) == layerW);
            }
        for (int i = 0; i < scales.Length; i++)
        {
            float scale = scales[i]; int w = (int)MathF.Ceiling(1280 * scale), h = (int)MathF.Ceiling(720 * scale);
            Check($"{scale}: CPU 1x 图片仍覆盖同一客体画布", WidenFrame.IsPagePicture(1280, 720, 1f, w, scale));
            Check($"{scale}: 已缩放图片仍覆盖同一客体画布", WidenFrame.IsPagePicture(w, h, scale, w, scale));
            Check($"{scale}: 半画布图片不能误认整画布", !WidenFrame.IsPagePicture((int)(640 * scale), (int)(360 * scale), scale, w, scale));
            Check($"{scale}: 720p 视频页", WidenFrame.IsPageTarget(h, scale));
            Check($"{scale}: 180p 后处理不是新页", !WidenFrame.IsPageTarget((int)(180 * scale), scale));
            Check($"{scale}: 8x8 背景仍是小图", WidenFrame.IsSmallTexture((int)(8 * scale), (int)(8 * scale), scale, 8));
            var frame = new WidenFrame(new WidenRewriter(2868f / 1320));
            Check($"{scale}: 整屏2346x1080各倍率分类不变", frame.IsScreenAspect((int)MathF.Ceiling(2346 * scale), (int)(1080 * scale), scale));
            Check($"{scale}: 丝之歌1252x576的0.8客体像素误差保持整屏", frame.IsScreenAspect((int)(1252 * scale), (int)(576 * scale), scale));
            Check($"{scale}: 483x224局部面板不会误认整屏", !frame.IsScreenAspect((int)MathF.Ceiling(483 * scale), (int)(224 * scale), scale));
            Check($"{scale}: 8客体像素高度下限不随倍率改变", frame.IsScreenAspect((int)MathF.Ceiling(17 * scale), (int)(8 * scale), scale));
            Check($"{scale}: 4客体像素高度仍排除", !frame.IsScreenAspect((int)MathF.Ceiling(9 * scale), (int)(4 * scale), scale));
            frame.OnTargetFilled(80, (int)(1252 * scale), (int)(576 * scale), true, scale);
            frame.OnTargetFilled(81, (int)(648 * scale), (int)(364 * scale), true, scale);
            frame.OnTargetFilled(82, (int)(1256 * scale), (int)(576 * scale), true, scale);
            frame.OnTargetFilled(83, (int)MathF.Ceiling(17 * scale), (int)(8 * scale), true, scale);
            frame.OnTargetFilled(84, (int)MathF.Ceiling(9 * scale), (int)(4 * scale), true, scale);
            Check($"{scale}: 屏幕比例目标保存整屏副本标记", frame.IsScreenCopy(80));
            Check($"{scale}: 16:9目标0.89客体像素容差保存整屏副本标记", frame.IsScreenCopy(81));
            Check($"{scale}: 超过客体像素容差不标整屏副本", !frame.IsScreenCopy(82));
            Check($"{scale}: 小整屏副本高度回客体单位", frame.IsScreenCopy(83) && !frame.IsScreenCopy(84));
            Check($"{scale}: 物理纹理放宽", frame.OnCreateTexture(1, w, h) == wideWidths[i]); frame.OnRenderTargets(1, 0);
            float x = 0, vw = w; frame.MapViewport(ViewportMode.Hor, ref x, ref vw);
            Check($"{scale}: 投影K与物理视口抵消", MathF.Abs(vw / frame.Rewriter.K - w) < 0.001f && MathF.Abs(x + vw / 2 - wideWidths[i] / 2f) < 0.001f);
            int sx = 0, sw = w; frame.MapScissor(ViewportMode.Hor, ref sx, ref sw);
            Check($"{scale}: 满画布裁剪覆盖放宽物理目标", sx == 0 && sw == wideWidths[i]);
            Check($"{scale}: 拷贝坐标仅乘横向比", frame.MapX(1, w) == wideWidths[i]);
            // 八方2实际夹取矩形来自客体 CBUF；倍率不能叠进常量。另核对各物理尺寸的最大坐标，始终先加一再放宽、最后减一。
            var rect = new[] { 447, 251, 0, 0 }; byte[] rectOut = new byte[16];
            Check($"{scale}: 客体整数矩形命中", frame.Rewriter.Rewrite(MemoryMarshal.AsBytes(rect.AsSpan()), 0, rectOut));
            Check($"{scale}: 客体整数矩形只做宽屏改写、不乘分辨率倍率", MemoryMarshal.Cast<byte, int>(rectOut).SequenceEqual(new[] { 547, 251, 0, 0 }));
            int physicalW = (int)MathF.Ceiling(448 * scale), physicalH = (int)MathF.Ceiling(252 * scale);
            rect = [physicalW - 1, physicalH - 1, 0, 0];
            Check($"{scale}: 实际尺寸整数矩形命中", frame.Rewriter.Rewrite(MemoryMarshal.AsBytes(rect.AsSpan()), 0, rectOut));
            Check($"{scale}: 实际尺寸最大坐标与目标最后一列一致", MemoryMarshal.Cast<byte, int>(rectOut).SequenceEqual(new[] { layerWidths[i] - 1, physicalH - 1, 0, 0 }));
            float[] rectFloats = new float[4];
            Check($"{scale}: 增量路径最大坐标与整段路径一致", frame.Rewriter.RewriteFloats(MemoryMarshal.Cast<int, float>(rect), true, rectFloats, out var rectKind) == 16
                && rectKind == WidenKind.ScreenSize && MemoryMarshal.AsBytes(rectFloats.AsSpan()).SequenceEqual(rectOut));
            float[] guestSize = [1280, 720, 1f / 1280, 1f / 720]; byte[] rewritten = new byte[16];
            Check($"{scale}: 客体常量识别仍使用原尺寸", frame.OnBufferData(8, 0, MemoryMarshal.AsBytes(guestSize.AsSpan()), rewritten));
            Check($"{scale}: 客体尺寸只乘宽屏比、不叠分辨率倍率", BitConverter.ToSingle(rewritten) == 1564 && BitConverter.ToSingle(rewritten, 4) == 720);
            var native = new WidenFrame(new WidenRewriter(2868f / 1320)) { GameWide = true };
            native.OnCreateTexture(1, wideWidths[i], h); native.OnRenderTargets(1, 0); native.OnViewport(0, wideWidths[i], h);
            Check($"{scale}: GameWide 不再乘宽屏比例", native.TargetScaleX == 1f);
            native.OnViewport(0, frame.Rewriter.Aspect * 8 * scale, 8 * scale, scale);
            Check($"{scale}: GameWide原生宽视口高度门限回客体单位", native.TargetNative);
            Console.WriteLine($"倍率 {scale}: 页 / 小图 / viewport / scissor / MapX / GameWide 通过");
        }
        var counterproof = new WidenFrame(new WidenRewriter(2868f / 1320));
        Check("旧物理1px判据反证：1252x576是整屏，2504x1152会丢分类", counterproof.IsScreenAspect(1252, 576) && !counterproof.IsScreenAspect(2504, 1152));
        Check("新判据：2504x1152带2x元数据恢复整屏分类", counterproof.IsScreenAspect(2504, 1152, 2f));
        Check("存储图像保持1x时计算派发的横向组数", WidenFrame.WidenGroupsX(80, 45, 640, 782, 360) == 98);

        using var nx = new NxRenderer(); nx.Initialize(GraphicsDebugLevel.None);
        var widen = new WidenRenderer(nx, 2868f / 1320);
        string recording = Path.Combine(args[3], "resolution.rec");
        using (var recorder = new GalRecorder(recording, 2 << 20, () => true, GalOps.Names, nx.GetCapabilities()))
        {
            var renderer = new RecordingRenderer(widen, null, recorder);
            foreach (float scale in scales)
            {
                int w = (int)MathF.Ceiling(1280 * scale), h = (int)MathF.Ceiling(720 * scale);
                ITexture texture = renderer.CreateTexture(Info(w, h), scale);
                Check($"{scale}: 真实录像包装透传逐纹理倍率", ((RecTexture)texture).Inner is WidenTexture wt && wt.ResolutionScale == scale);
                ITexture view = texture.CreateView(Info(w, h), 0, 0);
                Check($"{scale}: 真实 Metal 视图继承倍率", ((RecTexture)view).Inner is WidenTexture v && v.ResolutionScale == scale);
                view.Release(); texture.Release();
            }
            ITexture legacy = renderer.CreateTexture(Info(32, 32)); legacy.Release();
        }
        using (GalRecFile file = GalRecFile.Load(recording))
        {
            var replay = new GalRecReplayer(widen) { Hook = new ReplayScaleCheck() }; var found = new List<float>();
            replay.ReplayAll(file, (op, index) => { });
            Check("真实录像完整回放", replay.Unknown == 0 && replay.Errors == 0);
            foreach (GalRecRecord record in file.Records())
            {
                if (record.Op != ObjOps.CreateTextureScaled) continue;
                var reader = new R(file.Payload(record)); reader.Blit<TextureCreateInfo>(); found.Add(reader.F32());
            }
            Check("五个倍率原样记录", CollectionsMarshal.AsSpan(found).SequenceEqual(scales));
        }
        // 真实捕获经 Ryujinx SetScale 同样的整图缩放路径，图片首次采样后应保持原宽；底层 Metal 读回实际字节检查尺寸。
        foreach (float scale in scales)
        {
            var source = (WidenTexture)widen.CreateTexture(Info(sourceW, sourceH), 1f);
            source.SetData(MemoryOwner<byte>.RentCopy(pixels));
            int w = (int)MathF.Ceiling(sourceW * scale), h = (int)MathF.Ceiling(sourceH * scale);
            var destination = scale == 1f ? source : (WidenTexture)widen.CreateTexture(Info(w, h), scale);
            if (scale != 1f) source.CopyTo(destination, new Extents2D(0, 0, sourceW, sourceH), new Extents2D(0, 0, w, h), true);
            using (var readback = destination.GetData())
            {
                Check($"{scale}: 真实 CPU 图片换 storage 后按原宽读回", destination.Inner.Width == w && readback.Get().Length >= w * h * 4);
                double expected = MeanRgb(pixels, sourceW * sourceH), actual = MeanRgb(readback.Get(), w * h);
                Check($"{scale}: 实际捕获缩放后颜色内容保留", expected > 1 && Math.Abs(expected - actual) < 0.5);
                if (scale == 1f) Check("1x真实捕获逐字节保留", readback.Get()[..pixels.Length].SequenceEqual(pixels));
            }
            Check($"{scale}: CPU 图片倍率保持", destination.ResolutionScale == scale && !widen.State.IsWide(destination.Id));
            if (destination != source) destination.Release(); source.Release();
        }
        Console.WriteLine($"共 {checks} 项通过；真实 Metal 创建 / 视图 / 捕获缩放 / 录像往返均执行。");
        return 0;
    }
}
