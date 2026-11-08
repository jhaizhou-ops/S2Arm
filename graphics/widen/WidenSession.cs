// 通用宽屏 · 一局的宽屏会话（画幅线，10-24 双轨）：模式判定两种图形模式共用；直连模式（graphics/nvn 回放层经 export/s2a_widen.h 调）的绑定表 / 着色器读法表 / 每笔画法也在这里。
// 通用模式只用 Decide（services/aot/Compose.cs），其余照旧由 GAL 包装层直接调 WidenFrame。直连模式不经 GAL：贴图号、常量绑定（游戏内存 CPU 地址）、着色器句柄都由调用方给。
// 渲染路径零分配：绑定表、读法、出数全是定长数组；只有登记着色器（Shader）会分配。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    public enum WidenMode { Off = 0, Ui = 1, All = 2, Pillar = 3, Observe = 4 }

    public sealed class WidenSession
    {
        /// <summary>按屏幕宽与原生层第二 / 三层结果定模式与目标宽高比（10-21 起 Compose.cs 的判定原样搬来，两种模式同一份）：
        /// 屏幕不比 1920×1080 宽 → Off（只观察）；游戏自己按屏幕比出图（第二层）→ Ui（只管界面层）；第三层表验过 → All（整套放宽）；
        /// 都不是 → Pillar（不放宽，16:9 原比例居中、两侧黑边，出图层不报未满屏；10-21 jhz 实机暗黑2 / 巫师3 拉伸错位）。</summary>
        // screenH（10-26 任意宽高比）：以 1920 宽为基准的屏幕高，屏幕比 16:9 窄时 &gt; 1080（上下多画），宽屏时 1080；宽、高至多一边超出 16:9。</summary>
        public static WidenMode Decide(int screenW, int screenH, bool game, bool full, out float aspect)
        {
            WidenMode m = screenW <= 1920 && screenH <= 1080 ? WidenMode.Off : game ? WidenMode.Ui : full ? WidenMode.All : WidenMode.Pillar;
            aspect = m is WidenMode.Ui or WidenMode.All ? ScreenAspect(screenW, screenH) : 16f / 9f;
            return m;
        }
        /// <summary>屏幕宽高比：窄屏按 1920 ÷ 高，否则按宽 ÷ 1080。</summary>
        public static float ScreenAspect(int screenW, int screenH) => screenH > 1080 ? 1920f / screenH : screenW / 1080f;

        public WidenMode Mode { get; private set; }
        public WidenFrame Frame { get; private set; }
        public WidenRewriter Rewriter => Frame.Rewriter;

        /// <summary>镜头位姿（自动玩家 s2a_ap_cam，同包装层 WidenRenderer.Cam）：直连认出视图投影后每帧上屏发布一份；任何模式都跟踪，不改画面。</summary>
        public CameraTrack Cam { get; private set; }

        /// <param name="observe">只观察（10-25 总指挥：马车8 直连判不到 MARK 是因为直连没有镜头位姿）：宽屏关着、自动玩家开着时起会话，不放宽、不改写，只认镜头</param>
        public WidenSession(int screenW, int screenH, bool game, bool full, bool layout, bool observe = false)
        {
            Mode = observe ? WidenMode.Observe : Decide(screenW, screenH, game, full, out _);
            float aspect = Mode is WidenMode.Ui or WidenMode.All ? ScreenAspect(screenW, screenH) : 16f / 9f;
            Frame = new WidenFrame(new WidenRewriter(aspect)) { GameWide = !observe && game, LayoutWide = !observe && game && layout };
            Cam = new CameraTrack(Frame.Shadow);
            _game = game; _full = full; _layout = layout; _observe = observe;
        }
        readonly bool _game, _full, _layout, _observe;

        /// <summary>运行中换屏（10-27 Duo 合上 1.455 / 展开 1.422；macOS 窗口拖拽）：按新屏幕宽 / 高重定模式与 K / Ky，换一份新的帧状态（贴图登记、改写器、影子、页面全清），
        /// 着色器读法表保留（调用方缓存的着色器句柄照用）。调用方负责之后按新尺寸重新登记贴图、重建放宽的渲染目标（直连：graphics/nvn/widen_glue.inc wd_reaspect）。
        /// 第二层（游戏自己出宽图）开着时游戏的出图尺寸在装载时已定，不换（返回原模式、什么都不动）。返回新模式。</summary>
        public WidenMode Reaspect(int screenW, int screenH)
        {
            if (_observe || _game) return Mode;
            Mode = Decide(screenW, screenH, _game, _full, out _);
            float aspect = Mode is WidenMode.Ui or WidenMode.All ? ScreenAspect(screenW, screenH) : 16f / 9f;
            Frame = new WidenFrame(new WidenRewriter(aspect)) { GameWide = false, LayoutWide = false };
            Cam = new CameraTrack(Frame.Shadow);
            _root.Clear(); _rt.Clear(); Array.Clear(_bind); Array.Clear(_bound); Array.Clear(_noHit);
            _sides = default; _sidesNew = false; _rows = default; _rowsOn = false; _orig = false; Reaspects++; _lightTgt.Clear();
            return Mode;
        }
        public long Reaspects;

        /// <summary>拉伸风险累计（见 Draw）：场景 3D 笔按对 / 拉伸 / 收窄分。</summary>
        public long StretchOk, StretchRisk, SqueezeRisk;
        uint _depth;   // 本遍深度目标（镜头按「绘制最多的深度目标」选主镜头）
        /// <summary>开渲染遍：颜色目标 0 / 深度目标。</summary>
        public void Targets(uint color0, uint depth) { _depth = depth; if (color0 != 0) _drawn.Add(color0); Frame.OnRenderTargets(color0, depth); }

        // ---------- 直连：贴图 ----------
        readonly Dictionary<uint, uint> _root = new();   // 视图 → 根贴图（判「采样了放宽 / 原生宽 / 整屏副本」时根也算，同包装层 SampledWide）
        public const int UseRt = 1, UseRebuild = 2;   // UseRebuild：调用方能在运行中重建这张贴图的存储（按内容判画布，WidenFrame.TryPromote）

        readonly HashSet<uint> _rt = new();   // 登记过的渲染目标（放没放宽都记）：原比例页的来源只认没当过渲染目标的贴图（CPU 供图）
        // 当过颜色目标 / GPU 写过的贴图（只在贴图释放时删）：「当过渲染目标」是历史事实，重登记成放不宽（Texture 不带 UseRt，_rt 删掉）抹不掉它。
        //   11-05 旷野之息 Duo：场景目标 2820（1280×720 加高 900，当过绘制目标）起页时已不在 _rt，合成上屏那笔采样它被认成 16:9 图片，交换链每帧起原比例页，
        //   场景只占画布 [89,632) 行、下面纯黑、红心不见
        readonly HashSet<uint> _drawn = new();
        readonly Dictionary<uint, (int W, int H, float S)> _rtDim = new();   // 渲染目标的客体宽高与倍率（整屏副本登记要判「视口铺满整张目标」，Ui 模式目标不放宽、Frame 不记宽高）
        public int Texture(uint id, int w, int h, float scale, uint usage)
        {
            _root.Remove(id); _lightTgt.Remove(id);   // 重新登记 / 序号复用：写深度旁路的学习按贴图对象作废
            // 存储是游戏内存池 / 放不宽的贴图不放宽、不登记；记成定宽：当颜色目标时整遍不放宽（不从深度目标继承，见 WidenFrame.OnFixedTexture）。
            //   它已是当前颜色目标（胶水在同一遍里第一笔才登记、目标没变不重设）：当场按它重判当前目标
            if ((usage & UseRt) == 0) { _rt.Remove(id); _rtDim.Remove(id); Frame.OnFixedTexture(id); if (Frame.Target0 == id) Frame.OnRenderTargets(id, _depth); return w; }
            _rt.Add(id); _rtDim[id] = (w, h, scale > 0 ? scale : 1f);
            return Frame.OnCreateTexture(id, w, h, scale > 0 ? scale : 1f, (usage & UseRebuild) != 0);
        }
        /// <summary>视图宽由父定（同包装层 WidenTexture.CreateView：父放宽且视图是父第 level 级的同宽视图 → 父放宽宽按级缩）。</summary>
        public int View(uint id, uint parent, int level, int w0)
        {
            uint r = _root.TryGetValue(parent, out uint pr) ? pr : parent;
            _root[id] = r; _lightTgt.Remove(id);
            if (Frame.TryTall(parent, out int ph0, out int ph1) && Frame.TryWide(parent, out int tw0, out _) && w0 == Math.Max(1, tw0 >> level))   // 窄屏加高的父：视图同级加高（宽不变）
            { Frame.OnCreateViewTall(id, w0, Math.Max(1, ph0 >> level), Math.Max(1, ph1 >> level)); return w0; }
            if (Frame.TryWide(parent, out int pw0, out int pw1) && w0 == Math.Max(1, pw0 >> level)) { int vw = Frame.OnCreateView(id, w0, Math.Max(1, pw1 >> level)); if (level == 0) Frame.InheritCorner(id, r); return vw; }
            Frame.OnReleaseTexture(id);
            if (level == 0) Frame.OnCreateViewUndecided(id, r);   // 未定贴图的整级视图：画在它上面同样按内容判画布（晋升后调用方对它重调 View，按上面父放宽登记）
            return w0;
        }
        public void Release(uint id) { _root.Remove(id); _rt.Remove(id); _drawn.Remove(id); _rtDim.Remove(id); _lightTgt.Remove(id); Frame.OnReleaseTexture(id); }
        /// <summary>GPU 写过的贴图（计算派发写的图像、贴图拷贝的目标）记进 _rt：原比例页的来源只认 CPU 供图，GPU 写出的场景不是图片——放不放宽都一样（10-26 八方2：
        /// 计算写的 896×504 场景图存储放不宽、没登记，被认成 CPU 供图起了原比例页，清晰层只铺中间 896 列、右侧拉丝）。src ≠ 0：只在 src 本身是 GPU 写的时才记
        /// （视频帧等 CPU 供图被拷来拷去仍是图片）。返回 1 = 记了。不放宽、不改 Frame。</summary>
        public int GpuWrote(uint id, uint src)
        {
            // 放宽目标被计算整张写 / 从放宽的源拷来：两侧本帧有确定内容（见 WidenFrame.NoteSidesWritten）。从 CPU 供图拷来的只盖客体那一块，不算
            if (id != 0 && Frame.IsWide(id) && (src == 0 || Frame.IsWide(src) || Frame.IsWide(Root(src)))) Frame.NoteSidesWritten(id);
            if (id != 0 && src != 0) Frame.OnCopyPageSource(id, Frame.IsPageSource(src) || Frame.IsPageSource(Root(src)));   // 拷贝搬的是源的内容：页来源随源（见 OnCopyPageSource）
            if (id == 0 || src != 0 && !_rt.Contains(src) && !_rt.Contains(Root(src))) return 0;
            _rt.Add(id); _drawn.Add(id); return 1;
        }
        uint Root(uint id) => _root.TryGetValue(id, out uint r) ? r : id;

        // ---------- 直连：常量绑定 ----------
        public const int Stages = 6, Slots = 18;
        // 游戏内存 CPU 地址 → (影子键, 偏移)：高位当键、低 24 位当偏移（影子页表按偏移稠密分配，偏移要小）。同一段内存从不同 16 MB 段起绑会有两份影子，只多扫、结果相同
        const int KeyShift = 24;
        struct Bind { public ulong Key; public int Off, Len; public nint Ptr; public CbufShadow.Buf Buf; }   // Buf：绑定时扫描用的影子缓冲（BuildReads 免按键查表；键对不上 / 已删就重查）
        readonly Bind[] _bind = new Bind[Stages * Slots];
        readonly uint[] _bound = new uint[Stages];   // 各阶段非空的槽（位）：BuildReads 每笔只走这些，不扫满 18 槽

        public void CbufBind(int stage, int slot, nint ptr, int len)
        {
            if ((uint)stage >= Stages || (uint)slot >= Slots) { BadArgs++; return; }
            ref Bind b = ref _bind[stage * Slots + slot];
            if (ptr == 0 || len <= 0) { b = default; _bound[stage] &= ~(1u << slot); return; }
            _bound[stage] |= 1u << slot;
            ulong a = (ulong)ptr;
            b.Key = a >> KeyShift; b.Off = (int)(a & ((1UL << KeyShift) - 1)); b.Len = len; b.Ptr = ptr;
            if (!Rewriter.On) return;
            unsafe { b.Buf = Frame.OnGuestBound(b.Key, b.Off, new ReadOnlySpan<byte>((void*)ptr, len)); }
        }

        /// <summary>同 CbufBind，另给这次与上一次绑到同一处的内容只可能不同的区间（相对 ptr 的 [lo, hi) 对，升序）：核心只比这些区间（WidenFrame.OnGuestBoundRanges）。
        /// 调用方保证上一次交给这个槽的就是同一处（同 ptr、同 len）、区间以外字节没变。</summary>
        public void CbufBindRanges(int stage, int slot, nint ptr, int len, ReadOnlySpan<(int Lo, int Hi)> ranges)
        {
            if ((uint)stage >= Stages || (uint)slot >= Slots) { BadArgs++; return; }
            if (ptr == 0 || len <= 0) { CbufBind(stage, slot, ptr, len); return; }
            ref Bind b = ref _bind[stage * Slots + slot];
            _bound[stage] |= 1u << slot;
            ulong a = (ulong)ptr;
            b.Key = a >> KeyShift; b.Off = (int)(a & ((1UL << KeyShift) - 1)); b.Len = len; b.Ptr = ptr;
            if (!Rewriter.On) return;
            unsafe { b.Buf = Frame.OnGuestBoundRanges(b.Key, b.Off, new ReadOnlySpan<byte>((void*)ptr, len), ranges); }
        }

        /// <summary>本笔该看到的内容写进 scratch（返回改写处个数）；0 = 照原样零拷贝绑定；暂存区不够记红、返回 0。</summary>
        public int CbufEmit(int stage, int slot, Span<byte> scratch)
        {
            if ((uint)stage >= Stages || (uint)slot >= Slots) { BadArgs++; return 0; }
            ref readonly Bind b = ref _bind[stage * Slots + slot];
            if (b.Len <= 0 || !Rewriter.On || _orig || _noHit[stage * Slots + slot]) return 0;
            int n;
            unsafe { n = Frame.Emit(b.Key, b.Off, new ReadOnlySpan<byte>((void*)b.Ptr, b.Len), scratch); }
            if (n < 0) { ScratchShort++; return 0; }
            return n;
        }

        // ---------- 直连：着色器常量读法 ----------
        readonly List<CbufUse[]> _shaders = new() { null };   // 句柄 → 各槽读法（下标 = 槽号，null = 不读）；句柄 0 = 没登记
        readonly List<bool> _push = new() { false };
        static readonly CbufUse[] s_unknown = MakeUnknown();
        static CbufUse[] MakeUnknown() { var u = new CbufUse[Slots]; for (int i = 0; i < Slots; i++) u[i] = new CbufUse { Binding = i, Dynamic = true }; return u; }

        /// <summary>登记一条着色器的常量读法（建着色器时调一次，可分配）。useText = SpirvCbufUseText.Format 的输出（离线表原样）；null / 空 = 不知道，按整个绑定都读。</summary>
        public int Shader(string useText, bool push)
        {
            CbufUse[] u = string.IsNullOrEmpty(useText) ? s_unknown : SpirvCbufUseText.Parse(useText, Slots);
            if (u == s_unknown) UnknownShaders++;
            _shaders.Add(u); _push.Add(push);
            return _shaders.Count - 1;
        }

        // ---------- 直连：每笔绘制 ----------
        readonly CbufRead[] _reads = new CbufRead[Stages * Slots];
        int _fragN, _centerSaid;
        bool _orig;   // 本笔按原样铺满（见 Draw）：各槽出数 0 = 游戏原值   // 上一笔填进片元槽位表的条数（下一笔清掉多出来的）

        readonly bool[] _noHit = new bool[Stages * Slots];   // 本笔（BuildReads 之后）影子里没有命中的槽：出数直接 0
        int BuildReads(ReadOnlySpan<int> shader, int onlyStage)
        {
            int n = 0; Array.Clear(_noHit);
            for (int s = 0; s < Stages; s++)
            {
                if (onlyStage >= 0 && s != onlyStage) continue;
                int h = s < shader.Length ? shader[s] : 0;
                if (h <= 0 || h >= _shaders.Count) continue;
                CbufUse[] uses = _shaders[h];
                for (uint m = _bound[s]; m != 0; m &= m - 1)
                {
                    int slot = System.Numerics.BitOperations.TrailingZeroCount(m);
                    if (uses[slot] == null) continue;
                    ref readonly Bind b = ref _bind[s * Slots + slot];
                    // 这段在影子里一个命中都没有：判改写 / 界面正交 / 写回原值对它都是空操作、出数必为 0，不进读列表（10-24 直连真机热点：每个读区间被各处反复查影子表）
                    CbufShadow.Buf sb = b.Buf is { Deleted: false } c && c.Key == b.Key ? c : Frame.Shadow.TryGet(b.Key);
                    if (sb == null || !sb.OverlapsHit(b.Off, b.Off + b.Len)) { _noHit[s * Slots + slot] = true; continue; }
                    _reads[n++] = new CbufRead(b.Key, b.Off, b.Len, uses[slot]);
                }
            }
            return n;
        }

        // 镜头抽样用的读列表：本笔各阶段绑着的全部常量段（不按改写命中筛，镜头矩阵本身不是改写命中）
        readonly CbufRead[] _camReads = new CbufRead[Stages * Slots];
        /// <param name="sync">只观察模式：绑定时不写影子（每笔都写太贵），抽中的这笔才把绑着的内容写进影子（变了的粒置镜头脏位，候选随之重判）</param>
        int CamReads(ReadOnlySpan<int> shader, bool sync)
        {
            int n = 0;
            for (int s = 0; s < Stages; s++)
            {
                int h = s < shader.Length ? shader[s] : 0;
                if (h <= 0 || h >= _shaders.Count) continue;
                CbufUse[] uses = _shaders[h];
                for (uint m = _bound[s]; m != 0; m &= m - 1)
                {
                    int slot = System.Numerics.BitOperations.TrailingZeroCount(m);
                    if (uses[slot] == null) continue;
                    ref Bind b = ref _bind[s * Slots + slot];
                    if (sync) unsafe { b.Buf = Frame.OnGuestBound(b.Key, b.Off, new ReadOnlySpan<byte>((void*)b.Ptr, b.Len)); }
                    _camReads[n++] = new CbufRead(b.Key, b.Off, b.Len, uses[slot]);
                }
            }
            return n;
        }

        public struct Tex { public uint Id; public int W, H; public float Scale; public uint Flags; }
        /// <summary>最近一笔 Draw 的片元纵向倍率（窄屏；其余 1）。</summary>
        public float FragScaleY = 1f;
        public const uint TexTileU = 1, TexFlatKnown = 2, TexFlatContent = 4, TexEdgeSmooth = 8, TexSeamlessU = 16, TexRowConst = 32, DrawFragCoord = 1, DrawColor = 2, DrawWrites = 4, DrawOpaque = 8, DrawDepthWrite = 16, DrawInstanced = 32, DrawPatches = 64;
        const int SmallTex = 8;   // 同包装层：不超过 8×8 的贴图当纯色 / 渐变底

        // ---------- 写深度 3D 笔旁路（11-02 直连线主刀、满屏线审）----------
        // 游戏自出宽图（Ui 模式）时画进原生宽场景目标、开深度测试且写深度的笔是 3D 场景几何：Mac 回放塞尔达 20 万笔里占 79%，全量判定的结果全是
        //   ScaleK、出数 0、片元倍率同目标（读改写命中 0），却付常量绑定 + 扫描 + 逐笔判定（真机提交线程宽屏胶水 43%）。旁路只做这类笔改的记账（OnDrawLight），
        //   画法固定 ScaleK（原生宽目标上 ScaleK 的视口 / 剪刀 / 倍率都是 ×1，与 Keep 等价，但胶水按 ScaleK 分支取 tk，出 ScaleK 与现状逐位一样）。
        //   每张目标每帧至少一笔照走全量：常量扫描是改写器学习（镜头签名、_camFrame 时间窗）与镜头抽样的来源，每帧刷新。
        //   S2A_WIDEN_LIGHT=0 关；S2A_WIDEN_LIGHT_CHECK=1 校验档：不旁路，可旁路的笔照走全量后逐笔核「ScaleK、出数 0、没读改写」，不符计数并打前几条
        static readonly bool s_lightOff = Environment.GetEnvironmentVariable("S2A_WIDEN_LIGHT") == "0", s_lightCheck = Environment.GetEnvironmentVariable("S2A_WIDEN_LIGHT_CHECK") == "1";
        public long LightDraws, LightChecks, LightBad; readonly Dictionary<uint, (long S, long O)> _lcTgt = new(); long _lcN;
        bool LightEligible(uint flags) => Mode != WidenMode.Observe && (flags & DrawDepthWrite) != 0 && Frame.LightTarget;
        // 按目标学：同一目标上这类笔走全量判出的画法不全是 ScaleK（Mac 回放塞尔达 f1800：12 万笔里主场景目标 117910 / 0，三张小目标 0 / 38、0 / 38、38 / 38）。
        //   目标要先在全量路径上攒满 LightLearn 笔、全是 ScaleK 且出数 0 才放行；任一笔不是 → 这张目标此后一律全量。放行后每 LightResample 笔仍抽 1 笔走全量复核
        const int LightLearn = 64, LightResample = 16;
        sealed class LightTgt { public long Full, Seen, FullFrame = -1; public bool Bad; }
        readonly Dictionary<uint, LightTgt> _lightTgt = new();
        public long LightTargetsBad;
        LightTgt LightOf(uint t) { if (!_lightTgt.TryGetValue(t, out LightTgt g)) _lightTgt[t] = g = new LightTgt(); return g; }
        /// <summary>全量路径上的一笔有资格笔：记进它目标的学习账（Draw 末尾调）。</summary>
        void LightLearnNote(uint flags, ViewportMode m, ReadOnlySpan<float> push, int n, ReadOnlySpan<int> shader)
        {
            if (s_lightOff || !LightEligible(flags)) return;
            LightTgt g = LightOf(Frame.Target0); if (g.Bad) return;
            g.FullFrame = Frame.Frames;
            bool nz = false; foreach (float v in push) nz |= v != 0;
            bool rw = false; if (m == ViewportMode.ScaleK && !nz && !UvExtend) foreach (ref readonly CbufRead r in _reads.AsSpan(0, n)) if (r.Use != null && Frame.ReadsRewritten(r.Buffer, r.Offset, r.Size, r.Use)) { rw = true; break; }
            if (m != ViewportMode.ScaleK || nz || rw || UvExtend)
            {
                g.Bad = true; LightTargetsBad++;
                if (g.Full >= LightLearn)   // 已放行的目标复核不符：旁路这些笔会画错，响亮报（满屏线审 3），此后这张目标走全量
                    Console.Error.WriteLine($"[宽屏·核心] 【红】写深度旁路复核不符：帧 {Frame.Frames} 目标 {Frame.Target0}（已放行，学了 {g.Full} 笔）着色器 {(shader.Length > 0 ? shader[0] : -1)}/{(shader.Length > 1 ? shader[1] : -1)}：旁路给 ScaleK / 出数 0，全量判 {m}、出推量 {nz}、读改写 {rw}、采样外扩 {UvExtend}；这张目标此后走全量");
                return;
            }
            g.Full++;
        }
        /// <summary>旁路这笔：返回 true = 已按 ScaleK、出数 0 处理（push 清零、fragScaleX 同全量）；false = 照走 Draw。调用前已 Frame.OnViewport（s2a_widen_viewport）。</summary>
        public bool DrawLight(float vpX, float vpW, float vpH, float targetScale, uint flags, ReadOnlySpan<Tex> tex, Span<float> push, out float fragScaleX)
        {
            fragScaleX = 1f;
            if (s_lightOff || s_lightCheck || !LightEligible(flags)) return false;
            LightTgt g = LightOf(Frame.Target0);
            // 每张目标每帧至少一笔走全量（镜头抽样、改写器学习每张目标每帧都有样本，满屏线审 4）；没攒够 / 退回 / 抽到复核的也走全量
            if (g.Bad || g.Full < LightLearn || g.FullFrame != Frame.Frames || g.Seen++ % LightResample == 0) return false;
            push.Clear(); WantFlat = 0; UvExtend = false;
            int k = Math.Min(tex.Length, 256);
            for (int i = 0; i < k; i++) Frame.OnFragmentTexture(i, tex[i].Id);
            for (int i = k; i < _fragN; i++) Frame.OnFragmentTexture(i, 0);
            _fragN = k;
            Frame.NoteCanvas(vpX, vpW, vpH);
            Frame.OnDrawLight();
            NoteScreenCopy(vpX, vpW, vpH, targetScale > 0 ? targetScale : 1f, tex);
            bool fragY = (flags & DrawFragCoord) != 0;
            fragScaleX = Frame.FragScaleX(ViewportMode.ScaleK, fragY);
            FragScaleY = Frame.FragScaleY(ViewportMode.ScaleK, fragY);
            LightDraws++; Draws++;
            if (LightDraws % 50000 == 0) Console.Error.WriteLine($"[宽屏·核心] 写深度旁路 {LightDraws} 笔；学过的目标 {_lightTgt.Count}、退回全量 {LightTargetsBad}");
            return true;
        }
        void LightCheck(uint flags, ViewportMode m, ReadOnlySpan<float> push, int n)
        {
            if (!s_lightCheck || !LightEligible(flags)) return;
            {   // 校验档：有资格笔按目标的画法分布（ScaleK / 其它），每 2 万笔一行（满屏线要看「正确的核心下这类笔是不是恒为 ScaleK」）
                uint t = Frame.Target0; _lcTgt.TryGetValue(t, out var c); if (m == ViewportMode.ScaleK) c.S++; else c.O++; _lcTgt[t] = c;
                if (++_lcN % 20000 == 0) { var sb = new System.Text.StringBuilder(); foreach (var kv in _lcTgt) sb.Append($" {kv.Key}:{kv.Value.S}/{kv.Value.O}"); Console.Error.WriteLine($"[宽屏·核心] 写深度旁路校验 有资格 {_lcN} 笔、本会旁路的核了 {LightChecks}、不符 {LightBad}；按目标 ScaleK/其它：{sb}"); }
            }
            LightTgt g = LightOf(Frame.Target0); if (g.Bad || g.Full < LightLearn) return;   // 只核按学习规则本会旁路的笔（抽样复核那 1/16 也算在内：核的是「旁路会不会错」）
            LightChecks++;
            bool rw = false; foreach (ref readonly CbufRead r in _reads.AsSpan(0, n)) if (r.Use != null && Frame.ReadsRewritten(r.Buffer, r.Offset, r.Size, r.Use)) { rw = true; break; }
            bool nz = false; foreach (float v in push) nz |= v != 0;
            if (m == ViewportMode.ScaleK && !nz && !rw && !UvExtend) return;
            if (++LightBad <= 12) Console.Error.WriteLine($"[宽屏·核心] 写深度旁路校验不符 #{LightBad}：帧 {Frame.Frames} 目标 {Frame.Target0} 画法 {m}、出推量 {nz}、读改写 {rw}、采样外扩 {UvExtend}");
        }

        static readonly bool s_diag = Environment.GetEnvironmentVariable("S2A_WIDEN_DIAG") == "1";   // 每笔读环境变量占真机提交线程 0.4%（11-02 塞尔达）
        /// <summary>一笔绘制：定画法（ViewportMode）与外推参数、片元倍率。顺序同包装层 BeforeDraw：视口 0 → 采样来历 → OnDraw（写回原值登记）→ 收缩 / 外推。</summary>
        public ViewportMode Draw(float vpX, float vpW, float vpH, float targetScale, ReadOnlySpan<int> shader, uint flags, ReadOnlySpan<Tex> tex, Span<float> push, out float fragScaleX)
        {
            push.Clear(); fragScaleX = 1f; WantFlat = 0; UvExtend = false;
            if (_depth != 0 && Cam.Tick()) Cam.OnDrawSampled(_depth, _camReads.AsSpan(0, CamReads(shader, Mode == WidenMode.Observe)));
            if (Mode == WidenMode.Observe) { Draws++; return ViewportMode.Keep; }   // 只观察：不判画法、不出数
            int n = BuildReads(shader, -1);
            if ((flags & DrawColor) != 0) Frame.TryPromote(vpX, vpW, vpH, _reads.AsSpan(0, n));   // 未定目标（尺寸不属一族）按内容判画布；这一笔照旧按原样画
            Frame.OnViewport(vpX, vpW, MathF.Abs(vpH), targetScale > 0 ? targetScale : 1f);
            // 片元槽位表（上屏时按「最后一笔采样了谁」认出图目标，WidenFrame.OnPresent）
            int k = Math.Min(tex.Length, 256);
            for (int i = 0; i < k; i++) Frame.OnFragmentTexture(i, tex[i].Id);
            for (int i = k; i < _fragN; i++) Frame.OnFragmentTexture(i, 0);
            _fragN = k;
            bool wide = false;
            foreach (ref readonly Tex t in tex)
            {
                uint r = Root(t.Id);
                if (Frame.IsWide(t.Id) || Frame.IsNative(t.Id) || Frame.IsScreenCopy(t.Id) || Frame.IsWide(r) || Frame.IsNative(r) || Frame.IsScreenCopy(r)) { wide = true; break; }
            }
            Frame.DrawSamplesWide = wide;
            // 采样了没放宽、也不属 16:9 一族的渲染目标（游戏按原比例画的特效离屏层，如你裁我剪登场光晕 1024×512）：认不出镜头矩阵时按原尺寸居中合成
            //   （WidenFrame.OnDrawMode 兜底）。16:9 一族的没放宽目标是整幅画面，照旧按 k 铺满（宁铺满不留边）
            //   游戏自己出宽图（GameWide，第二层）时不判：宿主不放宽任何渲染目标，游戏的场景层本来就按宽尺寸画（塞尔达 1564×720，不属 16:9 一族），
            //   按这条收进原尺寸居中会把整幅场景缩成中间一块（11-02 jhz 测试机1 塞尔达户外满屏失效，b0875643c）
            //   只认纯离屏层合成：采样里有游戏资源贴图（不是渲染目标、也不是 ≤8×8 占位小图）的是 3D 材质表面，渲染目标只是它的一张查找图 / 探针，照旧按 k 铺满。
            //   11-06 马车8 比赛看台：不透明场景笔采 4076×4096 图集 + 1024×64 查找表 + 前几帧画好的 32×32 小目标，被这条判成原宽居中，看台整片画不出
            bool narrowRt = false;
            if (!wide && !Frame.GameWide)
                foreach (ref readonly Tex t in tex)
                {
                    uint r = Root(t.Id); bool isRt = _rt.Contains(t.Id) || _rt.Contains(r);
                    if (!isRt && !Small(t)) { narrowRt = false; break; }
                    if (isRt && !WidenRewriter.Family(t.W, t.H)) narrowRt = true;
                }
            Frame.DrawSamplesNarrowRt = narrowRt;
            bool fragY = (flags & DrawFragCoord) != 0, colorOut = (flags & DrawColor) != 0;
            // 16:9 原比例页（同包装层 TryBeginPage 的来源①）：放宽目标上采样整画布 16:9 图片 → 本帧这张目标余下的绘制按 16:9 原样画、平移居中，
            //   起页这笔交出两侧条带由调用方清黑（PageSides）
            _sidesNew = false; _rowsOn = false;
            //   页生效期间采样了放宽贴图的绘制照旧按页画：直连回放层把这类笔对放宽贴图的采样换到中间 16:9 区（widen_glue.inc uvx_fill，离线 dmsh_build.py fs_uvx），
            //   同包装层按贴图放宽比改采样坐标（10-26 马车8 主菜单：磨砂底板采样放宽的模糊图，按 k 画就和页里的遮罩错开）
            Frame.NoteCanvas(vpX, vpW, vpH);
            bool page = Frame.TargetWide && !Frame.TargetNative && colorOut && (Frame.PageActive || TryBeginPage(vpX, vpW, vpH, targetScale > 0 ? targetScale : 1f, tex));
            ViewportMode m = Frame.OnDraw(_reads.AsSpan(0, n), null, out DrawClass cls, page, fragY);
            // 拉伸风险（11-06 满屏泛化：大范围默认开的安全网，宿主 runtime/src/qprompt_host.c 按局内窗口判、命中自动退回 16:9）。只数「放宽目标上、挂着深度目标、
            //   写颜色、不在 16:9 原比例页里」的场景笔（3D 世界）：
            //   对 = 读到改写过的 16:9 镜头（Hor），或读到游戏自己已按屏幕比算的镜头（WideProjection，按 k 放宽视口正好），或采样了放宽贴图（整屏后处理 / 合成）；
            //   拉伸 = 以上都不是却按 k 拉宽（ScaleK）：16:9 的画面被横向拉 k 倍（smg2 1.222、10-21 暗黑3 角色）；
            //   收窄 = 以上都不是却原尺寸居中（CenterNative）：3D 世界被缩进中间 1/k（11-06 马车8 看台、11-02 塞尔达户外）
            if (cls == DrawClass.Scene && _depth != 0 && Frame.TargetWide && colorOut && !page)
            {
                bool ok = Frame.DrawReadCam || wide;
                if (!ok) foreach (ref readonly CbufRead r in _reads.AsSpan(0, n)) if (r.Use != null && Frame.ReadsWideProjection(r.Buffer, r.Offset, r.Size, r.Use)) { ok = true; break; }
                if (ok) StretchOk++; else if (m == ViewportMode.ScaleK) StretchRisk++; else if (m == ViewportMode.CenterNative) SqueezeRisk++; else StretchOk++;
            }
            if (m == ViewportMode.CenterNative && _centerSaid < 8 && s_diag)
            {   // 诊断（S2A_WIDEN_DIAG=1）：被判成界面层原宽居中的前几笔——目标、视口、采样了谁（放宽与否）。10-30 银河2 画布放宽后整幅被收进中间 1/k 定因用
                _centerSaid++; var sb = new System.Text.StringBuilder();
                foreach (ref readonly Tex t in tex) sb.Append($" {t.Id}:{t.W}×{t.H}{(Frame.IsWide(t.Id) || Frame.IsWide(Root(t.Id)) ? "宽" : "")}");
                Console.Error.WriteLine($"[宽屏·核心] 诊断 原宽居中：目标 {Frame.Target0}（原宽 {Frame.TargetW0} → {Frame.TargetW1}）视口 {vpX},{vpW}×{MathF.Abs(vpH)}，读区间 {n} 段，采样{(sb.Length > 0 ? sb.ToString() : " 无")}");
            }
            bool pushable = shader.Length > 0 && shader[0] > 0 && shader[0] < _push.Count && _push[shader[0]];
            // 写深度的笔不外推（收缩 / 推满 / 原生宽外推都不做，10-31）：它给之后的笔铺几何，顶点挪一点（外推连不推的顶点也乘 1 − NoBandZ）深度就和重画同一几何的笔对不上。
            //   马车8 选车页：本帧先一笔全屏合成模糊背景（Composited），之后赛车与展台先画深度（不写颜色、不采贴图 → 判成横向无细节层被外推）、再按「深度相等」着色，
            //   相等比较大片失败，背景从模型里透出蓝色碎点（帧回放：着色遍改深度恒过则碎点全消、剪影不变；去掉这笔外推亦全消）。界面遮罩不写深度（丝之歌暂停页 dw=0），照推
            //   一笔多实例的也不外推（11-01）：外推的前提是「一整块面、边上的顶点正好落在画布边」，一批贴片里跨画布边的那几个会被拉到屏幕边成横线。
            //   马车8 选车页背景光点（fs d2b0c7a9，128×128 平铺图、一笔 3620 实例）：平铺底纹放开后被推，右侧 2133 列外逐帧冒白线（轮胎页每 2 帧存图 66 张：35 张有线，不推 0 张）
            bool movable = pushable && (flags & (DrawDepthWrite | DrawInstanced | DrawPatches)) == 0;   // 多实例 / 多四边形一笔 = 一批贴片，不是一整块铺满的面（11-02 泡泡龙4 字形网格）
            bool wideRt = Frame.TargetWide && !Frame.TargetNative, full = FullCanvas(vpX, vpW, vpH);
            // 铺满画布的界面层两侧要有确定内容（10-29）：采样的贴图都「拉宽看不出」才推满宽屏——纯色 / ≤8×8 小图、横向平铺（原尺寸居中层，同包装层），
            //   或铺满画布时横向没有细节（WidenFrame.IsFlatTexture：喷3 房间列表暗化层 128×72 铺 1530 宽）。细节丰富的整画布 16:9 图片不推，照旧起原比例页清黑
            float cw = MathF.Abs(vpW) / (targetScale > 0 ? targetScale : 1f);
            //   平铺贴图「推了被拉宽」只对场景层算数（10-29 马车8 选轮胎页的标志面）；规则 A 判成界面层、或本帧已全屏合成的目标上的叠加层，铺满画布的平铺底纹也推：
            //   10-31 马车8 选赛道「OK」页（实局逐帧跳笔定因）：模糊背景之上一层平铺底纹（fs 6671d58c633f3325，64×64 + 160×160）按 Hor 只盖中间 16:9，两侧少了这层，142 / 1422 列亮度台阶
            bool overlay = cls == DrawClass.Hud || Frame.Composited(Frame.Target0);
            bool flatTex = full && OnlyFlat(tex, cw, overlay);
            // 收缩 + 推满（原尺寸居中层：先横向收 1/k、再把画布边的顶点推到屏幕边）只认按内容量过横向无细节、或横向平铺的贴图，不按尺寸猜：
            //   尺寸猜「放大 ≥ 4 倍」的前提是这张图铺满画布，而 Unreal / Slate 界面每个小部件都按整画布视口画、贴图 1:1 画在一小块里，部件贴着画布边的一侧被推到屏幕边、整块横拉
            //   （11-06 八方2 iPhone 小地图底盘 256×256 圆盘横拉约 1.5 倍并右移；帧回放 f6000 第 1403 笔，16:9 对照正圆）。读改写镜头的 Hor 推满层不收缩、照旧按尺寸判（马车8 菜单页回放逐像素不变）
            bool flatShrink = full && OnlyFlat(tex, cw, overlay, sizeOk: false);
            // 几何（11-06 B）：收缩 + 推满只给两侧都贴画布边的整画布层（宿主按顶点着色器位置切片在 CPU 求各顶点 NDC x，WidenCApi.Geom）。
            //   1 铺满 → 可收缩；0 只盖一部分（界面小部件，八方2 小地图那圈程序画的细环）/ −1 判不出 → 不收缩；−2 这支着色器没有位置切片（11-06 前出的直连库）→ 照旧
            bool bg = OnlyBackground(tex), shrink = Frame.ShrinkCandidate(m, colorOut, movable) && (bg || flatShrink) && GeomAllows();
            if (shrink && !bg) NoteFlat(ref DrawsFlatShrunk, "横向无细节原尺寸居中层推满宽屏", vpX, vpW, vpH, tex);
            // 放宽目标上铺满画布、没有深度目标（界面层：3D 场景都带深度）、读了改写过的镜头量（几何按原尺寸画在中间：Hor，或相机系数对改了投影横向缩放的 ScaleK）、
            //   只采横向无细节贴图的笔 → 画布边的顶点推到屏幕边（同原生宽目标的 PushCandidate + OnlySmall）。10-29 马车8 选轮胎页：界面是透视投影下的平面，
            //   画布大小的蓝底按 Hor+ 只占中间，两侧露出后面的标志面。平铺底纹（标志面，推了被拉宽）、带深度的 3D、子视口不推
            //   「没有深度目标」只是排除 3D 场景的近似：规则 A 已判成界面层的（出图目标上全屏合成之后的笔，DrawClass.Hud）挂着深度也照推。
            //   10-31 丝之歌暂停页（帧回放定因）：Unity 界面遍挂着深度 d4 且写深度，压暗遮罩（24×24 图铺满画布、读改写过的镜头）按 Hor 原尺寸只盖中间 16:9，左侧 213 列露出没压暗的场景
            //   规则 A 认不出出图目标时（交换链三张轮换）另认「本帧这张目标上已有全屏合成」（WidenFrame.Composited）：10-31 丝之歌实局暂停遮罩在 1 / 2 / 3 轮换的上屏图上判成场景，两侧都没压暗
            // 族 2（11-01）：叠加在已有完整画面上（界面层 / 本帧已全屏合成）、半透明混合、单实例的铺满画布层，带纹理也推满——
            //   推满只挪落在画布边的顶点，卡片 / 图标不碰边不受影响；铺满画布的半透明层（光束、压暗、模糊底、平铺底纹）被横向拉宽看不出，
            //   不推则只盖中间 16:9、213 列留接缝（泡泡龙 4 房间光束、马力欧惊奇选用户页浅蓝底，S2A_WIDEN_PUSHLOG 定因：叠加 True、不透明 False、无细节 False 被挡）。
            //   不透明的整幅图片照旧要横向无细节才推（推了被拉伸变形）
            bool overlayBlend = overlay && (flags & DrawOpaque) == 0 && OnlyExtensible(tex, cw);
            // 无细节铺满层（横向推满与竖向铺满共用这一份判定，11-02）：铺满画布、界面层 / 本帧已合成 / 无深度目标、只采横向无细节或叠加可延展的贴图、读改写过的镜头量
            bool flatLayer = colorOut && !page && wideRt && full && (_depth == 0 || cls == DrawClass.Hud || Frame.Composited(Frame.Target0)) && (flatTex || overlayBlend) && (m is ViewportMode.Hor or ViewportMode.ScaleK) && Frame.ReadsCamScale(_reads.AsSpan(0, n));
            bool flatPush = movable && flatLayer;
            if (_pushLog0 == -2) { _pushLog0 = -1; var e = Environment.GetEnvironmentVariable("S2A_WIDEN_PUSHLOG"); if (e != null) { var ab = e.Split('-'); if (ab.Length == 2 && long.TryParse(ab[0], out long a0) && long.TryParse(ab[1], out long a1)) { _pushLog0 = a0; _pushLog1 = a1; } } }
            if (_pushLog0 >= 0 && Frame.Frames >= _pushLog0 && Frame.Frames <= _pushLog1 && colorOut && wideRt && full)
            {   // 诊断（S2A_WIDEN_PUSHLOG=<起帧>-<止帧>）：放宽目标上铺满画布的每笔，推满判定的每个条件（族 2 带纹理全屏层没推满定因用，11-01）
                var sb = new System.Text.StringBuilder();
                foreach (ref readonly Tex t in tex) sb.Append($" {t.Id}:{t.W}×{t.H}/f{t.Flags}{(Frame.IsWide(t.Id) || Frame.IsWide(Root(t.Id)) ? "宽" : "")}");
                Console.Error.WriteLine($"[宽屏·核心] 推满诊断 帧 {Frame.Frames} 目标 {Frame.Target0} 画法 {m} 类 {cls} 页 {page} 可推 {pushable} 写深度 {(flags & DrawDepthWrite) != 0} 多实例 {(flags & DrawInstanced) != 0} 深度 {_depth} 已合成 {Frame.Composited(Frame.Target0)} 叠加 {overlay} 无细节 {flatTex} 读镜头 {Frame.ReadsCamScale(_reads.AsSpan(0, n))} 不透明 {(flags & DrawOpaque) != 0} 推满 {flatPush} 收缩 {shrink}；采样{(sb.Length > 0 ? sb.ToString() : " 无")}");
            }
            if (colorOut && wideRt && full && m == ViewportMode.ScaleK && wide && OnlyWide(tex)) Frame.NoteComposited(Frame.Target0);   // 铺满画布、只采放宽目标的全屏合成
            if (flatPush) NoteFlat(ref DrawsFlatPushed, "横向无细节界面层（读改写过的镜头量、几何原尺寸）推满宽屏", vpX, vpW, vpH, tex);
            UvExtend = flatPush && !flatTex;   // 只因「叠加半透明」才推的带纹理层：采样坐标随推满一起外扩（横向无细节的照旧拉宽，看不出）
            if (shrink) m = ViewportMode.Hor;
            // 着色器没改过、外推参数交不过去时（直连 v1）：通用模式会「收缩 + 外推」或「外推」的那两类界面层（只采纯色 / ≤8×8 小图的原尺寸居中层、读改写矩阵层）
            //   按原样铺满整个区域，不收进中间——全画布纯色遮罩 / 底收进中间会露出底下的内容（10-24 动森加载页：黑遮罩收进中间、两侧露蓝底）。
            //   代价：这两类里不铺满画布的纯色小块按游戏坐标画（不居中）。
            //   放宽目标（整套放宽，不是原生宽）上「原样」= 按 k 铺满（ScaleK，出数 0：游戏 16:9 坐标原样画、视口拉到全宽）；Keep 只铺得到客体宽 [0, 宽0)，右侧留旧内容（10-29）
            _orig = !pushable && (Frame.ShrinkCandidate(m, colorOut, true) && OnlyBackground(tex) || Frame.PushCandidate(m, colorOut, true) && OnlySmall(tex));
            if (_orig) { m = wideRt ? ViewportMode.ScaleK : ViewportMode.Keep; DrawsOrig++; }
            // 窄屏上下多画（Tall，11-02 jhz Duo 外屏丝之歌：开局压暗遮罩只盖原 16:9、顶部一条亮带）：Hor 画法下投影 y 乘 1/Ky、视口高乘 Ky 两相抵消，铺满层只盖中间。
            //   同横向推满：同一批无细节铺满层（flatPush：可外推、单块面）竖向外推——画布上下边上及外的顶点推到屏幕上下边，画布内的顶点不动（直连库外推尾段竖向段
            //   Dsh.VsPushY，参数 push.w = 1 − 1/Ky、门限² 共用 push.y，见下方出参）。11-05 前这里拿「整笔 ScaleK 竖向拉满」顶替：叠加半透明条件进来的文字 / 页签底板
            //   跟着整笔拉走（哆啦A梦牧场条款页：页签文字飘到上方星空、底板消失、按钮文字掉到按钮条下方；录帧回放关掉拉满全部归位）
            bool tallPush = Rewriter.Tall && flatPush;
            if (tallPush) NoteFlat(ref DrawsTallPushed, "无细节层（读改写过的镜头量、几何原尺寸）竖向外推到屏幕上下边", vpX, vpW, vpH, tex);
            // 两侧来历（同包装层 WidenTexture.Bands，见 WidenFrame.MarkBands）：铺满画布的 Hor（含收缩后推满宽屏的纯色底：10-28 八方2 直连读档页，1×1 底铺满画布、界面居中在上面），
            //   或采样了带标记贴图的铺满画布 ScaleK。直连不知道剪裁，收缩那类只按视口判
            if (!page && wideRt && full && (m == ViewportMode.Hor || m == ViewportMode.ScaleK && (_orig || flatPush || SamplesBands(tex))))
                Frame.MarkBands(Frame.Target0);
            // 两侧带兜底（见 WidenFrame.NoteSidesWritten）：调用方报清屏 / 拷贝 / 计算写时（DrawWrites），放宽目标本帧第一次被画、两侧还没有确定内容，
            //   而这笔自己不是不透明铺满全宽（铺满画布的 ScaleK / Hor、不混合、四通道全写：DrawOpaque）→ 这笔之前把两侧带清黑（同起页条带出口），本帧之后的绘制照常往上画。
            //   只在第一笔清：之后清会抹掉本帧已画的内容。10-29 马车8 选轮胎页：背景目标每帧不清屏，第一笔是半透明的全屏渐变（ScaleK），两侧一直叠着上一帧
            if (colorOut && wideRt && (flags & DrawWrites) != 0 && Frame.FirstDrawThisFrame(Frame.Target0) && !_sidesNew && !Frame.SidesWrittenThisFrame(Frame.Target0))
            {
                // 铺满画布的 ScaleK / Hor 采样了放宽过的目标（全屏处理：两侧同样由放宽的输入算出；读镜头矩阵重建位置的按 Hor）也不清：这笔自己写满两侧，带混合时要和目标里上一帧的结果累加，
                //   清黑后两侧永远从 0 起算。10-31 马车8 比赛画面黑边（实局逐遍截图定因）：光照累积目标每帧是新建的临时对象（同一块存储），每帧都算「本帧第一次画」，
                //   两侧每帧被清 0，光照两侧恒为 0 → 路面 / 背景两侧全黑，只剩自发光的广告牌
                if (full && (m is ViewportMode.ScaleK or ViewportMode.Hor) && ((flags & DrawOpaque) != 0 || wide)) Frame.NoteSidesWritten(Frame.Target0);
                else
                {
                    int w0 = Frame.TargetW0, w1 = Frame.TargetW1, c0 = (w1 - w0) / 2;
                    _sides = (0, c0, c0 + w0, w1); _sidesNew = true; _rowsOn = false; SideClears++;
                    Frame.NoteSidesWritten(Frame.Target0);
                }
            }
            bool on = movable && (shrink || flatPush || Frame.PushCandidate(m, colorOut, true) && OnlySmall(tex));
            NoteScreenCopy(vpX, vpW, vpH, targetScale > 0 ? targetScale : 1f, tex);
            Frame.PushParams(on, shrink, out float d, out float e2, out float z);
            if (push.Length >= 3) { push[0] = d; push[1] = e2; push[2] = z; }
            if (push.Length >= 4) push[3] = 0;
            if (tallPush && push.Length >= 4) { (float ty2, float ty) = SpirvEdgePush.Params(Rewriter.Ky); push[0] = 0; push[1] = ty2; push[2] = 0; push[3] = ty; }   // 竖向：横向段只加 0（k = 1）、不收缩
            fragScaleX = Frame.FragScaleX(m, fragY);
            FragScaleY = Frame.FragScaleY(m, fragY);   // 窄屏加高目标上片元 y 的倍率（直连胶水按 s2a_widen_frag_scale_y 取，写 render_scale_y）
            LightCheck(flags, m, push, n);
            LightLearnNote(flags, m, push, n, shader);
            Draws++;
            return m;
        }

        /// <summary>计算派发（绑定已按 CbufBind 登记）：同包装层 DispatchCompute 的写回原值规则（WidenFrame.OnDispatch）。</summary>
        public void Dispatch(ReadOnlySpan<int> shader, bool narrowOnly)
        {
            _orig = false;
            int n = BuildReads(shader, 5);
            Frame.OnDispatch(_reads.AsSpan(0, n), null, narrowOnly);
        }

        // ---------- 16:9 原比例页（同包装层 WidenPipeline.TryBeginPage / PageSource 的来源①，判据见那里） ----------
        // 画布 = 整张目标，或从原点起、16:9、不窄于原宽 60% 的视口（掌机档在主机尺寸缓冲里只用左上一块）。来源：没放宽的 16:9 贴图、宽 ≥ 画布 90%、横向非平铺；
        // 画布高 ≥ 360（包装层按目标高判；直连不知道目标高，按铺满画布的视口高判）。采样了任何放宽贴图 → 不是页。
        // 来源只认没当过渲染目标的贴图（CPU 供图：标题图、视频帧）：GPU 画出来却没放宽的 16:9 目标（包装层算来源、但不认证）直连不认——10-25 马车8 标题页
        //   合成笔采样 1280×720 没放宽的渲染目标被起成页，视频背景右移、右侧被切。GL / Vulkan 胶水报没放宽的贴图号是 0，分不出渲染目标，照旧按尺寸认
        // 包装层的来源②（页内容的放宽贴图，页沿采样链传下去）直连不做：包装层按贴图放宽比改采样坐标，直连改不了——全屏采样放宽贴图按 k 铺满就是一比一拷贝，
        //   页面（居中内容 + 黑边）原样带过去；再起页会把已居中的内容再平移一次（10-25 马车8 直连读盘白页：内容落在 [425, 2130)，应为 [213, 2133)）
        (int M0, int C0, int C1, int M1) _sides; bool _sidesNew;
        (int R0, int C0, int C1, int R1) _rows; bool _rowsOn;   // 窄屏加高的目标起页：上下条带（行，10-28 B06）
        public long PageDraws;
        bool TryBeginPage(float vpX, float vpW, float vpH, float ts, ReadOnlySpan<Tex> tex)
        {
            int w0 = Frame.TargetW0, cw = w0; float vw = MathF.Abs(vpW), vh = MathF.Abs(vpH);
            if (MathF.Abs(vpX) < 0.5f && vh > 0 && MathF.Abs(vw / vh / (16f / 9f) - 1) < 0.01f && vw >= 0.6f * w0 && vw < w0) cw = (int)MathF.Round(vw);
            bool any = false;
            foreach (ref readonly Tex t in tex)
            {
                if (t.H <= 0) continue;
                if (t.Id != 0 && (Frame.IsWide(t.Id) || Frame.IsWide(Root(t.Id)))) return false;
                if (t.Id != 0 && (_rt.Contains(t.Id) || _rt.Contains(Root(t.Id)) || _drawn.Contains(t.Id) || _drawn.Contains(Root(t.Id)))) continue;   // GPU 画出来的目标，不是图片来源
                if (WidenFrame.IsPagePicture(t.W, t.H, t.Scale > 0 ? t.Scale : 1f, cw, ts) && (t.Flags & TexTileU) == 0) any = true;
            }
            if (!any || !WidenFrame.IsPageTarget((int)vh, ts)) return false;
            uint rt = Frame.Target0;
            if (!Frame.BeginPage(rt, 0, cw, out int c0, out int c1, out int m0, out int m1)) return false;
            _sides = (m0, c0, c1, m1); _sidesNew = true; PageDraws++; Frame.NoteSidesWritten(rt);
            _rowsOn = Frame.PageRows(out int r0, out int rc0, out int rc1, out int r1); _rows = (r0, rc0, rc1, r1);
            if (PageDraws <= 8)
            {
                var sb = new System.Text.StringBuilder();
                foreach (ref readonly Tex t in tex) sb.Append($" {t.Id}:{t.W}×{t.H}{((t.Flags & TexTileU) != 0 ? "平铺" : "")}{(t.Id != 0 && _rt.Contains(Root(t.Id)) ? "目标" : "")}");
                Console.Error.WriteLine($"[宽屏·核心] 16:9 原比例页：目标 {rt}（原宽 {w0} → {Frame.TargetW1}）视口 {vpX},{vpW}×{vh} 画布 {cw}，内容 [{c0},{c1})、两侧 [{m0},{c0}) [{c1},{m1}){(_rowsOn ? $"、上下 [{r0},{rc0}) [{rc1},{r1}) 行" : "")} 清黑；采样{sb}（第 {PageDraws} 页）");
            }
            return true;
        }
        /// <summary>本笔刚起了原比例页：两侧条带 [m0, c0) [c1, m1)（放宽贴图像素列），调用方在画这笔之前把颜色目标 0 的这两条整高清成全 0。</summary>
        public bool PageSides(out int m0, out int c0, out int c1, out int m1)
        {
            (m0, c0, c1, m1) = _sides;
            return _sidesNew;
        }
        /// <summary>本笔刚起了原比例页且目标是窄屏加高的：上下条带 [r0, c0) [c1, r1)（像素行，整宽），调用方同 PageSides 一起清成全 0（10-28 B06）。</summary>
        public bool PageRows(out int r0, out int c0, out int c1, out int r1)
        {
            (r0, c0, c1, r1) = _rows;
            return _sidesNew && _rowsOn;
        }

        // 铺满画布的横向无细节层推满宽屏：计数，前 8 笔打一行（实局验收据此证明那笔被推满，同起页的「16:9 原比例页」行）
        void NoteFlat(ref long n, string what, float vpX, float vpW, float vpH, ReadOnlySpan<Tex> tex)
        {
            if (++n > 8) return;
            var sb = new System.Text.StringBuilder();
            foreach (ref readonly Tex t in tex) sb.Append($" {t.Id}:{t.W}×{t.H}");
            Console.Error.WriteLine($"[宽屏·核心] 铺满画布的{what}：目标 {Frame.Target0}（原宽 {Frame.TargetW0} → {Frame.TargetW1}）视口 {vpX},{vpW}×{MathF.Abs(vpH)}；采样{(sb.Length > 0 ? sb.ToString() : " 无")}（第 {n} 笔）");
        }
        bool Small(in Tex t) => WidenFrame.IsSmallTexture(t.W, t.H, t.Scale > 0 ? t.Scale : 1f, SmallTex);
        // 整屏副本登记（同包装层 WidenRenderer.NoteScreenCopy，WidenFrame.OnTargetFilled）：视口铺满整张颜色目标 0、采样的全是整屏画面（宽 = 高 × 屏幕比）/ 整屏副本
        //   （≤8×8 的噪声 / 查找表不算）→ 目标记为整屏副本；采样它的铺满层按「采样了宽内容」铺满，不当界面层收进中间。
        //   11-02 塞尔达直连菜单：10-21 的整屏副本规则判定那半（上面 wide / OnlySmall）搬进了直连核心，登记这半没搬，直连下副本从来登记不上 →
        //   暂停菜单底图（1564×720 整屏模糊副本）判成界面层原宽居中，只铺 [142, 1422)、右侧 213 列黑（左侧被向左出血的面板盖住）
        void NoteScreenCopy(float vpX, float vpW, float vpH, float ts, ReadOnlySpan<Tex> tex)
        {
            uint rt = Frame.Target0;
            if (rt == 0 || tex.Length == 0 || !_rtDim.TryGetValue(rt, out var d) || MathF.Abs(vpX) >= 0.5f || MathF.Abs(vpW) / ts < d.W - 0.5f || MathF.Abs(vpH) / ts < d.H - 0.5f) return;
            Filled(rt, d.W, d.H, d.S, tex);
        }
        /// <summary>调用方跳过核心的绘制（s2a_widen_viewport 回 0：Ui 模式下 16:9 视口不算原生宽、整笔不进核心）里铺满整张目标的那些笔：只登记整屏副本来历、不改画法。
        /// 11-02 塞尔达直连菜单：整屏模糊缩图链 782×360（屏幕比，进核心、登记得上）→ 320×180（16:9，跳过核心）断在这一环，菜单底图采样 320×180 认不出是副本，
        /// 按界面层收进中间 16:9、右侧 213 列黑。w / h = 目标客体宽高（调用方已核视口铺满整张）</summary>
        public void NoteFill(uint rt, int w, int h, ReadOnlySpan<Tex> tex) { if (rt != 0 && tex.Length > 0 && w > 0 && h > 0) Filled(rt, w, h, 1f, tex); }
        void Filled(uint rt, int w, int h, float s, ReadOnlySpan<Tex> tex)
        {
            bool scr = false, other = false;
            foreach (ref readonly Tex t in tex)
            {
                if (t.Id == 0 || t.H <= 0) continue;
                if (Frame.IsScreenAspect(t.W, t.H, t.Scale > 0 ? t.Scale : 1f) || Frame.IsScreenCopy(t.Id) || Frame.IsScreenCopy(Root(t.Id))) scr = true;
                else if (!Small(t)) other = true;
            }
            Frame.OnTargetFilled(rt, w, h, scr && !other, s);
        }
        // 同包装层 WidenPipeline.FullCanvasViewport：从原点起、宽 = 目标原宽，或 16:9 且不窄于原宽 60%（掌机档在主机尺寸缓冲里只用左上 1280×720）
        bool FullCanvas(float vpX, float vpW, float vpH)
        {
            float vw = MathF.Abs(vpW), vh = MathF.Abs(vpH); int w0 = Frame.TargetW0;
            return MathF.Abs(vpX) < 0.5f && (MathF.Abs(vw - w0) < 1f || vh > 0 && MathF.Abs(vw / vh / (16f / 9f) - 1) < 0.01f && vw >= 0.6f * w0 && vw < w0);
        }
        bool SamplesBands(ReadOnlySpan<Tex> tex)
        {
            foreach (ref readonly Tex t in tex) if (t.Id != 0 && (Frame.IsBands(t.Id) || Frame.IsBands(Root(t.Id)))) return true;
            return false;
        }
        // 同包装层 WidenPipeline.OnlyBackground：片元只采小图或横向平铺的贴图
        bool OnlyBackground(ReadOnlySpan<Tex> tex)
        {
            foreach (ref readonly Tex t in tex) if (!Small(t) && (t.Flags & TexTileU) == 0) return false;
            return true;
        }
        // 铺满画布（宽 cw 客体像素）的层片元只采纯色 / 小图或横向无细节的贴图（WidenFrame.IsFlatTexture）；不采贴图（纯色）也算
        bool OnlyWide(ReadOnlySpan<Tex> tex)
        {
            foreach (ref readonly Tex t in tex) { uint r = Root(t.Id); if (!Frame.IsWide(t.Id) && !Frame.IsWide(r) && !Small(t)) return false; }
            return true;
        }
        // 横向无细节按内容判（11-01，根因族 2「叠加层没推满」）：尺寸规则（每纹素 ≥ FlatMag 列）只是「拉宽看不出」的保守近似，平滑渐变的大图被误判成有细节，
        //   原尺寸居中不推、两侧接缝（异度3 选难度页横带：9 块 400 宽九宫格拼块铺满画布只放大 3.2 倍）。尺寸不过时看调用方量过的内容（TexFlatKnown / TexFlatContent：
        //   贴图横向高频细节，直连胶水层按内容哈希缓存）；还没量过就点名（WantFlat），本笔照旧按有细节，量完从下一帧起生效
        public uint WantFlat;
        /// <summary>本笔是「带纹理的半透明叠加层被推满」（族 2，11-01）：调用方把它没放宽过的贴图的横向采样坐标以 0.5 为中心放大 k 倍（同推满的拉宽倍数），
        /// 中间 16:9 区逐像素同原版、两侧采样落在 [0,1] 外按采样器钳边 / 镜像 / 平铺取（总指挥：不能用拉宽 22% 换接缝）</summary>
        public bool UvExtend;
        // 族 2（11-01）：带纹理的半透明叠加层推满要两侧有可延续的内容——采样坐标随推满外扩（UvExtend），两侧采到贴图 [0,1] 以外：
        //   小图 / 按尺寸横向无细节 / 放宽过的目标（自带两侧内容）/ 重复寻址且首尾无缝（按平铺延续）/ 量过整体平滑或左右边缘带平滑（调用方外扩时换钳边）可延续；
        //   边缘有细节的整图（马力欧惊奇标题主视觉：平铺采样绕回另一边、钳边成拉丝）不可延续 → 不推，按原版 16:9 画。没量过的点名量
        bool OnlyExtensible(ReadOnlySpan<Tex> tex, float cw)
        {
            foreach (ref readonly Tex t in tex)
            {
                if (Small(t) || Frame.IsWide(t.Id) || Frame.IsWide(Root(t.Id)) || WidenFrame.IsFlatTexture(t.W, t.Scale > 0 ? t.Scale : 1f, false, cw)) continue;
                //   TexTileU 只说采样器横向重复寻址，不说图是平铺设计的（标题主视觉也是重复寻址）：重复寻址要首尾无缝（TexSeamlessU）才按平铺延续
                if ((t.Flags & TexFlatKnown) != 0) { if ((t.Flags & (TexFlatContent | TexEdgeSmooth)) != 0 || (t.Flags & (TexTileU | TexSeamlessU)) == (TexTileU | TexSeamlessU)) continue; return false; }
                if (WantFlat == 0) WantFlat = t.Id;
                return false;
            }
            return true;
        }
        /// <summary>收缩候选笔的几何结论（宿主回调，见 WidenCApi.Geom / s2a_widen_set_geom_cb）：1 铺满、0 只盖部分、−1 判不出、−2 没有位置切片（照旧）。没接 = −2。</summary>
        public Func<int> GeomCovers;
        public long GeomShrinkCovered, GeomShrinkPartial, GeomShrinkUnknown, GeomShrinkNoSlice;
        bool GeomAllows()
        {
            int g = GeomCovers?.Invoke() ?? -2;
            if (g == 1) { GeomShrinkCovered++; return true; }
            if (g == 0) { GeomShrinkPartial++; return false; }
            if (g == -1) { GeomShrinkUnknown++; return false; }
            GeomShrinkNoSlice++; return true;
        }
        bool OnlyFlat(ReadOnlySpan<Tex> tex, float cw, bool tileOk = false, bool sizeOk = true)
        {
            foreach (ref readonly Tex t in tex)
            {
                if (Small(t) || (sizeOk || tileOk && (t.Flags & TexTileU) != 0) && WidenFrame.IsFlatTexture(t.W, t.Scale > 0 ? t.Scale : 1f, (t.Flags & TexTileU) != 0 && !tileOk, cw)) continue;   // sizeOk = false：只有横向平铺的照尺寸（平铺 = 几何铺满画布）
                // 收缩（sizeOk = false）还要每行横向近乎不变（TexRowConst）：曲率处处小的圆盘 / 柔边图标「平滑」但行内变化大，收缩后贴画布边的一侧被推到屏幕边、整块横拉
                //   （11-06 八方2 iPhone 实局：小地图底盘 256×256 量得横向高频点 0 / 8128 → 平滑，照样收缩横拉；帧回放取不到这张贴图、按缺省有细节，曾误判修好）
                if ((t.Flags & TexFlatKnown) != 0) { if ((t.Flags & TexFlatContent) != 0 && (sizeOk || (t.Flags & TexRowConst) != 0)) continue; return false; }
                if (WantFlat == 0) WantFlat = t.Id;
                return false;
            }
            return true;
        }
        // 同包装层 WidenPipeline.OnlySmall：片元只采小图，或 16:9 的整屏副本（界面库按画布铺满、内容横向压了 k 倍，推到屏幕边 = 按原比例还原）
        bool OnlySmall(ReadOnlySpan<Tex> tex)
        {
            foreach (ref readonly Tex t in tex)
                if (!Small(t) && !(Frame.IsScreenCopy(Root(t.Id)) && !Frame.IsScreenAspect(t.W, t.H, t.Scale > 0 ? t.Scale : 1f))) return false;
            return true;
        }

        /// <summary>上屏：裁剪换算 + 定下一帧的出图目标。返回 1 = 本帧按 16:9 原比例居中留黑边（Pillar 模式，或上屏贴图内容是原比例页）；
        /// 2 = 上屏贴图两侧是放宽内容画的（黑是游戏画的，见 WidenFrame.MarkBands）；5 = 原比例回退（纯 2D 帧两侧游戏都没画到，见 SideCoverage）；0 = 照常判。</summary>
        public int Present(uint tex, ref int left, ref int right, ref float aspectX, float aspectY) { int t = 0, b = 0; return Present(tex, ref left, ref right, ref t, ref b, ref aspectX, aspectY); }
        public int Present(uint tex, ref int left, ref int right, ref int top, ref int bottom, ref float aspectX, float aspectY)
        {
            int l0 = left, r0 = right; float ax0 = aspectX;   // 游戏给的裁剪（3D 镜头帧回退按原宽收进中间用）
            Frame.MapCrop(tex, ref left, ref right, ref aspectX, aspectY);
            Frame.MapCropY(tex, ref top, ref bottom);
            bool pageSource = Frame.IsPageSource(tex), bands = Frame.IsBands(tex);
            Frame.OnPresent(tex);
            Cam.OnPresent();
            CameraTrack.Publish(Cam, (ulong)Frame.Frames);   // 自动玩家在线读（s2a_ap_cam），同包装层上屏
            // Ui 模式回退（游戏自己出宽图）：上屏裁剪框收进中间 16:9（宽 ÷ k、居中）；上屏层按裁剪框自己的宽高比居中留黑边，不拉伸
            //   只收比 16:9 宽的裁剪框（游戏出的宽画面；整张就是 16:9 的照旧）
            if (CropUi) { int w = right - left, h = bottom - top; if (w > 0 && (h <= 0 || w > h * (16f / 9f) * 1.01f)) { int pad = (int)Math.Round(w * (1 - 1 / Rewriter.K) / 2); left += pad; right -= pad; } FallbackFrames++; return 5; }
            if (Rewriter.Pure2DOff && Rewriter.Pure2DRecent) { FallbackFrames++; return 5; }
            // 3D 镜头帧回退：裁剪框收进存储中间 16:9（放宽 = 两侧加视野，中间原宽那块就是原版整幅）；上屏按比例留黑边，不拉伸
            if (Crop3D && !Rewriter.Pure2DRecent && Frame.TryWide(tex, out int w0, out int w1) && w1 > w0) { int pad = (w1 - w0) / 2; left = l0 + pad; right = (r0 != 0 ? r0 : w0) + pad; aspectX = ax0; FallbackFrames++; return 5; }
            return Mode == WidenMode.Pillar || pageSource ? 1 : bands ? 2 : 0;
        }

        // 原比例回退（11-01，根因族 1「放宽后一侧游戏没画到」）：调用方在上屏路径常驻采样出图两侧带「本帧有没有被画到」（哨兵判，不按亮度），
        //   连同中间区的粗格亮度签名交来。纯 2D 帧连续 FallbackSamples 个样本两侧都没画到（游戏整帧只画 16:9） → 关纯 2D 的场景改写，整帧 16:9 居中（Present 返回 5）；
        //   只一侧没画到不回退：横版关卡镜头走到关卡一端时那一侧本来就没东西（DOUBLE DRAGON4 关卡左端露清屏色、右侧照画场景），回退会随镜头来回切、丢掉另一侧；
        //   回退中中间区签名大变（换页 / 换场景）才重试放宽，不按帧来回切。3D 帧（见过场景镜头）不受影响
        public const int FallbackSamples = 2;
        // 滞回（11-01 总指挥：暗场景 / 过场黑幕 / 淡入淡出会让画面在宽屏和原比例之间左右闪）：回退至少持续 FallbackHoldFrames 次上屏，
        //   且连续 FallbackSamples 个样本都判「换了场景」才解除（忍者龟 tmnt_fb10 原先回退 30 次上屏就解除 = 60 帧下 0.5 秒）
        public const int FallbackHoldFrames = 60;
        int _fbMiss, _fbChanged; uint _fbSig; long _fbStart, _fbEnd = -1;
        public long FallbackShortest = -1;
        public long WideShortest = -1;   // 解除后到再次回退之间的宽屏段里最短的一段（上屏次数），-1 = 还没有过
        public long BlankSamples;   // 中间也没内容、不计的样本数   // 已解除的回退里持续最短的一次（上屏次数），-1 = 还没解除过
        public long Fallbacks, FallbackRetries, FallbackFrames;
        /// <summary>3D 镜头帧原比例回退（族 1 ③，11-01）：游戏用透视镜头画、放宽后两侧游戏根本没画到（哨兵还在）时，上屏只取存储中间 16:9（Present 返回 5、裁剪框收进中间）。
        /// 两侧本就空，中间这块就是原版的视角与界面，不用动改写器。判据比纯 2D 严：要「没画到」，画成纯色 / 暗也不算（真 3D 场景放宽后两侧总被画到，夜空 / 太空不误回退）。
        /// 忍者龟标题、太鼓说明页、马力欧惊奇标题（状态行「纯2D否」）</summary>
        public bool Crop3D;
        /// <summary>Ui 模式（游戏靠第二层代码补丁自己出宽图，宿主只管界面层）的原比例回退（11-02）：界面页按 16:9 布局只画中间，两侧露游戏清宽目标的清屏色
        /// （怪猎健康提醒页两侧白、塞尔达菜单右侧黑）。宿主关不掉游戏自己的宽布局（关纯 2D 改写没用），回退只能在上屏收：裁剪框收进中间 16:9（Present 返回 5）。
        /// 触发同上（纯 2D 帧两侧没内容 / 3D 帧两侧没画到），回退期间游戏照常画宽、两侧带还采得到：任一侧有内容就是能放宽的直接证据（同 3D 回退的解除法）</summary>
        public bool CropUi;
        /// <summary>两侧覆盖样本（只给「有没有内容」，没画到不另报：只走纯 2D 判据）</summary>
        public void SideCoverage(bool leftDrawn, bool rightDrawn, uint sig) => SideCoverage(leftDrawn, rightDrawn, false, false, sig);
        /// <summary>两侧覆盖样本：leftDrawn / rightDrawn = 出图两侧带本帧有游戏内容（画到且亮度不是一片均匀）；leftUndrawn / rightUndrawn = 两侧带一半以上的点
        /// 游戏根本没画到（哨兵还在）；sig = 中间区 8 格各 4 位亮度（第 i 格在 4i 位）</summary>
        public void SideCoverage(bool leftDrawn, bool rightDrawn, bool leftUndrawn, bool rightUndrawn, uint sig)
        {
            var rw = Rewriter;
            // 中间也没内容（8 格亮度最高 ≤ 1 档：开机黑屏、过场黑幕）的样本不是「游戏只画 16:9」的证据，也不说明换了场景：不计、不清零、不解除。
            //   植物大战僵尸开机黑屏两侧也黑 → 旧规则回退，之后协议页底板暗、签名只变 0–1 档，回退锁死（pvz_fb21 采样存图：回退中两侧被原比例页清黑）
            uint top = 0; for (int i = 0; i < 8; i++) top = Math.Max(top, sig >> (4 * i) & 15);
            if (top <= 1) { BlankSamples++; return; }
            bool pure2d = rw.Pure2DRecent, ui = Mode == WidenMode.Ui, bare = pure2d ? !leftDrawn && !rightDrawn : leftUndrawn && rightUndrawn;
            if (!rw.Pure2DOff && !Crop3D && !CropUi)
            {
                // 纯 2D 帧：两侧都没内容（没画到或纯色）；3D 镜头帧：两侧都没画到（哨兵还在）
                if (bare) { if (++_fbMiss >= FallbackSamples) { if (ui) CropUi = true; else if (pure2d) rw.Pure2DOff = true; else Crop3D = true; _lightTgt.Clear();
                    _fbSig = sig; _fbMiss = 0; _fbChanged = 0; _fbStart = Frame.Frames; Fallbacks++; long wide = _fbEnd < 0 ? -1 : Frame.Frames - _fbEnd; if (wide >= 0 && (WideShortest < 0 || wide < WideShortest)) WideShortest = wide;
                    Console.Error.WriteLine(ui ? $"[宽屏·核心] 原比例回退：游戏自己出宽图（Ui 模式）的{(pure2d ? "纯 2D 帧两侧都没有游戏内容（没画到或只画了纯色）" : "3D 镜头帧两侧游戏都没画到")}（连续 {FallbackSamples} 个样本），上屏收进中间 16:9（第 {Fallbacks} 次{(wide >= 0 ? $"，距上次解除 {wide} 次上屏" : "")}）"
                        : pure2d ? $"[宽屏·核心] 原比例回退：纯 2D 帧放宽后两侧都没有游戏内容（没画到或只画了纯色）（连续 {FallbackSamples} 个样本），整帧退回 16:9 居中（第 {Fallbacks} 次{(wide >= 0 ? $"，距上次解除 {wide} 次上屏" : "")}）"
                        : $"[宽屏·核心] 原比例回退：3D 镜头帧放宽后两侧游戏都没画到（连续 {FallbackSamples} 个样本），上屏只取中间 16:9（第 {Fallbacks} 次{(wide >= 0 ? $"，距上次解除 {wide} 次上屏" : "")}）"); } }
                else _fbMiss = 0;
            }
            // 3D 裁剪回退期间游戏照常放宽画、只是上屏裁掉两侧：两侧带还采得到，任一侧被画到（进关、3D 场景铺满）就是能放宽的直接证据，不靠中间签名猜换场景
            else if (CropUi ? bare : Crop3D ? leftUndrawn && rightUndrawn : !SceneChanged(sig, _fbSig)) _fbChanged = 0;
            else if (++_fbChanged >= FallbackSamples && Frame.Frames - _fbStart >= FallbackHoldFrames)
            {
                long held = Frame.Frames - _fbStart; _fbEnd = Frame.Frames; _fbMiss = 0; _fbChanged = 0;
                if (FallbackShortest < 0 || held < FallbackShortest) FallbackShortest = held;
                Console.Error.WriteLine(CropUi ? $"[宽屏·核心] 原比例回退解除：游戏自己出宽图（Ui 模式）两侧有游戏内容了（连续 {FallbackSamples} 个样本），恢复整幅上屏（第 {FallbackRetries + 1} 次，这次回退持续 {held} 次上屏）"
                    : Crop3D ? $"[宽屏·核心] 原比例回退解除：3D 镜头帧两侧游戏画到了（连续 {FallbackSamples} 个样本），恢复放宽上屏（第 {FallbackRetries + 1} 次，这次回退持续 {held} 次上屏）"
                    : $"[宽屏·核心] 原比例回退解除：中间画面换了（签名 {_fbSig:x8} → {sig:x8}，连续 {FallbackSamples} 个样本），重试放宽（第 {FallbackRetries + 1} 次，这次回退持续 {held} 次上屏）");
                rw.Pure2DOff = false; Crop3D = false; CropUi = false; FallbackRetries++; _lightTgt.Clear();
            }
        }
        /// <summary>中间区换页 / 换场景：8 格里至少 3 格亮度差 ≥ 3 档（16 档）</summary>
        public static bool SceneChanged(uint a, uint b)
        {
            int n = 0; for (int i = 0; i < 8; i++) { int x = (int)(a >> (4 * i) & 15), y = (int)(b >> (4 * i) & 15); if (Math.Abs(x - y) >= 3) n++; }
            return n >= 3;
        }

        /// <summary>出数结果的状态版本：同一次提交里同一绑定、版本没变，出数必与上次相同（直连回放层据此复用上一份改写副本，不再调出数）。
        /// 直连路径里命中只在绑定扫描时增删（ScanGen），写回原值 / 补回改写值各有计数。</summary>
        public long StateGen => Frame.ScanGen + Frame.Restores + Frame.Reapplies;
        /// <summary>本笔各槽出数全为 0（Draw 判成按原样铺满）。</summary>
        public bool EmitsNone => _orig;

        // ---------- 计数（s2a_widen_report） ----------
        long _pushLog0 = -2, _pushLog1;
        public long Draws, DrawsOrig, DrawsFlatShrunk, DrawsFlatPushed, DrawsTallPushed, SideClears, ScratchShort, BadArgs, UnknownShaders, Errors;
        public string Report() => $"[宽屏·核心] 模式 {Mode}，k {Rewriter.K:F4}；写深度旁路 {LightDraws} 笔（校验 {LightChecks}、不符 {LightBad}；退回全量的目标 {LightTargetsBad}）；直连绘制 {Draws}（其中纯色 / 小图层按原样铺满 {DrawsOrig}、横向无细节层推满（原尺寸居中层 {DrawsFlatShrunk}、原尺寸界面层 {DrawsFlatPushed}）、起 16:9 原比例页 {PageDraws}、两侧带没内容先清黑 {SideClears}）；按内容判画布 {Frame.Promoted} 张（未定目标上判过 {Frame.PromoteTries} 笔：视口不铺满 {Frame.PromoteSmallVp}、没读到镜头矩阵 {Frame.PromoteNoCam}）；降采样链中间目标跟着放宽 {Frame.ChainWidened} 张；红：暂存区不够 {ScratchShort}、参数越界 {BadArgs}、异常 {Errors}；没有读法表的着色器 {UnknownShaders} 条；"
            + $"{Rewriter.Stats}；绘制 {Frame.Draws}（放宽目标 {Frame.DrawsWide}、读到改写矩阵 {Frame.DrawsCovered}、界面层 {Frame.DrawsHud}、其中原宽居中 {Frame.DrawsHudCentered}）；写回原值 {Frame.Restores} / 改写值 {Frame.Reapplies}；"
            + $"只扫变了的：比 {Frame.UpBytes >> 10} KB、扫 {Frame.ScanBytes >> 10} KB，影子 {Frame.Shadow.Bytes >> 10} KB，同段未变跳过 {Frame.SameSkips} 次（校验不符 {Frame.SameSkipMiss}），只比更新段 {Frame.RangeBinds} 次（前提不满足改整段 {Frame.RangeFallbacks}、校验不符 {Frame.RangeCheckMiss}）；"
            + $"镜头：有主镜头的帧 {Cam.ValidFrames}/{Cam.Frames}、认出过的候选 {Cam.Found}、末帧存活候选 {Cam.FrameLive}、末帧抽样深度绘制 {Cam.FrameDepthDraws}（深度 {Cam.DiagD1}×{Cam.DiagN1} / {Cam.DiagD2}×{Cam.DiagN2}；主深度上有计数的候选 {Cam.DiagCand}、最高 {Cam.DiagBest}）；原比例回退 {Fallbacks} 次、解除 {FallbackRetries} 次、回退帧 {FallbackFrames}、最短一次 {(FallbackShortest < 0 ? "—" : FallbackShortest + " 次上屏")}、解除后宽屏段最短 {(WideShortest < 0 ? "—" : WideShortest + " 次上屏")}、中间没内容不计的样本 {BlankSamples}";
    }
}
