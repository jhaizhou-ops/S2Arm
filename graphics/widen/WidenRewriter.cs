// 通用宽屏 · 常量识别与改写（画幅线）。不依赖 Ryujinx：输入是「写进某缓冲某偏移的一段字节」，只认数学形状，不写死任何游戏的偏移。
//
// 原理：Switch 游戏按 16:9 出图。把 16:9 一族渲染目标横向放宽 k = 目标宽高比 ÷ (16/9)、视口同比放宽后，
// 再把透视投影的 x 行乘 f = 1/k，裁剪空间 x 缩 k 倍，像素尺寸与原来相同而视野横向变宽（Hor+），不拉伸。
// 识别对象（每个 16 字节对齐的 4×4 矩阵，行存与列存两种布局都认）：
//   投影 P：w 行 = (0, 0, ±1, 0)，x / y 行只有对角（及 z 列的偏心项），|P11| / P00 ≈ 16/9 → x 行乘 f；
//   视图投影 VP：x / y / w 行的 xyz 三分量模之比 = 9 : 16 : 1，三者两两正交，z 行 xyz 非零且与 w 行平行 → x 行乘 f；
//   逆投影 P⁻¹：x / y 行只有对角、对角比 ≈ 16/9、z 行 = (0, 0, 0, ±1) → x 行乘 k；
// 另认三种常量（4 字节对齐）：宽高比常量对 (16/9, 9/16) → (A, 1/A)；屏幕尺寸 vec4 (W, H, 1/W, 1/H) 或 (1/W, 1/H, W, H)，W×H 属 16:9 一族
// → W 换成放宽后的宽度；相机系数对：从已认出的投影 / 逆投影 / 视图投影记下相机签名 (P00, |P11|)，常量里成对出现的 (1/P00, ±1/P11)
// （屏幕空间效果从深度反推视空间位置用，马车8 每帧数十处）→ x 乘 k，(P00, ±P11) → x 乘 1/k；签名只取自本帧及之前认出的矩阵，容差 2e-4。已改写过的值不再匹配（宽高比已不是 16/9），所以同一份数据重复经过也只改一次。
// 零分配：调用方给源与同长的目标缓冲；第一次命中才整段复制到目标，返回 true 时目标就是改写后的数据。
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;

namespace S2Arm.Gfx.Widen
{
    public enum WidenKind : byte { Projection, ViewProjection, InverseProjection, AspectPair, ScreenSize, CameraPair, UiOrtho, PixelRay, PixelStep, UiOrthoWide, WideProjection }
    // WideProjection（11-06 满屏泛化·拉伸风险）：透视投影 / 视图投影的宽高比已经是屏幕比（游戏自己按宽屏算的镜头：第二层改了宽高比除法、或游戏读服务层报的分辨率）。
    //   只登记不改写；按它画的 3D 笔按 k 放宽视口正好不拉伸（WidenFrame.ReadsWideProjection、WidenSession 拉伸风险计数）

    /// <summary>命中回调：缓冲内偏移、长度、种类、是否列存。用于界面层判定记「哪些常量区间被改写过」。</summary>
    public interface IWidenHitSink { void Hit(int bufferOffset, int length, WidenKind kind, bool columnMajor); }

    public struct WidenStats
    {
        public long Scanned, ScannedBytes, Projection, ViewProjection, InverseProjection, AspectPair, ScreenSize, CameraPair, ColumnMajor, ByDepth, Ortho, Ortho2D, UiOrtho, PixelRay, PixelStep, UiOrthoWide, WideProjection;
        public readonly long Total => Projection + ViewProjection + InverseProjection + AspectPair + ScreenSize + CameraPair + PixelRay;
        public override readonly string ToString() =>
            $"扫描 {Scanned} 段 / {ScannedBytes} 字节；改写 投影 {Projection}、视图投影 {ViewProjection}（其中按镜头深度映射认出 {ByDepth}、正交 {Ortho}、纯 2D 款的像素正交 {Ortho2D}）、逆投影 {InverseProjection}、宽高比常量对 {AspectPair}、屏幕尺寸 {ScreenSize}、相机系数对 {CameraPair}（其中列存 {ColumnMajor}）、像素射线起点 {PixelRay} / 步长 {PixelStep}；界面正交（只登记不改）{UiOrtho}、宽排版界面正交 {UiOrthoWide}";
    }

    public sealed class WidenRewriter
    {
        public const float SrcAspect = 16f / 9f;
        /// <summary>诊断（S2A_WIDEN_NOCAM=1）：改写器认不出任何 16:9 镜头（投影 / 视图投影 / 逆投影都不改），模拟「改写器没认出镜头、场景整幅按 k 横拉」（smg2 10-27），
        /// 给满屏自检的拉伸风险做阳性对照（runtime/src/qprompt_host.c 应在两个局内窗口后自动退回 16:9）。</summary>
        static readonly bool s_noCam = Environment.GetEnvironmentVariable("S2A_WIDEN_NOCAM") == "1";
        const float AspectTol = 0.01f;   // 宽高比相对容差（1%，fovy 取整不影响）
        const float ZeroTol = 1e-6f;

        public readonly float Aspect, K, F;
        readonly int _extra1920;   // 1920 宽多出的列数（偶数）；各宽度按它精确成比例
        // 纵向（10-26 任意宽高比：屏幕比 16:9 窄，iPhone Duo 内屏 1.42、iPad 4:3）：宽不动、高放 Ky（上下多画），投影 y 行乘 Fy = 1/Ky（水平视野不变、竖直多看）。
        //   Ky 吸附到「1080 高多出的行数为偶数」，同横向。K 与 Ky 至多一个 > 1
        public readonly float Ky = 1, Fy = 1;
        readonly int _extra1080;
        public WidenStats Stats;
        const int MaxCams = 8;
        readonly float[] _camX = new float[MaxCams], _camY = new float[MaxCams];   // 相机签名 (P00, |P11|)
        // 表满时淘汰最久没见到的签名（登记或去重命中都算见到）。10-23 暗黑2 营地：每隔几十帧有一批深度参数各异的签名连续登记，原先按先进先出轮换，
        // 把每帧都在用的世界正交镜头挤出表，那一帧它的正交投影认不出，火光粒子按拉伸位置画进光晕层（截帧第 145 帧火苗脱离火把右移 48 像素）
        readonly long[] _camSeen = new long[MaxCams]; long _camTick;
        // 相机深度映射 (a, b)：任何 M = P·X（X 仿射，世界矩阵任意、含非均匀缩放）都满足 z 行 = a·w 行 + b·(0,0,0,1)，(a, b) 只由投影的深度参数定（a = −P22、b = P23）；
        // 逆投影来的签名没有（NaN）。用来认「形状已看不出 16:9」的世界·视图·投影（10-21 暗黑3 点光源光照体：非均匀缩放，|w| = 36、y·w 不正交）
        readonly float[] _camA = new float[MaxCams], _camB = new float[MaxCams];
        readonly bool[] _camOrtho = new bool[MaxCams];   // 签名来自正交投影（w 行 = 0001）：MatchOrtho 只认这些
        // 每个镜头最近一次见到的原始视图投影 C（行存，形状认出的不缩放视图投影 / 投影才记）及其逆（要用时才求）。认「这台镜头 × 不带剪切的世界矩阵」：
        // M = C·W ⇔ C⁻¹·M 是仿射（末行 0001）且线性部分各列两两正交（旋转 × 各轴缩放）。镜头移动 / 转动不影响（C_old⁻¹·C_new 仍是仿射 + 旋转）；
        // 换一台视角不同的镜头（10-21 马车8 选车界面的卡丁车预览）C⁻¹·M 带两个投影之比，不是仿射 → 不认
        readonly double[][] _camC = new double[MaxCams][], _camCi = new double[MaxCams][];
        readonly bool[] _camCiOk = new bool[MaxCams];   // 逆矩阵与 C 同步（C 每次认出视图投影都更新；用到时才原地重求，稳态零分配）
        int _camN;
        /// <summary>新签名放哪一格：表没满放末尾，满了换掉最久没见到的。</summary>
        int CamSlot() { if (_camN < MaxCams) return _camN++; int j = 0; for (int i = 1; i < MaxCams; i++) if (_camSeen[i] < _camSeen[j]) j = i; return j; }
        public int Cameras => _camN;
        /// <summary>相机签名表变过几次（新签名加入）：变了之后，之前在不变的数据里判过没中的系数对要重判（WidenFrame 让影子全部作废、下次上传整段重扫）。</summary>
        public long CameraVersion => _camVer;
        long _camVer;

        /// <param name="targetAspect">屏幕宽高比（iPhone 17 Pro Max 2868×1320 = 2.1727，吸附后 2346/1080 = 2.1722）；≤ 16/9 时不放宽（K = 1，一切改写关闭）。</param>
        public WidenRewriter(float targetAspect)
        {
            float a = targetAspect > SrcAspect * (1 + AspectTol) ? targetAspect : SrcAspect;
            // K 吸附到「1920 宽多出的列数为偶数」：Switch 两档输出 1920 / 1280 宽都正好多偶数列，居中偏移是整数像素，
            // 中间 16:9 区（含界面层）与原图逐像素对齐、不出半像素模糊。2868×1320 → K = 2346/1920 = 1.221875，比例误差 0.02%
            _extra1920 = 2 * (int)MathF.Round(960 * (a / SrcAspect - 1));
            K = 1 + _extra1920 / 1920f;
            if (targetAspect > 0 && targetAspect < SrcAspect * (1 - AspectTol))   // 窄屏：同理吸附到「1080 高多出偶数行」（Duo 2670×1878 → 1080 × 1.25 = 1350）
            { _extra1080 = 2 * (int)MathF.Round(540 * (SrcAspect / targetAspect - 1)); Ky = 1 + _extra1080 / 1080f; Fy = 1 / Ky; }
            Aspect = K * SrcAspect / Ky;
            F = 1 / K;
        }

        public bool On => K > 1 || Ky > 1;
        public bool Tall => Ky > 1;   // 窄屏上下多画

        /// <summary>16:9 一族（1920×1080、1280×720、960×540 … 30×17 这类整除取整的尺寸也算）。</summary>
        public static bool Family(int w, int h) => h >= 8 && w >= 16 && Math.Abs(w * 9.0 / (h * 16.0) - 1) < 0.04;

        /// <summary>放宽后的宽度；不属 16:9 一族或关闭时原样返回。两条，按优先：
        /// ① 宽是某个「宽 × K 正好是整数」的整宽（1920 / 1600 / 1280 / 640 / 320）本身或按级缩下来的（宽 &lt;&lt; L ≤ 4096）：取 ⌊宽 × K⌋——
        ///    L = 0 时就是整数宽 × K：横向放宽比正好是 K，贴图里从原点起的子画布（掌机档在主机尺寸缓冲里只画左上 1280×720）与整张、不同宽度的贴图之间横向换算都是整数、互拷 / 合成 1:1
        ///    （10-21 前 1600 按②取 1956：暗黑2 视口 1280 → 1564.8、上屏裁剪 1565，半像素）；
        ///    L &gt; 0 时 ⌊宽 × K⌋ = 整宽放宽后按级缩的宽（mip 第 L 级 = ⌊宽1 / 2^L⌋），独立建的降采样链贴图与大贴图的 mip 级互拷尺寸一致
        ///    （10-21 暗黑2 / 帧率能耗线开校验层：160×90 按②取 196、拷进 1280 链第 3 级只有 1564 &gt;&gt; 3 = 195，第 4 级 98 对 97 → 拷贝越界）；
        /// ② 否则多出偶数列（居中偏移是整数，按改写投影画的内容像素格在中心与客体对齐）：丝之歌 1024×576 取 1251（≈ 1024 × K）时像素格错半格，中间三分之一差异 >8 的像素 160 → 6012。</summary>
        /// <summary>窄屏上下多画时放高后的高度（同 WidenWidth 的两条规则，按 1080 高多出的偶数行 _extra1080 成比例）；不加高或不属 16:9 一族原样返回。</summary>
        public int WidenHeight(int w, int h)
        {
            if (Ky <= 1 || !Family(w, h)) return h;
            long e = (long)h * _extra1080;
            for (long b = h; b <= 4096; b <<= 1)
                if (b * _extra1080 % 1080 == 0) return h + (int)(e / 1080);
            return h + 2 * (int)Math.Round((double)e / 2160, MidpointRounding.AwayFromZero);
        }
        public int WidenWidth(int w, int h) => !On || !Family(w, h) ? w : WidenAnyWidth(w);

