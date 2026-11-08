// 通用宽屏 · GAL 包装层：套在我方渲染器（NxRenderer）外、Ryujinx 多线程渲染器之内的一层 IRenderer 装饰，不改 Ryujinx 源码。
// 只拦宽屏要管的调用（建贴图 / 视图放宽、常量改写、程序读法分析、视口 / 裁剪换算、区域拷贝 / 上屏裁剪换算），其余原样转发。
// 贴图、贴图数组、图像数组要包一层（它们自己的方法要换算或拆包）；程序用弱表挂读法；采样器、计数事件直通。
// 每帧路径零分配：拆包数组按长度复用，视口 / 裁剪用栈上数组，常量改写用线程内复用缓冲。
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2Arm.Gfx.Widen.Gal
{
    /// <summary>尺寸对不上、只能报红的调用计数（期望全 0；非 0 写进局后报告）。</summary>
    public struct WidenRed
    {
        public long TexSetData, TexGetData, TexCopyToBuffer, TexCopyMismatch, ComputeOnWide, ProgramNoSpirv;
        public long Narrowed;   // 放宽贴图读回前缩回原宽的次数（不是红，诊断用）
        public long ComputeWidened;   // 写放宽图像的计算派发按像素铺、X 组数补到放宽宽度的次数（不是红）
        // 机制判据（10-22 巫师3 光照 / 泛光金字塔）：放宽目标上按 ScaleK / Hor 画、片元却按真实像素坐标的绘制（SpirvFetchScale 不 exact 的程序、旧包里有整数取图的程序）——
        // 它们读到的客体像素常量（区域矩形、瓦片数、像素射线起点…）没法逐个认全，是「某一遍常量没跟着放宽」的来源；不是红，按款计数看暴露面
        public long RealPxDraws, RealPxPrograms;
        public readonly long Total => TexSetData + TexGetData + TexCopyToBuffer + TexCopyMismatch + ComputeOnWide;
        public override readonly string ToString() =>
            $"放宽贴图 CPU 上传 {TexSetData}、CPU 读回 {TexGetData}、拷到缓冲 {TexCopyToBuffer}、整张拷贝尺寸不符 {TexCopyMismatch}、计算着色器写放宽图像 {ComputeOnWide}；无 SPIR-V 的程序 {ProgramNoSpirv}；读回前缩回原宽 {Narrowed}；计算派发补到放宽宽度 {ComputeWidened}；按真实像素画的放宽绘制 {RealPxDraws}（程序 {RealPxPrograms} 个）";
    }

    /// <summary>包装层程序：底层程序 + 宽屏层对它的登记（建程序时填一次，SetProgram 直接读字段）。只有 SetProgram 往下传 Inner。</summary>
    internal sealed class WidenProgram : IProgram
    {
        public readonly IProgram Inner;
        public CbufUse[] Uses;
        public bool FragY, RealPx, RealPxSeen;
        // 片元要按真实像素坐标画（RealPx）；片元取图缩放项（render_scale 下标、绑定号、存储图像）
        public (int Index, int Binding, bool Image)[] Scales;
        // 能按原画框外推画（SpirvExtrap 改了片元、SpirvEdgePush 改了顶点）→ 外推时归一化采样要写 off 的 (render_scale 下标, 绑定号)；顶点着色器位置切片（几何判定）
        public (int Index, int Binding)[] Extrap;
        // 顶点着色器位置切片（几何判定用）：建程序时只记来源（原 SPIR-V 或着色器包 widen_pos.bin 的键），几何判定第一次用到才解析（10-23 马车8 首帧载 395 个程序，
        // 载入时逐个解析每个 236–660 KB、编码线程 69 MB / GC 38 ms；多数程序从不进几何判定）。只在渲染线程（GeomCovers）读
        byte[] _posSpv; PosFile _posFile; ulong _posKey; SpirvPosSlice _pos; bool _posDone;
        public void PosFromSpirv(byte[] spv) { _posSpv = spv; _posFile = null; _posDone = false; }
        public void PosFromFile(PosFile f, ulong key) { _posFile = f; _posKey = key; _posSpv = null; _posDone = false; }
        public SpirvPosSlice Pos
        {
            get
            {
                if (_posDone) return _pos;
                _posDone = true;
                _pos = _posSpv != null ? SpirvPosSlice.Extract(_posSpv, out _) : _posFile?.Get(_posKey);
                _posSpv = null; _posFile = null;
                return _pos;
            }
        }
        // 片元采样的贴图绑定号（整画布 16:9 图片判据）；顶点已改（可外推）的程序的同一份（外推前查是不是都很小）；用到的图像绑定号（ShaderInfo 资源表里的 Image / BufferImage：计算派发只认这些是输出；null = 不知道，按全部已绑图像算）
        public int[] Sampled, Push, Images;
        // 顶点阶段采样的贴图绑定号（顶点阶段贴图槽常留着别的程序的旧绑定，只认本程序真采样的；null = 不知道，如旧包）
        public int[] VSampled;
        // 几何判定上一次确定的结果（1 铺满 / 0 只盖部分），按「顶点数 / 绘制种类 / 实例数 / 视口」分：本帧输入读不到时沿用（见 GeomCovers）。只在渲染线程读写
        internal Dictionary<(int Count, int Kind, int Inst, int VpX, int VpW), int> LastGeom;
        public WidenProgram(IProgram inner) { Inner = inner; }
        public ProgramLinkStatus CheckProgramLink(bool blocking) => Inner.CheckProgramLink(blocking);
        public byte[] GetBinary() => Inner.GetBinary();
        public void Dispose() => Inner.Dispose();
    }

    public sealed class WidenRenderer : IRenderer, IBufferPatcher
    {
        /// <summary>量具（galplay --ui-noscissor，闭环 ⑩「界面裁剪不多切」）：不开深度测的绘制（界面 / 二维）裁剪一律放成整张。产品里恒 false。</summary>
        public static bool IgnoreOutScissor;
        internal readonly IRenderer Inner;
        internal readonly WidenFrame Frame;
        /// <summary>每帧镜头位姿（frames.tsv cam_* 列；不放宽时也照常认，包装层此时只观察）。</summary>
        public readonly CameraTrack Cam;
        internal WidenRed Red;
        /// <summary>诊断（galplay --trace）：每次绘制报一行换算前后的视口 0 / 裁剪 0 与换算方式；产品里为 null，零开销。</summary>
        public Action<string> DrawTrace;
        /// <summary>--trace 里贴图的名字（回放器给录像对象号；没给用包装层贴图号）。</summary>
        public Func<ITexture, string> TraceTexName;
        internal long FragYPatched, ScaleWrites, TexScaleWrites, PushPatched, EdgeDraws, ShrinkDraws, PushWrites;
        // 原画框外推（SpirvExtrap）：能外推的程序数、外推画的绘制数、其中采样了「拉伸内容」贴图的（放宽贴图内容不是居中排布：平移换算会错位，诊断用）、
        // 铺满画布的 ScaleK 绘制里程序不能外推、照旧按拉伸画的
        internal long ExtrapPrograms, ExtrapDraws, ExtrapOnStretched, ExtrapStretchFallback;
        // 原画框外推的写侧来历（10-23 八方2 存档菜单模糊链：图集子块）：程序 → 顶点着色器位置切片（SpirvPosSlice）；
        // 候选外推笔里几何只盖住画布一部分退回拉伸 / 采样了「框外不是外延」的放宽贴图退回拉伸 / 几何判不出（按铺满、同改前）的笔数
        internal long ExtrapGeomPartial, ExtrapProvFallback, ExtrapGeomUnknown, ExtrapGeomUnread, ExtrapGeomReuse, ExtrapChainMaxFrames;
        internal readonly HashSet<uint> ExtrapChainLong = new();   // 传染退回时，所采样贴图已连续 ≥ 3 帧不是外延的（跨帧持续链：如 TAA 历史）
        /// <summary>只读 CPU 侧此刻内容、不等 GPU 的读（宽屏几何判定用；产品与回放接 NxRenderer.S2APeekBufferCpu，空 = 判不出）。</summary>
        public delegate bool CpuPeekFn(BufferHandle buffer, int offset, Span<byte> dst);
        public CpuPeekFn CpuPeek;
        internal readonly HashSet<ulong> GpuWrittenBufs = new();   // GPU 会写的缓冲（存储缓冲可写绑定 / 拷贝 / 清除目标）：CPU 读它要等 GPU，几何判定不读
        // 支持缓冲（绑定 0）里 render_scale[0] 的位置与 GPU 上当前值：Gpu 层写入时记它写的值，绘制前按目标放宽比改
        internal ulong SupportBuf; internal int SupportScaleAt = -1; internal float SupportScaleNow = 1;
        internal float SupportBaseScale = 1f;
        internal readonly float[] SupportBaseTexScale = new float[SupportBuffer.RenderScaleMaxCount];
        // render_scale[1..] 在 GPU 上的当前值（NaN = 不知道）与被宽屏覆盖的下标（绘制换程序时恢复 GPU 原倍率）
        internal readonly float[] SupportTexScale = new float[SupportBuffer.RenderScaleMaxCount]; internal readonly List<int> SupportTexScaleSet = new();
        // s2a_widen.x / .y（外推量、外推门限²）在支持缓冲里的位置与 GPU 上当前的外推量（NaN = 不知道，下次必写）
        internal int SupportPushAt = -1; internal float SupportPushNow = float.NaN, SupportThrNow = float.NaN, SupportShrinkNow = float.NaN, SupportPadNow = float.NaN;   // s2a_widen.w = 外推语义的 pad
        WidenPipeline _pipe;
        WidenWindow _win;
        int _nextTex;
        [ThreadStatic] static byte[] t_scratch;
        const int ScratchBytes = 64 * 1024;
        // Ryujinx.Graphics.Shader 的 SupportBufferField.RenderScale（内部枚举，= SupportBuffer 结构第 6 个成员，序号 5）；锁版本 475615f0 核对过
        const int RenderScaleMember = WidenShaders.RenderScaleMember;

        /// <param name="gameWide">游戏自己按屏幕比出图（第二层生效）：只管界面层，不放宽贴图（见 WidenFrame.GameWide）</param>
        public WidenRenderer(IRenderer inner, float targetAspect, bool gameWide = false)
        {
            Inner = inner;
            SupportBaseTexScale.AsSpan().Fill(1f);
            Frame = new WidenFrame(new WidenRewriter(targetAspect)) { GameWide = gameWide };
            Cam = new CameraTrack(Frame.Shadow);
        }

        public WidenRed RedCounts => Red;

        /// <summary>上一帧的主镜头位姿：o[0..7] = 位置 x y z、前向 fx fy fz、偏航、俯仰（度，Y 朝上）。没有透视主镜头（2D 款 / 菜单）返回 false。</summary>
        public bool TryCamera(Span<float> o)
        {
            if (!Cam.Valid || o.Length < 8) return false;
            o[0] = Cam.X; o[1] = Cam.Y; o[2] = Cam.Z; o[3] = Cam.Fx; o[4] = Cam.Fy; o[5] = Cam.Fz; o[6] = Cam.Yaw; o[7] = Cam.Pitch;
            return true;
        }
        public WidenFrame State => Frame;

        public string Report() => $"[宽屏] k {Frame.Rewriter.K:F4}；片元 y 去缩放 {FragYPatched} 处、render_scale[0] 写入 {ScaleWrites} 次、贴图取图缩放写入 {TexScaleWrites} 次；CPU 供图换回原宽 {Unwidened} 张（其中后来当渲染目标、重新放宽 {Rewidened} 张）、画面分层图集按需放宽 {LayerWidenedTex} 张、16:9 原比例页 {PicDraws} 页（页内绘制 {Frame.DrawsPage} 次、被采样取中间区副本 {ShadowCopies} 次、首次用之前的 CPU 供图按页上屏 {PresentPages} 次）、两侧条带清黑 {SideClears} 次；程序二进制带宽屏元数据 {BinaryMeta} 个 / 没带 {BinaryNoMeta} 个；越界顶点外推 顶点着色器改 {PushPatched} 个、外推绘制 {EdgeDraws} 次（其中原尺寸居中层收缩外推 {ShrinkDraws} 次、原画框外推 {ExtrapDraws} 次）、参数写入 {PushWrites} 次；原画框外推：能外推的程序 {ExtrapPrograms} 个、铺满画布的 ScaleK 里程序不能外推照旧拉伸 {ExtrapStretchFallback} 次、外推采样了拉伸内容的贴图 {ExtrapOnStretched} 次、因来历退回拉伸：几何只盖画布一部分 {ExtrapGeomPartial} 笔 / 采样了框外不是外延的贴图 {ExtrapProvFallback} 笔、几何判不出（按铺满）{ExtrapGeomUnknown} 笔、输入读不到（按拉伸）{ExtrapGeomUnread} 笔 / 读不到沿用上次判定 {ExtrapGeomReuse} 笔、传染跨帧持续 ≥ 3 帧的贴图 {ExtrapChainLong.Count} 张（最长 {ExtrapChainMaxFrames} 帧）；{Frame.Rewriter.Stats}；绘制 {Frame.Draws}（放宽目标 {Frame.DrawsWide}、读到改写矩阵 {Frame.DrawsCovered}、界面层 {Frame.DrawsHud}、其中原宽居中 {Frame.DrawsHudCentered}、界面层目标按界面正交居中 {Frame.DrawsUiLayer}）；写回原值 {Frame.Restores} / 改写值 {Frame.Reapplies}；只扫变了的：上传 {Frame.UpBytes >> 10} KB（其中没影子的 {Frame.Shadow.NoPageBytes >> 10} KB）、扫 {Frame.ScanBytes >> 10} KB，常量缓冲影子 {Frame.Shadow.Bytes >> 10} KB（峰值 {Frame.Shadow.PeakBytes >> 10} KB）、同段未变跳过 {Frame.SameSkips} 次（校验不符 {Frame.SameSkipMiss}）、相机签名变过 {Frame.Rewriter.CameraVersion} 次；红：{Red}";

        internal uint NewTexId() => (uint)Interlocked.Increment(ref _nextTex);
        internal WidenTexture Wrap(ITexture t, uint id, int w0, WidenTexture parent = null, float resolutionScale = 1f) => t == null ? null : new WidenTexture(this, t, id, w0, parent, resolutionScale);
        /// <summary>取底层贴图；target = 这次是 GPU 往里写（渲染目标 / 拷贝目标 / 图像存储），否则是读（采样 / 拷贝源 / 上屏）。首次用时定放宽贴图的去留（见 WidenTexture.Resolve）。</summary>
        internal static ITexture U(ITexture t, bool target = false) { if (t is WidenTexture w) { if (target) w.Root.GpuWritten = true; w.Resolve(target); return w.Inner; } return t; }
        /// <summary>当渲染目标 / 存储图像用（GPU 往里画）：同 U(t, true)，另外把「先被读、换回原宽」的贴图重新放宽（见 WidenTexture.Rewiden）。拷贝目标不走这里。</summary>
        internal static ITexture URt(ITexture t) { if (t is WidenTexture w) { w.Root.GpuWritten = true; w.Resolve(true); w.Rewiden(); return w.Inner; } return t; }
        // 16:9 原比例页（10-20 jhz 拍板：游戏自己画死 16:9、没有更宽内容可补的页面留黑边原比例，满屏判据认它合格）：本帧画了「整画布 16:9 图片」且那张图从没被 GPU 写过
        // （纯 CPU 供图：标题图 / 视频帧）时记下帧号，上屏前告诉出图层（nxgal_present_pillar，graphics/metal/gal_present.m 内容判据据此不报红）。
        // 整画布图片是 GPU 画出来的目标（真该宽没宽）不记，出图层照样报红。真值 Ryujinx 里没有出图层（nxgal 库），第一次调不到就停
        internal long PillarFrame = -1; internal int PicGpuLog;
        /// <summary>最近一次上屏告诉出图层的种类（0 照常判 / 1 原比例页 / 2 两侧是放宽内容画的）：CPU 回放（widen_scanbench --bands）逐帧读。</summary>
        public int LastPillar;
        /// <summary>整局 16:9 原比例居中（屏幕比宽、但第二层没生效且第三层没验过）：每帧告诉出图层是原比例页，两侧黑边不算未满屏。</summary>
        public bool PillarAll;
        /// <summary>游戏界面布局也是宽的（原生层 s2a_widen_layout，见 WidenFrame.LayoutWide）。</summary>
        public bool LayoutWide { get => Frame.LayoutWide; set => Frame.LayoutWide = value; }
        static bool s_noPillarSink;
        [DllImport("nxgal")] static extern void nxgal_present_pillar(int on);
        /// <summary>kind：0 = 照常判；1 = 16:9 原比例页；2 = 两侧是放宽内容画出来的（见 WidenTexture.Bands）——两种都不判未满屏，出图层按种类记日志。</summary>
        internal static void NotePillar(int kind)
        {
            if (s_noPillarSink) return;
            try { nxgal_present_pillar(kind); } catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { s_noPillarSink = true; }
        }
        internal int Unwidened;   // 放宽贴图首次被读之前收到 CPU 上传、换回原宽的张数
        internal int Rewidened;   // 换回原宽之后又被当渲染目标 / 存储图像、重新放宽的张数
        internal int LayerWidenedTex;   // 画面分层图集按需放宽的张数（WidenTexture.ForceWiden）
        // 重新放宽换了底层贴图：之前绑着它采样的槽要重发（Ryujinx 只在绑定的贴图对象变化时才重发，包装对象没变，后端还拿着已释放的原宽贴图）
        internal void RebindSampled(WidenTexture t) => _pipe?.Rebind(t);
        /// <summary>诊断（galplay --cbuf）：当前绘制某个常量绑定的缓冲 / 区间；没绑返回 false。</summary>
        public bool TryUniform(int binding, out ulong buffer, out int offset, out int size) { buffer = 0; offset = size = 0; return _pipe != null && _pipe.TryUniform(binding, out buffer, out offset, out size); }
        /// <summary>诊断：当前绘制片元各采样绑定的贴图号与尺寸。</summary>
        public string FragmentTextures() => _pipe?.FragmentTextures() ?? "";
        internal long PicDraws; internal int PicLog;   // 16:9 原比例页（S2A_WIDEN_PIC）登记次数（原生宽目标上为整画布 16:9 图片命中次数）
        internal long ShadowCopies, PresentPages;
        internal long WidenedUploads;   // 放宽贴图收到原宽整张 CPU 上传、横向按 k 拷进去的次数
        internal long NarrowSkipped;   // 放宽贴图读回时缩不回原宽、原样读的次数
        internal long SideClears;   // 放宽颜色目标两侧条带清黑次数（每个游戏帧每张最多一次）
        // 游戏帧边界按命令流里的写入顺序认，不按上屏次数（10-21 马车8 比赛：上屏调用常落在下一帧场景画到一半时，按上屏次数分帧会把同一游戏帧里
        // 已画好两侧的场景目标再清一次黑——之后的半透明遍盖不回来，整帧场景只剩中间 16:9 + 两侧泛光）：
        // WriteSeq = 全局写入序号（绘制 / 清屏 / 拷入各 +1）；FrameStartSeq = 最近一次写进上屏贴图（交换链）的序号 = 上一游戏帧收尾的合成。
        // 一张贴图最近一次写入早于它 = 本游戏帧还没写过它
        internal long WriteSeq, FrameStartSeq;
        internal void NoteWrite(WidenTexture t)
        {
            WidenTexture r = t.Root; r.LastWriteSeq = ++WriteSeq;
            if (r.Presented) FrameStartSeq = WriteSeq;
        }
        internal bool FirstWriteThisFrame(WidenTexture t) => t.Root.LastWriteSeq < FrameStartSeq;
        internal static ulong Key(BufferHandle h) => Unsafe.As<BufferHandle, ulong>(ref h);

        // ---------- 宽屏要拦的 ----------
        public ITexture CreateTexture(TextureCreateInfo info) => CreateTexture(info, 1f);

        public ITexture CreateTexture(TextureCreateInfo info, float resolutionScale)
        {
            if (!(resolutionScale > 0f) || !float.IsFinite(resolutionScale)) throw new ArgumentOutOfRangeException(nameof(resolutionScale));
            uint id = NewTexId();
            int w1 = Frame.OnCreateTexture(id, info.Width, info.Height, resolutionScale);
            var t = Wrap(Inner.CreateTexture(w1 == info.Width ? info : WithWidth(info, w1)), id, info.Width, resolutionScale: resolutionScale);
            if (t != null && w1 != info.Width) t.Native = t.Guest = info;   // 放宽了：记下原尺寸建法，首次用之前收到 CPU 上传时暂存进原宽副本
            else if (t != null && info.Target == Target.Texture2D && info.Depth == 1 && info.Samples == 1 && !info.Format.IsDepthOrStencil) t.Made = info;   // 没放宽的单层 2D 颜色图：留建法，画面分层图集按需放宽（ForceWiden）
            return t;
        }

        internal static TextureCreateInfo WithWidth(in TextureCreateInfo i, int w) => new(w, i.Height, i.Depth, i.Levels, i.Samples, i.BlockWidth, i.BlockHeight, i.BytesPerPixel,
            i.Format, i.DepthStencilMode, i.Target, i.SwizzleR, i.SwizzleG, i.SwizzleB, i.SwizzleA);

        // ---------- 上传租约（帧率能耗线 10-22，方案 B）：租 / 退直接交内层；租约写缓冲先做与 SetBufferData 相同的检查与帧影子，改写过就写回租约再往下传 ----------
        public bool S2ATryRentUpload(int size, out S2AUploadLease lease) => Inner.S2ATryRentUpload(size, out lease);
        public void S2ADropUpload(S2AUploadLease lease) => Inner.S2ADropUpload(lease);
        public void S2ASetBufferData(BufferHandle buffer, int offset, S2AUploadLease lease)
        {
            Span<byte> data = lease.Span;
            NoteSupportWrite(buffer, offset, data);
            byte[] s = t_scratch ??= new byte[ScratchBytes];
            if (data.Length <= s.Length)
            {
                if (Frame.OnBufferData(Key(buffer), offset, data, s)) s.AsSpan(0, data.Length).CopyTo(data);   // 改写值叠在暂存里，拷回租约再发（src 与 dst 不能是同一块：ScanStraddle 要原值）
                Inner.S2ASetBufferData(buffer, offset, lease);
            }
            else
            {
                Frame.OnBufferData(Key(buffer), offset, data, default, null);   // 先扫描登记（租约交出去后内存就还了，不能再读）
                Inner.S2ASetBufferData(buffer, offset, lease);
                Frame.WriteHits(Key(buffer), offset, data.Length, this);        // 命中处补写改写值（取自影子，不读租约；排在租约上传之后）
            }
        }

        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data)
        {
            NoteSupportWrite(buffer, offset, data);
            // 临时缓冲定长（10-22 巫师3 换场景：按上传大小长的临时缓冲一帧分配约 44 MB）：装得下的叠好改写值一次发；装不下的大上传先原样发，命中处由帧层逐段补写
            byte[] s = t_scratch ??= new byte[ScratchBytes];
            if (data.Length <= s.Length)
            {
                if (Frame.OnBufferData(Key(buffer), offset, data, s)) Inner.SetBufferData(buffer, offset, s.AsSpan(0, data.Length));
                else Inner.SetBufferData(buffer, offset, data);
            }
            else { Inner.SetBufferData(buffer, offset, data); Frame.OnBufferData(Key(buffer), offset, data, default, this); }
        }

        // 支持缓冲的外部写跟踪（SetBufferData / S2ASetBufferData 共用）：Ryujinx 写了 render_scale[0] / render_scale[1..] / s2a_widen 推远与收缩字段时记下它写的值
        void NoteSupportWrite(BufferHandle buffer, int offset, ReadOnlySpan<byte> data)
        {
            if (SupportScaleAt >= 0 && Key(buffer) == SupportBuf && offset <= SupportScaleAt && SupportScaleAt + 4 <= offset + data.Length)
                SupportBaseScale = SupportScaleNow = System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(data[(SupportScaleAt - offset)..]);
            if (SupportScaleAt >= 0 && Key(buffer) == SupportBuf && offset < SupportScaleAt + 16 * SupportTexScale.Length && SupportScaleAt + 16 < offset + data.Length)   // Ryujinx 写了 render_scale[1..]：记它写的值
                for (int i = Math.Max(1, (offset - SupportScaleAt + 15) >> 4); i < SupportTexScale.Length && SupportScaleAt + 16 * i + 4 <= offset + data.Length; i++)
                    if (SupportScaleAt + 16 * i >= offset) SupportBaseTexScale[i] = SupportTexScale[i] = System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(data[(SupportScaleAt + 16 * i - offset)..]);
            if (SupportPushAt >= 0 && Key(buffer) == SupportBuf && offset < SupportPushAt + 16 && SupportPushAt < offset + data.Length)   // 别人（Ryujinx 整段上传支持缓冲）连带写了这 16 字节
            {
                bool all = offset <= SupportPushAt && SupportPushAt + 16 <= offset + data.Length;
                SupportPushNow = all ? System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(data[(SupportPushAt - offset)..]) : float.NaN;
                SupportThrNow = all ? System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(data[(SupportPushAt + 4 - offset)..]) : float.NaN;
                SupportShrinkNow = all ? System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(data[(SupportPushAt + 8 - offset)..]) : float.NaN;
                SupportPadNow = all ? System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(data[(SupportPushAt + 12 - offset)..]) : float.NaN;
            }
        }

        void IBufferPatcher.Write(ulong buffer, int offset, ReadOnlySpan<byte> data) => Inner.SetBufferData(Unsafe.As<ulong, BufferHandle>(ref buffer), offset, data);

        public void DeleteBuffer(BufferHandle buffer) { Frame.OnDeleteBuffer(Key(buffer)); Cam.OnDeleteBuffer(Key(buffer)); Inner.DeleteBuffer(buffer); }

        /// <summary>着色器改写（运行时与出包离线预编同一份：WidenShaders）：所有程序一律改，与屏幕无关。fragY = 片元 y 改了几处，push = 顶点改没改，
        /// scales / realPx = 片元取图缩放项、要不要按真实像素坐标画（SpirvFetchScale）。</summary>
        public static ShaderSource[] TransformShaders(ShaderSource[] shaders, out int fragY, out bool push, out (int Index, int Binding, bool Image)[] scales, out bool realPx,
            out (int Index, int Binding)[] extrap, bool allowExtrap)
        {
            ShaderSource[] src = shaders; fragY = 0; push = false; scales = Array.Empty<(int, int, bool)>(); realPx = false; extrap = null;
            bool fx = false; (int, int)[] es = null;
            for (int i = 0; i < shaders.Length; i++)
            {
                ShaderSource s = shaders[i];
                if (s.BinaryCode == null || s.Language != TargetLanguage.Spirv) continue;
                byte[] b = s.BinaryCode;
                if (s.Stage == ShaderStage.Fragment) { b = WidenShaders.Fragment(s.BinaryCode, allowExtrap, out int yp, out scales, out bool exact, out fx, out es); fragY += yp; realPx = !exact; }
                else if (s.Stage == ShaderStage.Vertex) { b = WidenShaders.Vertex(s.BinaryCode, out bool pv); push |= pv; }
                if (ReferenceEquals(b, s.BinaryCode)) continue;
                if (src == shaders) src = (ShaderSource[])shaders.Clone();
                src[i] = new ShaderSource(b, s.Stage, s.Language);
            }
            if (fx && push) extrap = es;
            return src;
        }

        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info)
        {
            ShaderSource[] src = TransformShaders(shaders, out int yp, out bool push, out var scales, out bool realPx, out var extrap, !Frame.GameWide);
            IProgram ip = Inner.CreateProgram(src, info);
            if (ip == null) return ip;
            var p = new WidenProgram(ip);
            if (extrap != null)
            {
                p.Extrap = extrap; Interlocked.Increment(ref ExtrapPrograms);
                foreach (ShaderSource s in shaders) if (s.Stage == ShaderStage.Vertex && s.BinaryCode != null && s.Language == TargetLanguage.Spirv) p.PosFromSpirv(s.BinaryCode);
            }
            NoteImages(p, info);
            FragYPatched += yp;
            if (yp > 0) p.FragY = true;
            if (realPx) p.RealPx = true;
            if (scales.Length > 0) p.Scales = scales;
            var tex = new List<int>();
            foreach (ShaderSource f in src) if (f.Stage == ShaderStage.Fragment && f.BinaryCode != null && f.Language == TargetLanguage.Spirv) tex.AddRange(SpirvEdgePush.SampledBindings(f.BinaryCode));
            p.Sampled = tex.ToArray();
            var vtex = new List<int>();
            foreach (ShaderSource v in src) if (v.Stage == ShaderStage.Vertex && v.BinaryCode != null && v.Language == TargetLanguage.Spirv) vtex.AddRange(SpirvEdgePush.SampledBindings(v.BinaryCode));
            p.VSampled = vtex.ToArray();
            if (push) { PushPatched++; p.Push = tex.ToArray(); }
            var uses = new List<CbufUse>(); bool any = false;
            foreach (ShaderSource s in shaders)
            {
                if (s.BinaryCode == null || s.Language != TargetLanguage.Spirv) continue;
                any = true;
                if (SpirvCbufUse.Analyze(s.BinaryCode) is { } u) uses.AddRange(u);
            }
            if (!any) Red.ProgramNoSpirv++;
            p.Uses = uses.ToArray();
            return p;
        }

        // 着色器包里的宽屏元数据（shaders/widen.idx，出包时 graphics/tools/shbake 写）：程序二进制没有 SPIR-V，按各阶段记录的键查读法 / 片元 y / 外推 / 采样绑定
        WidenIdxTable _widx; bool _widxTried; readonly object _widxLock = new();   // Ryujinx 磁盘缓存可能多线程并行载程序
        internal long BinaryMeta, BinaryNoMeta;
        PosFile _pidx; bool _pidxTried;
        PosFile PosIdx()
        {
            lock (_widxLock)
            {
                if (_pidxTried) return _pidx; _pidxTried = true;
                string p = Environment.GetEnvironmentVariable("S2A_WIDEN_IDX");
                if (string.IsNullOrEmpty(p) && Environment.GetEnvironmentVariable("S2A_GAME_DATA") is string gd && gd.Length > 0) p = System.IO.Path.Combine(gd, "shaders", WidenIndex.FileName);
                string pp = string.IsNullOrEmpty(p) ? null : System.IO.Path.Combine(System.IO.Path.GetDirectoryName(p) ?? ".", PosFile.FileName);
                try { _pidx = PosFile.Open(pp); } catch (Exception e) { Console.Error.WriteLine($"[宽屏] 【红】读 {pp} 失败：{e.Message}"); }
                Console.Error.WriteLine(_pidx != null ? $"[宽屏] 外推写侧位置切片 {_pidx.Count} 支（{pp}）" : $"[宽屏] 没有外推写侧位置切片（{pp}）：二进制程序的几何一律按铺满");
                return _pidx;
            }
        }
        WidenIdxTable WidenIdx()
        {
            lock (_widxLock) { if (!_widxTried) { _widx = LoadWidenIdx(); _widxTried = true; } return _widx; }
        }
        static WidenIdxTable LoadWidenIdx()
        {
            WidenIdxTable _widx;
            string p = Environment.GetEnvironmentVariable("S2A_WIDEN_IDX");
            if (string.IsNullOrEmpty(p) && Environment.GetEnvironmentVariable("S2A_GAME_DATA") is string gd && gd.Length > 0) p = System.IO.Path.Combine(gd, "shaders", WidenIndex.FileName);
            try { _widx = WidenIndex.Read(p); } catch (Exception e) { Console.Error.WriteLine($"[宽屏] 【红】读 {p} 失败：{e.Message}"); _widx = null; }
            Console.Error.WriteLine(_widx != null ? $"[宽屏] 着色器包宽屏元数据 {_widx.Count} 条（{p}）" : $"[宽屏] 没有着色器包宽屏元数据（{p}）：程序二进制按「读法未知」处理");
            return _widx;
        }

        public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info)
        {
            IProgram ip = Inner.LoadProgramBinary(programBinary, hasFragmentShader, info);
            // 加载失败的占位对象要原样交回：上层靠它的类型识别失败并重新编译，包一层就看不出来了。
            if (ip == null || ip is IProgramBinaryLoadFailure { ProgramBinaryLoadFailure: not null }) return ip;
            var p = new WidenProgram(ip);
            NoteImages(p, info);
            var idx = WidenIdx(); var metas = new List<WidenStageMeta>(); var keys = new List<ulong>(6);
            if (idx != null && WidenIndex.BinaryKeys(programBinary, keys))
                foreach (ulong k in keys) { if (idx.TryGetValue(k, out WidenStageMeta m)) metas.Add(m); else { metas.Clear(); break; } }
            if (metas.Count == 0) { Interlocked.Increment(ref Red.ProgramNoSpirv); Interlocked.Increment(ref BinaryNoMeta); return p; }   // 没有元数据：读法未知，界面层按「没读到改写矩阵」处理
            Interlocked.Increment(ref BinaryMeta);
            var uses = new List<CbufUse>(); var tex = new List<int>(); var scl = new List<(int, int, bool)>(); bool push = false, realPx = false, imgKnown = true, fx = false; int fy = 0; var imgs = new List<int>();
            var es = new List<(int, int)>();
            var vtx = new List<int>(); bool vKnown = false;
            foreach (WidenStageMeta m in metas) { uses.AddRange(m.Uses); if (m.Stage == (int)ShaderStage.Vertex) { vtx.AddRange(m.Sampled); vKnown |= m.Sampled.Length > 0; } else tex.AddRange(m.Sampled); scl.AddRange(m.Scales); push |= m.Push; realPx |= m.RealPx; fy += m.FragY; if (m.Images == null) imgKnown = false; else imgs.AddRange(m.Images); fx |= m.Extrap; es.AddRange(m.ExtrapSamples); }
            if (fx && push)
            {
                p.Extrap = es.ToArray(); Interlocked.Increment(ref ExtrapPrograms);
                for (int i = 0; i < metas.Count; i++) if (metas[i].Stage == (int)ShaderStage.Vertex && PosIdx() is { } pf && pf.Has(keys[i])) p.PosFromFile(pf, keys[i]);
            }
            // 程序二进制的 ShaderInfo 资源表是空集合（NoteImages 登记成「不写任何图像」）：用的图像按元数据（出包时从 SPIR-V 取）重登；旧包没有 = 不知道，按全部已绑图像算
            if (imgKnown) p.Images = imgs.ToArray(); else p.Images = null;
            if (realPx) p.RealPx = true;
            if (scl.Count > 0) p.Scales = scl.ToArray();
            p.Uses = uses.ToArray();
            if (fy > 0) { p.FragY = true; Interlocked.Add(ref FragYPatched, fy); }
            p.Sampled = tex.ToArray();
            if (vKnown) p.VSampled = vtx.ToArray();
            if (push) { p.Push = tex.ToArray(); Interlocked.Increment(ref PushPatched); }
            return p;
        }

        void NoteImages(WidenProgram p, ShaderInfo info)
        {
            if (info.ResourceLayout.SetUsages == null) return;
            var b = new List<int>();
            foreach (ResourceUsageCollection set in info.ResourceLayout.SetUsages)
                if (set.Usages != null)
                    foreach (ResourceUsage u in set.Usages)
                        if (u.Type is ResourceType.Image or ResourceType.BufferImage) b.Add(u.Binding);
            p.Images = b.ToArray();
        }

        public ITextureArray CreateTextureArray(int size, bool isBuffer) => new WidenTextureArray(Inner.CreateTextureArray(size, isBuffer));
        public IImageArray CreateImageArray(int size, bool isBuffer) => new WidenImageArray(Inner.CreateImageArray(size, isBuffer));

        // ---------- 直通 ----------
        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add => Inner.ScreenCaptured += value; remove => Inner.ScreenCaptured -= value; }
        public bool PreferThreading => Inner.PreferThreading;
        public IPipeline Pipeline => _pipe ??= Inner.Pipeline is { } p ? new WidenPipeline(this, p) : null;   // 同 Window：Vulkan 的管线在 Initialize 之后才有
        // 用到时再包：Vulkan 等后端的窗口在 Initialize 之后才有（构造时 Inner.Window 为空，10-20 宽屏真值 Ryujinx 撞到）
        public IWindow Window => _win ??= Inner.Window is { } w ? new WidenWindow(this, w) : null;
        public uint ProgramCount => Inner.ProgramCount;
        public void BackgroundContextAction(Action action, bool alwaysBackground = false) => Inner.BackgroundContextAction(action, alwaysBackground);
        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => Inner.CreateBuffer(size, access);
        public BufferHandle CreateBuffer(nint pointer, int size) => Inner.CreateBuffer(pointer, size);
        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => Inner.CreateBufferSparse(storageBuffers);
        public ISampler CreateSampler(SamplerCreateInfo info)
        {
            ISampler sm = Inner.CreateSampler(info);
            if (sm != null) { SmpU.AddOrUpdate(sm, info.AddressU); if (info.AddressU is AddressMode.Repeat or AddressMode.MirroredRepeat) TilingU.AddOrUpdate(sm, null); }   // 横向平铺采样器：整画布 16:9 图片判据排除它（外推不看它，见 OnlySmall）
            return sm;
        }
        internal readonly ConditionalWeakTable<ISampler, object> TilingU = new();
        internal readonly ConditionalWeakTable<ISampler, object> SmpU = new();   // 诊断：采样器横向寻址方式
        internal int EdgeLogPush;   // 外推判定诊断：外推前 16 次各一行；跳过按「贴图尺寸 + 横向寻址」去重，最多 40 种
        internal readonly HashSet<(int, int, int)> EdgeSkipSeen = new();   // 键全是整数：判过的组合再遇到时零分配
        public bool PrepareHostMapping(nint address, ulong size) => Inner.PrepareHostMapping(address, size);
        public void CreateSync(ulong id, bool strict) => Inner.CreateSync(id, strict);
        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => Inner.GetBufferData(buffer, offset, size);
        public Capabilities GetCapabilities() => Inner.GetCapabilities();
        public ulong GetCurrentSync() => Inner.GetCurrentSync();
        public HardwareInfo GetHardwareInfo() => Inner.GetHardwareInfo();
        public void UpdateCounters() => Inner.UpdateCounters();
        public void PreFrame() => Inner.PreFrame();
        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => Inner.ReportCounter(type, resultHandler, divisor, hostReserved);
        public void ResetCounter(CounterType type) => Inner.ResetCounter(type);
        public void RunLoop(ThreadStart gpuLoop) => Inner.RunLoop(gpuLoop);
        public void WaitSync(ulong id) => Inner.WaitSync(id);
        public void Initialize(GraphicsDebugLevel logLevel) => Inner.Initialize(logLevel);
        public void SetInterruptAction(Action<Action> interruptAction) => Inner.SetInterruptAction(interruptAction);
        public void Screenshot() => Inner.Screenshot();
        public void Dispose() => Inner.Dispose();
    }

    public sealed class WidenTexture : ITexture
    {
        readonly WidenRenderer _r;
        public ITexture Inner { get; private set; }
        public readonly uint Id;
        readonly int _w0;
        internal TextureCreateInfo? Native;   // 放宽建的才有：原尺寸建法
        bool _used;                           // 首次用过：之后不再换底层贴图
        internal long LastWriteSeq = -1;      // （记在 Root 上）最近一次被写的全局写入序号（WidenRenderer.NoteWrite）
        internal bool Presented;              // （记在 Root 上）上过屏（交换链）：写它就是游戏帧收尾
        internal readonly WidenTexture Root;  // 视图记到父贴图上：存储是同一块
        public float ResolutionScale { get; }
        internal bool GpuWritten;             // （记在 Root 上）当过渲染目标 / 拷贝目标 / 存储图像：内容是 GPU 画的，不是 CPU 供图
        ITexture _pending;                    // 首次用之前收到的 CPU 上传暂存在这张原宽副本里
        TextureCreateInfo? _wideInfo;         // 换回原宽时记下放宽建法：之后被当渲染目标 / 存储图像就按它重新放宽（Rewiden）；建过视图后作废（视图共用原宽存储）
        internal TextureCreateInfo? Guest;    // 放宽登记的才有：客体（原宽）建法——原比例页被采样时按它建中间区副本
        // 内容来历（记在 Root 上）：Gen 每次被画 / 清 / 拷入 +1；PageContent = 现在的内容是 16:9 原比例页（原尺寸画在 [PageX0+s, PageX0+PageW+s)、两侧黑），
        // PageCertified = 页的来源全是 CPU 供图（或认证过的页）——出图层据此认原比例页、不报未满屏
        internal long Gen; internal bool PageContent, PageCertified; internal int PageX0, PageW; internal double PageShift;
        // Bands（记在 Root 上，10-21 马车8 比赛前读盘页）：现在的内容两侧是放宽内容——清屏后被铺满画布的 Hor 绘制（读了改写过的镜头矩阵）画过，
        // 或被采样了带此标记贴图的铺满画布 ScaleK 全屏遍画过；整张拷入随内容带过去，清屏作废。按内容记、不按帧号：交换链图是前 2–3 帧画的。
        // 上屏贴图带标记 = 两侧黑是游戏画的（转场把放宽后的场景压黑、读盘遮盖层只盖 16:9 画布），出图层不判未满屏。场景被当界面居中画时两侧只被清过、没有标记，照样报红
        internal bool Bands;
        // Scene3D（记在 Root 上，10-22 塞尔达标题页）：现在的内容里有 3D 场景——被开了深度测试 / 深度写的绘制画过，或被采样了带此标记贴图的绘制画过、
        // 整张拷入随内容带过去、计算着色器写过（保守），清屏 / CPU 上传作废。游戏自己出宽图（GameWide）时上屏贴图不带它 = 这一帧全是 2D 合成
        // （标题 / 菜单 / 读盘页），排版归游戏：两侧黑不黑都是游戏的设计（塞尔达标题：16:9 原画居中、菜单衬底贴右缘），出图层不判未满屏；有 3D 场景的帧照判。
        internal bool Scene3D;
        // CamContent（记在 Root 上，10-22 巫师3 读盘页）：现在的内容里有读到改写镜头矩阵的绘制画的东西——放宽目标上读了改写矩阵的绘制 / 派发画过，或被采样了带此标记贴图的绘制 / 派发画过，
        // 整张拷入随内容带过去，清屏 / CPU 上传作废。上屏的放宽贴图不带它 = 这一帧没有可扩视野的内容（读盘原画是图集取块、界面层原尺寸居中，底下场景是清空的）：
        // 两侧黑是「没得补就留黑边」，出图层不判未满屏；有镜头内容的帧照判（场景认出了镜头却画窄的真问题照样抓）
        internal bool CamContent;
        // Stretched（记在 Root 上，10-22 原画框外推）：现在的内容里有按「拉伸」画进放宽目标的东西——放宽目标上 ScaleK 且没按原画框外推的绘制画过（铺满画布的画完即整张算，
        // 不铺满的只置不清）；铺满画布的外推 / Hor 绘制画过即作废，整张拷入随内容带过去。外推绘制采样带它的贴图 = 放宽贴图内容不是居中排布，平移换算会错位（诊断计数）
        internal bool Stretched;
        // Extended（记在 Root 上，10-23 原画框外推写侧来历）：现在的内容在 16:9 原画框外是「原画框的外延」——被几何铺满画布的外推绘制 / 读改写镜头的 Hor 绘制 /
        // 计算派发 / 整张清屏写过；被拉伸画（ScaleK 没外推）或只盖住画布一部分的绘制写过即否；整张拷入随内容带过去。外推绘制采样了否的放宽贴图 = 框外是别的东西
        // （图集邻块），这一笔不外推、按拉伸画
        internal bool Extended;
        internal long NonExtSince = -1;   // 从哪一帧起一直「框外不是外延」（Extended 置否时记、置是时清；跨帧持续的传染链计数用）
        // （记在 Root 上）原生宽目标上整画布 16:9 图片居中时两侧清黑：最近一次清的全局写入序号（每个游戏帧最多一次，见 ClearPictureSides）
        internal long PicSidesSeq = -1;
        // （记在 Root 上，GameWide 用）现在的内容 = CPU 供图经 GPU 转一手铺满整张（视频 YUV 平面 → RGB 帧）：最近一次写它的是铺满整张、只采样 CPU 供图 / 同类贴图的绘制，
        // 或整张拷入同类贴图；清屏、其他绘制、区域拷入都作废。整画布 16:9 图片按它与「从没被 GPU 写过」一样算 CPU 供图（10-22 怪猎开场 logo 视频帧 1280×720 由 GPU 转出）
        internal bool PicContent;
        // （记在 Root 上，GameWide 用）现在的内容是原生宽目标上原尺寸居中、两侧清黑的整画布 16:9 CPU 供图页（ClearPictureSides 那次绘制起），随采样 / 整张拷贝传到交换链：
        // 上屏贴图带它 = 原比例页（出图层不判未满屏）。按内容记、不按帧号：游戏 30 帧视频常把同一张交换链图上屏两次、中间那次本帧没画图片（10-22 怪猎开场按帧号漏标、报未满屏）。
        // 本游戏帧第一次写它、清屏、区域拷入都作废
        internal bool PicPage;
        ITexture _shadow; long _shadowGen = -1;   // 原比例页被采样时绑这张原宽副本（页的中间区原样拷过来），采样坐标与 16:9 原图一致
        internal WidenTexture(WidenRenderer r, ITexture inner, uint id, int w0, WidenTexture parent = null, float resolutionScale = 1f) { _r = r; Inner = inner; Id = id; _w0 = w0; Root = parent?.Root ?? this; ResolutionScale = parent?.ResolutionScale ?? resolutionScale; }
        bool Wide => _r.Frame.IsWide(Id);

        // 放宽贴图首次用之前收到 CPU 上传：内容是原尺寸的图，先暂存进原宽副本。首次用时定去留——
        //   GPU 往里写（渲染目标 / 拷贝目标 / 图像存储）：是渲染目标，Ryujinx 建它时把客体内存初始内容传了一遍，丢掉副本、保持放宽（同以前跳过）；
        //   先被读（采样 / 拷贝源 / 上屏）：是 CPU 供图（10-20 马车8 标题背景 1920×1080 三张，放宽后上传被跳过 → 背景全黑、两侧没初始化的显存），换成原宽副本。
        // 只按首次用途判、不按格式猜（同一局里 R11G11B10 / R16 的渲染目标也收到过初始上传）。
        internal void Resolve(bool target)
        {
            if (_used) return;
            _used = true;
            if (target) { _pending?.Release(); _pending = null; return; }
            if (_pending == null) return;
            _wideInfo = Native is { } ni && _r.Frame.TryWide(Id, out _, out int ww1) ? WidenRenderer.WithWidth(ni, ww1) : null;
            Inner.Release(); Inner = _pending; _pending = null; Native = null;
            _r.Frame.OnReleaseTexture(Id);
            int n = Interlocked.Increment(ref _r.Unwidened);
            if (n <= 8) Console.Error.WriteLine($"[宽屏] 贴图 {Inner.Width}×{Inner.Height} 首次用之前收到 CPU 上传、先被读：换回原宽（第 {n} 张）");
        }
        // 先被读、换回原宽的贴图后来被 GPU 当渲染目标 / 存储图像画：它是渲染目标，不是 CPU 供图——首次读只是游戏先采样了还没画过的那张
        // （10-20 巫师3 / 暗黑2 交换链：轮到的那张缓冲在第一次被画之前先被采样，换回原宽后永远 1280×720，出图在 1564 / 1280 两种尺寸间每帧来回切，
        //  满屏判据跟着每帧「未满屏 / 恢复满屏」翻）。重新按放宽尺寸建、登记回放宽一族，原宽里已有的内容按横向放宽比拷过去（与 ScaleK 视口同一换算），只做一次。
        // 只认渲染目标 / 存储图像（URt）：拷贝目标、建视图不算——CPU 供图的整画布 16:9 图片（马车8 标题图）不会因此被重新放宽。
        internal TextureCreateInfo? Made;   // 没放宽的单层 2D 颜色图的建法（ForceWiden 用）
        // 画面分层图集按需放宽（见 WidenFrame.LayerWiden）：第一次被读宽外延内容的绘制当目标时调；尺寸关系不符 / 不是根贴图返回 false。
        // 原有内容按横向放宽比拷过去（同 Rewiden），只做一次
        internal bool ForceWiden()
        {
            if (Root != this || Made is not { } mi || _r.Frame.IsWide(Id)) return false;
            Made = null;
            int w1 = _r.Frame.LayerWiden(Id, mi.Width, mi.Height, ResolutionScale);
            if (w1 == mi.Width) return false;
            ITexture wide = _r.Inner.CreateTexture(WidenRenderer.WithWidth(mi, w1));
            if (wide == null) { _r.Frame.OnReleaseTexture(Id); return false; }
            Inner.CopyTo(wide, new Extents2D(0, 0, mi.Width, mi.Height), new Extents2D(0, 0, w1, mi.Height), true);
            Inner.Release(); Inner = wide; Guest = mi;
            _r.RebindSampled(this);
            int n = Interlocked.Increment(ref _r.LayerWidenedTex);
            if (n <= 8) Console.Error.WriteLine($"[宽屏] 画面分层图集 {mi.Width}×{mi.Height} 被读宽外延内容的绘制当目标：放宽到 {w1}×{mi.Height}（第 {n} 张）");
            return true;
        }
        internal void Rewiden()
        {
            if (_wideInfo is not { } wi) return;
            _wideInfo = null;
            int h = Inner.Height;
            int w1 = _r.Frame.OnCreateTexture(Id, _w0, h, ResolutionScale);
            if (w1 != wi.Width) { _r.Frame.OnReleaseTexture(Id); return; }
            ITexture wide = _r.Inner.CreateTexture(wi);
            if (wide == null) { _r.Frame.OnReleaseTexture(Id); return; }
            Inner.CopyTo(wide, new Extents2D(0, 0, _w0, h), new Extents2D(0, 0, w1, h), true);
            Inner.Release(); Inner = wide;
            _r.RebindSampled(this);
            int n = Interlocked.Increment(ref _r.Rewidened);
            if (n <= 8) Console.Error.WriteLine($"[宽屏] 贴图 {_w0}×{h} 先被读换回原宽、后来当渲染目标：重新放宽到 {w1}×{h}（第 {n} 张）");
        }
        ITexture Pending()
        {
            if (_used || Native is not { } info) return null;
            return _pending ??= _r.Inner.CreateTexture(info);
        }

        /// <summary>采样用的底层贴图：内容是原比例页的放宽贴图给原宽副本（页的中间区 1:1 拷过来，内容变了才重拷），采样坐标与 16:9 原图一致——
        /// 后面的合成 / 缩略图读到的就是原图（10-21 巫师3 视频：Y/U/V 平面是原比例页，合成程序采样放宽平面时两侧读到 0 → 粉色带、中间错位）。其余返回 Inner。</summary>
        internal ITexture ForSampling()
        {
            WidenTexture r = Root;
            if (!r.PageContent || Guest is not { } gi || !_r.Frame.TryWide(Id, out int w0, out _) || r.PageW <= 0 || r.PageX0 + r.PageW > w0) return Inner;
            if (_shadow == null && (_shadow = _r.Inner.CreateTexture(gi)) == null) return Inner;
            if (_shadowGen != r.Gen)
            {
                _shadowGen = r.Gen;
                int h = Inner.Height, sx = (int)Math.Round(r.PageX0 + r.PageShift);
                Inner.CopyTo(_shadow, new Extents2D(sx, 0, sx + r.PageW, h), new Extents2D(r.PageX0, 0, r.PageX0 + r.PageW, h), false);
                _r.ShadowCopies++;
            }
            return _shadow;
        }

        /// <summary>上屏一张还没定去留、首次用之前收到过 CPU 上传的放宽贴图（交换链第一次出图早于第一次被画，10-21 暗黑2 / 丝之歌录像序章）：
        /// 上屏不说明内容来历（不是采样也不是 GPU 往里画），不定去留——把暂存的 CPU 内容按 16:9 原比例页放进放宽贴图（原尺寸居中在裁剪区里、两侧黑），
        /// 照放宽尺寸上屏，出图参数与之后游戏画进来的帧相同。之后首次被画 → 丢副本保持放宽；首次被采样 → 照旧换成原宽副本。返回 false = 不是这种情况。</summary>
        internal bool PresentUndecided(in ImageCrop crop)
        {
            if (_used || _pending == null || Guest is not { } gi || !_r.Frame.TryWide(Id, out _, out int w1)) return false;
            int h = Inner.Height, cl = crop.Left != 0 || crop.Right != 0 ? crop.Left : 0, cr = crop.Left != 0 || crop.Right != 0 ? crop.Right : _w0;
            if (cr <= cl) return false;
            double s = _r.Frame.PageShift(Id, cl, cr - cl); int si = (int)Math.Round(s), n = Math.Min(_w0, w1 - si);
            if (si < 0 || n <= 0) return false;
            _pending.CopyTo(Inner, new Extents2D(0, 0, n, h), new Extents2D(si, 0, si + n, h), false);
            // 两侧黑：页面放宽区 [cl·k, cr·k) 减内容区 [cl+s, cr+s)。用一张 1×1 全 0 的同格式贴图放大拷过去（不动游戏的渲染目标 / 剪裁状态）
            int m0 = _r.Frame.MapX(Id, cl), m1 = _r.Frame.MapX(Id, cr), c0 = cl + si, c1 = cr + si;
            if (m0 < c0 || c1 < m1)
            {
                var bi = new TextureCreateInfo(1, 1, 1, 1, 1, gi.BlockWidth, gi.BlockHeight, gi.BytesPerPixel, gi.Format, gi.DepthStencilMode, Target.Texture2D, gi.SwizzleR, gi.SwizzleG, gi.SwizzleB, gi.SwizzleA);
                ITexture black = _r.Inner.CreateTexture(bi);
                if (black != null)
                {
                    black.SetData(MemoryOwner<byte>.RentCleared(Math.Max(1, gi.BytesPerPixel)));
                    if (m0 < c0) black.CopyTo(Inner, new Extents2D(0, 0, 1, 1), new Extents2D(m0, 0, c0, h), false);
                    if (c1 < m1) black.CopyTo(Inner, new Extents2D(0, 0, 1, 1), new Extents2D(c1, 0, m1, h), false);
                    black.Release();
                }
            }
            WidenTexture r = Root; r.Gen++; r.PageContent = r.PageCertified = true; r.PageX0 = cl; r.PageW = cr - cl; r.PageShift = s;
            long k = Interlocked.Increment(ref _r.PresentPages);
            if (k <= 4) Console.Error.WriteLine($"[宽屏] 贴图 {_w0}×{h} 首次被画 / 采样之前先上屏：CPU 内容按原比例页放进放宽贴图（内容 [{c0},{c1})、页面 [{m0},{m1})），不定去留（第 {k} 次）");
            return true;
        }

        public int Width => _w0;   // Gpu 层按客体尺寸算
        public int Height => Inner.Height;

        public void CopyTo(ITexture destination, int firstLayer, int firstLevel) { Resolve(false); var d = WidenRenderer.U(destination, true); Mismatch(destination); CopiedInto(destination, true); Inner.CopyTo(d, firstLayer, firstLevel); }
        public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel) { Resolve(false); var d = WidenRenderer.U(destination, true); Mismatch(destination); CopiedInto(destination, true); Inner.CopyTo(d, srcLayer, dstLayer, srcLevel, dstLevel); }
        // 拷入：目标内容换了（副本作废）；整张拷贝原样带上原比例页的来历，区域拷贝不算页
        void CopiedInto(ITexture destination, bool whole)
        {
            if (destination is not WidenTexture w) return;
            WidenTexture d = w.Root, s = Root; d.Gen++; _r.NoteWrite(d);
            double ratio = w.Width / (double)Width;
            d.PageContent = whole && s.PageContent; d.PageCertified = s.PageCertified; d.PicContent = whole && (!s.GpuWritten || s.PicContent); d.PicPage = whole && s.PicPage;
            d.PageX0 = (int)Math.Round(s.PageX0 * ratio); d.PageW = (int)Math.Round(s.PageW * ratio); d.PageShift = s.PageShift * ratio;
            if (whole) { d.Bands = s.Bands; d.Scene3D = s.Scene3D; d.CamContent = s.CamContent; d.Stretched = s.Stretched; d.Extended = s.Extended; } else { if (s.Scene3D) d.Scene3D = true; if (s.CamContent) d.CamContent = true; }
        }
        void Mismatch(ITexture d) { if (d is WidenTexture w && w.Wide != Wide) _r.Red.TexCopyMismatch++; }

        public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter)
        {
            Resolve(false);
            // Ryujinx SetScale 为 CPU 图片换 storage：原样复制到目标的原宽暂存，首次采样时仍按 CPU 供图换回原宽。
            // 否则复制本身会把一张图片认成宽屏 GPU 目标，之后 PageSource 看不到原比例图片。
            bool whole = srcRegion.X1 == 0 && srcRegion.Y1 == 0 && srcRegion.X2 == Width && srcRegion.Y2 == Height
                && dstRegion.X1 == 0 && dstRegion.Y1 == 0 && dstRegion.X2 == destination.Width && dstRegion.Y2 == destination.Height;
            if (whole && !Wide && !Root.GpuWritten && destination is WidenTexture cpu && cpu.ResolutionScale != ResolutionScale && cpu.Pending() is { } pending)
            {
                Inner.CopyTo(pending, srcRegion, dstRegion, linearFilter);
                return;
            }
            ITexture dt = WidenRenderer.U(destination, true);
            uint did = destination is WidenTexture w ? w.Id : 0;
            CopiedInto(destination, whole && destination is WidenTexture scaled && scaled.ResolutionScale != ResolutionScale);
            var s = new Extents2D(_r.Frame.MapX(Id, srcRegion.X1), srcRegion.Y1, _r.Frame.MapX(Id, srcRegion.X2), srcRegion.Y2);
            var d = new Extents2D(_r.Frame.MapX(did, dstRegion.X1), dstRegion.Y1, _r.Frame.MapX(did, dstRegion.X2), dstRegion.Y2);
            Inner.CopyTo(dt, s, d, linearFilter);
        }

        // 读回给客体（拷到缓冲 / CPU 读）：客体按原宽算布局与长度，放宽贴图先整张横向缩回原宽（最近点，与区域拷贝同一 MapX 换算，逐级逐层）再读。
        // 10-21 巫师3：R8 1564×720 原样拷进按客体 1280 宽算的 983040 字节区间、要写 1126080 → GPU 越界写（帧率能耗线 perf/resfault 在渲染器侧跳过报红）。
        // 缩不了的（压缩 / 多重采样，区域缩放拷贝不支持；没有客体建法）照旧原样读并报红
        ITexture Narrowed()
        {
            if (!Wide) return null;
            if (Guest is not { } g || g.BlockWidth > 1 || g.BlockHeight > 1 || g.Samples > 1)
            {
                long m = Interlocked.Increment(ref _r.NarrowSkipped);
                if (m <= 4) Console.Error.WriteLine($"[宽屏] 放宽贴图 {Inner.Width}×{Inner.Height} 读回给客体：缩不回原宽（{(Guest == null ? "没有客体建法" : "压缩 / 多重采样")}），原样读（第 {m} 次）");
                return null;
            }
            ITexture t = _r.Inner.CreateTexture(g);
            if (t == null) return null;
            Inner.CopyTo(t, new Extents2D(0, 0, Inner.Width, Inner.Height), new Extents2D(0, 0, g.Width, g.Height), false);
            long n = ++_r.Red.Narrowed;
            if (n <= 4) Console.Error.WriteLine($"[宽屏] 放宽贴图 {Inner.Width}×{Inner.Height} 读回给客体：先缩回原宽 {g.Width}×{g.Height} 再读（第 {n} 次）");
            return t;
        }
        public void CopyTo(BufferRange range, int layer, int level, int stride)
        {
            Resolve(false);
            if (Narrowed() is { } t) { t.CopyTo(range, layer, level, stride); t.Release(); return; }
            if (Wide) _r.Red.TexCopyToBuffer++;
            Inner.CopyTo(range, layer, level, stride);
        }

        public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel)
        {
            Resolve(true);   // 建视图多半为换格式当渲染目标：保持原判（放宽）
            _wideInfo = null;   // 换回原宽后建的视图共用原宽存储：之后不再重新放宽，免得视图与本体尺寸对不上
            uint id = _r.NewTexId();
            int w1;
            // 父贴图放宽、视图是父某一级的同宽视图：视图宽 = 父放宽宽度按级缩（存储由父定）。不按视图自己的宽高重算——放宽宽度取整到偶数，
            // 逐级算与按级缩会差 1（10-21 暗黑2：1280→1564，第 3 级视图 160 重算成 196、存储该级只有 195 → 整级拷贝按 196 越界，帧率能耗线 perf/resfault 报红）
            if (Wide && _r.Frame.TryWide(Id, out int pw0, out int pw1) && info.Width == Math.Max(1, pw0 >> firstLevel))
                w1 = _r.Frame.OnCreateView(id, info.Width, Math.Max(1, pw1 >> firstLevel));
            else
            {
                w1 = _r.Frame.OnCreateTexture(id, info.Width, info.Height, ResolutionScale);
                if (!Wide && w1 != info.Width) { _r.Frame.OnReleaseTexture(id); w1 = info.Width; }   // 父贴图没放宽，视图也不放（存储尺寸由父定）
            }
            WidenTexture v = _r.Wrap(Inner.CreateView(w1 == info.Width ? info : WidenRenderer.WithWidth(info, w1), firstLayer, firstLevel), id, info.Width, this);
            if (v != null && w1 != info.Width) v.Guest = info;
            return v;
        }

        // 读回数据拷进渲染器的块池（NxTexture.Get），缩回用的临时贴图读完即可释放
        public PinnedSpan<byte> GetData()
        {
            Resolve(false);
            if (Narrowed() is { } t) { var d = t.GetData(); t.Release(); return d; }
            if (Wide) _r.Red.TexGetData++;
            return Inner.GetData();
        }
        public PinnedSpan<byte> GetData(int layer, int level)
        {
            Resolve(false);
            if (Narrowed() is { } t) { var d = t.GetData(layer, level); t.Release(); return d; }
            if (Wide) _r.Red.TexGetData++;
            return Inner.GetData(layer, level);
        }
        // 往放宽贴图上传原尺寸的数据：首次用之前进原宽副本（见 Resolve）；用过之后尺寸对不上，跳过并报红
        // 租约写贴图：放宽与否都把租约直接交给原宽的底层贴图（没放宽 = 本体；首次用之前 = 原宽副本；用过之后 = 原宽临时贴图再横向拷），不拷托管副本
        // （10-23 测试出包线拆账：马车8 首帧 12 次 12.3 MB——旧做法 RentCopy 整份上传，首帧都是新贴图、尺寸各异，池子复用不上）
        public void S2ASetData(S2AUploadLease lease)
        {
            Root.Scene3D = Root.CamContent = false;
            if (!Wide) { Inner.S2ASetData(lease); return; }
            if (Pending() is { } q) { q.S2ASetData(lease); return; }
            if (WidenUpload(null, lease)) return;
            _r.Red.TexSetData++; _r.Inner.S2ADropUpload(lease);
        }
        public void SetData(MemoryOwner<byte> data) { Root.Scene3D = Root.CamContent = false; if (Wide) { if (Pending() is { } q) { q.SetData(data); return; } if (WidenUpload(data, default)) return; _r.Red.TexSetData++; data.Dispose(); return; } Inner.SetData(data); }
        public void SetData(MemoryOwner<byte> data, int layer, int level)
        {
            if (Wide) { if (Pending() is { } q) { q.SetData(data, layer, level); return; } if (layer == 0 && level == 0 && WidenUpload(data, default)) return; _r.Red.TexSetData++; data.Dispose(); return; }
            Inner.SetData(data, layer, level);
        }
        // 用过之后（已定为放宽）又收到原宽的整张 CPU 上传：传进原宽临时贴图，再横向按 k 拷进放宽贴图（同重新放宽 / 区域拷贝的 MapX 换算），不再丢弃。
        // 10-21 暗黑2 录像回放：录像开始前就有的渲染目标靠序章 CPU 上传补内容，丢了 18 张 → 最终合成采样到全黑图，W 模式整屏黑（实机由 GPU 画出、正常）。
        // 只接单级单层（整张拷贝会逐级逐层覆盖，多级 / 多层只传了一级时会把其他级清掉）；压缩 / 多重采样不支持缩放拷贝，照旧报红
        // 数据二选一：data（托管）或 lease（data == null 时，租约交给临时贴图）；返回 false 时数据没动，由调用方处理
        bool WidenUpload(MemoryOwner<byte> data, S2AUploadLease lease)
        {
            if (Guest is not { } g || g.Levels > 1 || g.Depth > 1 || g.BlockWidth > 1 || g.BlockHeight > 1 || g.Samples > 1) return false;
            ITexture t = _r.Inner.CreateTexture(g);
            if (t == null) return false;
            if (data != null) t.SetData(data); else t.S2ASetData(lease);
            t.CopyTo(Inner, new Extents2D(0, 0, g.Width, g.Height), new Extents2D(0, 0, Inner.Width, Inner.Height), true);
            t.Release();
            Root.Gen++;
            long n = Interlocked.Increment(ref _r.WidenedUploads);
            if (n <= 4) Console.Error.WriteLine($"[宽屏] 放宽贴图 {Inner.Width}×{Inner.Height} 收到原宽 {g.Width}×{g.Height} 整张 CPU 上传：横向按 k 拷进去（第 {n} 次）");
            return true;
        }
        public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region)
        {
            if (Wide) { if (Pending() is { } q) { q.SetData(data, layer, level, region); return; } _r.Red.TexSetData++; data.Dispose(); return; }
            Inner.SetData(data, layer, level, region);
        }
        public void SetStorage(BufferRange buffer) { Root.GpuWritten = true; Resolve(true); Inner.SetStorage(buffer); }
        public void Release() { _r.Frame.OnReleaseTexture(Id); _pending?.Release(); _pending = null; _shadow?.Release(); _shadow = null; Inner.Release(); }
    }

    sealed class WidenTextureArray : ITextureArray
    {
        internal readonly ITextureArray Inner;
        public WidenTextureArray(ITextureArray inner) { Inner = inner; }
        public void SetSamplers(int index, ISampler[] samplers) => Inner.SetSamplers(index, samplers);
        public void SetTextures(int index, ITexture[] textures) => Inner.SetTextures(index, Unwrap(textures, ref _scratch));
        public void Dispose() => Inner.Dispose();
        // 贴图数组复用开着时（缺省开，S2A_TEXARR_REUSE=0 关）：用本对象的暂存数组（下层 Metal 后端同步拷走编号，不留引用）。10-24 塞尔达：贴图池一改就整条重建，
        //   原注释「不在每帧热路径上」不成立（可操作阶段 ITexture[] 每 GC 间隔 2.1 MB，见 Ryujinx.Graphics.GAL.S2ATexArrReuse）
        ITexture[] _scratch;
        internal static ITexture[] Unwrap(ITexture[] a) { ITexture[] none = null; return Unwrap(a, ref none); }
        internal static ITexture[] Unwrap(ITexture[] a, ref ITexture[] scratch)
        {
            if (a == null) return null;
            ITexture[] o;
            if (Ryujinx.Graphics.GAL.S2ATexArrReuse.On) { if (scratch?.Length != a.Length) { Ryujinx.Graphics.GAL.S2ATexArrReuse.DiagAdd(1, a.Length); scratch = new ITexture[a.Length]; } o = scratch; }
            else { Ryujinx.Graphics.GAL.S2ATexArrReuse.DiagAdd(1, a.Length); o = new ITexture[a.Length]; }
            for (int i = 0; i < a.Length; i++) o[i] = WidenRenderer.U(a[i]);
            return o;
        }
    }

    sealed class WidenImageArray : IImageArray
    {
        internal readonly IImageArray Inner;
        public WidenImageArray(IImageArray inner) { Inner = inner; }
        public void SetImages(int index, ITexture[] images) => Inner.SetImages(index, Ryujinx.Graphics.GAL.S2ATexArrReuse.ImgOn ? WidenTextureArray.Unwrap(images, ref _scratch) : WidenTextureArray.Unwrap(images));
        ITexture[] _scratch;   // 图像数组复用开着时（S2ATexArrReuse.ImgOn）的暂存数组，同 WidenTextureArray
        public void Dispose() => Inner.Dispose();
    }

    sealed class WidenWindow : IWindow
    {
        readonly WidenRenderer _r; readonly IWindow _w;
        public WidenWindow(WidenRenderer r, IWindow w) { _r = r; _w = w; }
        public void Present(ITexture texture, ImageCrop crop, Action swapBuffersCallback)
        {
            _r.Cam.OnPresent();
            var t = texture as WidenTexture; uint id = t?.Id ?? 0;
            // 先定去留（或按原比例页放好首次用之前的 CPU 内容），再按定下的尺寸算裁剪——10-21 前先按放宽算裁剪后定去留：首次上屏前收到 CPU 上传的交换链贴图
            // 被换回原宽，却套了放宽裁剪 [0,1564)（暗黑2 / 丝之歌头 1–2 帧出图错、出图参数多变 1 次）
            ITexture inner = t != null && t.PresentUndecided(crop) ? t.Inner : WidenRenderer.U(texture);
            if (id != 0 && _r.Frame.TryWide(id, out _, out _))
            {
                int left = crop.Left, right = crop.Right; float ax = crop.AspectRatioX;
                _r.Frame.MapCrop(id, ref left, ref right, ref ax, crop.AspectRatioY);
                crop = new ImageCrop(left, right, crop.Top, crop.Bottom, crop.FlipX, crop.FlipY, crop.IsStretched, ax, crop.AspectRatioY);
            }
            // 高屏：通用层不加高渲染目标，上屏比例按上屏贴图本身高不高定（WidenFrame.GenericPresentAspectX；宽屏 Ky = 1 原样）
            if (_r.Frame.Rewriter.Tall && texture != null)
            {
                float gx = _r.Frame.GenericPresentAspectX(crop.AspectRatioX, crop.AspectRatioY, texture.Width, texture.Height);
                if (gx != crop.AspectRatioX) crop = new ImageCrop(crop.Left, crop.Right, crop.Top, crop.Bottom, crop.FlipX, crop.FlipY, crop.IsStretched, gx, crop.AspectRatioY);
            }
            // 原比例页：放宽的上屏贴图内容是认证过的 16:9 原比例页（来源全是 CPU 供图）；原生宽目标上本帧（OnPresent 加帧号之前）画过纯 CPU 供图的整画布 16:9 图片
            //   或上屏贴图内容带 PicPage（GameWide：原尺寸居中、两侧清黑的整画布 16:9 CPU 供图页传下来的）
            //   两侧是游戏画的（2）：放宽的上屏贴图两侧是放宽内容（Bands）——只免纯黑带，贴边暗带照判（某一遍没铺满放宽宽度，10-22 八方2 右带反证）；
            //   没有可扩视野的内容（3，CamContent）；游戏自己出宽图时这一帧全是 2D 合成（4，没有 Scene3D，见 WidenTexture.Scene3D）——3 / 4 全免
            WidenRenderer.NotePillar(_r.LastPillar = _r.PillarAll || _r.PillarFrame == _r.Frame.Frames || t != null && t.Root.PicPage || t != null && _r.Frame.IsWide(id) && t.Root.PageContent && t.Root.PageCertified ? 1
                : t != null && (_r.Frame.IsWide(id) || _r.Frame.GameWide) && t.Root.Bands ? 2
                : t != null && _r.Frame.IsWide(id) && !t.Root.CamContent ? 3
                : t != null && _r.Frame.GameWide && !t.Root.Scene3D ? 4 : 0);
            // 交换链：上屏的这张最近一次写入就是这一游戏帧的收尾（首次上屏的那张也认得出边界）
            if (t != null) { WidenTexture pr = t.Root; pr.Presented = true; if (pr.LastWriteSeq > _r.FrameStartSeq) _r.FrameStartSeq = pr.LastWriteSeq; }
            _r.Frame.OnPresent(id);
            CameraTrack.Publish(_r.Cam, (ulong)_r.Frame.Frames);   // 自动玩家在线读（s2a_ap_cam）
            _w.Present(inner, crop, swapBuffersCallback);
        }
        public void SetSize(int width, int height) => _w.SetSize(width, height);
        public void ChangeVSyncMode(VSyncMode vSyncMode) => _w.ChangeVSyncMode(vSyncMode);
        public void SetAntiAliasing(AntiAliasing antialiasing) => _w.SetAntiAliasing(antialiasing);
        public void SetScalingFilter(ScalingFilter type) => _w.SetScalingFilter(type);
        public void SetScalingFilterLevel(float level) => _w.SetScalingFilterLevel(level);
        public void SetColorSpacePassthrough(bool colorSpacePassThroughEnabled) => _w.SetColorSpacePassthrough(colorSpacePassThroughEnabled);
    }

    sealed class WidenPipeline : IPipeline
    {
        const int MaxVp = 16, MaxUbo = 256;
        readonly WidenRenderer _r; readonly IPipeline _p;
        readonly Viewport[] _vp = new Viewport[MaxVp]; int _vpN;
        readonly Rectangle<int>[] _sc = new Rectangle<int>[MaxVp]; int _scN;
        bool _stateDirty = true; ViewportMode _applied = ViewportMode.Keep;
        CbufUse[] _uses = Array.Empty<CbufUse>();
        readonly (ulong Buf, int Off, int Size)[] _ubo = new (ulong, int, int)[MaxUbo];
        readonly CbufRead[] _reads = new CbufRead[MaxUbo];
        readonly ITexture[][] _rtArr = new ITexture[9][];
        bool _fragY, _realPx; WidenProgram _prog;
        (int Index, int Binding, bool Image)[] _scales;   // 当前程序片元取图缩放项（null = 没有）
        (int Index, int Binding)[] _extrap;               // 当前程序能按原画框外推：归一化采样项（null = 不能外推）
        bool _extrapOn;                                   // 本次绘制按原画框外推（BeforeDraw 定）
        uint _depthId;   // 当前深度附件（镜头位姿按它分组计数）
        int[] _pushTex;   // 当前程序顶点可外推时：片元采样的贴图绑定号；不可外推为 null
        int[] _picTex;    // 当前程序片元采样的贴图绑定号（整画布 16:9 图片判据；不论能否外推）
        int[] _progImg;   // 当前程序用到的图像绑定号（null = 不知道，按全部已绑图像算）
        readonly ITexture[] _fragTexObj = new ITexture[256];   // 片元阶段各绑定号当前的贴图（外推前查：都很小）
        readonly ISampler[] _fragSmp = new ISampler[256];
        const int SmallTex = 8;   // 不超过 8×8 的贴图当纯色 / 渐变底：拉伸看不出
        static bool Small(ITexture t) => WidenFrame.IsSmallTexture(t.Width, t.Height, t is WidenTexture w ? w.ResolutionScale : 1f, SmallTex);
        readonly bool[] _imageWide = new bool[64];
        readonly ITexture[] _imageObj = new ITexture[64];   // 各绑定号当前的图像（--trace 派发行用）

        public WidenPipeline(WidenRenderer r, IPipeline p)
        {
            _r = r; _p = p;
            for (int i = 0; i < _rtArr.Length; i++) _rtArr[i] = new ITexture[i];
        }

        // ---------- 宽屏要拦的 ----------
        ITexture[] _rtW = new ITexture[8]; int _rtWN; ITexture _rtWD;   // 游戏最近一次给的颜色 / 深度目标（画面分层图集按需放宽后重发用）
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil)
        {
            if (colors.Length <= _rtW.Length) { colors.CopyTo(_rtW); _rtWN = colors.Length; } else _rtWN = -1;
            _rtWD = depthStencil;
            ITexture[] a = colors.Length < _rtArr.Length ? _rtArr[colors.Length] : new ITexture[colors.Length];
            for (int i = 0; i < colors.Length; i++) a[i] = WidenRenderer.URt(colors[i]);
            uint c0 = colors.Length > 0 && colors[0] is WidenTexture t0 ? t0.Id : 0, ds = depthStencil is WidenTexture td ? td.Id : 0;
            _depthId = ds;
            _r.Frame.OnRenderTargets(c0, ds);
            _stateDirty = true;
            _p.SetRenderTargets(a, WidenRenderer.URt(depthStencil));
            Array.Clear(a);
            _sidesPending = false;
            for (int i = 0; i < _cur.Length; i++)
            {
                _cur[i] = i < colors.Length ? colors[i] as WidenTexture : null;
                if (_cur[i] is { } t && _r.FirstWriteThisFrame(t) && _r.Frame.IsWide(t.Id)) _sidesPending = true;
            }
        }

        // 放宽颜色目标这一帧第一次被画之前，游戏这帧没清过它，就把两侧放宽出来的条带（中间原宽 16:9 区以外）清黑：
        // 游戏按 16:9 画、不清屏只铺整画布底图的页（10-20 马车8 标题 / 选 Mii），两侧没人写，显出这张贴图上次用剩的旧画面（复用的渲染目标，首次清零也没用）。
        // 放在首次绘制前（通道反正要开）而不是绑定时：不抢游戏整张清屏的载入动作（load action），不多一次整张读显存；游戏自己清过（包装层把清屏按全宽发）就不清。
        // 这一帧之后往两侧画的 3D / 外推的底照常盖上；只清条带、不碰中间区，每帧每张最多一次（后端只清剪裁内，一次两个小三角）。
        readonly WidenTexture[] _cur = new WidenTexture[8];   // 当前颜色目标
        bool _sidesPending;
        void ClearPendingSides()
        {
            _sidesPending = false;
            for (int i = 0; i < _cur.Length; i++) if (_cur[i] is { } t) ClearSides(i, t);
        }
        void ClearSides(int index, WidenTexture t)
        {
            if (!_r.FirstWriteThisFrame(t) || !_r.Frame.TryWide(t.Id, out int w0, out int w1)) return;
            _r.NoteWrite(t);
            // 两侧被清黑：不再是放宽内容（10-21 马车8：错清之后标记还在，出图层把清出来的黑当成游戏画的、不报未满屏）
            t.Root.Bands = false;
            int pad = (w1 - w0) / 2;
            if (pad <= 0 || t.Height <= 0) return;
            ClearCols(index, t, 0, pad); ClearCols(index, t, pad + w0, w1);
            _r.SideClears++;
        }
        /// <summary>颜色目标 index 的 [x0, x1) 列清黑（后端只清剪裁内）；游戏自己的剪裁 / 视口在下一次绘制 / 清屏前重发。</summary>
        void ClearCols(int index, WidenTexture t, int x0, int x1)
        {
            if (x1 <= x0 || t.Height <= 0) return;
            Span<Rectangle<int>> r = stackalloc Rectangle<int>[1];
            r[0] = new Rectangle<int>(x0, 0, x1 - x0, t.Height); _p.SetScissors(r); _p.ClearRenderTargetColor(index, 0, 1, 0xf, default);
            _stateDirty = true;
        }
        // 原生宽目标（GameWide）上整画布 16:9 CPU 供图（视频帧 / 静态页图）被原尺寸居中（CenterNative）：16:9 下它盖住先画的底层，
        // 居中后两侧露出的是 16:9 里看不见的底层（10-22 怪猎开场 logo / 健康提醒页：先铺满画布的底 254 白 / 72 灰，不套包装层回放两侧为 0）——
        // 没有更宽内容可补，按 jhz 规则两侧清黑（同放宽目标的原比例页）。区域 = 当前原生宽区域（视口 0）两侧各 (宽1 − 宽0)/2 列；每个游戏帧每张最多一次，
        // 本帧之后画到两侧的绘制（转场压暗等）照常盖上。
        void ClearPictureSides()
        {
            if (_cur[0] is not { } t) return;
            WidenTexture rt = t.Root;
            if (rt.PicSidesSeq >= _r.FrameStartSeq) return;
            int w0 = _r.Frame.TargetW0, w1 = _r.Frame.TargetW1, vx = (int)Math.Round(_r.Frame.NativeX), pad = (w1 - w0) / 2;
            if (pad <= 0 || t.Height <= 0) return;
            ClearCols(0, t, vx, vx + pad); ClearCols(0, t, vx + pad + w0, vx + w1);
            _r.NoteWrite(t); rt.PicSidesSeq = _r.WriteSeq; _r.SideClears++;
        }

        public void SetViewports(ReadOnlySpan<Viewport> viewports)
        {
            _vpN = Math.Min(viewports.Length, MaxVp); viewports[.._vpN].CopyTo(_vp);
            _stateDirty = true;   // 延到下一次绘制 / 清屏按当时的方式换算后再发
        }

        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions)
        {
            _scN = Math.Min(regions.Length, MaxVp); regions[.._scN].CopyTo(_sc);
            _stateDirty = true;
        }

        void Apply(ViewportMode mode)
        {
            if (!_stateDirty && mode == _applied) return;
            _applied = mode; _stateDirty = false;
            if (!_r.Frame.TargetWide) mode = ViewportMode.Keep;
            Span<Viewport> v = stackalloc Viewport[_vpN];
            for (int i = 0; i < _vpN; i++)
            {
                var g = _vp[i]; var rg = g.Region; float x = rg.X, w = rg.Width;
                _r.Frame.MapViewport(mode, ref x, ref w);
                v[i] = new Viewport(new Rectangle<float>(x, rg.Y, w, rg.Height), g.SwizzleX, g.SwizzleY, g.SwizzleZ, g.SwizzleW, g.DepthNear, g.DepthFar);
            }
            Span<Rectangle<int>> s = stackalloc Rectangle<int>[_scN];
            for (int i = 0; i < _scN; i++)
            {
                var g = _sc[i]; int x = g.X, w = g.Width;
                _r.Frame.MapScissor(mode, ref x, ref w);
                s[i] = WidenRenderer.IgnoreOutScissor && !(_depthId != 0 && _depthOn) ? new Rectangle<int>(0, 0, 0xffff, 0xffff) : new Rectangle<int>(x, g.Y, w, g.Height);
            }
            if (_vpN > 0) _p.SetViewports(v);
            // 原比例页（同一帧、同一目标）：剪裁与页面内容区取交集，两侧黑边不再被画（见 TryBeginPage）
            if (_r.Frame.PageClip(out int lo, out int hi))
            {
                if (_scN == 0) { Span<Rectangle<int>> one = stackalloc Rectangle<int>[1]; one[0] = new Rectangle<int>(lo, 0, hi - lo, 0xffff); _p.SetScissors(one); return; }
                for (int i = 0; i < _scN; i++)
                {
                    long x0 = Math.Max(s[i].X, lo), x1 = Math.Min((long)s[i].X + s[i].Width, hi);
                    s[i] = new Rectangle<int>((int)x0, s[i].Y, (int)Math.Max(0, x1 - x0), s[i].Height);
                }
            }
            if (_scN > 0) _p.SetScissors(s);
        }

        public void SetProgram(IProgram program)
        {
            // 程序信息挂在包装层程序对象上（直接字段，不查表；10-23 塞尔达渲染线程拆账：原 8 次 ConditionalWeakTable 查询约占 1%）；
            // 不是包装层建的程序（理论上没有）按「什么都没登记」处理、原样下传
            WidenProgram w = program as WidenProgram; _prog = w;
            _uses = w?.Uses ?? Array.Empty<CbufUse>();
            _fragY = w != null && w.FragY;
            _realPx = w != null && w.RealPx;
            _scales = w?.Scales; _extrap = w?.Extrap; _pushTex = w?.Push; _picTex = w?.Sampled; _progImg = w?.Images;
            _p.SetProgram(w != null ? w.Inner : program);
        }

        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers)
        {
            Span<byte> value = stackalloc byte[4];
            foreach (BufferAssignment b in buffers)
            {
                if ((uint)b.Binding < MaxUbo) _ubo[b.Binding] = (WidenRenderer.Key(b.Range.Handle), b.Range.Offset, b.Range.Size);
                if (b.Range.Size > 0) _r.Frame.OnUniformBound(WidenRenderer.Key(b.Range.Handle), b.Range.Offset, b.Range.Size);   // 常量缓冲影子按绑定的区间建（上传时比它、只扫变了的）
                if (b.Binding == SupportBuffer.Binding && b.Range.Size > 0)
                {
                    ulong k = WidenRenderer.Key(b.Range.Handle); int at = b.Range.Offset + SupportBuffer.GraphicsRenderScaleOffset;
                    if (k != _r.SupportBuf || at != _r.SupportScaleAt)
                    {
                        _r.SupportBuf = k; _r.SupportScaleAt = at; _r.SupportScaleNow = float.NaN; _r.SupportBaseScale = 1f;
                        _r.SupportTexScale.AsSpan().Fill(float.NaN); _r.SupportBaseTexScale.AsSpan().Fill(1f); _r.SupportTexScaleSet.Clear();
                        // 正常 BufferUpdater 先绑定、再上传。录像 prologue / 换回旧缓冲可能相反：影子保存的是 GPU 层递来的原值，
                        // 不含包装层之后写的宽屏值；首次绑定没有影子时只读 CPU 已知内容，不等 GPU。
                        var shadow = _r.Frame.Shadow.TryGet(k);
                        for (int i = 0; i < _r.SupportBaseTexScale.Length; i++)
                            if (shadow != null && shadow.ReadKnown(at + 16 * i, value) || _r.CpuPeek != null && _r.CpuPeek(b.Range.Handle, at + 16 * i, value))
                            {
                                float scale = System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(value);
                                if (i == 0) _r.SupportBaseScale = scale; else _r.SupportBaseTexScale[i] = scale;
                            }
                    }
                    int pa = b.Range.Offset + SupportBuffer.S2AWidenOffset;   // s2a_widen.x / .y / .z / .w
                    int pat = pa + 16 <= b.Range.Offset + b.Range.Size ? pa : -1;
                    if (k != _r.SupportBuf || pat != _r.SupportPushAt) { _r.SupportPushAt = pat; _r.SupportPushNow = _r.SupportThrNow = _r.SupportShrinkNow = _r.SupportPadNow = float.NaN; }
                }
            }
            _p.SetUniformBuffers(buffers);
        }

        // 各阶段各绑定号当前绑着的贴图 / 采样器（重新放宽后重发用，见 Rebind）；定长数组，零分配
        const int MaxTexBind = 256;
        readonly ITexture[] _boundTex = new ITexture[(int)ShaderStage.Count * MaxTexBind];
        readonly ISampler[] _boundSmp = new ISampler[(int)ShaderStage.Count * MaxTexBind];
        readonly ITexture[] _sentTex = new ITexture[(int)ShaderStage.Count * MaxTexBind];   // 实际发给后端的底层贴图（原比例页的原宽副本 / Inner）
        internal void Rebind(WidenTexture t)
        {
            for (int i = 0; i < _boundTex.Length; i++)
                if (ReferenceEquals(_boundTex[i], t)) _p.SetTextureAndSampler((ShaderStage)(i / MaxTexBind), i % MaxTexBind, _sentTex[i] = t.ForSampling(), _boundSmp[i]);
        }
        /// <summary>这笔（片元采样 + 顶点阶段采样，只认本程序真采样的绑定）读到放宽、GPU 画过、框外是外延的颜色贴图。</summary>
        bool ReadsExtendedWide()
        {
            if (_picTex != null) foreach (int b in _picTex) if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t && ExtWide(t)) return true;
            if (_prog?.VSampled is { } vs) { int vb = (int)ShaderStage.Vertex * MaxTexBind; foreach (int b in vs) if ((uint)b < MaxTexBind && _boundTex[vb + b] is WidenTexture t && ExtWide(t)) return true; }
            return false;
        }
        bool ExtWide(WidenTexture t) => _r.Frame.IsWide(t.Id) && t.Root.Extended && t.Root.GpuWritten && !(t.Guest is { } g && g.Format.IsDepthOrStencil);
        // 每次绘制前：片元采样的放宽贴图若现在是原比例页，换绑原宽副本（内容变了重拷）；不再是页了换回本体。Ryujinx 只在绑定对象变化时才重发，这里补发
        void RefreshSampled()
        {
            if (_picTex == null) return;
            int fb = (int)ShaderStage.Fragment * MaxTexBind;
            foreach (int b in _picTex)
            {
                if ((uint)b >= MaxTexBind || _boundTex[fb + b] is not WidenTexture w) continue;
                ITexture want = w.ForSampling();
                if (!ReferenceEquals(want, _sentTex[fb + b])) { _p.SetTextureAndSampler(ShaderStage.Fragment, b, want, _boundSmp[fb + b]); _sentTex[fb + b] = want; }
            }
        }

        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler)
        {
            ITexture u = WidenRenderer.U(texture);   // 先定去留，再按放宽与否记
            if (texture is WidenTexture wt) u = wt.ForSampling();
            if ((uint)stage < (uint)ShaderStage.Count && (uint)binding < MaxTexBind) { int bi = (int)stage * MaxTexBind + binding; _boundTex[bi] = texture; _boundSmp[bi] = sampler; _sentTex[bi] = u; }
            if (stage == ShaderStage.Fragment) { _r.Frame.OnFragmentTexture(binding, texture is WidenTexture t ? t.Id : 0); if ((uint)binding < (uint)_fragTexObj.Length) { _fragTexObj[binding] = texture; _fragSmp[binding] = sampler; } }
            _p.SetTextureAndSampler(stage, binding, u, sampler);
        }

        public void SetImage(ShaderStage stage, int binding, ITexture texture)
        {
            ITexture u = WidenRenderer.URt(texture);
            if ((uint)binding < (uint)_imageWide.Length)
            {
                _imageWide[binding] = texture is WidenTexture t && _r.Frame.IsWide(t.Id);
                _imageObj[binding] = texture;
            }
            _p.SetImage(stage, binding, u);
        }

        /// <summary>当前程序各常量读法对上当前绑定，填进 _reads，返回条数。</summary>
        int BuildReads()
        {
            int n = 0;
            foreach (CbufUse u in _uses)
            {
                if ((uint)u.Binding >= MaxUbo) continue;
                var b = _ubo[u.Binding];
                if (b.Size > 0) _reads[n++] = new CbufRead(b.Buf, b.Off, b.Size, u);
            }
            return n;
        }

        void BeforeDraw()
        {
            // 画面分层图集按需放宽（WidenFrame.LayerWiden）：没放宽的单层 2D 颜色目标、没绑深度，这笔读到放宽且是外延的内容（散点按放宽源铺精灵、合成遍再按放宽画布读）
            // → 目标放宽后重发渲染目标（视口 / 裁剪随之按放宽目标换算）
            if (_cur[0] is { Made: not null } lc && _depthId == 0 && _rtWN > 0 && !_r.Frame.GameWide && ReadsExtendedWide() && lc.ForceWiden())
                SetRenderTargets(_rtW.AsSpan(0, _rtWN), _rtWD);
            if (_sidesPending) ClearPendingSides();
            int n = BuildReads();
            _r.Cam.OnDraw(_depthId, _reads.AsSpan(0, n));
            if (_vpN > 0 && _r.Frame.OnViewport(_vp[0].Region.X, _vp[0].Region.Width, Math.Abs(_vp[0].Region.Height), _cur[0]?.ResolutionScale ?? _r.SupportBaseScale)) _stateDirty = true;
            // 16:9 原比例页（放宽目标）：本帧已登记，或这次绘制采样整画布 16:9 图片 → 登记
            bool page = PicBlack && _r.Frame.TargetWide && !_r.Frame.TargetNative && _cur[0] != null && (_r.Frame.PageActive || TryBeginPage());
            _r.Frame.DrawSamplesWide = SampledWide();
            ViewportMode m = _r.Frame.OnDraw(_reads.AsSpan(0, n), _r, out _, page, _fragY && !_realPx);
            // 原画框外推（SpirvExtrap）：放宽目标上铺满画布、没读改写矩阵的 2D / 全屏遍（ScaleK）——视口照拉伸、几何不动，片元按 s2a_widen.w = pad、.y = 放宽比外推
            bool canvas = m == ViewportMode.ScaleK && !page && _r.Frame.TargetWide && !_r.Frame.TargetNative && FullCanvasViewport();
            _extrapOn = canvas && _extrap != null && _r.SupportPushAt >= 0 && _r.SupportScaleAt >= 0;
            if (canvas && !_extrapOn) _r.ExtrapStretchFallback++;
            if (_extrapOn)
            {
                // 来历位只对「GPU 绘制写过的画布空间渲染目标」有意义（10-23 总指挥）：没被 GPU 写过的（CPU 素材 / 录像窗口内没画过）与按平铺采样的贴图内容和画布无关，
                // 既不算外延也不挡外推（暗黑2 贴图 154：整段没被画、只被上屏前合成平铺采样，曾让合成与上屏每帧退回拉伸）
                // 读侧：采样的放宽颜色贴图框外不是外延（被子块 / 拉伸画过）→ 不外推；写侧：几何只盖住画布一部分 → 不外推（同改前按拉伸画）
                bool prov = true;
                foreach (var (_, b) in _extrap)
                    if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture st && _r.Frame.IsWide(st.Id) && !st.Root.Extended && !(st.Guest is { } gi && gi.Format.IsDepthOrStencil)
                        && st.Root.GpuWritten && !(_fragSmp[b] is ISampler tsm && _r.TilingU.TryGetValue(tsm, out _)))
                    {
                        prov = false;
                        if (st.Root.NonExtSince >= 0) { long d = _r.Frame.Frames - st.Root.NonExtSince; if (d > _r.ExtrapChainMaxFrames) _r.ExtrapChainMaxFrames = d; if (d >= 3) _r.ExtrapChainLong.Add(st.Root.Id); }
                        break;
                    }
                int cov = prov ? GeomCovers() : 1;
                if (!prov) _r.ExtrapProvFallback++; else if (cov == 0) _r.ExtrapGeomPartial++; else if (cov == GeomUnread) _r.ExtrapGeomUnread++; else if (cov < 0) _r.ExtrapGeomUnknown++;
                if (!prov || cov == 0 || cov == GeomUnread) _extrapOn = false;
            }
            if (_extrapOn) _r.Frame.RestoreForExtrap(_reads.AsSpan(0, n), _r);
            if (_realPx && m is ViewportMode.ScaleK or ViewportMode.Hor)
            {
                _r.Red.RealPxDraws++;
                if (!_prog.RealPxSeen) { _prog.RealPxSeen = true; _r.Red.RealPxPrograms++; }
            }
            // 原生宽目标（游戏自己出宽图，不放宽贴图）：只记「本帧画过纯 CPU 供图的整画布 16:9 图片」给出图层（同 10-20）
            bool picPage = false;
            if (PicBlack && _r.Frame.TargetWide && _r.Frame.TargetNative && FullPicture() is { } pic)
            {
                _r.PicDraws++;
                if (!pic.Root.GpuWritten || pic.Root.PicContent) { _r.PillarFrame = _r.Frame.Frames; if (m == ViewportMode.CenterNative) { ClearPictureSides(); picPage = true; } }
                else if (_r.PicGpuLog < 4) { _r.PicGpuLog++; Console.Error.WriteLine($"[宽屏] 整画布 16:9 图片 {pic.Width}×{pic.Height} 是 GPU 画出来的目标（不是 CPU 供图）：不认原比例页，满屏判据照判"); }
            }
            // 被画的颜色目标：内容换了（采样副本作废）；不是原比例页的绘制让它不再是页
            bool gw = _r.Frame.GameWide, fromPic = gw && !_r.Frame.TargetWide && FromPictures(), smpPage = gw && SamplesPicPage();
            bool s3d = _depthId != 0 && _depthOn || SampledScene3D();   // 内容来历：3D 场景（见 WidenTexture.Scene3D）
            bool cam = _r.Frame.DrawReadCam || SampledCam();   // 内容来历：读到改写镜头（见 WidenTexture.CamContent）
            // 实例化散点（实例数 > 4，按源像素铺精灵）照拉伸视口画、不外推（GeomCovers）：精灵位置与取色都按归一化坐标铺满整张放宽源，拉伸视口下写出的正是放宽画面的散点——
            // 读的是外延内容就记外延、不记拉伸（10-23 八方2 景深：133 画进放宽的散景图集，合成遍 134 才能按放宽画布外推读它）
            bool scat = m == ViewportMode.ScaleK && !_extrapOn && _dKind != 0 && _dInst > 4 && _r.Frame.TargetWide && !_r.Frame.TargetNative && ReadsExtendedWide();
            for (int i = 0; i < _cur.Length; i++) if (_cur[i] is { } ct)
            {
                WidenTexture rt = ct.Root; bool first = _r.FirstWriteThisFrame(rt); rt.Gen++; _r.NoteWrite(rt); if (!(page && i == 0)) rt.PageContent = false; rt.PicContent = fromPic && i == 0;
                if (s3d) rt.Scene3D = true;
                if (cam) rt.CamContent = true;
                if (m == ViewportMode.ScaleK && !_extrapOn && !scat && _r.Frame.TargetWide && !_r.Frame.TargetNative) rt.Stretched = true;
                else if (_extrapOn || scat || m == ViewportMode.Hor && FullCanvasViewport()) rt.Stretched = false;
                if (_extrapOn || scat || m == ViewportMode.Hor && cam) { rt.Extended = true; rt.NonExtSince = -1; }
                else if (m == ViewportMode.ScaleK && _r.Frame.TargetWide && !_r.Frame.TargetNative) { rt.Extended = false; if (rt.NonExtSince < 0) rt.NonExtSince = _r.Frame.Frames; }
                if (gw) rt.PicPage = i == 0 && (picPage || smpPage) || !first && rt.PicPage;
            }
            // 两侧来历（见 WidenTexture.Bands）：铺满画布的 Hor，或采样了两侧是放宽内容的贴图的铺满画布 ScaleK
            if (!page && _r.Frame.TargetWide && !_r.Frame.TargetNative && FullCanvasViewport() && (m == ViewportMode.Hor || m == ViewportMode.ScaleK && SampledBands()))
                for (int i = 0; i < _cur.Length; i++) if (_cur[i] is { } bt) bt.Root.Bands = true;
            // 游戏自己出宽图（GameWide）的原生宽目标：铺满整张目标（视口 / 裁剪）的 3D 绘制（开深度）画过，或铺满的绘制采样了带标记的贴图 → 两侧是游戏画的
            // （10-23 怪猎村子：镜头贴着柱子 / 墙，柱子在阴影里纯黑、整列到屏幕边，出图层报「右侧 142 黑带」；回放与 Ryujinx 参照逐像素一致）。
            // 补丁没生效、场景按 16:9 画时 3D 绘制的视口只有 16:9 宽，不标，照样报红
            if (!page && _r.Frame.GameWide && _r.Frame.TargetNative && CoversTarget() && (_depthId != 0 && _depthOn || SampledBands()))
                for (int i = 0; i < _cur.Length; i++) if (_cur[i] is { } nt) nt.Root.Bands = true;
            RefreshSampled();
            // 原尺寸居中的界面层（原生宽目标上没读改写矩阵 = CenterNative）若只采小图 / 平铺寻址贴图：改发全宽视口（Hor 在原生宽目标上不动视口），
            // 着色器先横向收缩 1/k 再把画布边上的顶点推到屏幕边（SpirvEdgePush，s2a_widen.z）——画布内的元素位置与居中时逐点相同，全屏黑底 / 压暗遮罩铺满宽屏、不留两侧残影（10-21 暗黑3 自动存档页 / 难度弹窗）
            // 放宽目标同样适用（10-21 暗黑2 开物品栏：界面层铺满画布的纯色压暗遮罩被原尺寸居中收在 16:9 里，两侧露出没压暗的场景）：放宽目标上 Hor 视口按 k 铺满，
            // 着色器收缩 1/k 后画布内与原尺寸居中逐点相同，画布边的顶点推到屏幕边
            // 不写颜色的绘制（只写深度 / 模板：遮罩）不单独推：它遮的内容采样大贴图、不推，遮罩推走就和内容错开
            // （10-23 暗黑3 回放：HUD 的模板遮罩绘制没有颜色目标、不采样贴图，按「只采小图」被单独推）
            bool colorOut = HasColorTarget();
            // 子视口（GameWide 原生宽区域里的小视口，见 WidenFrame.OnViewport）不走收缩：收缩是绕本次视口中心横向缩，只有视口 = 整个区域时才等于原尺寸居中；
            // 子视口要按 CenterNative 换算视口本身（暗黑3 血条填充 / 怒气液体，10-23）
            bool shrink = _r.Frame.ShrinkCandidate(m, colorOut, _pushTex != null && _r.SupportPushAt >= 0) && OnlyBackground();
            if (shrink) m = ViewportMode.Hor;
            // 原尺寸居中的背景层被推到屏幕边（shrink）且视口 / 裁剪铺满画布：两侧是游戏的底色画的，同样算「两侧是放宽内容」（10-23 八方2 存档页：
            // 纯色底 1×1 贴图铺满画布、推满宽屏，界面居中在上面；上面的「铺满画布 Hor」判定在改成 Hor 之前，认不到，出图层报两侧黑带每局红）
            if (shrink && !page && _r.Frame.TargetWide && !_r.Frame.TargetNative && FullCanvasViewport() && FullCanvasScissor())
                for (int i = 0; i < _cur.Length; i++) if (_cur[i] is { } pt) pt.Root.Bands = true;
            if (_extrapOn)
            {
                _r.ExtrapDraws++;   // 视口照拉伸（ScaleK）铺满，几何不动；片元按 s2a_widen.w / .y 把插值、片元坐标、采样换算回原画框（SpirvExtrap）
                foreach (var (_, b) in _extrap) if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture st && st.Root.Stretched) { _r.ExtrapOnStretched++; break; }
            }
            Apply(m);
            NoteScreenCopy();
            if (_r.DrawTrace != null) Trace(m);
            // 外推参数（s2a_widen.x / .y）：原生宽目标上读改写矩阵、片元不采样贴图或只采样 ≤8×8 小图（及 16:9 整屏副本）的绘制写 ((1−3‰)/k)² 与 1 − 1/k，其余写 0（= 原样）；
            // 原画框外推另写 z = 1 − 1/K（收缩）与 w = pad。片元也读 w（SpirvExtrap 改了的片元不管顶点改没改），所以每次绘制都对齐，不只可外推的程序
            if (_r.SupportPushAt >= 0)
            {
                bool on = _pushTex != null && (shrink || _r.Frame.PushCandidate(m, colorOut, true) && OnlySmall());
                _r.Frame.PushParams(on, shrink, out float d, out float e2, out float z);
                float pad = _extrapOn ? ExtrapPad() : 0f;
                if (_extrapOn) e2 = _r.Frame.TargetScaleX ?? 1f;   // 原画框外推：y = 目标放宽比 k（片元插值换算用；外推量 x = 0，顶点不动）
                if (on) { _r.EdgeDraws++; if (shrink) _r.ShrinkDraws++; if (_r.EdgeLogPush < 16) { _r.EdgeLogPush++; Console.Error.WriteLine($"[宽屏] 外推：第 {_r.EdgeDraws} 次{(shrink ? "（原尺寸居中层，全宽视口 + 横向收缩）" : "")}，采样绑定 [{string.Join(",", _pushTex)}]"); } }
                if (!(_r.SupportPushNow == d) || !(_r.SupportThrNow == e2) || !(_r.SupportShrinkNow == z) || !(_r.SupportPadNow == pad))
                {
                    Span<byte> v = stackalloc byte[16];
                    System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(v, d); System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(v[4..], e2);   // x = 外推量、y = 门限²
                    System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(v[8..], z);   // z = 横向收缩量
                    System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(v[12..], pad);   // w = 原画框外推的 pad（0 = 关）
                    ulong sb = _r.SupportBuf;
                    _r.Inner.SetBufferData(Unsafe.As<ulong, BufferHandle>(ref sb), _r.SupportPushAt, v);
                    _r.SupportPushNow = d; _r.SupportThrNow = e2; _r.SupportShrinkNow = z; _r.SupportPadNow = pad; _r.PushWrites++;
                }
            }
            // render_scale[0]：原分辨率倍率 × 目标横向放宽比；外推 / 真实像素约定 / 不放宽时恢复原倍率，Y 由 GPU 的独立数组保留。
            if (_r.SupportScaleAt >= 0)
            {
                float want = _r.SupportBaseScale * _r.Frame.FragScaleX(m, _fragY && !_extrapOn && !_realPx);
                if (!(_r.SupportScaleNow == want))
                {
                    Span<byte> v = stackalloc byte[4];
                    System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(v, want);
                    ulong sb = _r.SupportBuf;
                    _r.Inner.SetBufferData(Unsafe.As<ulong, BufferHandle>(ref sb), _r.SupportScaleAt, v);
                    _r.SupportScaleNow = want; _r.ScaleWrites++;
                }
            }
            if (_r.SupportScaleAt >= 0) WriteTexScales(m);
        }

        /// <summary>render_scale[1 + 缩放下标]：原纹理分辨率倍率与所绑贴图放宽比相乘——目标按同一比例放宽（片元坐标即放宽像素）写负值，
        /// 着色器按 ⌊客体坐标⌋·k + mod(片元坐标, k) 还原真实像素（同 Ryujinx 分辨率缩放）；否则写正值（纯乘）；没放宽的贴图写 1。
        /// 按真实像素画的程序、未使用的下标恢复 GPU 原倍率；不能一律写全局倍率，否则破坏缩放黑名单。</summary>
        void WriteTexScales(ViewportMode m)
        {
            float tk = (m == ViewportMode.ScaleK || m == ViewportMode.Hor) && _r.Frame.TargetScaleX is float kx ? kx : 1f;
            var set = _r.SupportTexScaleSet;
            bool guest = _scales != null && !_realPx;
            if (guest)
                foreach (var s in _scales)
                {
                    if ((uint)s.Index >= (uint)_r.SupportTexScale.Length) continue;
                    float k = TexRatio(s.Binding, s.Image), native = _r.SupportBaseTexScale[s.Index];
                    float want = _extrapOn ? TexPad(s.Binding, s.Image) : k == 1f ? native : MathF.Abs(native) * (k == tk ? -k : k);
                    if (!(_r.SupportTexScale[s.Index] == want)) WriteTexScale(s.Index, want);
                    if (want != native && !set.Contains(s.Index)) set.Add(s.Index);
                }
            if (_extrapOn)   // 外推：归一化采样按 (u·w0 + off)/w1 换算，写各采样贴图的 off（没放宽 = 0）
                foreach (var (si, sb) in _extrap)
                {
                    if ((uint)si >= (uint)_r.SupportTexScale.Length) continue;
                    float want = TexPad(sb, false);
                    if (!(_r.SupportTexScale[si] == want)) WriteTexScale(si, want);
                    if (want != _r.SupportBaseTexScale[si] && !set.Contains(si)) set.Add(si);
                }
            for (int j = set.Count - 1; j >= 0; j--)
            {
                int i = set[j]; bool used = false;
                if (guest) foreach (var s in _scales) if (s.Index == i) { used = true; break; }
                if (_extrapOn) foreach (var (si, _) in _extrap) if (si == i) { used = true; break; }
                if (used && _r.SupportTexScale[i] != _r.SupportBaseTexScale[i]) continue;
                if (!(_r.SupportTexScale[i] == _r.SupportBaseTexScale[i])) WriteTexScale(i, _r.SupportBaseTexScale[i]);
                set.RemoveAt(j);
            }
        }
        void ResetTexScales()
        {
            var set = _r.SupportTexScaleSet;
            foreach (int i in set) if (!(_r.SupportTexScale[i] == _r.SupportBaseTexScale[i])) WriteTexScale(i, _r.SupportBaseTexScale[i]);
            set.Clear();
        }
        void WriteTexScale(int i, float v)
        {
            Span<byte> b = stackalloc byte[4];
            System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(b, v);
            ulong sb = _r.SupportBuf;
            _r.Inner.SetBufferData(Unsafe.As<ulong, BufferHandle>(ref sb), _r.SupportScaleAt + 16 * i, b);
            _r.SupportTexScale[i] = v; _r.TexScaleWrites++;
        }
        /// <summary>原画框外推：片元绑定的贴图 / 图像两侧各放宽多少纹素（(实际发给后端的宽 − 客体宽)/2；没放宽 = 0）。</summary>
        float TexPad(int binding, bool image)
        {
            if (image) return (uint)binding < (uint)_imageObj.Length && _imageObj[binding] is WidenTexture t && _r.Frame.TryWide(t.Id, out int w0, out int w1) && w0 > 0 ? (w1 - w0) * 0.5f : 0f;
            if ((uint)binding >= MaxTexBind || _fragTexObj[binding] is not ITexture g || _sentTex[(int)ShaderStage.Fragment * MaxTexBind + binding] is not ITexture h || g.Width <= 0) return 0f;
            return (h.Width - g.Width) * 0.5f;
        }
        /// <summary>片元绑定的贴图 / 图像的横向放宽比（实际发给后端的宽 ÷ 客体宽；没放宽 = 1）。</summary>
        float TexRatio(int binding, bool image)
        {
            if (image) return (uint)binding < (uint)_imageObj.Length && _imageObj[binding] is WidenTexture t && _r.Frame.TryWide(t.Id, out int w0, out int w1) && w0 > 0 ? (float)w1 / w0 : 1f;
            if ((uint)binding >= MaxTexBind || _fragTexObj[binding] is not ITexture g || _sentTex[(int)ShaderStage.Fragment * MaxTexBind + binding] is not ITexture h || g.Width <= 0) return 1f;
            return h.Width == g.Width ? 1f : (float)h.Width / g.Width;
        }

        internal bool TryUniform(int binding, out ulong buffer, out int offset, out int size)
        {
            buffer = 0; offset = size = 0;
            if ((uint)binding >= MaxUbo || _ubo[binding].Size <= 0) return false;
            (buffer, offset, size) = _ubo[binding]; return true;
        }
        internal string FragmentTextures()
        {
            var sb = new System.Text.StringBuilder();
            if (_picTex != null) foreach (int b in _picTex) if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is ITexture t) sb.Append($"{b}:{(t is WidenTexture w ? w.Root.Id : 0)}:{t.Width}x{t.Height} ");
            return sb.ToString();
        }
        void Trace(ViewportMode m)
        {
            ViewportMode e = _r.Frame.TargetWide ? m : ViewportMode.Keep;
            var sb = new System.Text.StringBuilder();
            sb.Append($"{m}{(_extrapOn ? "外推" : "")}\t{(e == m ? "" : "→Keep")}\t宽 {_r.Frame.TargetWide} 原生 {_r.Frame.TargetNative} W0 {_r.Frame.TargetW0}\t");
            if (_vpN > 0) { var g = _vp[0].Region; float x = g.X, w = g.Width; _r.Frame.MapViewport(e, ref x, ref w); sb.Append($"视口 {g.X},{g.Y} {g.Width}x{g.Height} → {x},{w}"); }
            sb.Append('\t');
            if (_scN > 0) { var g = _sc[0]; int x = g.X, w = g.Width; _r.Frame.MapScissor(e, ref x, ref w); sb.Append($"裁剪 {g.X},{g.Y} {g.Width}x{g.Height} → {x},{w}"); }
            sb.Append($"\t外推 {(_pushTex == null ? "不可" : m == ViewportMode.Hor && _r.Frame.TargetNative && OnlySmall() ? "推" : "不推")}\t采样");
            if (_picTex != null) foreach (int b in _picTex) if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is ITexture t) sb.Append($" {b}:{(_r.TraceTexName?.Invoke(t) is string tn ? tn + ":" : "")}{t.Width}x{t.Height}{(t is WidenTexture tw && _r.Frame.IsWide(tw.Id) ? "宽" : "")}{(_fragSmp[b] is ISampler sm && _r.TilingU.TryGetValue(sm, out _) ? "平铺" : "")}{(t is WidenTexture wt && _r.Frame.IsScreenCopy(wt.Root.Id) ? "副本" : "")}");
            _r.DrawTrace(sb.ToString());
        }

        // 顶层整画布 16:9 图片（放宽目标上采样一张没放宽、16:9、不小于目标原宽 90%、横向非平铺的贴图：标题图 / 视频帧 / 静态页底图，原尺寸画在中间）：
        // 16:9 下它盖住底下所有层；放宽后两侧露出底层（10-20 马车8 标题 / 选 Mii 页两侧的图标图案菜单底，底层按视野加宽本来就有内容）。
        // 取舍（10-20 总指挥暂定 B，jhz 早上看对比图定；S2A_WIDEN_PIC）：缺省 = 画它之前把两侧条带清黑，本帧之后画到这张目标的绘制剪到中间原宽区
        //   （两侧不露底层、人物不拉伸）；off = 原样（露底层）。
        // 放宽目标上的后处理采样的都是放宽贴图，不命中；比赛画面两侧非黑不变（画幅门禁马车8 录像读数）。
        // 10-21 起放宽目标走 16:9 原比例页（TryBeginPage：同一判据 + 页的来历沿采样链传递、页内按 16:9 原样画）；FullPicture 只留给原生宽目标记出图层标记。
        static readonly bool PicBlack = Environment.GetEnvironmentVariable("S2A_WIDEN_PIC") != "off";
        WidenTexture FullPicture()
        {
            int w0 = _r.Frame.TargetW0;
            if (_picTex == null || w0 <= 0) return null;
            foreach (int b in _picTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t && !_r.Frame.IsWide(t.Id) && t.Height > 0
                    && WidenFrame.IsPagePicture(t.Width, t.Height, t.ResolutionScale, w0, _cur[0]?.ResolutionScale ?? _r.SupportBaseScale)
                    && !(_fragSmp[b] is ISampler sm && _r.TilingU.TryGetValue(sm, out _)))
                    return t;
            return null;
        }
        // 片元采样的贴图里有原比例页内容（WidenTexture.PicPage，不算目标自己）：合成 / 上屏拷贝把页传下去
        bool SamplesPicPage()
        {
            if (_picTex == null) return false;
            foreach (int b in _picTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t && t.Root.PicPage && t.Root != _cur[0]?.Root) return true;
            return false;
        }
        // 这次绘制铺满颜色目标 0 整张（视口从原点起、覆盖整张），片元不采样贴图，或采样的贴图全是 CPU 供图或 PicContent 贴图：目标内容 = CPU 供图转一手（见 WidenTexture.PicContent）
        bool FromPictures()
        {
            if (_picTex == null || _vpN == 0 || _cur[0] is not { } tgt) return false;
            var rg = _vp[0].Region;
            if (Math.Abs(rg.X) >= 0.5f || Math.Abs(rg.Width) < tgt.Width - 1 || Math.Abs(rg.Height) < tgt.Height - 1) return false;
            bool any = false;
            foreach (int b in _picTex)
            {
                if ((uint)b >= (uint)_fragTexObj.Length || _fragTexObj[b] is not WidenTexture t) continue;
                if (t.Root == tgt.Root || _r.Frame.IsWide(t.Id) || t.Root.GpuWritten && !t.Root.PicContent) return false;
                any = true;
            }
            return any || _picTex.Length == 0;   // 不采样贴图的铺满（纯色 / 程序生成的底，10-22 怪猎视频开播前那帧先把视频帧目标铺黑）同样没有更宽内容
        }
        // 16:9 原比例页（10-21，按内容来历判，不按游戏）：放宽目标上的一次绘制采样了「整画布 16:9 图片」——
        //   ① 没放宽的 16:9 贴图、宽 ≥ 画布 90%、横向非平铺（CPU 供图的标题图 / 视频帧；GPU 画出来却没放宽的 16:9 目标也算，但不认证）；
        //   ② 内容是原比例页的放宽贴图（页的来历沿采样链传下去：视频平面 → 合成 → 交换链）。
        // 这张目标的内容就是一张 16:9 图片的重采样，放宽也扩不出内容：本帧余下画到它的绘制一律按 16:9 原样画（改写常量写回原值、视口 / 裁剪原尺寸），
        // 整体平移到页面中心；页面放宽区两侧清黑、之后的绘制剪到内容区。画布 = 从原点起、16:9、不窄于贴图 60% 的视口（掌机档在主机尺寸缓冲里只用左上 1280×720：
        // 暗黑2 1600×900、丝之歌 1920×1080），否则整张贴图。10-20 的旧规则只认①、图片本身仍按 k 拉伸（暗黑2 视频读到不相干的改写矩阵按 Hor 放大、字幕按 k 拉宽），
        // 也认不出 GPU 转出来的视频平面（巫师3 两侧粉带）。
        // 新起一页（来源有①）要求目标高至少半个掌机屏（360）：小的后处理缓冲（怪猎曝光缩减 32×18 / 128×72）采样录像序章换回原宽的同尺寸缓冲时会凑成「整画布 16:9 图片」，不是页。
        // 只从页传下来（来源全是②）不限尺寸：页的缩小 / 模糊链（马车8 选 Mii 页背景 1280 → 320×180 模糊 → 画回页）也是页
        bool TryBeginPage()
        {
            WidenTexture c0 = _cur[0];
            int w0 = _r.Frame.TargetW0, cw = w0;
            if (_vpN > 0)
            {
                var rg = _vp[0].Region; float vw = Math.Abs(rg.Width), vh = Math.Abs(rg.Height);
                if (Math.Abs(rg.X) < 0.5f && vh > 0 && Math.Abs(vw / vh / (16f / 9f) - 1) < 0.01f && vw >= 0.6f * w0 && vw < w0) cw = (int)Math.Round(vw);
            }
            if (!PageSource(cw, out bool cert) || !_r.Frame.BeginPage(c0.Id, 0, cw, out int pc0, out int pc1, out int pm0, out int pm1)) return false;
            ClearCols(0, c0, pm0, pc0); ClearCols(0, c0, pc1, pm1);
            _r.NoteWrite(c0);
            WidenTexture r = c0.Root; r.PageContent = true; r.PageCertified = cert; r.PageX0 = 0; r.PageW = cw; r.PageShift = _r.Frame.PageShift(c0.Id, 0, cw);
            _r.PicDraws++;
            if (_r.PicLog < 6) { _r.PicLog++; Console.Error.WriteLine($"[宽屏] 16:9 原比例页：目标 {c0.Width}×{c0.Height} 画布 {cw} 宽，内容 [{pc0},{pc1})、两侧 [{pm0},{pc0}) [{pc1},{pm1}) 清黑{(cert ? "" : "（来源有 GPU 画出来却没放宽的 16:9 目标：不认证，满屏判据照判）")}（第 {_r.PicDraws} 页）"); }
            _stateDirty = true;
            return true;
        }
        /// <summary>这次绘制片元采样的贴图里有没有整画布 16:9 图片（见 TryBeginPage ① ②）；certified = 找到的来源全是 CPU 供图或认证过的页。
        /// 同时采样了内容不是页的放宽贴图（真宽的场景 / 后处理）→ 不是页：目标内容里有能扩的部分（10-21 怪猎：曝光缩减链的小缓冲成了页，
        /// 色调映射同时采样场景与曝光，不加这条整屏都会被当成页、丢掉宽视野）。</summary>
        bool PageSource(int canvasW, out bool certified)
        {
            certified = true; bool any = false, fresh = false;
            if (_picTex == null || _cur[0] is not { } tgt) return false;
            foreach (int b in _picTex)
            {
                if ((uint)b >= (uint)_fragTexObj.Length || _fragTexObj[b] is not WidenTexture t || t.Height <= 0) continue;
                if (_r.Frame.IsWide(t.Id)) { if (!t.Root.PageContent) return false; any = true; certified &= t.Root.PageCertified; continue; }
                if (WidenFrame.IsPagePicture(t.Width, t.Height, t.ResolutionScale, canvasW, tgt.ResolutionScale) && !(_fragSmp[b] is ISampler sm && _r.TilingU.TryGetValue(sm, out _)))
                { any = fresh = true; certified &= !t.Root.GpuWritten; }
            }
            return any && !(fresh && !WidenFrame.IsPageTarget(tgt.Height, tgt.ResolutionScale));
        }

        // 铺满整张颜色目标 0 的绘制（视口覆盖整张）：采样的都是整屏画面 / 整屏副本（≤8×8 的噪声 / 查找表不算），就把目标记为整屏副本（WidenFrame.IsScreenCopy，外推判据用）。
        // 要「都是」：动森 488×200 界面层离屏图采样 66×40 的整屏缩图之外还采样 64×64 / 256×256 平铺花纹，内容是界面不是整屏——按「有一张」判会把它当副本外推，时钟被横向拉宽（金样第 593 帧）
        void NoteScreenCopy()
        {
            if (_cur[0] is not { } rt || _picTex == null || _vpN == 0) return;
            var g = _vp[0].Region;
            if (g.X > 0 || g.X + g.Width < rt.Width || Math.Abs(g.Height) < rt.Height) return;
            bool scr = false, other = false;
            foreach (int b in _picTex)
            {
                if ((uint)b >= (uint)_fragTexObj.Length || _fragTexObj[b] is not ITexture t) continue;
                if (t is WidenTexture w && (_r.Frame.IsScreenAspect(t.Width, t.Height, w.ResolutionScale) || _r.Frame.IsScreenCopy(w.Root.Id))) scr = true;
                else if (!Small(t)) other = true;
            }
            _r.Frame.OnTargetFilled(rt.Root.Id, rt.Width, rt.Height, scr && !other, rt.ResolutionScale);
        }

        // 外推只挪 gl_Position.x、不动贴图坐标：画布边 ±1/k 的顶点挪到 ±1，同一段贴图坐标铺到 k 倍宽 = 贴图内容（含平铺周期）横向拉伸 k 倍。
        // 所以只推「拉伸看不出」的绘制：不采样贴图（纯色）或只采样 ≤8×8 小图（纯色 / 渐变底）；例外是 16:9 的整屏副本（推了是还原，见下）。横向平铺采样的大贴图不推（10-21：采样器 repeat 不等于布局里真铺了多遍——
        // nn::ui2d 只铺一遍的整画布底也是 repeat，推了就是整张底图拉伸 k 倍；真平铺的底由数据层 ui_lyt.py 加宽、SRT 同比放大，再推会把已到屏幕边的底又拉伸一次）。
        // 原尺寸居中层的收缩外推（BeforeDraw shrink）用：采样的贴图都是 ≤8×8 小图或平铺寻址的贴图（底纹 / 雾 / 暗角叠层）。比 OnlySmall 宽，只用于这条新路径（Hor 层外推判据不变）。
        // 10-21 暗黑3：自动存档页黑底 32×8 平铺（BC 压缩底纹，着色器乘黑色常量）、主菜单 1024² / 2048² 平铺暗角叠层（推了 16:9 边界接缝消失，叠层横向多铺 k 倍，jhz 可否决）；
        // 夹边寻址的大图（立绘、字模、整画布图片）不推。nn::ui2d 界面读改写后的 16:9 投影，走 Hor，不进这条
        bool OnlyBackground()
        {
            foreach (int b in _pushTex)
            {
                if ((uint)b >= (uint)_fragTexObj.Length || _fragTexObj[b] is not ITexture t || Small(t)) continue;
                if (_fragSmp[b] is ISampler sm && _r.TilingU.TryGetValue(sm, out _)) continue;
                return false;
            }
            return true;
        }

        /// <summary>当前程序实际采样的贴图里有没有放宽 / 整屏贴图（界面层判定用：有就是整屏后处理，不按界面居中）。</summary>
        bool SampledWide()
        {
            if (_picTex == null) return false;
            foreach (int b in _picTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t)
                {
                    foreach (uint id in stackalloc uint[] { t.Id, t.Root.Id })
                        if (_r.Frame.IsWide(id) || _r.Frame.IsNative(id) || _r.Frame.IsScreenCopy(id)) return true;
                }
            return false;
        }

        // 铺满画布的视口：从原点起、宽 = 目标原宽，或 16:9 且不窄于原宽 60%（掌机档在主机尺寸缓冲里只用左上 1280×720，同 TryBeginPage 的画布）
        /// <summary>原画框外推的 pad：视口按 k 拉宽后，原画框内容居中放回视口中心——pad = (k − 1)·(视口 x + 视口宽 / 2)。
        /// 整画布视口即 (W1 − W0) / 2；10-23 丝之歌把 1280×720 画进 1920×1080 交换链左上一块，按整张目标算差 71 像素（画面整体右移）。</summary>
        float ExtrapPad()
        {
            float k = _r.Frame.TargetScaleX ?? 1f; var rg = _vp[0].Region;
            return (k - 1f) * (rg.X + Math.Abs(rg.Width) * 0.5f);
        }
        /// <summary>原生宽目标（没放宽，TargetW0 = 0）：视口铺满出图区（整张或左上屏幕比例一块），裁剪（没设 = 不裁）不小于视口。</summary>
        bool CoversTarget()
        {
            if (_vpN == 0 || _cur[0] is not { } t) return false;
            var rg = _vp[0].Region; float vw = Math.Abs(rg.Width), vh = Math.Abs(rg.Height);
            if (Math.Abs(rg.X) >= 0.5f) return false;
            // 整张，或从原点起、宽高比 = 屏幕（16:9 × k）且不窄于目标 60%（掌机档在主机尺寸交换链里只用左上 1564×720，10-23 怪猎上屏那一笔）
            bool whole = vw >= t.Width - 1f && vh >= t.Height - 1f;
            bool corner = vh > 0 && vw >= 0.6f * t.Width && Math.Abs(vw / vh / (16f / 9f * _r.Frame.Rewriter.K) - 1) < 0.01f;
            if (!whole && !corner) return false;
            if (_scN == 0) return true;
            var g = _sc[0]; return g.X <= 0 && g.X + g.Width >= vw - 1f && g.Y <= 0 && g.Y + g.Height >= vh - 1f;
        }
        /// <summary>裁剪（没设 = 不裁）盖住整个画布：原宽 W0 × 目标高。</summary>
        bool FullCanvasScissor()
        {
            if (_scN == 0 || _cur[0] is not { } t) return true;
            var g = _sc[0]; return g.X <= 0 && g.X + g.Width >= _r.Frame.TargetW0 && g.Y <= 0 && g.Y + g.Height >= t.Height;
        }
        bool FullCanvasViewport()
        {
            if (_vpN == 0) return false;
            var rg = _vp[0].Region; float vw = Math.Abs(rg.Width), vh = Math.Abs(rg.Height); int w0 = _r.Frame.TargetW0;
            return Math.Abs(rg.X) < 0.5f && (Math.Abs(vw - w0) < 1f || vh > 0 && Math.Abs(vw / vh / (16f / 9f) - 1) < 0.01f && vw >= 0.6f * w0 && vw < w0);
        }
        /// <summary>本次绘制采样的贴图里有带 CamContent 的（程序读法未知时按片元各槽位当前绑定的判，保守）。</summary>
        bool SampledCam()
        {
            if (_picTex == null) { foreach (ITexture o in _fragTexObj) if (o is WidenTexture w && w.Root.CamContent) return true; return false; }
            foreach (int b in _picTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t && t.Root.CamContent) return true;
            return false;
        }
        /// <summary>计算阶段各采样槽当前绑定的贴图里有带 CamContent 的（派发用）。</summary>
        bool ComputeSampledCam()
        {
            int c0 = (int)ShaderStage.Compute * MaxTexBind;
            for (int b = 0; b < MaxTexBind; b++) if (_boundTex[c0 + b] is WidenTexture w && w.Root.CamContent) return true;
            return false;
        }
        /// <summary>本次绘制采样的贴图里有带 Scene3D 的（程序读法未知时按片元各槽位当前绑定的判，保守）。</summary>
        bool SampledScene3D()
        {
            if (_picTex == null) { foreach (ITexture o in _fragTexObj) if (o is WidenTexture w && w.Root.Scene3D) return true; return false; }
            foreach (int b in _picTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t && t.Root.Scene3D) return true;
            return false;
        }
        bool SampledBands()
        {
            if (_picTex == null) return false;
            foreach (int b in _picTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is WidenTexture t && t.Root.Bands) return true;
            return false;
        }

        bool HasColorTarget() { foreach (WidenTexture t in _cur) if (t != null) return true; return false; }
        bool OnlySmall()
        {
            foreach (int b in _pushTex)
                if ((uint)b < (uint)_fragTexObj.Length && _fragTexObj[b] is ITexture t && !Small(t)
                    && !(t is WidenTexture wt && _r.Frame.IsScreenCopy(wt.Root.Id) && !_r.Frame.IsScreenAspect(wt.Width, wt.Height, wt.ResolutionScale)))   // 16:9 的整屏副本：界面库按画布铺满（UV 0..1）、内容是整屏横向压了 k 倍，推到屏幕边 = 按原比例还原，不是拉伸（WidenFrame.IsScreenCopy）
                {
                    int mode = _fragSmp[b] is ISampler s2 && _r.SmpU.TryGetValue(s2, out object am) ? (int)(AddressMode)am : -1;
                    if (_r.EdgeSkipSeen.Count < 40 && _r.EdgeSkipSeen.Add((t.Width, t.Height, mode)))
                        Console.Error.WriteLine($"[宽屏] 外推跳过：绑定 {b} 贴图 {t.Width}x{t.Height} 横向寻址 {(mode < 0 ? "无采样器" : ((AddressMode)mode).ToString())}（全部采样绑定 [{string.Join(",", _pushTex)}]）");
                    return false;
                }
            return true;
        }

        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) { _dKind = 1; _dCount = vertexCount; _dFirst = firstVertex; _dBase = 0; _dInst = instanceCount; BeforeDraw(); _p.Draw(vertexCount, instanceCount, firstVertex, firstInstance); }
        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance) { _dKind = 2; _dCount = indexCount; _dFirst = firstIndex; _dBase = firstVertex; _dInst = instanceCount; BeforeDraw(); _p.DrawIndexed(indexCount, instanceCount, firstIndex, firstVertex, firstInstance); }
        public void DrawIndexedIndirect(BufferRange indirectBuffer) { _dKind = 0; BeforeDraw(); _p.DrawIndexedIndirect(indirectBuffer); }
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) { _dKind = 0; BeforeDraw(); _p.DrawIndexedIndirectCount(indirectBuffer, parameterBuffer, maxDrawCount, stride); }
        public void DrawIndirect(BufferRange indirectBuffer) { _dKind = 0; BeforeDraw(); _p.DrawIndirect(indirectBuffer); }
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) { _dKind = 0; BeforeDraw(); _p.DrawIndirectCount(indirectBuffer, parameterBuffer, maxDrawCount, stride); }

        // ---------- 原画框外推写侧：这笔几何是否铺满画布（10-23）----------
        int _dKind, _dCount, _dFirst, _dBase, _dInst;   // 当前绘制：0 间接（判不出）/ 1 非索引 / 2 索引
        // 顶点状态（几何判定读）：拷进复用数组 + 条数，不逐次新建（10-23 动森每帧约 730 次 ToArray、317 KB）
        VertexAttribDescriptor[] _va = new VertexAttribDescriptor[32]; int _vaN; VertexBufferDescriptor[] _vb = new VertexBufferDescriptor[32]; int _vbN; BufferRange _ib; IndexType _ibt;
        const int GeomMaxVerts = 64;
        sealed class GeomEnv : IPosEnv
        {
            public WidenPipeline P; public uint Vid, Iid;
            // 读到的字（几何判定结果缓存的依赖，见 GeomCovers）：按绑定记（种类 0 常量绑定 / 1 顶点缓冲 / 2 索引区间 + 槽号 + 绑定内偏移 + 值），
            //   复核时按当时的绑定重读——环形常量缓冲每帧换偏移照样能比；复用数组，超过上限或有字读不到就不进缓存
            internal const int ReadMax = 1024;
            internal readonly byte[] RdKind = new byte[ReadMax]; internal readonly int[] RdSlot = new int[ReadMax], RdOff = new int[ReadMax]; internal readonly uint[] RdVal = new uint[ReadMax];
            internal int RdN; internal bool RdOver;
            // 第一个读不到的字（CPU 侧拿不准）：求值就此停（结果必然判不出），条目记下它，下次先单读它一下（见 GeomCovers）
            internal bool Failed; internal byte FKind; internal int FSlot, FOff;
            public bool Stop => Failed;
            readonly uint[] _w = new uint[4];
            // 同一个字（种类 / 槽 / 偏移）只记一次：每个顶点都读同一份矩阵常量，不去重 64 个顶点 × 16 字就把上限占满（10-23 巫师3 每帧 7 笔因此进不了缓存）。
            //   去重表定长开放寻址、按代号作废（每次求值代号加一，不清表），零分配
            const int DedupBits = 11;
            readonly int[] _dedupGen = new int[1 << DedupBits]; readonly int[] _dedupIdx = new int[1 << DedupBits]; int _gen;
            internal void BeginEval() { RdN = 0; RdOver = false; Failed = false; if (++_gen == int.MaxValue) { Array.Clear(_dedupGen); _gen = 1; } }
            internal void Note(byte kind, int slot, int off, uint v)
            {
                uint h = ((uint)kind * 0x9E3779B1u ^ (uint)slot * 0x85EBCA77u ^ (uint)off * 0xC2B2AE3Du) >> (32 - DedupBits);
                for (int p = 0; p < 1 << DedupBits; p++, h = (h + 1) & ((1u << DedupBits) - 1))
                {
                    if (_dedupGen[h] != _gen) break;
                    int i = _dedupIdx[h]; if (RdKind[i] == kind && RdSlot[i] == slot && RdOff[i] == off) return;
                }
                if (RdN >= ReadMax) { RdOver = true; return; }
                _dedupGen[h] = _gen; _dedupIdx[h] = RdN;
                RdKind[RdN] = kind; RdSlot[RdN] = slot; RdOff[RdN] = off; RdVal[RdN] = v; RdN++;
            }
            // 取绑定 r 里 [off, off+len)（len ≤ 16）：只读 CPU 侧此刻内容（WidenPipeline.Peek，不等 GPU）；读不到 = 判不出，且这次不进缓存
            uint[] Get(byte kind, int slot, BufferRange r, int off, int len)
            {
                if (len > 16) { RdOver = true; return null; }
                if (!P.Peek(r, off, MemoryMarshal.AsBytes(_w.AsSpan(0, len >> 2)), kind == 0)) { if (!Failed) { Failed = true; FKind = kind; FSlot = slot; FOff = off; } return null; }
                for (int q = 0; q < len >> 2; q++) Note(kind, slot, off + q * 4, _w[q]);
                return _w;
            }
            public bool Attr(int loc, int lane, out uint bits)
            {
                bits = lane == 3 ? 0x3f800000u : 0;
                if ((uint)loc >= (uint)P._vaN) return false;
                VertexAttribDescriptor a = P._va[loc]; if (a.IsZero) return true;
                if ((uint)a.BufferIndex >= (uint)P._vbN) return false;
                VertexBufferDescriptor vb = P._vb[a.BufferIndex]; uint idx = vb.Divisor != 0 ? Iid / (uint)vb.Divisor : Vid;
                int comps = a.Format switch { Format.R32G32B32A32Float => 4, Format.R32G32B32Float => 3, Format.R32G32Float => 2, Format.R32Float => 1, _ => 0 };
                if (comps == 0) return false;
                if (lane >= comps) return true;
                uint[] d = Get(1, a.BufferIndex, vb.Buffer, (int)idx * vb.Stride + a.Offset + lane * 4, 4); if (d == null) return false;
                bits = d[0]; return true;
            }
            public uint Builtin(uint bi) => bi switch { 42 or 5 => Vid, 43 or 6 => Iid, _ => 0 };
            public bool Ubo(int binding, int off, out uint bits)
            {
                bits = 0; if ((uint)binding >= (uint)P._ubo.Length) return false;
                var u = P._ubo[binding]; if (u.Size <= 0 || off + 4 > u.Size) return false;
                uint[] d = Get(0, binding, new BufferRange(Unsafe.As<ulong, BufferHandle>(ref u.Buf), u.Off, u.Size), off & ~15, 16); if (d == null) return false;
                bits = d[(off & 15) >> 2]; return true;
            }
        }
        /// <summary>只读 CPU 侧此刻内容（不等 GPU、不读回）：绑定 r 内 [off, off+dst.Length)。GPU 写过的缓冲、越界、没接通（CpuPeek 空）一律 false。</summary>
        //   常量（cbuf）先读宽屏层自己的常量缓冲影子（CbufShadow：CPU 递来的原值，按粒记已知，迁移 / 拷贝时跟着搬）——上传租约等路径由 GPU 拷进真缓冲，
        //   原生侧判拿不准（10-23 巫师3 每帧 318 次），影子里却是已知的；影子没有再问原生侧
        bool Peek(BufferRange r, int off, Span<byte> dst, bool cbuf = false)
        {
            if (r.Size <= 0 || off < 0 || off + dst.Length > r.Size || _r.GpuWrittenBufs.Contains(WidenRenderer.Key(r.Handle))) return false;
            if (cbuf && _r.Frame.Shadow.TryGet(WidenRenderer.Key(r.Handle)) is { } sb && sb.ReadKnown(r.Offset + off, dst)) return true;
            return _r.CpuPeek != null && _r.CpuPeek(r.Handle, r.Offset + off, dst);
        }
        bool CanRead(byte kind, int slot, int off) { Span<byte> one = stackalloc byte[4]; return Bind(kind, slot, out BufferRange r) && Peek(r, off, one, kind == 0); }
        bool Bind(byte kind, int slot, out BufferRange r)
        {
            r = default;
            if (kind == 0) { if ((uint)slot >= (uint)_ubo.Length || _ubo[slot].Size <= 0) return false; var u = _ubo[slot]; r = new BufferRange(Unsafe.As<ulong, BufferHandle>(ref u.Buf), u.Off, u.Size); }
            else if (kind == 1) { if ((uint)slot >= (uint)_vbN) return false; r = _vb[slot].Buffer; }
            else r = _ib;
            return true;
        }
        /// <summary>读记录 i 按当时的绑定重读，值是否不变。</summary>
        bool RereadSame(byte kind, int slot, int off, uint val)
        {
            BufferRange r;
            if (kind == 0) { if ((uint)slot >= (uint)_ubo.Length || _ubo[slot].Size <= 0) return false; var u = _ubo[slot]; r = new BufferRange(Unsafe.As<ulong, BufferHandle>(ref u.Buf), u.Off, u.Size); }
            else if (kind == 1) { if ((uint)slot >= (uint)_vbN) return false; r = _vb[slot].Buffer; }
            else r = _ib;
            Span<byte> one = stackalloc byte[4];
            return Peek(r, off, one, kind == 0) && MemoryMarshal.Read<uint>(one) == val;
        }
        readonly GeomEnv _genv = new();
        /// <summary>这笔绘制的几何在 x 上铺满客体画布（各顶点 NDC x/w 的最小 ≤ −1、最大 ≥ 1，容差 1e-3）：1 铺满、0 只盖一部分、−1 判不出（间接绘制 / 顶点多 / 位置切片没有 / 读不到输入）。</summary>
        // 结果缓存（10-23 巫师3 每帧解释执行约 3.3 MB 分配、8–20 ms）：键 = 程序 + 绘制参数 + 索引区间 + 顶点格式 / 缓冲绑定 + 常量绑定的 64 位散列（存程序引用复核）；
        //   结果只取决于求值时读到的字（顶点属性、常量、索引），条目按绑定记下这些字，命中时按当时的绑定逐字重读比值——流式缓冲每帧重传 / 换偏移但值没变照样命中。
        //   读一律只读 CPU 侧此刻内容（CpuPeek，不等 GPU；10-23 帧率能耗线：GetBufferData 读刚写过的小缓冲次次 gal_finish），读不到 = 判不出。
        //   上限 GeomCacheMax 条，满了整表清空；读到的字超过 ReadMax 不进缓存
        const int GeomCacheMax = 1024;
        // Unreadable：求值时有个字读不到（FKind / FSlot / FOff），结果 −1；复核 = 那个字此刻仍读不到（读得到了就重算）
        // 条目与其数组复用（新几何帧建条目也不分配）：数组取自共享数组池、条目对象回收进 _geomFree；整表清空 / 同键覆盖时还回去
        sealed class GeomEntry { public IProgram Prog; public int Result; public int N; public byte[] Kind; public int[] Slot, Off; public uint[] Val; public bool Unreadable; public byte FKind; public int FSlot, FOff; }
        readonly Stack<GeomEntry> _geomFree = new();
        void GeomRelease(GeomEntry e)
        {
            if (e.Kind != null) { System.Buffers.ArrayPool<byte>.Shared.Return(e.Kind); System.Buffers.ArrayPool<int>.Shared.Return(e.Slot); System.Buffers.ArrayPool<int>.Shared.Return(e.Off); System.Buffers.ArrayPool<uint>.Shared.Return(e.Val); }
            e.Kind = null; e.Slot = e.Off = null; e.Val = null; e.N = 0; e.Prog = null; e.Unreadable = false; _geomFree.Push(e);
        }
        void GeomClearAll() { foreach (GeomEntry e in _geomCache.Values) GeomRelease(e); _geomCache.Clear(); }
        GeomEntry GeomPut(ulong key)
        {
            if (_geomCache.Remove(key, out GeomEntry old)) GeomRelease(old);
            else if (_geomCache.Count >= GeomCacheMax) GeomClearAll();
            GeomEntry e = _geomFree.Count > 0 ? _geomFree.Pop() : new GeomEntry();
            _geomCache[key] = e; return e;
        }
        readonly Dictionary<ulong, GeomEntry> _geomCache = new();
        uint[] _ix = new uint[GeomMaxVerts];
        ulong GeomKey()
        {
            ulong h = 14695981039346656037UL;
            void Mix(ulong v) { h = (h ^ v) * 1099511628211UL; }
            Mix((ulong)System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(_prog)); Mix((ulong)_dKind); Mix((ulong)_dCount); Mix((ulong)(uint)_dFirst); Mix((ulong)(uint)_dBase); Mix((ulong)_dInst);
            if (_dKind == 2) Mix((ulong)_ibt);
            foreach (byte b in MemoryMarshal.AsBytes(_va.AsSpan(0, _vaN))) Mix(b);
            for (int i = 0; i < _vbN; i++) { Mix((ulong)(uint)_vb[i].Stride); Mix((ulong)(uint)_vb[i].Divisor); }   // 缓冲区间不进键：读到的字按绑定复核
            for (int i = 0; i < _ubo.Length; i++) if (_ubo[i].Size > 0) Mix((ulong)i);
            return h;
        }
        bool GeomStillSame(GeomEntry e)
        {
            if (e.Unreadable) return !CanRead(e.FKind, e.FSlot, e.FOff);
            for (int i = 0; i < e.N; i++) if (!RereadSame(e.Kind[i], e.Slot[i], e.Off[i], e.Val[i])) return false;
            return true;
        }
        internal static long GeomEvals, GeomHits;
        // 输入此刻在 CPU 侧读不到（GPU 写着 / 在录命令里刚写过）：几何不明，按拉伸画（不外推）——10-23 只读 CPU 侧后按「判不出 = 铺满」外推，
        //   巫师3 小地图 / 丝之歌血条这类界面子块在读不到的那几帧被外推、错位破图；拉伸是外推之前的画法，不会破图
        internal const int GeomUnread = -2;
        /// <summary>这笔绘制的几何在 x 上铺满客体画布（各顶点 NDC x/w 的最小 ≤ −1、最大 ≥ 1，容差 1e-3）：1 铺满、0 只盖一部分、−1 判不出（间接绘制 / 顶点多 / 位置切片没有 / 读不到输入）。
        // 几何判定的时间一致性（10-23 jhz 实机巫师3 露台：站着不动远处 / 右侧外延逐帧在变）：同一个全屏遍（程序 10 把 231 / 236 写进 220）
        // 一帧顶点缓冲读得到 → 外推、下一帧读不到（流式顶点缓冲的在途上传）→ 按拉伸，两种画法逐帧交替，外延内容跟着跳。
        // 读不到时沿用同一程序、同样顶点数 / 绘制种类 / 实例数 / 视口上一次确定的结果；从没判出来过的照旧按拉伸（10-23 界面子块读不到时别外推的保护不变）
        int GeomCovers()
        {
            int r = GeomCoversNow();
            if (_prog == null || _dKind == 0) return r;
            var k = (_dCount, (int)_dKind, _dInst, _vpN > 0 ? (int)_vp[0].Region.X : 0, _vpN > 0 ? (int)_vp[0].Region.Width : 0);
            if (r is 0 or 1) { (_prog.LastGeom ??= new())[k] = r; return r; }
            if (r == GeomUnread && _prog.LastGeom != null && _prog.LastGeom.TryGetValue(k, out int last)) { _r.ExtrapGeomReuse++; return last; }
            return r;
        }
        int GeomCoversNow()
        {
            // 实例化散点（实例数 > 4）不是铺满画布的四边形：插值外推（v + dFdx(v)·Δ）对精灵内坐标不成立（10-23 八方2 景深散点外推后几乎画空）→ 按「只盖部分」
            if (_dKind != 0 && _dInst > 4) return 0;
            if (_prog?.Pos is not SpirvPosSlice ps || _dKind == 0 || _dCount <= 0 || _dCount > GeomMaxVerts || _dInst > 4) return -1;
            ulong key = GeomKey();
            if (_geomCache.TryGetValue(key, out GeomEntry ce) && ReferenceEquals(ce.Prog, _prog) && GeomStillSame(ce)) { GeomHits++; return ce.Result; }
            GeomEvals++;
            _genv.P = this; _genv.BeginEval(); float mn = float.MaxValue, mx = float.MinValue;
            if (_dKind == 2)
            {
                int isz = _ibt switch { IndexType.UByte => 1, IndexType.UShort => 2, _ => 4 }, off = _dFirst * isz, len = _dCount * isz;
                if ((len & 3) != 0) return -1;   // 奇数个 16 位 / 8 位索引：按字复核不了，判不出（这类绘制少，不值得另记）
                Span<byte> raw = stackalloc byte[GeomMaxVerts * 4];
                if (!Peek(_ib, off, raw[..len])) return GeomUnread;
                for (int i = 0; i < _dCount; i++) _ix[i] = isz == 1 ? raw[i] : isz == 2 ? BitConverter.ToUInt16(raw[(i * 2)..]) : BitConverter.ToUInt32(raw[(i * 4)..]);
                for (int q = 0; q + 4 <= len; q += 4) _genv.Note(2, 0, off + q, MemoryMarshal.Read<uint>(raw[q..]));
            }
            int res = 1;
            for (uint inst = 0; inst < (uint)Math.Max(1, _dInst) && res >= 0; inst++)
                for (int i = 0; i < _dCount; i++)
                {
                    _genv.Vid = _dKind == 2 ? (uint)(_ix[i] + _dBase) : (uint)(_dFirst + i); _genv.Iid = inst;
                    if (!ps.Eval(_genv, out float x, out float w) || !(w > 1e-6f)) { res = -1; break; }
                    float n = x / w; if (n < mn) mn = n; if (n > mx) mx = n;
                }
            if (res >= 0) res = mn <= -1f + 1e-3f && mx >= 1f - 1e-3f ? 1 : 0;
            if (_genv.Failed)
            {
                // 读不到：结果 −1（判不出）。记下读不到的那个字，之后它仍读不到就直接答 −1、不再解释执行（10-23 巫师3 每帧 7 笔、每笔约 22 万字节）
                GeomEntry ue = GeomPut(key); ue.Prog = _prog; ue.Result = GeomUnread; ue.Unreadable = true; ue.FKind = _genv.FKind; ue.FSlot = _genv.FSlot; ue.FOff = _genv.FOff;
                return GeomUnread;
            }
            if (!_genv.RdOver)
            {
                int n = _genv.RdN; GeomEntry e = GeomPut(key); e.Prog = _prog; e.Result = res; e.N = n;
                e.Kind = System.Buffers.ArrayPool<byte>.Shared.Rent(Math.Max(n, 1)); e.Slot = System.Buffers.ArrayPool<int>.Shared.Rent(Math.Max(n, 1)); e.Off = System.Buffers.ArrayPool<int>.Shared.Rent(Math.Max(n, 1)); e.Val = System.Buffers.ArrayPool<uint>.Shared.Rent(Math.Max(n, 1));
                _genv.RdKind.AsSpan(0, n).CopyTo(e.Kind); _genv.RdSlot.AsSpan(0, n).CopyTo(e.Slot); _genv.RdOff.AsSpan(0, n).CopyTo(e.Off); _genv.RdVal.AsSpan(0, n).CopyTo(e.Val);
            }
            return res;
        }

        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion)
        {
            if (_sidesPending) ClearPendingSides();
            if (_cur[0] is { } dt) { _r.NoteWrite(dt); if (texture is WidenTexture st && st.Root.CamContent) dt.Root.CamContent = true; }
            ITexture u = WidenRenderer.U(texture);
            uint sid = texture is WidenTexture t ? t.Id : 0;
            float ks = _r.Frame.TryWide(sid, out int s0, out int s1) ? (float)s1 / s0 : 1;
            float x1 = dstRegion.X1, w = dstRegion.X2 - dstRegion.X1;
            _r.Frame.MapViewport(ViewportMode.ScaleK, ref x1, ref w);   // 目标没放宽时不变
            _p.DrawTexture(u, sampler, new Extents2DF(srcRegion.X1 * ks, srcRegion.Y1, srcRegion.X2 * ks, srcRegion.Y2), new Extents2DF(x1, dstRegion.Y1, x1 + w, dstRegion.Y2));
        }

        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color)
        {
            if ((uint)index < (uint)_cur.Length && _cur[index] is { } t)
            {
                _r.NoteWrite(t);   // 游戏这帧自己清过（按全宽发）：不用再清两侧
                WidenTexture rt = t.Root; rt.Gen++; rt.Bands = false; rt.Scene3D = rt.CamContent = false; rt.Extended = true; rt.NonExtSince = -1; rt.PicContent = rt.PicPage = false; if (!(index == 0 && _r.Frame.PageActive)) rt.PageContent = false;
                _r.Frame.OnTargetCleared(rt.Id);   // 内容不再是整屏副本
            }
            Apply(ViewportMode.ScaleK); _p.ClearRenderTargetColor(index, layer, layerCount, componentMask, color);
        }
        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask) { Apply(ViewportMode.ScaleK); _p.ClearRenderTargetDepthStencil(layer, layerCount, depthValue, depthMask, stencilValue, stencilMask); }

        public void DispatchCompute(int groupsX, int groupsY, int groupsZ)
        {
            // 计算着色器沿用 Ryujinx 等比缩放：恢复之前片元覆盖的 X 项到 GPU 原倍率（GPU 只在自己记的值变了时才写）。
            if (_r.SupportScaleAt >= 0 && _r.SupportTexScaleSet.Count > 0) ResetTexScales();
            // 只认本程序用到的图像（WidenProgram.Images）：别的程序留下的旧绑定不是这次派发的输出（10-22 暗黑2 光照块深度 / 光照剔除一张图不写、输出是存储缓冲，
            // 旧做法看到前面留下的小图绑定 → 按「只写没放宽的图像」把屏幕尺寸 / 逆投影写回原值，光照块只铺到放宽深度图左 1280 列）
            bool anyImg = false, onWide = false;
            for (int b = 0; b < _imageObj.Length; b++)
            {
                if (_imageObj[b] == null || _progImg != null && Array.IndexOf(_progImg, b) < 0) continue;
                anyImg = true; onWide |= _imageWide[b];
                if (_imageObj[b] is WidenTexture it) { it.Root.Scene3D = true; it.Root.Extended = true; it.Root.NonExtSince = -1; }   // 计算写的内容来历不明：保守算 3D；派发补到放宽宽度，框外算外延
            }
            // 内容来历：派发读到改写镜头、或采样了带镜头内容的贴图 → 写的图像带镜头内容（见 WidenTexture.CamContent）
            if (anyImg && (_r.Frame.ReadsCam(_reads.AsSpan(0, BuildReads())) || ComputeSampledCam()))
                for (int b = 0; b < _imageObj.Length; b++)
                    if (_imageObj[b] is WidenTexture ci && (_progImg == null || Array.IndexOf(_progImg, b) >= 0)) ci.Root.CamContent = true;
            if (onWide)
            {
                // 写放宽图像：派发按像素铺就把 X 组数补到放宽宽度（WidenFrame.WidenGroupsX）；不按像素铺的照原样发、记红
                int gx = -1;
                for (int b = 0; b < _imageObj.Length && gx < 0; b++)
                    if (_imageWide[b] && (_progImg == null || Array.IndexOf(_progImg, b) >= 0) && _imageObj[b] is WidenTexture t && _r.Frame.TryWide(t.Id, out int w0, out int w1))
                        gx = WidenFrame.WidenGroupsX(groupsX, groupsY, w0, w1, t.Height);
                if (gx > 0) { _r.Red.ComputeWidened++; groupsX = gx; }
                else _r.Red.ComputeOnWide++;
            }
            // 常量写回原值（同绘制，WidenFrame.OnDispatch）：只写没放宽的图像 = 同画到没放宽的目标
            _r.Frame.OnDispatch(_reads.AsSpan(0, BuildReads()), _r, anyImg && !onWide);
            if (_r.DrawTrace != null) TraceDispatch(groupsX, groupsY, groupsZ);
            _p.DispatchCompute(groupsX, groupsY, groupsZ);
        }

        /// <summary>--trace：计算派发一行（组数、写的图像与采样的贴图：绑定号:宽x高，放宽的标「宽」）。</summary>
        void TraceDispatch(int gx, int gy, int gz)
        {
            var sb = new System.Text.StringBuilder($"派发 {gx},{gy},{gz}\t\t\t\t\t\t图像");
            for (int b = 0; b < _imageObj.Length; b++)
                if (_imageObj[b] is ITexture t) sb.Append($" {b}:{(_r.TraceTexName?.Invoke(t) ?? (t is WidenTexture wi ? wi.Id.ToString() : "?"))}:{t.Width}x{t.Height}{(_imageWide[b] ? "宽" : "")}");
            sb.Append("\t采样");
            int c0 = (int)ShaderStage.Compute * MaxTexBind;
            for (int b = 0; b < MaxTexBind; b++)
                if (_boundTex[c0 + b] is ITexture t) sb.Append($" {b}:{(_r.TraceTexName?.Invoke(t) ?? (t is WidenTexture wi ? wi.Id.ToString() : "?"))}:{t.Width}x{t.Height}{(t is WidenTexture w && _r.Frame.IsWide(w.Id) ? "宽" : "")}");
            _r.DrawTrace(sb.ToString());
        }

        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) => _p.SetTextureArray(stage, binding, array is WidenTextureArray w ? w.Inner : array);
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) => _p.SetTextureArraySeparate(stage, setIndex, array is WidenTextureArray w ? w.Inner : array);
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) => _p.SetImageArray(stage, binding, array is WidenImageArray w ? w.Inner : array);
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) => _p.SetImageArraySeparate(stage, setIndex, array is WidenImageArray w ? w.Inner : array);

        // ---------- 直通 ----------
        public void Barrier() => _p.Barrier();
        public void BeginTransformFeedback(PrimitiveTopology topology) => _p.BeginTransformFeedback(topology);
        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value) { _r.GpuWrittenBufs.Add(WidenRenderer.Key(destination)); _r.Frame.OnClearBuffer(WidenRenderer.Key(destination), offset, size, value); _p.ClearBuffer(destination, offset, size, value); }
        public void CommandBufferBarrier() => _p.CommandBufferBarrier();
        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size) { _r.GpuWrittenBufs.Add(WidenRenderer.Key(destination)); _r.Frame.OnCopyBuffer(WidenRenderer.Key(source), WidenRenderer.Key(destination), srcOffset, dstOffset, size); _p.CopyBuffer(source, destination, srcOffset, dstOffset, size); }
        public void EndTransformFeedback() => _p.EndTransformFeedback();
        public void SetAlphaTest(bool enable, float reference, CompareOp op) => _p.SetAlphaTest(enable, reference, op);
        public void SetBlendState(AdvancedBlendDescriptor blend) => _p.SetBlendState(blend);
        public void SetBlendState(int index, BlendDescriptor blend) => _p.SetBlendState(index, blend);
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp) => _p.SetDepthBias(enables, factor, units, clamp);
        public void SetDepthClamp(bool clamp) => _p.SetDepthClamp(clamp);
        public void SetDepthMode(DepthMode mode) => _p.SetDepthMode(mode);
        public void SetDepthTest(DepthTestDescriptor depthTest) { _depthOn = depthTest.TestEnable || depthTest.WriteEnable; _p.SetDepthTest(depthTest); }
        bool _depthOn;   // 深度测试 / 深度写开着（内容来历 Scene3D 用）
        public void SetFaceCulling(bool enable, Face face) => _p.SetFaceCulling(enable, face);
        public void SetFrontFace(FrontFace frontFace) => _p.SetFrontFace(frontFace);
        public void SetIndexBuffer(BufferRange buffer, IndexType type) { _ib = buffer; _ibt = type; _p.SetIndexBuffer(buffer, type); }
        public void SetLineParameters(float width, bool smooth) => _p.SetLineParameters(width, smooth);
        public void SetLogicOpState(bool enable, LogicalOp op) => _p.SetLogicOpState(enable, op);
        public void SetMultisampleState(MultisampleDescriptor multisample) => _p.SetMultisampleState(multisample);
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel) => _p.SetPatchParameters(vertices, defaultOuterLevel, defaultInnerLevel);
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin) => _p.SetPointParameters(size, isProgramPointSize, enablePointSprite, origin);
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode) => _p.SetPolygonMode(frontMode, backMode);
        public void SetPrimitiveRestart(bool enable, int index) => _p.SetPrimitiveRestart(enable, index);
        public void SetPrimitiveTopology(PrimitiveTopology topology) => _p.SetPrimitiveTopology(topology);
        public void SetRasterizerDiscard(bool discard) => _p.SetRasterizerDiscard(discard);
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask) => _p.SetRenderTargetColorMasks(componentMask);
        public void SetStencilTest(StencilTestDescriptor stencilTest) => _p.SetStencilTest(stencilTest);
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers) { foreach (var a in buffers) if (a.Range.Write && a.Range.Size > 0) _r.GpuWrittenBufs.Add(WidenRenderer.Key(a.Range.Handle)); _p.SetStorageBuffers(buffers); }
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers) => _p.SetTransformFeedbackBuffers(buffers);
        public void SetUserClipDistance(int index, bool enableClip) => _p.SetUserClipDistance(index, enableClip);
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs) { if (vertexAttribs.Length > _va.Length) _va = new VertexAttribDescriptor[vertexAttribs.Length]; vertexAttribs.CopyTo(_va); _vaN = vertexAttribs.Length; _p.SetVertexAttribs(vertexAttribs); }
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers) { if (vertexBuffers.Length > _vb.Length) _vb = new VertexBufferDescriptor[vertexBuffers.Length]; vertexBuffers.CopyTo(_vb); _vbN = vertexBuffers.Length; _p.SetVertexBuffers(vertexBuffers); }
        public void TextureBarrier() => _p.TextureBarrier();
        public void TextureBarrierTiled() => _p.TextureBarrierTiled();
        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual) => _p.TryHostConditionalRendering(value, compare, isEqual);
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual) => _p.TryHostConditionalRendering(value, compare, isEqual);
        public void EndHostConditionalRendering() => _p.EndHostConditionalRendering();
    }
}