        /// <summary>窄屏上下多画时按内容判成画布的非 16:9 目标（WidenFrame.TryPromote 竖向，11-02 银河2 Duo 外屏 Wii EFB 1920×1584）：不看宽，按 WidenHeight 同一规则多出偶数行。</summary>
        public int WidenAnyHeight(int h)
        {
            if (Ky <= 1) return h;
            long e = (long)h * _extra1080;
            for (long b = h; b <= 4096; b <<= 1)
                if (b * _extra1080 % 1080 == 0) return h + (int)(e / 1080);
            return h + 2 * (int)Math.Round((double)e / 2160, MidpointRounding.AwayFromZero);
        }
        /// <summary>按内容判成画布的非 16:9 目标（WidenFrame.Promote，10-30 银河2 1920×1584 Wii EFB）：不看高，按同一规则多出偶数列（1920 → 屏宽）。</summary>
        public int WidenAnyWidth(int w)
        {
            if (!On) return w;
            long e = (long)w * _extra1920;
            for (long b = w; b <= 4096; b <<= 1)
                if (b * _extra1920 % 1920 == 0) return w + (int)(e / 1920);
            return w + 2 * (int)Math.Round((double)e / 3840, MidpointRounding.AwayFromZero);
        }

        /// <summary>扫描一段写入缓冲的数据。bufferOffset = 这段数据在缓冲内的起始偏移（矩阵按缓冲内 16 字节对齐找）。
        /// 有命中返回 true，此时 dst[..src.Length] 是改写后的整段；无命中不碰 dst。</summary>
        public bool Rewrite(ReadOnlySpan<byte> src, int bufferOffset, Span<byte> dst, IWidenHitSink sink = null)
        {
            if (!On || src.Length < 8) return false;
            Stats.Scanned++; Stats.ScannedBytes += src.Length;
            bool hit = false;
            int start = (16 - (bufferOffset & 15)) & 15;
            // 快筛按下标读整段的浮点视图（不逐位置切片）：读 src 即可——改写只动命中窗口自己的 x 行，之后的窗口从命中窗口末尾起，碰不到改过的字节
            ReadOnlySpan<float> fs = start < src.Length ? MemoryMarshal.Cast<byte, float>(src[start..]) : default;
            // 第一段（向量、一遍）：每 16 字节块 i 的平方 sq = (a², b², c², d²)，记 s3[i] = a² + b² + c²、l2[i] = c²、l3[i] = d²。
            // 第二段：窗口 b（块 b..b+3）先过只读这几个数的必要条件——行存 w 行模方 s3[b+3] 或列存 w 行模方 l3[b]+l3[b+1]+l3[b+2] ∈ (0.979, 1.021)
            //（透视投影的 w 行 ≈ (0, 0, ±1) 也落在里面），或 |z 行|² ≈ a²·|w 行|²（某个已认出镜头的深度映射：带缩放的世界·视图·投影 w 行模长 ≠ 1，见 MatchRows / MatchDepth），
            // 或逆投影：行存 s3[b+2] &lt; 3e-10 且 l3[b+2] ≈ 1、列存 l2[b]+l2[b+1]+l2[b+2] &lt; 3e-10 且 l2[b+3] ≈ 1。都比 MaybeMatrix 宽
            int nb = fs.Length >> 2;
            if (nb >= 4) Squares(fs, nb);
            float[] s3 = t_s3, l2 = t_l2, l3 = t_l3;
            PrepareDepthFilter();
            for (int p = start; p + 64 <= src.Length; p += 16)
            {
                int b = (p - start) >> 4;
                float rw = s3[b + 3], cw = l3[b] + l3[b + 1] + l3[b + 2];
                if (!(MathF.Abs(rw - 1) < 0.021f || MathF.Abs(cw - 1) < 0.021f
                    || (s3[b + 2] < 3e-10f && MathF.Abs(l3[b + 2] - 1) < 4.1e-4f)
                    || ((rw < 3e-10f || cw < 3e-10f) && MathF.Abs(l3[b + 3] - 1) < 4.1e-4f)
                    || (l2[b] + l2[b + 1] + l2[b + 2] < 3e-10f && MathF.Abs(l2[b + 3] - 1) < 4.1e-4f)
                    || MaybeDepth(s3[b + 2], rw, l2[b] + l2[b + 1] + l2[b + 2], cw, l3[b + 2], l2[b + 3])
                    || MaybeUiCanvas(fs.Slice((p - start) >> 2, 8)))) continue;
                bool shape = MaybeMatrix(fs.Slice((p - start) >> 2, 16)), depth = MaybeDepth(s3[b + 2], rw, l2[b] + l2[b + 1] + l2[b + 2], cw, l3[b + 2], l2[b + 3]);
                bool w0001 = (rw < 3e-10f || cw < 3e-10f) && MathF.Abs(l3[b + 3] - 1) < 4.1e-4f, ortho = w0001 && _orthoN > 0;
                if (w0001 && shape) NoteSymOrtho(MemoryMarshal.Cast<byte, float>((hit ? dst : src).Slice(p, 64)));
                bool wideShape = !shape && MaybeWide(fs.Slice((p - start) >> 2, 16));
                if (!shape && !depth && !ortho && !w0001 && !wideShape) continue;
                ReadOnlySpan<float> m = MemoryMarshal.Cast<byte, float>((hit ? dst : src).Slice(p, 64));
                if (!AllFinite(m)) continue;
                WidenKind kind; bool col; bool canvasHit = false;
                if (shape && MatchEither(m, out kind, out col) && AcceptShape(m, kind, col)) { }
                else if (depth && MatchDepth(m, out col)) { kind = WidenKind.ViewProjection; Stats.ByDepth++; }
                else if (ortho && MatchOrtho(m, out col)) { kind = WidenKind.ViewProjection; Stats.Ortho++; }
                else if (w0001 && MatchTiltOrtho(m, out col)) { kind = WidenKind.ViewProjection; Stats.Ortho++; }
                else if (ortho && MatchInvOrtho(m, out col)) kind = WidenKind.InverseProjection;
                else if (w0001 && IsUiOrtho(m, out col)) kind = WidenKind.UiOrtho;
                else if (IsUiCanvas(m)) { kind = WidenKind.UiOrtho; col = false; canvasHit = true; }
                else if (K > 1 && w0001 && IsUiOrthoWide(m, Aspect, out col)) kind = WidenKind.UiOrthoWide;
                else if (K > 1 && IsUiCanvasWide(m, Aspect)) { kind = WidenKind.UiOrthoWide; col = false; canvasHit = true; }
                else if ((shape || wideShape) && MatchWide(m, out col)) kind = WidenKind.WideProjection;
                else continue;
                if (s_noCam && kind <= WidenKind.InverseProjection) continue;   // 诊断：认不出 16:9 镜头（拉伸风险阳性对照）
                kind = Scene2D(kind, canvasHit);
                if (!hit) { src.CopyTo(dst); hit = true; }
                Span<float> w = MemoryMarshal.Cast<byte, float>(dst.Slice(p, 64));
                float s = kind == WidenKind.InverseProjection ? K : F;
                if (kind != WidenKind.UiOrtho && kind != WidenKind.UiOrthoWide && kind != WidenKind.WideProjection) { ScaleX(w, col, s); if (Ky > 1) ScaleY(w, col, kind == WidenKind.InverseProjection ? Ky : Fy); }   // 界面正交只登记不改
                Count(kind, col);
                sink?.Hit(bufferOffset + p, canvasHit ? 32 : 64, kind, col);
                p += canvasHit ? 16 : 48;   // 界面画布只占 32 字节：后面的窗口照判
            }
            // 逐浮点扫的三种（宽高比对 / 相机系数对 / 屏幕尺寸）先按取值范围快筛：落在任何一种可能的取值区间外的位置原样跳过（只跳过一定不命中的，结果逐位同不筛）
            float aLo = SrcAspect * (1 - 2e-4f), aHi = SrcAspect * (1 + 2e-4f);
            // 相机系数对的首元素要 ≈ 某个相机签名的 P00 或 1/P00（相对容差 2e-4，CameraPair）：每个签名两个小区间（放宽到 4e-4 吸收浮点舍入），外加总范围先挡一道
            Span<float> cLo = stackalloc float[2 * MaxCams], cHi = stackalloc float[2 * MaxCams]; int nc = 0; float cMin = float.MaxValue, cMax = float.MinValue;
            for (int i = 0; i < _camN; i++)
                for (int j = 0; j < 2; j++)
                {
                    float t = j == 0 ? _camX[i] : 1 / _camX[i];
                    if (!(t > 0) || _camOrtho[i]) continue;   // 正交签名不参与相机系数对（只给 MatchOrtho 用）
                    cLo[nc] = t * (1 - 4e-4f); cHi[nc] = t * (1 + 4e-4f); cMin = MathF.Min(cMin, cLo[nc]); cMax = MathF.Max(cMax, cHi[nc]); nc++;
                }
            // 快筛读本循环开始时的那份（之前已命中读 dst、否则读 src）：本循环里的改写同样只动当前位置起的几个浮点、之后跳过它们，后面的位置读到的值不变
            int p0 = (4 - (bufferOffset & 3)) & 3;
            ReadOnlySpan<float> fv = p0 < src.Length ? MemoryMarshal.Cast<byte, float>((hit ? (ReadOnlySpan<byte>)dst[..src.Length] : src)[p0..]) : default;
            Vector128<float> vaLo = Vector128.Create(aLo), vaHi = Vector128.Create(aHi), vcLo = Vector128.Create(cMin), vcHi = Vector128.Create(cMax);
            int j16 = ((-(bufferOffset + p0)) & 15) >> 2;   // 每块（从 p0 起每 4 个浮点）里缓冲内 16 字节对齐的那个位置
            int blkStart = -1, blkMask = 0;
            for (int p = p0; p + 8 <= src.Length; p += 4)
            {
                int q = (p - p0) >> 2;
                // 按块（从 p0 起每 4 个浮点）算可疑位掩码：第 j 位 = 第 j 个位置的首元素在宽高比 / 相机签名总范围内，或它是块里唯一 16 字节对齐的位置（第 j16 个）
                // 且第 0 或第 2 个浮点在 [16, 16384]（像屏幕尺寸）。掩码外的位置三种判定都一定不命中，直接跳到块里下一个可疑位置或下一块
                int bs = q & ~3;
                if (bs != blkStart)
                {
                    blkStart = bs;
                    if (bs + 4 <= fv.Length && bs + j16 + 3 <= fv.Length)
                    {
                        Vector128<float> x = Vector128.Create(fv.Slice(bs, 4));
                        Vector128<float> hitv = (Vector128.GreaterThanOrEqual(x, vaLo) & Vector128.LessThanOrEqual(x, vaHi)) | (Vector128.GreaterThanOrEqual(x, vcLo) & Vector128.LessThanOrEqual(x, vcHi));
                        float s0 = fv[bs + j16], s2 = fv[bs + j16 + 2];
                        blkMask = (int)hitv.ExtractMostSignificantBits() | ((s0 >= 16 && s0 <= 16384) || (s2 >= 16 && s2 <= 16384) || IntMaxLead(s0) ? 1 << j16 : 0);
                    }
                    else blkMask = 0xF;
                }
                int rest = blkMask >> (q - bs);
                if ((rest & 1) == 0)
                {
                    p += 4 * (rest == 0 ? bs + 4 - q : System.Numerics.BitOperations.TrailingZeroCount(rest)) - 4;
                    continue;
                }
                float a0 = fv[q];
                bool inA = a0 >= aLo && a0 <= aHi, inC = a0 >= cMin && a0 <= cMax && InAny(a0, cLo[..nc], cHi[..nc]);
                // 屏幕尺寸 vec4：两种排列里宽（第 0 或第 2 个）要在 [16, 16384]（ScreenSize 的第一道条件；NaN 为假）
                bool inS = ((bufferOffset + p) & 15) == 0 && p + 16 <= src.Length && ((fv[q] >= 16 && fv[q] <= 16384) || (fv[q + 2] >= 16 && fv[q + 2] <= 16384) || IntMaxLead(fv[q]));
                if (!inA && !inC && !inS) continue;
                ReadOnlySpan<float> v = MemoryMarshal.Cast<byte, float>((hit ? dst : src).Slice(p, Math.Min(16, src.Length - p) & ~3));
                // 三种判定按宽高比对 → 屏幕尺寸 → 相机系数对；快筛没过的那种一定不命中，直接跳过它（结果同不跳）
                if (inA && Near(v[0], SrcAspect, 1e-4f) && Near(v[1], 1 / SrcAspect, 1e-4f))
                {
                    if (!hit) { src.CopyTo(dst); hit = true; }
                    Span<float> w = MemoryMarshal.Cast<byte, float>(dst.Slice(p, 8));
                    w[0] = Aspect; w[1] = 1 / Aspect;
                    Count(WidenKind.AspectPair, false); sink?.Hit(bufferOffset + p, 8, WidenKind.AspectPair, false);
                    p += 4; continue;
                }
                // 屏幕尺寸先于相机系数对：完整的 (W, H, 1/W, 1/H)（W、H 是 16:9 一族的整数像素、后两格恰是倒数）比两个浮点的系数对具体得多。
                // 10-23 暗黑2 火光漂移：错位窗口把界面正交（2/1280、2/720）认成视图投影，登记出像素尺度的「镜头」(1/640, 1/360)；半分辨率屏幕尺寸
                // (640, 360, 1/640, 1/360) 于是被当成两个相机系数对改成 782——数值同屏幕尺寸改写，但种类不对，「读片元坐标的程序要原值」（WidenFrame.NeedsOriginal）管不到，
                // 光晕降采样（片元坐标 ÷ k × 1/782 取图）把火苗 / 紫火的光横向拉 k 倍（营地火把 x 873 → 1241，应在 1015）
                if (v.Length == 4 && ((bufferOffset + p) & 15) == 0 && ScreenSize(v, out int order, out int sw, out int sh))
                {
                    if (!hit) { src.CopyTo(dst); hit = true; }
                    Span<float> w = MemoryMarshal.Cast<byte, float>(dst.Slice(p, 16));
                    float nw = WidenWidth(sw, sh), nh = WidenHeight(sw, sh);
                    if (order == 0) { w[0] = nw; w[2] = 1 / nw; } else if (order == 1) { w[0] = 1 / nw; w[2] = nw; } else w[2] = nw;
                    if (Ky > 1) { if (order == 0) { w[1] = nh; w[3] = 1 / nh; } else if (order == 1) { w[1] = 1 / nh; w[3] = nh; } else w[3] = nh; }   // 高只在窄屏改：宽屏时高的位按原值不动（逐位不变）
                    Count(WidenKind.ScreenSize, false); sink?.Hit(bufferOffset + p, 16, WidenKind.ScreenSize, false);
                    p += 12; continue;
                }
                if (v.Length == 4 && ((bufferOffset + p) & 15) == 0 && IntMaxRect(v, out int mw, out int mh))
                {
                    if (!hit) { src.CopyTo(dst); hit = true; }
                    MemoryMarshal.Cast<byte, int>(dst.Slice(p, 16))[0] = WidenWidth(mw, mh) - 1; if (Ky > 1) MemoryMarshal.Cast<byte, int>(dst.Slice(p, 16))[1] = WidenHeight(mw, mh) - 1;
                    Count(WidenKind.ScreenSize, false); sink?.Hit(bufferOffset + p, 16, WidenKind.ScreenSize, false);
                    p += 12; continue;
                }
                if (inC && CameraPair(v[0], v[1], out bool inverse))
                {
                    if (!hit) { src.CopyTo(dst); hit = true; }
                    MemoryMarshal.Cast<byte, float>(dst.Slice(p, 4))[0] *= inverse ? K : F;
                    if (Ky > 1) MemoryMarshal.Cast<byte, float>(dst.Slice(p, 8))[1] *= inverse ? Ky : Fy;   // 系数对的第二个是 |P11|（或其倒数）
                    Count(WidenKind.CameraPair, false); sink?.Hit(bufferOffset + p, 8, WidenKind.CameraPair, false);
                    p += 4; continue;
                }
            }
            return hit;
        }

        // ---------- 逐单元判（10-21「只扫变了的」：WidenFrame 上传时只判碰到变了字节的窗口 / 浮点位置；判据、改写、相机签名、计数与上面整段扫描同一套） ----------
        /// <summary>一个 64 字节窗口（缓冲内 16 字节对齐）判投影 / 视图投影 / 逆投影。命中返回 true：dst = 改写后的 16 个浮点（x 行乘 F，逆投影乘 K），并记相机签名、计数。
        /// 整段扫描的块平方快筛只是比 MaybeMatrix 宽的必要条件，这里省掉不影响结果。</summary>
        public bool RewriteWindow(ReadOnlySpan<float> m, Span<float> dst, out WidenKind kind, out bool col)
        {
            kind = default; col = false;
            if (!On) return false;
            // 先过两种快筛（形状 / 深度），都不过的窗口不做全有限数检查与判定（逐窗口路径的热点：w 行模方 ≈ 1 放进来的窗口很多）
            bool shape = MaybeMatrix(m), depth = PrepareDepthFilterCheap() && MaybeDepth(m[8] * m[8] + m[9] * m[9] + m[10] * m[10], m[12] * m[12] + m[13] * m[13] + m[14] * m[14],
                m[2] * m[2] + m[6] * m[6] + m[10] * m[10], m[3] * m[3] + m[7] * m[7] + m[11] * m[11], m[11] * m[11], m[14] * m[14]);
            float orw = m[12] * m[12] + m[13] * m[13] + m[14] * m[14], ocw = m[3] * m[3] + m[7] * m[7] + m[11] * m[11];
            bool w0001 = (orw < 3e-10f || ocw < 3e-10f) && MathF.Abs(m[15] * m[15] - 1) < 4.1e-4f, ortho = w0001 && _orthoN > 0;
            bool canvasForm = false;
            if (w0001 && shape) NoteSymOrtho(m);
            bool canvas = MaybeUiCanvas(m), wideShape = !shape && MaybeWide(m);
            if (!shape && !depth && !ortho && !w0001 && !canvas && !wideShape || !AllFinite(m)) return false;
            if (shape && MatchEither(m, out kind, out col) && AcceptShape(m, kind, col)) { }
            else if (depth && MatchDepth(m, out col)) { kind = WidenKind.ViewProjection; Stats.ByDepth++; }
            else if (ortho && MatchOrtho(m, out col)) { kind = WidenKind.ViewProjection; Stats.Ortho++; }
            else if (w0001 && MatchTiltOrtho(m, out col)) { kind = WidenKind.ViewProjection; Stats.Ortho++; }
            else if (ortho && MatchInvOrtho(m, out col)) kind = WidenKind.InverseProjection;
            else if (w0001 && IsUiOrtho(m, out col)) kind = WidenKind.UiOrtho;
            else if (canvas && IsUiCanvas(m)) { kind = WidenKind.UiOrtho; col = false; canvasForm = true; }
            else if (K > 1 && w0001 && IsUiOrthoWide(m, Aspect, out col)) kind = WidenKind.UiOrthoWide;
            else if (K > 1 && canvas && IsUiCanvasWide(m, Aspect)) { kind = WidenKind.UiOrthoWide; col = false; }
            else if ((shape || wideShape) && MatchWide(m, out col)) kind = WidenKind.WideProjection;
            else return false;
            if (s_noCam && kind <= WidenKind.InverseProjection) return false;   // 诊断：认不出 16:9 镜头（拉伸风险阳性对照）
            kind = Scene2D(kind, canvasForm);
            m[..16].CopyTo(dst);
            float s = kind == WidenKind.InverseProjection ? K : F;
            if (kind != WidenKind.UiOrtho && kind != WidenKind.UiOrthoWide && kind != WidenKind.WideProjection) { ScaleX(dst, col, s); if (Ky > 1) ScaleY(dst, col, kind == WidenKind.InverseProjection ? Ky : Fy); }
            Count(kind, col);
            return true;
        }

        /// <summary>窗口快筛（同整段扫描的块平方必要条件）：形状快筛 QuickShape，或 |z 行|² ≈ a²·|w 行|²（某个已知相机的深度映射，MatchDepth 的必要条件）。</summary>
        public bool QuickWindow(ReadOnlySpan<float> m) => QuickShape(m) || MaybeUiCanvas(m)
            || (PrepareDepthFilterCheap() && MaybeDepth(m[8] * m[8] + m[9] * m[9] + m[10] * m[10], m[12] * m[12] + m[13] * m[13] + m[14] * m[14], m[2] * m[2] + m[6] * m[6] + m[10] * m[10], m[3] * m[3] + m[7] * m[7] + m[11] * m[11], m[11] * m[11], m[14] * m[14]));
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        bool PrepareDepthFilterCheap() { if (_dVer != _camVer) PrepareDepthFilter(); return _dN + _z0N > 0; }

        /// <summary>形状快筛（比 MaybeMatrix 宽）：行存 / 列存 w 行模方 ∈ (0.979, 1.021)，或逆投影的 z 行 / 列近零且 (2,3) / (3,2) ≈ ±1。
        /// 带缩放的世界·视图·投影（|w| ≠ 1）由 QuickWindow 的深度快筛放进来（要先由不缩放的视图投影 / 投影认出镜头）。</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool QuickShape(ReadOnlySpan<float> m)
        {
            float rw = m[12] * m[12] + m[13] * m[13] + m[14] * m[14], cw = m[3] * m[3] + m[7] * m[7] + m[11] * m[11];
            if (MathF.Abs(rw - 1) < 0.021f || MathF.Abs(cw - 1) < 0.021f) return true;
            // 正交投影 / 正交 × 视图：行存 / 列存 w 行 xyz ≈ 0 且 w₃ ≈ 1
            if ((rw < 3e-10f || cw < 3e-10f) && MathF.Abs(m[15] * m[15] - 1) < 4.1e-4f) return true;
            if (m[8] * m[8] + m[9] * m[9] + m[10] * m[10] < 3e-10f && MathF.Abs(m[11] * m[11] - 1) < 4.1e-4f) return true;
            return m[2] * m[2] + m[6] * m[6] + m[10] * m[10] < 3e-10f && MathF.Abs(m[14] * m[14] - 1) < 4.1e-4f;
        }

        // 浮点条目快筛（同整段扫描）：首元素在宽高比 / 某个相机签名附近，或（16 字节对齐处）第 0 / 2 个浮点像屏幕宽 [16, 16384]
        readonly float[] _fLo = new float[2 * MaxCams], _fHi = new float[2 * MaxCams]; int _fN; float _fMin, _fMax; long _fVer = -1;
        /// <summary>按当前相机签名备好浮点快筛的区间（签名只在判矩阵时增加：每扫一轮浮点之前调一次）。</summary>
        public void PrepareFloatFilter()
        {
            if (_fVer == _camVer) return;
            _fVer = _camVer;
            _fN = 0; _fMin = float.MaxValue; _fMax = float.MinValue;
            for (int i = 0; i < _camN; i++)
                for (int j = 0; j < 2; j++)
                {
                    float t = j == 0 ? _camX[i] : 1 / _camX[i];
                    if (!(t > 0) || _camOrtho[i]) continue;   // 正交签名不参与相机系数对
                    _fLo[_fN] = t * (1 - 4e-4f); _fHi[_fN] = t * (1 + 4e-4f); _fMin = MathF.Min(_fMin, _fLo[_fN]); _fMax = MathF.Max(_fMax, _fHi[_fN]); _fN++;
                }
        }
        /// <summary>相机签名快筛的总范围（PrepareFloatFilter 之后有效；没有签名时 Min &gt; Max）。</summary>
        public float FilterMin => _fMin;
        public float FilterMax => _fMax;
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool QuickFloat(float a0, float a2, bool aligned16)
        {
            const float aLo = SrcAspect * (1 - 2e-4f), aHi = SrcAspect * (1 + 2e-4f);
            if (a0 >= aLo && a0 <= aHi) return true;
            if (a0 >= _fMin && a0 <= _fMax && InAny(a0, _fLo.AsSpan(0, _fN), _fHi.AsSpan(0, _fN))) return true;
            return aligned16 && ((a0 >= 16 && a0 <= 16384) || (a2 >= 16 && a2 <= 16384) || IntMaxLead(a0));
        }

        /// <summary>缓冲内 4 字节对齐位置上的浮点条目，判据与顺序同整段扫描（宽高比对 → 屏幕尺寸 → 相机系数对）。v = 从这里起已知的浮点（≥2 个才判，
        /// 屏幕尺寸要 4 个且 aligned16）。命中返回条目字节数（8 / 16），dst[..字节数/4] = 改写后的值；否则 0。</summary>
        public int RewriteFloats(ReadOnlySpan<float> v, bool aligned16, Span<float> dst, out WidenKind kind)
        {
            kind = default;
            if (!On || v.Length < 2) return 0;
            if (Near(v[0], SrcAspect, 1e-4f) && Near(v[1], 1 / SrcAspect, 1e-4f))
            {
                dst[0] = Aspect; dst[1] = 1 / Aspect;
                kind = WidenKind.AspectPair; Count(kind, false); return 8;
            }
            if (v.Length >= 4 && aligned16 && ScreenSize(v[..4], out int order, out int sw, out int sh))
            {
                v[..4].CopyTo(dst);
                float nw = WidenWidth(sw, sh), nh = WidenHeight(sw, sh);
                if (order == 0) { dst[0] = nw; dst[2] = 1 / nw; } else if (order == 1) { dst[0] = 1 / nw; dst[2] = nw; } else dst[2] = nw;
                    if (Ky > 1) { if (order == 0) { dst[1] = nh; dst[3] = 1 / nh; } else if (order == 1) { dst[1] = 1 / nh; dst[3] = nh; } else dst[3] = nh; }   // 高只在窄屏改：宽屏时高的位按原值不动（逐位不变）
                kind = WidenKind.ScreenSize; Count(kind, false); return 16;
            }
            if (v.Length >= 4 && aligned16 && IntMaxRect(v[..4], out int mw, out int mh))
            {
                v[..4].CopyTo(dst);
                MemoryMarshal.Cast<float, int>(dst)[0] = WidenWidth(mw, mh) - 1; if (Ky > 1) MemoryMarshal.Cast<float, int>(dst)[1] = WidenHeight(mw, mh) - 1;
                kind = WidenKind.ScreenSize; Count(kind, false); return 16;
            }
            if (CameraPair(v[0], v[1], out bool inverse))
            {
                dst[0] = v[0] * (inverse ? K : F); dst[1] = Ky > 1 ? v[1] * (inverse ? Ky : Fy) : v[1];
                kind = WidenKind.CameraPair; Count(kind, false); return 8;
            }
            return 0;
        }

        /// <summary>界面正交投影（像素空间画布 → NDC）：w 行 = (0,0,0,1)，x / y 行轴对齐，2/|(0,0)|、2/|(1,1)| 是 16:9 一族的整数像素宽高（1280×720、1920×1080 …），偏移任意。
        /// 只登记不改写：读它的绘制在放宽目标上按原尺寸居中画（WidenFrame.OnDraw），不再被视口按 k 横向拉宽（10-21 暗黑2 界面层：生命球 / 法力球横 1.215 / 1.220）。
        /// 世界的正交投影 2/P00 是世界单位（暗黑2 78.6），不是像素尺寸，不在这里。</summary>
        public static bool IsUiOrtho(ReadOnlySpan<float> m, out bool col)
        {
            for (int c = 0; c < 2; c++)
            {
                col = c == 1;
                float a0 = m[0], a1 = col ? m[4] : m[1], a2 = col ? m[8] : m[2], b0 = col ? m[1] : m[4], b1 = m[5], b2 = col ? m[9] : m[6];
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14];
                if (!Z(w0) || !Z(w1) || !Z(w2) || MathF.Abs(m[15] - 1) > 1e-4f || !Z(a1) || !Z(a2) || !Z(b0) || !Z(b2) || Z(a0) || Z(b1)) continue;
                float W = 2 / MathF.Abs(a0), H = 2 / MathF.Abs(b1);
                if (W < 16 || W > 16384 || MathF.Abs(W - MathF.Round(W)) > 0.02f || MathF.Abs(H - MathF.Round(H)) > 0.02f) continue;
                if (!Family((int)MathF.Round(W), (int)MathF.Round(H)) || !Near(W / H, SrcAspect, AspectTol)) continue;
                return true;
            }
            col = false; return false;
        }

        /// <summary>宽排版界面正交（10-26 暗黑2 直连菜单）：同 IsUiOrtho 的轴对齐像素正交，但画布宽高比 = 放宽后的屏幕比（16:9 × K，如 1564×720），
        /// 即游戏按第一层报的宽分辨率自己把界面排成了宽版。只登记不改：读它的绘制已经铺满原生宽区域，不能再当 16:9 界面层收回中间（收回会露出右侧黑边、界面不居中）。</summary>
        public static bool IsUiOrthoWide(ReadOnlySpan<float> m, float aspect, out bool col)
        {
            for (int c = 0; c < 2; c++)
            {
                col = c == 1;
                float a0 = m[0], a1 = col ? m[4] : m[1], a2 = col ? m[8] : m[2], b0 = col ? m[1] : m[4], b1 = m[5], b2 = col ? m[9] : m[6];
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14];
                if (!Z(w0) || !Z(w1) || !Z(w2) || MathF.Abs(m[15] - 1) > 1e-4f || !Z(a1) || !Z(a2) || !Z(b0) || !Z(b2) || Z(a0) || Z(b1)) continue;
                float W = 2 / MathF.Abs(a0), H = 2 / MathF.Abs(b1);
                if (W < 16 || W > 16384 || H < 16 || MathF.Abs(W - MathF.Round(W)) > 0.02f || MathF.Abs(H - MathF.Round(H)) > 0.02f) continue;
                if (!Near(W / H, aspect, AspectTol)) continue;
                return true;
            }
            col = false; return false;
        }
        /// <summary>宽排版界面画布的「缩放 + 偏移」形式（同 IsUiCanvas，画布宽高比 = 放宽后的屏幕比）。</summary>
        public static bool IsUiCanvasWide(ReadOnlySpan<float> m, float aspect)
        {
            if (m.Length < 8 || !MaybeUiCanvas(m)) return false;
            float W = 2 / m[0], H = 2 / MathF.Abs(m[1]);
            if (H < 16 || MathF.Abs(W - MathF.Round(W)) > 0.02f || MathF.Abs(H - MathF.Round(H)) > 0.02f || !Near(W / H, aspect, AspectTol)) return false;
            return m[2] == 0 && m[3] == 0 && Near(m[6], -W / 2, 1e-4f) && Near(m[7], -H / 2, 1e-4f);
        }

        /// <summary>界面画布的「缩放 + 偏移」形式（10-25 哈迪斯 HUD 文字，Vulkan 层按笔转储）：两个 vec4 (2/W, ±2/H, 0, 0)、(2/W, ±2/H, −W/2, ∓H/2)，
        /// 着色器按 (像素 + 偏移) × 缩放 把像素画布换到裁剪空间；W×H 是 16:9 一族的整数像素。同 IsUiOrtho 只登记不改写：读它、没读改写矩阵、
        /// 不采放宽贴图的绘制（字形）按界面层原尺寸居中，与读俯仰屏幕层判 Hor 的框体落在同一处（原先认不出，字形判 ScaleK 横向拉开、和框体错位）。</summary>
        public static bool IsUiCanvas(ReadOnlySpan<float> m)
        {
            if (m.Length < 8 || !MaybeUiCanvas(m)) return false;
            float W = 2 / m[0], H = 2 / MathF.Abs(m[1]);
            if (MathF.Abs(W - MathF.Round(W)) > 0.02f || MathF.Abs(H - MathF.Round(H)) > 0.02f) return false;
            int w = (int)MathF.Round(W), h = (int)MathF.Round(H);
            if (!Family(w, h) || !Near(W / H, SrcAspect, AspectTol)) return false;
            return m[2] == 0 && m[3] == 0 && Near(m[6], -W / 2, 1e-4f) && Near(m[7], -H / 2, 1e-4f);   // 偏移是画布中心的负值（y 向下用负缩放翻转，偏移不变号）
        }
        /// <summary>IsUiCanvas 的快筛：两个 vec4 前两格相同、缩放在像素画布的取值范围（2/16384 .. 2/16）。</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool MaybeUiCanvas(ReadOnlySpan<float> m) => m.Length >= 8 && m[0] >= 1.2e-4f && m[0] <= 0.125f && m[4] == m[0] && m[5] == m[1] && m[1] != 0;

        /// <summary>对称轴对齐的正交投影（w 行 = 0001，x / y 行只有对角元、平移为 0，z 行只有 (2,2) ≠ 0 与平移，|(1,1)| / (0,0) ≈ 16/9）：只记正交相机签名、本身不改写
        ///（保持原行为：10-21 丝之歌界面用这种投影，改写它会让界面移位，门禁中间区 517134 → 518382）。界面常用的带 −1 / +1 偏移的不对称正交、骨骼 / 世界矩阵都不在这里。</summary>
        void NoteSymOrtho(ReadOnlySpan<float> m)
        {
            for (int c = 0; c < 2; c++)
            {
                bool col = c == 1;
                Span<float> a = stackalloc float[16];
                for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) a[i * 4 + j] = col ? m[j * 4 + i] : m[i * 4 + j];
                if (Z(a[12]) && Z(a[13]) && Z(a[14]) && MathF.Abs(a[15] - 1) < 1e-4f && Z(a[1]) && Z(a[2]) && Z(a[3]) && Z(a[4]) && Z(a[6]) && Z(a[7])
                    && Z(a[8]) && Z(a[9]) && !Z(a[10]) && a[0] > 1e-6f && Near(MathF.Abs(a[5]) / a[0], SrcAspect, AspectTol))
                { NoteOrthoCamera(a[0], MathF.Abs(a[5])); return; }
            }
        }

        void NoteOrthoCamera(float x, float y)
        {
            for (int i = 0; i < _camN; i++) if (_camOrtho[i] && Near(_camX[i], x, 1e-5f) && Near(_camY[i], y, 1e-5f)) { _camSeen[i] = ++_camTick; return; }
            int n = CamSlot();
            _camX[n] = x; _camY[n] = y; _camA[n] = float.NaN; _camB[n] = float.NaN; _camOrtho[n] = true; _camSeen[n] = ++_camTick;
            _camC[n] = null; _camVer++;
        }

        /// <summary>正交 × 视图旋转（10-21 暗黑2 等距视角的世界）：w 行 = (0,0,0,1)、x 行不轴对齐、x / y / z 行两两正交，且 (|x 行|, |y 行|) = 某个已认出的正交投影的 (P00, |P11|)（相对 1e-4）——
        /// 同一台正交镜头只是多乘了视图旋转（行模不变）。不按形状单独认：带非均匀缩放的仿射（骨骼）也可能两两正交、比例 16:9。改写过的 |x| 变了，不再对上签名（幂等）。</summary>
        bool MatchOrtho(ReadOnlySpan<float> m, out bool col)
        {
            for (int c = 0; c < 2; c++)
            {
                col = c == 1;
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14];
                if (!Z(w0) || !Z(w1) || !Z(w2) || MathF.Abs(m[15] - 1) > 1e-4f) continue;
                float x0 = m[0], x1 = col ? m[4] : m[1], x2 = col ? m[8] : m[2], y0 = col ? m[1] : m[4], y1 = m[5], y2 = col ? m[9] : m[6], z0 = col ? m[2] : m[8], z1 = col ? m[6] : m[9], z2 = m[10];
                float nx = MathF.Sqrt(x0 * x0 + x1 * x1 + x2 * x2), ny = MathF.Sqrt(y0 * y0 + y1 * y1 + y2 * y2), nz = MathF.Sqrt(z0 * z0 + z1 * z1 + z2 * z2);
                if (!(nx > 1e-9f && nz > 1e-12f)) continue;
                // 要带视图旋转（x 行不轴对齐）：轴对齐的正交 × 平移是 2D 层（界面、2D 贴片），照旧按界面规则处理，不在这里放宽（10-21 丝之歌血量条用它，改写后界面移位、门禁中间区 517134 → 518382）
                if (MathF.Max(MathF.Abs(x0), MathF.Max(MathF.Abs(x1), MathF.Abs(x2))) > 0.999f * nx) continue;
                if (MathF.Abs(x0 * y0 + x1 * y1 + x2 * y2) > 2e-3f * nx * ny || MathF.Abs(x0 * z0 + x1 * z1 + x2 * z2) > 2e-3f * nx * nz || MathF.Abs(y0 * z0 + y1 * z1 + y2 * z2) > 2e-3f * ny * nz) continue;
                for (int i = 0; i < _camN; i++)
                    if (_camOrtho[i] && Near(nx, _camX[i], 1e-4f) && Near(ny, _camY[i], 1e-4f)) return true;
            }
            col = false; return false;
        }

        /// <summary>16:9 正交 × 绕 x 轴的俯仰（10-25 哈迪斯等距视角，Vulkan 层回放取的真实数值：世界相机行存 x = (0.0007925, 0, 0, −1.59)、y = (0, −0.000704, −0.00122, 7.18)、
        /// z = (0, −4.33e-6, 2.5e-6, 0.544)，屏幕层 x = (2/1920, 0, 0, −1)、y = (0, −0.000926, −0.0016, 1)）：游戏只上传 正交 × 俯仰，从不单独上传正交投影，MatchOrtho 等不到签名；
        /// 俯仰轴正是 x 轴，x 行仍轴对齐，又被「轴对齐 = 2D 层」挡掉。认法只看形状：w 行 = (0,0,0,1)，x 行轴对齐，y 行带 z 分量（俯仰，2D 层 / 界面的 y 行没有），
        /// x / y / z 行两两正交，(|y 行| / |x 行|) ≈ 16:9（哈迪斯 1.7776，按 m11 / m00 只看到 1.125 是俯仰把 y 行分到了 z 列），
        /// |z 行| ≤ 0.05·|x 行|（投影把深度压进 0..1；骨骼 / 世界矩阵三行同量级）。认出后记正交签名 (|x 行|, |y 行|)，同一镜头的逆投影 / 其他 正交 × 视图 随之能认。改写过的 x 行比例不再是 16:9（幂等）。</summary>
        bool MatchTiltOrtho(ReadOnlySpan<float> m, out bool col)
        {
            for (int c = 0; c < 2; c++)
            {
                col = c == 1;
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14];
                if (!Z(w0) || !Z(w1) || !Z(w2) || MathF.Abs(m[15] - 1) > 1e-4f) continue;
                float x0 = m[0], x1 = col ? m[4] : m[1], x2 = col ? m[8] : m[2], y0 = col ? m[1] : m[4], y1 = m[5], y2 = col ? m[9] : m[6], z0 = col ? m[2] : m[8], z1 = col ? m[6] : m[9], z2 = m[10];
                float nx = MathF.Abs(x0), ny = MathF.Sqrt(y0 * y0 + y1 * y1 + y2 * y2), nz = MathF.Sqrt(z0 * z0 + z1 * z1 + z2 * z2);
                if (!(nx > 1e-9f && nz > 1e-12f) || MathF.Abs(x1) > 1e-4f * nx || MathF.Abs(x2) > 1e-4f * nx) continue;
                if (MathF.Abs(y2) < 0.05f * ny || nz > 0.05f * nx || !Near(ny / nx, SrcAspect, AspectTol)) continue;
                if (MathF.Abs(x0 * y0) > 2e-3f * nx * ny || MathF.Abs(x0 * z0) > 2e-3f * nx * nz || MathF.Abs(y0 * z0 + y1 * z1 + y2 * z2) > 2e-3f * ny * nz) continue;
                NoteOrthoCamera(nx, ny);
                return true;
            }
            col = false; return false;
        }

        /// <summary>正交投影的逆（10-22 暗黑2 营地等距视角：光照遮罩按屏幕坐标 × 逆投影 x 缩放 c[17].x = 1/P00 重建视空间，逆投影没改 → 放宽后每盏灯的光斑横向拉宽 k 倍、
        /// 镜头一动光斑相对火把滑动）：w 行 = (0,0,0,1)，x / y / z 行只有对角元与平移，且 (1/x 对角, 1/|y 对角|) = 某个已认出的正交投影的 (P00, |P11|)（相对 1e-4）。
        /// 不按形状单独认：对角 16:9 的贴图变换很多（同一缓冲里就有 diag(0.025, 0.125, …)）。改写（x 行 × K）后 1/x 不再对上签名（幂等）。</summary>
        bool MatchInvOrtho(ReadOnlySpan<float> m, out bool col)
        {
            for (int c = 0; c < 2; c++)
            {
                col = c == 1;
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14];
                if (!Z(w0) || !Z(w1) || !Z(w2) || MathF.Abs(m[15] - 1) > 1e-4f) continue;
                float x0 = m[0], x1 = col ? m[4] : m[1], x2 = col ? m[8] : m[2], y0 = col ? m[1] : m[4], y1 = m[5], y2 = col ? m[9] : m[6], z0 = col ? m[2] : m[8], z1 = col ? m[6] : m[9], z2 = m[10];
                if (!Z(x1) || !Z(x2) || !Z(y0) || !Z(y2) || !Z(z0) || !Z(z1) || Z(z2) || !(x0 > 1e-6f) || Z(y1)) continue;
                float px = 1 / x0, py = 1 / MathF.Abs(y1);
                for (int i = 0; i < _camN; i++)
                    if (_camOrtho[i] && Near(px, _camX[i], 1e-4f) && Near(py, _camY[i], 1e-4f)) return true;
            }
            col = false; return false;
        }

        /// <summary>按已知相机的深度映射认世界·视图·投影（形状看不出 16:9 的：非均匀缩放的世界矩阵，x / y / w 行不两两正交）：w 行非零、x 行非零，z 行 xyz ≈ a·w 行 xyz（相对 1e-4），
        /// z₃ ≈ a·w₃ + b。行存、列存各判一次。只认已经由形状认出过的相机（同一镜头），阴影 / 其他镜头的投影深度参数不同，不认。</summary>
        bool MatchDepth(ReadOnlySpan<float> m, out bool col)
        {
            for (int c = 0; c < 2; c++)
            {
                col = c == 1;
                float z0 = col ? m[2] : m[8], z1 = col ? m[6] : m[9], z2 = m[10], z3 = col ? m[14] : m[11];
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14], w3 = m[15];
                float ww = w0 * w0 + w1 * w1 + w2 * w2, zz = z0 * z0 + z1 * z1 + z2 * z2;
                // 最便宜的必要条件先判：z 行 ∥ w 行（叉积 ≈ 0）。深度快筛放进来的多是单位向量类数据（a ≈ 1），绝大多数在这里就出去（10-21 马车8 采样：MatchDepth 占 Rewrite 8%、命中只有 15 个）
                float q0 = z1 * w2 - z2 * w1, q1 = z2 * w0 - z0 * w2, q2 = z0 * w1 - z1 * w0;
                if (!(ww > 1e-12f) || q0 * q0 + q1 * q1 + q2 * q2 > 1e-8f * zz * ww) continue;
                float x0 = m[0], x1 = col ? m[4] : m[1], x2 = col ? m[8] : m[2], xx = x0 * x0 + x1 * x1 + x2 * x2;
                if (!(xx > 1e-12f * ww)) continue;
                float y0 = col ? m[1] : m[4], y1 = m[5], y2 = col ? m[9] : m[6], yy = y0 * y0 + y1 * y1 + y2 * y2;
                float xw = x0 * w0 + x1 * w1 + x2 * w2, yw = y0 * w0 + y1 * w1 + y2 * w2, xy = x0 * y0 + x1 * y1 + x2 * y2;
                // 带缩放的世界·视图·投影都在这里认（形状判据只认 |w| ≈ 1）。相似形态（x / y / w 行两两正交，均匀缩放）另要 y / x 行模比 ≈ 16/9：改写过的是 2.17，不再命中（幂等）；
                // 非相似形态（非均匀缩放）从形状看不出改没改过：幂等靠数据流——改写结果只发给 GPU，从不回流再扫
                if (xw * xw < 4e-6f * xx * ww && yw * yw < 4e-6f * yy * ww && xy * xy < 4e-6f * xx * yy && !Near(MathF.Sqrt(yy / xx), SrcAspect, AspectTol)) continue;
                for (int i = 0; i < _camN; i++)
                {
                    float a = _camA[i], b = _camB[i];
                    if (float.IsNaN(a)) continue;
                    float e0 = z0 - a * w0, e1 = z1 - a * w1, e2 = z2 - a * w2;
                    if (e0 * e0 + e1 * e1 + e2 * e2 > 1e-8f * a * a * ww) continue;
                    if (MathF.Abs(z3 - (a * w3 + b)) > 2e-5f * (MathF.Abs(a * w3) + MathF.Abs(b)) + 1e-6f) continue;
                    if (!SameCamera(m, col, i)) continue;
                    return true;
                }
            }
            col = false; return false;
        }

        void SetCamC(int i, ReadOnlySpan<float> m, bool col)
        {
            double[] c = _camC[i] ??= new double[16];
            for (int r = 0; r < 4; r++) for (int k = 0; k < 4; k++) c[r * 4 + k] = col ? m[k * 4 + r] : m[r * 4 + k];
            _camCiOk[i] = false;
        }

        /// <summary>M（col 指明存法）是否 = 某个已认出镜头的视图投影 C × 不带剪切的世界矩阵：C⁻¹·M 末行 ≈ (0,0,0,1)、线性部分各列两两正交（相对 2e-3）。
        /// only ≥ 0：只比这一台镜头（深度映射已对上的那台）。</summary>
        bool SameCamera(ReadOnlySpan<float> m, bool col, int only)
        {
            Span<double> a = stackalloc double[16], w = stackalloc double[16];
            for (int r = 0; r < 4; r++) for (int k = 0; k < 4; k++) a[r * 4 + k] = col ? m[k * 4 + r] : m[r * 4 + k];
            for (int i = only >= 0 ? only : 0; i < (only >= 0 ? only + 1 : _camN); i++)
            {
                if (_camC[i] == null) continue;
                double[] ci = _camCi[i] ??= new double[16];
                if (!_camCiOk[i]) { if (!Inv4(_camC[i], ci)) continue; _camCiOk[i] = true; }
                for (int r = 0; r < 4; r++) for (int k = 0; k < 4; k++) { double acc = 0; for (int t = 0; t < 4; t++) acc += ci[r * 4 + t] * a[t * 4 + k]; w[r * 4 + k] = acc; }
                double n0 = Math.Sqrt(w[0] * w[0] + w[4] * w[4] + w[8] * w[8]), n1 = Math.Sqrt(w[1] * w[1] + w[5] * w[5] + w[9] * w[9]), n2 = Math.Sqrt(w[2] * w[2] + w[6] * w[6] + w[10] * w[10]);
                double sc = Math.Max(n0, Math.Max(n1, n2));
                if (!(n0 > 1e-9 * sc && n1 > 1e-9 * sc && n2 > 1e-9 * sc)) continue;
                if (Math.Abs(w[12]) > 2e-3 * sc || Math.Abs(w[13]) > 2e-3 * sc || Math.Abs(w[14]) > 2e-3 * sc || Math.Abs(w[15] - 1) > 2e-3) continue;
                double d01 = w[0] * w[1] + w[4] * w[5] + w[8] * w[9], d02 = w[0] * w[2] + w[4] * w[6] + w[8] * w[10], d12 = w[1] * w[2] + w[5] * w[6] + w[9] * w[10];
                if (Math.Abs(d01) > 2e-3 * n0 * n1 || Math.Abs(d02) > 2e-3 * n0 * n2 || Math.Abs(d12) > 2e-3 * n1 * n2) continue;
                return true;
            }
            return false;
        }

        /// <summary>4×4 求逆（行存，高斯消元选主元），写进 o；奇异返回 false。不分配。</summary>
        static bool Inv4(double[] a, double[] o)
        {
            Span<double> m = stackalloc double[32];   // [i*8 + j]：左 4 列 a、右 4 列单位阵
            for (int i = 0; i < 4; i++) { for (int j = 0; j < 4; j++) { m[i * 8 + j] = a[i * 4 + j]; m[i * 8 + 4 + j] = i == j ? 1 : 0; } }
            for (int c = 0; c < 4; c++)
            {
                int piv = c; for (int r = c + 1; r < 4; r++) if (Math.Abs(m[r * 8 + c]) > Math.Abs(m[piv * 8 + c])) piv = r;
                if (Math.Abs(m[piv * 8 + c]) < 1e-30) return false;
                if (piv != c) for (int j = 0; j < 8; j++) (m[c * 8 + j], m[piv * 8 + j]) = (m[piv * 8 + j], m[c * 8 + j]);
                double d = m[c * 8 + c]; for (int j = 0; j < 8; j++) m[c * 8 + j] /= d;
                for (int r = 0; r < 4; r++) if (r != c) { double f = m[r * 8 + c]; for (int j = 0; j < 8; j++) m[r * 8 + j] -= f * m[c * 8 + j]; }
            }
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) o[i * 4 + j] = m[i * 8 + 4 + j];
            return true;
        }

        /// <summary>形状认出的匹配要不要记签名 / 能不能改：|w| ≈ 1 的（纯视图投影、投影、逆投影）照旧记签名；带缩放的视图投影（|w| ≠ 1）不记、必须过 SameCamera。</summary>
        bool AcceptShape(ReadOnlySpan<float> m, WidenKind kind, bool col)
        {
            if (kind != WidenKind.ViewProjection) { NoteCamera(m, kind, col); return true; }
            float c0 = col ? m[3] : m[12], c1 = col ? m[7] : m[13], c2 = col ? m[11] : m[14], nw = c0 * c0 + c1 * c1 + c2 * c2;
            if (MathF.Abs(nw - 1) < 0.02f) { NoteCamera(m, kind, col); return true; }
            return SameCamera(m, col, -1);
        }

        /// <summary>MatchDepth 的快筛（必要条件）：行存 / 列存 |z 行|² ∈ a²·|w 行|²·(1 ± 4e-4)（某个已知相机）。区间按相机签名版本预先备好（PrepareDepthFilter），
        /// 先过总范围一道再逐个比；不用除法。每个 16 字节窗口都要过一次，是整段扫描的热点（10-21 逐个现算 a²：马车8 每帧 +0.23 ms）。</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        bool MaybeDepth(float rz, float rw, float cz, float cw, float rz3, float cz3)
        {
            if (_dN > 0 && (rw > 1e-12f && rz >= _dMin * rw && rz <= _dMax * rw && InDepth(rz, rw) || cw > 1e-12f && cz >= _dMin * cw && cz <= _dMax * cw && InDepth(cz, cw))) return true;
            // a = 0 的相机（无限远反向 Z：z 行 = (0, 0, 0, b)，深度只由 w 定）：z 行 xyz ≈ 0 且 z₃² ≈ b²。只看 xyz ≈ 0 放进来的窗口太多（稀疏数据），z₃ 要对上相机的 b
            return _z0N > 0 && (rw > 1e-12f && rz <= 1e-12f * rw && InZ0(rz3) || cw > 1e-12f && cz <= 1e-12f * cw && InZ0(cz3));
        }
        bool InZ0(float z3)
        {
            for (int i = 0; i < _z0N; i++) if (z3 >= _z0Lo[i] && z3 <= _z0Hi[i]) return true;
            return false;
        }
        readonly float[] _z0Lo = new float[MaxCams], _z0Hi = new float[MaxCams]; int _z0N;
        bool InDepth(float z, float w)
        {
            for (int i = 0; i < _dN; i++) if (z >= _dLo[i] * w && z <= _dHi[i] * w) return true;
            return false;
        }
        readonly float[] _dLo = new float[MaxCams], _dHi = new float[MaxCams]; int _dN, _orthoN; float _dMin, _dMax; long _dVer = -1;
        /// <summary>按当前相机签名备好深度快筛区间（签名只在判矩阵时增加：整段扫描 / 逐窗口判之前调）。</summary>
        void PrepareDepthFilter()
        {
            if (_dVer == _camVer) return;
            _dVer = _camVer; _dN = 0; _z0N = 0; _dMin = float.MaxValue; _dMax = float.MinValue;
            _orthoN = 0; for (int i = 0; i < _camN; i++) if (_camOrtho[i]) _orthoN++;
            for (int i = 0; i < _camN; i++)
            {
                float a2 = _camA[i] * _camA[i];
                // a = 0（无限远反向 Z）：|z 行|² ≈ a²·|w 行|² 的区间退化成 0，另按 z₃ ≈ b 筛（10-22 暗黑2 人物界面：场景 140 次绘制的视图投影 z 行 (0,0,0,0.1)，一直没认出、整场景按 k 拉伸）
                if (a2 == 0 && _camB[i] != 0 && !float.IsNaN(_camB[i])) { float b2 = _camB[i] * _camB[i]; _z0Lo[_z0N] = b2 * (1 - 4e-4f); _z0Hi[_z0N] = b2 * (1 + 4e-4f); _z0N++; continue; }
                if (!(a2 > 0)) continue;
                _dLo[_dN] = a2 * (1 - 4e-4f); _dHi[_dN] = a2 * (1 + 4e-4f); _dMin = MathF.Min(_dMin, _dLo[_dN]); _dMax = MathF.Max(_dMax, _dHi[_dN]); _dN++;
            }
        }

        /// <summary>记相机签名 (P00, |P11|)（矩阵改写前的原值）。</summary>
        void NoteCamera(ReadOnlySpan<float> m, WidenKind kind, bool col)
        {
            float x, y;
            if (kind == WidenKind.Projection) { x = m[0]; y = MathF.Abs(m[5]); }
            else if (kind == WidenKind.InverseProjection) { x = 1 / m[0]; y = 1 / MathF.Abs(m[5]); }
            else
            {
                // 按 w 行模长归一：带均匀缩放的世界·视图·投影与纯视图投影是同一个相机签名
                float a0 = m[0], a1 = col ? m[4] : m[1], a2 = col ? m[8] : m[2], b0 = col ? m[1] : m[4], b1 = m[5], b2 = col ? m[9] : m[6];
                float c0 = col ? m[3] : m[12], c1 = col ? m[7] : m[13], c2 = col ? m[11] : m[14], nw = MathF.Sqrt(c0 * c0 + c1 * c1 + c2 * c2);
                x = MathF.Sqrt(a0 * a0 + a1 * a1 + a2 * a2) / nw; y = MathF.Sqrt(b0 * b0 + b1 * b1 + b2 * b2) / nw;
            }
            float da = float.NaN, db = float.NaN, dtol = 0;
            if (kind != WidenKind.InverseProjection)
            {
                float z0 = col ? m[2] : m[8], z1 = col ? m[6] : m[9], z2 = col ? m[10] : m[10], z3 = col ? m[14] : m[11];
                float w0 = col ? m[3] : m[12], w1 = col ? m[7] : m[13], w2 = col ? m[11] : m[14], w3 = m[15];
                float ww = w0 * w0 + w1 * w1 + w2 * w2;
                // b = z₃ − a·w₃：w₃ 带着物体平移（暗黑3 上百），浮点误差随 |a·w₃| 放大；去重容差与 MatchDepth 同一尺度，不然同一镜头被记成多个签名、挤掉别的镜头、签名版本频繁变触发整段重扫
                if (ww > 1e-12f) { da = (z0 * w0 + z1 * w1 + z2 * w2) / ww; db = z3 - da * w3; dtol = 2e-5f * (MathF.Abs(da * w3) + MathF.Abs(db)) + 1e-6f; }
            }
            for (int i = 0; i < _camN; i++)
                if (!_camOrtho[i] && Near(_camX[i], x, 1e-5f) && Near(_camY[i], y, 1e-5f) && (float.IsNaN(da) ? float.IsNaN(_camA[i]) : Near(_camA[i], da, 1e-5f) && MathF.Abs(_camB[i] - db) <= dtol))
                { _camSeen[i] = ++_camTick; if (kind != WidenKind.InverseProjection) SetCamC(i, m, col); return; }
            int s0 = CamSlot();
            _camX[s0] = x; _camY[s0] = y; _camA[s0] = da; _camB[s0] = db; _camVer++; _camSeen[s0] = ++_camTick;
            _camOrtho[s0] = false;
            if (kind != WidenKind.InverseProjection) SetCamC(s0, m, col); else { _camC[s0] = null; _camCi[s0] = null; }
        }

        bool CameraPair(float a, float b, out bool inverse)
        {
            inverse = false;
            if (!(a > 0)) return false;
            b = MathF.Abs(b);
            for (int i = 0; i < _camN; i++)
            {
                if (_camOrtho[i]) continue;
                if (Near(a, 1 / _camX[i], 2e-4f) && Near(b, 1 / _camY[i], 2e-4f)) { inverse = true; return true; }
                if (Near(a, _camX[i], 2e-4f) && Near(b, _camY[i], 2e-4f)) return true;
            }
            return false;
        }

        // ---------- 像素射线基（10-22 巫师3 光照累积：中间区与 k=1 差 67%、放宽目标右侧 1280 列以外整条没光） ----------
        // 游戏把「像素 → 世界射线」存成常量：每像素横 / 纵步长 A、B（世界方向，|A| = 2·tanX / W、|B| = 2·tanY / H）和左上像素的射线 C（视深 1），
        // 片元里按 射线 = C + x·A + y·B 重建世界位置（x、y 是片元坐标）。放宽目标上真实像素 x' 的射线 = C + (x' − pad)·A（pad = (放宽宽 − W) / 2，纵向视角不变、横向按 k 扩视野，
        // 每像素步长不变）。片元按客体坐标画（x = x'/k，render_scale[0] = k）的程序要 C' + x·(k·A)：C' = C − pad·A、A' = k·A（各登记一条命中：PixelRay / PixelStep）；
        // 按真实像素坐标画的（片元坐标即 x'，计算着色器）要 C' 与原 A——A 那条对它们写回原值（WidenFrame.NeedsOriginal）。B 不改。
        // 认法：A、B 是相邻两行（w ≈ 0）、等长、正交；某个已认出的透视镜头反解出 W = 2 / (P00·|A|)、H = 2 / (|P11|·|B|) 都接近整数、属 16:9 一族（射线不在视深 1 的反解不出整数，不认）；
        // C 在 A 前两行到后四行里：C·A / |A|² ≈ −W/2（±3%：前向与 A、B 不严格正交，巫师3 差 6 像素）、|C|² ≈ 1 + tanX² + tanY²（±5%）。

        /// <summary>行 a、b（各 4 个浮点）是不是某个透视镜头的像素步长对；是则给出画布宽高（整数）与该镜头 tanX、tanY。</summary>
        public bool RayBasis(ReadOnlySpan<float> a, ReadOnlySpan<float> b, out int w, out int h, out float tanX, out float tanY)
        {
            w = h = 0; tanX = tanY = 0;
            if (!On || _camN == 0) return false;
            float la = a[0] * a[0] + a[1] * a[1] + a[2] * a[2], lb = b[0] * b[0] + b[1] * b[1] + b[2] * b[2];
            if (!(la > 1e-10f && la < 0.1f) || a[3] * a[3] > 1e-8f * la || b[3] * b[3] > 1e-8f * la || MathF.Abs(la - lb) > 4e-3f * la) return false;
            float ab = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
            if (ab * ab > 4e-6f * la * lb) return false;
            float na = MathF.Sqrt(la), nb = MathF.Sqrt(lb);
            for (int i = 0; i < _camN; i++)
            {
                if (_camOrtho[i] || !(_camX[i] > 0) || !(_camY[i] > 0)) continue;
                float fw = 2 / (_camX[i] * na), fh = 2 / (_camY[i] * nb);
                int iw = (int)MathF.Round(fw), ih = (int)MathF.Round(fh);
                if (MathF.Abs(fw - iw) > 0.25f || MathF.Abs(fh - ih) > 0.25f || iw < 64 || iw > 4096 || !Family(iw, ih)) continue;
                w = iw; h = ih; tanX = 1 / _camX[i]; tanY = 1 / _camY[i]; return true;
            }
            return false;
        }

        /// <summary>步长行 a 按客体坐标用时的改写：xyz × K（w 不动）并计数。</summary>
        public void RewriteRayStep(ReadOnlySpan<float> a, Span<float> dst)
        {
            for (int j = 0; j < 3; j++) dst[j] = a[j] * K;
            dst[3] = a[3];
            Count(WidenKind.PixelStep, false);
        }

        /// <summary>行 c 是不是步长 a（画布 w 宽、镜头 tanX、tanY，RayBasis 给出）对应的左上像素射线；是则 dst = 改写后的 c（xyz 减 pad·a，w 不动）并计数。</summary>
        public bool RewriteRayOrigin(ReadOnlySpan<float> a, ReadOnlySpan<float> c, int w, int h, float tanX, float tanY, Span<float> dst)
        {
            float la = a[0] * a[0] + a[1] * a[1] + a[2] * a[2];
            float u = (c[0] * a[0] + c[1] * a[1] + c[2] * a[2]) / la, lc = c[0] * c[0] + c[1] * c[1] + c[2] * c[2], want = 1 + tanX * tanX + tanY * tanY;
            if (!(MathF.Abs(u + w * 0.5f) <= 0.03f * w) || !(MathF.Abs(lc - want) <= 0.05f * want) || !float.IsFinite(c[3])) return false;
            float pad = (WidenWidth(w, h) - w) * 0.5f;
            for (int j = 0; j < 3; j++) dst[j] = c[j] - pad * a[j];
            dst[3] = c[3];
            Count(WidenKind.PixelRay, false);
            return true;
        }

        // 纯 2D 款（10-31 jhz 发现普查款两侧 213 黑带：植物大战僵尸重植版、Slay the Spire）：世界镜头就是像素正交（2/1280、2/720），与界面正交分不开，
        //   整局按界面层原宽居中、两侧黑。最近 Scene2DFrames 次上屏内没出现过场景镜头（投影 / 视图投影 / 逆投影 / 相机系数对 / 像素射线）时，
        //   像素正交（矩阵形式）按场景镜头改写（Hor+）：游戏画在 16:9 画布外的内容露出来（植物大战僵尸标题背景层本就比画布宽），界面仍按原尺寸居中（Hor 平移）。
        //   3D 款每帧上传镜头，界面正交照旧只登记不改；按时间窗而不是「整局见过」：植物大战僵尸开机只有 5 次镜头命中，之后 18 万段像素正交（直连实局）。
        //   画布形式（缩放 / 偏移对，32 字节）不改：ScaleX 只认 4×4 矩阵
        public const int Scene2DFrames = 60;
        long _frames, _camFrame = long.MinValue / 2;
        /// <summary>上屏一次（WidenFrame.OnPresent 调）：纯 2D 判定的时间窗按上屏数算。</summary>
        public void EndFrame() => _frames++;
        bool SawCamera => _frames - _camFrame <= Scene2DFrames;
        /// <summary>原比例回退（11-01，会话按两侧覆盖反馈设，见 WidenSession.SideCoverage）：纯 2D 帧的像素正交不再按场景改写、界面照原尺寸居中 = 整帧 16:9 居中。
        /// Hor+ 露出的是游戏画在画布外的内容，游戏没画到的一侧就成了黑（忍者龟标题页：插画 / 天空只向右伸出画布，左侧 356 列黑）；jhz 口径「不支持的原比例完美运行」</summary>
        public bool Pure2DOff;
        long _p2Frame = long.MinValue / 2;
        /// <summary>最近 Scene2DFrames 次上屏内有纯 2D 帧（像素正交按场景改写了，或回退中本该改写）。窗口同场景镜头：改写结果按段缓存复用、不是每帧都走到这里（忍者龟实局按 1 帧判几乎总是假）</summary>
        public bool Pure2DRecent => _frames - _p2Frame <= Scene2DFrames;
        WidenKind Scene2D(WidenKind kind, bool canvasForm)
        {
            if (kind != WidenKind.UiOrtho) { if (kind <= WidenKind.InverseProjection) _camFrame = _frames; return kind; }
            if (SawCamera || canvasForm) return kind;
            _p2Frame = _frames;
            if (Pure2DOff) return kind;
            Stats.Ortho2D++; return WidenKind.ViewProjection;
        }
        void Count(WidenKind k, bool col)
        {
            if (k is WidenKind.CameraPair or WidenKind.PixelRay or WidenKind.PixelStep) _camFrame = _frames;
            switch (k)
            {
                case WidenKind.Projection: Stats.Projection++; break;
                case WidenKind.ViewProjection: Stats.ViewProjection++; break;
                case WidenKind.InverseProjection: Stats.InverseProjection++; break;
                case WidenKind.AspectPair: Stats.AspectPair++; break;
                case WidenKind.CameraPair: Stats.CameraPair++; break;
                case WidenKind.UiOrtho: Stats.UiOrtho++; break;
                case WidenKind.UiOrthoWide: Stats.UiOrthoWide++; break;
                case WidenKind.PixelRay: Stats.PixelRay++; break;
                case WidenKind.PixelStep: Stats.PixelStep++; break;
                case WidenKind.WideProjection: Stats.WideProjection++; break;
                default: Stats.ScreenSize++; break;
            }
            if (col) Stats.ColumnMajor++;
        }

        /// <summary>行存 / 列存各判一次：一边是结构更严的投影 / 逆投影、另一边只是视图投影时取前者——纯透视投影转置后按行读，w 行 = (0, 0, P32)、模长 ≠ 1，
        /// 也满足（允许均匀缩放的）视图投影判据（10-21 起）；以前 |w| ≈ 1 把它挡在外面，行存优先不出错。</summary>
        /// <summary>游戏自己已按屏幕比算的镜头（WideProjection，只登记）：屏幕比与 16:9 差出容差两倍以上才判（屏幕就是 16:9 时与改写的镜头分不开）。
        ///   逆投影不算（拉伸风险只看画 3D 的投影 / 视图投影）。</summary>
        bool MatchWide(ReadOnlySpan<float> m, out bool col)
        {
            col = false;
            if (MathF.Abs(Aspect / SrcAspect - 1) < 2 * AspectTol) return false;
            Span<float> a = stackalloc float[16];
            for (int c = 0; c < 2; c++)
            {
                for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) a[i * 4 + j] = c == 1 ? m[j * 4 + i] : m[i * 4 + j];
                if (MatchRowsAt(a, Aspect, out WidenKind k) && k != WidenKind.InverseProjection) { col = c == 1; return true; }
            }
            return false;
        }
        static bool MatchEither(ReadOnlySpan<float> m, out WidenKind kind, out bool col)
        {
            bool r = Match(m, false, out WidenKind kr), c = Match(m, true, out WidenKind kc);
            if (r && (kr != WidenKind.ViewProjection || !c || kc == WidenKind.ViewProjection)) { kind = kr; col = false; return true; }
            kind = kc; col = true; return c;
        }

        /// <summary>按数学形状判 4×4 矩阵种类。col = 列存（元素 (i,j) 在 m[j*4+i]）。</summary>
        public static bool Match(ReadOnlySpan<float> m, bool col, out WidenKind kind)
        {
            kind = default;
            Span<float> a = stackalloc float[16];   // 统一成行存：a[i*4+j] = 元素 (i,j)
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) a[i * 4 + j] = col ? m[j * 4 + i] : m[i * 4 + j];
            return MatchRows(a, out kind);
        }

        static bool MatchRows(ReadOnlySpan<float> a, out WidenKind kind) => MatchRowsAt(a, SrcAspect, out kind);
        /// <summary>同 MatchRows，宽高比按 aspect 判（P11 / P00 或视图投影 |y| / |x| ≈ aspect）：SrcAspect 认 16:9 的镜头（要改写），屏幕比认游戏自己已放宽的镜头（WideProjection）。</summary>
        static bool MatchRowsAt(ReadOnlySpan<float> a, float aspect, out WidenKind kind)
        {
            kind = default;
            // 透视投影
            if (Z(a[12]) && Z(a[13]) && Z(a[15]) && MathF.Abs(MathF.Abs(a[14]) - 1) < 1e-4f
                && Z(a[1]) && Z(a[3]) && Z(a[4]) && Z(a[7])
                && a[0] > 1e-4f && Near(MathF.Abs(a[5]) / a[0], aspect, AspectTol))
            { kind = WidenKind.Projection; return true; }
            // 逆投影
            if (a[0] > 1e-4f && Z(a[1]) && Z(a[2]) && Z(a[3]) && Z(a[4]) && Z(a[6]) && Z(a[7])
                && Z(a[8]) && Z(a[9]) && Z(a[10]) && MathF.Abs(MathF.Abs(a[11]) - 1) < 1e-4f
                && Near(a[0] / MathF.Abs(a[5]), aspect, AspectTol))
            { kind = WidenKind.InverseProjection; return true; }
            // 视图投影：x / y / w 行的 xyz 三分量
            // 透视的 z 行 xyz 与 w 行 xyz 平行（都是视线方向）：排除「窗口跨两个矩阵、零多」造成的假形状
            float x0 = a[0], x1 = a[1], x2 = a[2], y0 = a[4], y1 = a[5], y2 = a[6], z0 = a[8], z1 = a[9], z2 = a[10], w0 = a[12], w1 = a[13], w2 = a[14];
            float nx = MathF.Sqrt(x0 * x0 + x1 * x1 + x2 * x2), ny = MathF.Sqrt(y0 * y0 + y1 * y1 + y2 * y2), nz = MathF.Sqrt(z0 * z0 + z1 * z1 + z2 * z2), nw = MathF.Sqrt(w0 * w0 + w1 * w1 + w2 * w2);
            float cx = z1 * w2 - z2 * w1, cy = z2 * w0 - z0 * w2, cz = z0 * w1 - z1 * w0;
            // w 行模长：纯视图投影 = 1（视线方向单位向量）；带均匀缩放 s 的世界·视图·投影四行同乘 s（10-21 暗黑3 角色 s = 1.35：旧判据要求 |w| ≈ 1，
            // 角色一律没改写 → 按 16:9 投影画在宽目标上横向拉 k 倍、偏离自己的阴影，镜头一动就在阴影上滑）。比值 / 正交 / 平行都与 s 无关，只按 |w| 归一；
            // 正交投影 w 行 ≈ 0、非透视的普通矩阵 y/x 比不是 16:9，仍排除
            if (nx > 1e-3f * nw && nz > 1e-6f * nw && MathF.Abs(nw - 1) < 0.01f && Near(ny / nx, aspect, AspectTol)
                && MathF.Sqrt(cx * cx + cy * cy + cz * cz) < 2e-3f * nz * nw
                && MathF.Abs(x0 * y0 + x1 * y1 + x2 * y2) < 2e-3f * nx * ny
                && MathF.Abs(x0 * w0 + x1 * w1 + x2 * w2) < 2e-3f * nx * nw
                && MathF.Abs(y0 * w0 + y1 * w1 + y2 * w2) < 2e-3f * ny * nw)
            { kind = WidenKind.ViewProjection; return true; }
            return false;
        }

        /// <summary>屏幕尺寸 vec4 三种排列：order 0 = (宽, 高, 1/宽, 1/高)，1 = (1/宽, 1/高, 宽, 高)，2 = 原点在 (0,0) 的矩形 (0, 0, 宽, 高)。
        /// 宽高都要是 16:9 一族的整数像素。矩形写法：计算着色器按它判线程越界（10-22 八方2 镇上：半分辨率 640×360 放宽成 782×360、派发已补到 98 组，
        /// 着色器 `x &lt; 矩形.宽` 才写，宽 640 没改 → 右边 142 列从没人写，后面按块取深度 / 合成用到这片 0，镇上场景右侧约 20% 隔帧被盖黑）。</summary>
        /// <summary>整数最大像素坐标矩形 (宽 − 1, 高 − 1, 0, 0)（四个 32 位整数，16 字节对齐）：计算着色器按它夹紧整数取图坐标
        /// （10-23 八方2 走动右侧拉丝：时域抗锯齿 131 取半分辨率颜色 191 时 x = max(min(px, c4[2].x), c4[1].x)，c4[2] = (447, 251, 0, 0)，
        /// 191 放宽成 548、派发补到放宽宽度后右侧 100 列都取第 447 列，乒乓历史逐帧累积成整片横向拉丝，再被景深散点读进散景层）。
        /// 宽 − 1 ≥ 127、(宽, 高) 是 16:9 一族；后两格必须是 0（排除恰好落在这个范围的别的整数数据）。改写：x = 放宽宽 − 1，其余不动。
        /// 坐标空间沿用这份常量：客体 CBUF 不叠加宿主分辨率倍率；实际像素矩形按其自身宽高取整，不能先放宽最大坐标再加一。</summary>
        static bool IntMaxRect(ReadOnlySpan<float> v, out int w, out int h)
        {
            ReadOnlySpan<int> i = MemoryMarshal.Cast<float, int>(v);
            w = i[0] + 1; h = i[1] + 1;
            return IntMaxLead(v[0]) && i[1] >= 63 && i[1] < 16384 && i[2] == 0 && i[3] == 0 && Family(w, h);
        }
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static bool IntMaxLead(float f) { int b = BitConverter.SingleToInt32Bits(f); return b >= 127 && b < 16384; }

        static bool ScreenSize(ReadOnlySpan<float> v, out int order, out int w, out int h)
        {
            order = 0; w = h = 0;
            if (v[0] == 0 && v[1] == 0 && v[2] >= 16 && v[3] >= 8 && v[2] <= 16384 && v[2] == MathF.Floor(v[2]) && v[3] == MathF.Floor(v[3]) && Family((int)v[2], (int)v[3]))
            { order = 2; w = (int)v[2]; h = (int)v[3]; return true; }
            for (int o = 0; o < 2; o++)
            {
                float W = o == 0 ? v[0] : v[2], H = o == 0 ? v[1] : v[3], iW = o == 0 ? v[2] : v[0], iH = o == 0 ? v[3] : v[1];
                if (W < 16 || H < 8 || W > 16384 || W != MathF.Floor(W) || H != MathF.Floor(H)) continue;
                if (!Family((int)W, (int)H) || !Near(iW * W, 1, 1e-4f) || !Near(iH * H, 1, 1e-4f)) continue;
                order = o; w = (int)W; h = (int)H; return true;
            }
            return false;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool Z(float v) => MathF.Abs(v) < ZeroTol;

        /// <summary>x 行（列存时是每列第 0 个）乘 s。判定当零（Z）的元素原样不动：零乘 s 还是零，而窗口可能跨到矩阵后面的别的数据——
        /// 10-22 暗黑2 人物界面：3 行投影后紧跟光照分块参数（整数 32 = 横向格数，按浮点读是 4.5e-44 ≈ 0，凑成「第 4 列」），乘 1/k 变成 26，
        /// 光照剔除只铺 26 格；这块参数只在前面恰好是投影的帧被改（回放第 8 帧改、第 9 帧不改）→ 光照遮罩逐帧变、画面闪。</summary>
        static void ScaleX(Span<float> w, bool col, float s)
        {
            for (int j = 0; j < 4; j++) { ref float e = ref w[col ? j * 4 : j]; if (!Z(e)) e *= s; }
        }
        /// <summary>y 行（列存时是每列第 1 个）乘 s：窄屏上下多画（Ky）时投影的纵向同 ScaleX 的横向，零元素同样不动。</summary>
        static void ScaleY(Span<float> w, bool col, float s)
        {
            for (int j = 0; j < 4; j++) { ref float e = ref w[col ? j * 4 + 1 : 4 + j]; if (!Z(e)) e *= s; }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool Near(float a, float b, float tol) => MathF.Abs(a - b) <= tol * MathF.Max(MathF.Abs(b), 1e-6f);

        /// <summary>快筛（只排除一定不是投影 / 逆投影 / 视图投影的窗口，结果与不筛逐位相同）。行存、列存各判一次（列存按转置取元素），满足任一种的必要条件才进 Match：
        /// 透视投影 (3,0)(3,1) ≈ 0、|(3,2)| ≈ 1、|(1,1)|/(0,0) ≈ 16/9；视图投影 w 行 xyz 模方 ∈ (0.979, 1.021)（|模 − 1| &lt; 0.01）、y 行与 x 行 xyz 模方比 ≈ (16/9)²（1% 容差平方后放宽到 ±2.2%）、
        /// x 行模 &gt; 1e-3、x / y 行与 w 行近正交；逆投影 |(2,3)| ≈ 1、(2,0)(2,1)(2,2) ≈ 0、(0,0)/|(1,1)| ≈ 16/9。容差都比 MatchRows 宽；NaN 比较为假，同 AllFinite 一样跳过。</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        /// <summary>游戏自己的宽镜头的形状快筛（屏幕比与 16:9 分得开时才做，见 MatchWide）。</summary>
        bool MaybeWide(ReadOnlySpan<float> m) => MathF.Abs(Aspect / SrcAspect - 1) >= 2 * AspectTol
            && (MaybeRowsAt(Aspect, m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[11], m[12], m[13], m[14])
                || MaybeRowsAt(Aspect, m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10], m[14], m[3], m[7], m[11]));
        static bool MaybeMatrix(ReadOnlySpan<float> m) =>
            MaybeRows(m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[11], m[12], m[13], m[14])
            || MaybeRows(m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10], m[14], m[3], m[7], m[11]);

        /// <summary>按行存元素 a(i,j) 判：x0..x2 = (0,0..2)，y0..y2 = (1,0..2)，z0..z2 = (2,0..2)，z3 = (2,3)，w0..w2 = (3,0..2)。</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool MaybeRows(float x0, float x1, float x2, float y0, float y1, float y2, float z0, float z1, float z2, float z3, float w0, float w1, float w2)
            => MaybeRowsAt(SrcAspect, x0, x1, x2, y0, y1, y2, z0, z1, z2, z3, w0, w1, w2);
        /// <summary>同 MaybeRows，宽高比按 aspect（游戏自己的宽镜头 WideProjection 用屏幕比）。</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool MaybeRowsAt(float SrcAspect, float x0, float x1, float x2, float y0, float y1, float y2, float z0, float z1, float z2, float z3, float w0, float w1, float w2)
        {
            float S2 = SrcAspect * SrcAspect;
            // 透视投影：另要 (0,0) > 1e-4、|(1,1)| / (0,0) ≈ 16/9（1% 放宽到 ±2%）
            if (MathF.Abs(MathF.Abs(w2) - 1) < 2e-4f && MathF.Abs(w0) < 1e-5f && MathF.Abs(w1) < 1e-5f
                && x0 > 1e-4f && MathF.Abs(y1) >= x0 * SrcAspect * 0.98f && MathF.Abs(y1) <= x0 * SrcAspect * 1.02f) return true;
            float nw = w0 * w0 + w1 * w1 + w2 * w2;
            if (MathF.Abs(nw - 1) < 0.021f)
            {
                // 视图投影（|w| ≈ 1；带缩放的走深度路径 MatchDepth）：另要 x / y 行与 w 行近正交（|x·w| &lt; 2e-3·|x|·|w|，平方后 4e-6 放宽到 5e-6）
                float nx = x0 * x0 + x1 * x1 + x2 * x2, ny = y0 * y0 + y1 * y1 + y2 * y2, xw = x0 * w0 + x1 * w1 + x2 * w2, yw = y0 * w0 + y1 * w1 + y2 * w2;
                if (nx > 1e-6f && ny >= nx * S2 * 0.978f && ny <= nx * S2 * 1.022f && xw * xw < 5e-6f * nx * nw && yw * yw < 5e-6f * ny * nw) return true;
            }
            // 正交投影（对称轴对齐）：w 行 xyz ≈ 0、(0,0) > 1e-6、|(1,1)| / (0,0) ≈ 16/9（其余由 MatchRows 判）
            if (nw < 3e-10f && x0 > 1e-6f && MathF.Abs(y1) >= x0 * SrcAspect * 0.98f && MathF.Abs(y1) <= x0 * SrcAspect * 1.02f) return true;
            // 逆投影：另要 (0,0) > 1e-4、(0,0) / |(1,1)| ≈ 16/9
            return MathF.Abs(MathF.Abs(z3) - 1) < 2e-4f && MathF.Abs(z0) < 1e-5f && MathF.Abs(z1) < 1e-5f && MathF.Abs(z2) < 1e-5f
                && x0 > 1e-4f && x0 >= MathF.Abs(y1) * SrcAspect * 0.98f && x0 <= MathF.Abs(y1) * SrcAspect * 1.02f;
        }

        [ThreadStatic] static float[] t_s3, t_l2, t_l3;   // 每 16 字节块的平方和（线程内复用，稳态零分配）

        static void Squares(ReadOnlySpan<float> fs, int nb)
        {
            if (t_s3 == null || t_s3.Length < nb) { int n = Math.Max(nb, 16384); t_s3 = new float[n]; t_l2 = new float[n]; t_l3 = new float[n]; }
            float[] s3 = t_s3, l2 = t_l2, l3 = t_l3;
            for (int i = 0; i < nb; i++)
            {
                Vector128<float> v = Vector128.Create(fs.Slice(i << 2, 4)), q = v * v;
                float a = q.GetElement(0), b = q.GetElement(1), c = q.GetElement(2), d = q.GetElement(3);
                s3[i] = a + b + c; l2[i] = c; l3[i] = d;
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static bool InAny(float a, ReadOnlySpan<float> lo, ReadOnlySpan<float> hi)
        {
            for (int i = 0; i < lo.Length; i++) if (a >= lo[i] && a <= hi[i]) return true;
            return false;
        }

        static bool AllFinite(ReadOnlySpan<float> m)
        {
            for (int i = 0; i < m.Length; i++) if (!float.IsFinite(m[i])) return false;
            return true;
        }
    }
}
