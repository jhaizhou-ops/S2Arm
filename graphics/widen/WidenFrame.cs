// 通用宽屏 · 逐帧状态：放宽贴图登记、常量改写区间（带原值）登记、界面层（HUD）判定、视口 / 裁剪换算。不依赖 Ryujinx，对象用整数号表示。
//
// 视口规则：画到放宽目标上的绘制，视口 / 裁剪横向乘 k（场景、全屏合成、上屏拷贝都是这样，配合投影改写即 Hor+）。
// 界面层（规则 A，马车8 三帧 84/84 判对、误判 0）：颜色目标 0 = 最终输出贴图 T_out，且不是本帧对 T_out 的第一次绘制（第一次是色调映射全屏合成）。
//   · 着色器读到了被改写的矩阵 → 按 Hor 处理（与场景同）：投影 x 已乘 1/k，视口中心平移、宽度乘 k，两者抵消 = 原尺寸、平移到居中位置；
//   · 没读到 → 视口保持原宽、横向居中（直接画在 16:9 中间，不拉伸）。
// T_out：上一帧上屏前最后一次画到上屏贴图的绘制所采样的、属放宽一族的贴图；上屏贴图本身被直接画（无拷贝）时 T_out = 上屏贴图。
// 原生宽目标（游戏自己按屏幕宽高比出图，宽屏第一 / 二层生效时）：宽高比 ≈ 屏幕比的目标登记为「原生宽」，不放宽、不改视口；
//   界面层读的仍是 16:9 投影 → 改写器照样把 x 乘 1/k，在全宽视口下画 = 原尺寸居中；没读到改写矩阵的界面层视口收进中间 16:9。
// 非放宽目标读到改写区间（动森：界面库用 16:9 界面投影往 600×300 离屏界面贴图上画）：就地写回原值，回到放宽目标时再写回改写值，
//   每个区间每通道最多一次。写回经 IBufferPatcher，要求与绘制同序生效（与 SetBufferData 相同语义）。
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;

namespace S2Arm.Gfx.Widen
{
    public enum DrawClass : byte { NotWide, Scene, FirstToOut, Hud }
    /// <summary>Keep：目标没放宽。ScaleK：2D / 全屏通道（裁剪空间没改），视口 / 裁剪按 k 缩放。
    /// Hor：读了改写投影的绘制——客体像素 x 落在加宽图 x + 居中偏移（平移，不是缩放），视口「中心平移 + 宽度乘 k」、裁剪框平移（覆盖全宽的仍铺满）。
    /// CenterNative：没读改写矩阵的界面层，视口 / 裁剪原宽平移居中。
    /// Page：16:9 原比例页（见 BeginPage）——这张目标本帧余下的绘制按 16:9 原样画（常量写回原值、视口 / 裁剪原尺寸），整体平移到页面中心。</summary>
    public enum ViewportMode : byte { Keep, ScaleK, Hor, CenterNative, Page }

    /// <summary>一次绘制读的一个常量绑定：缓冲号、绑定区间、着色器读法（建程序时由 SpirvCbufUse 得出）。</summary>
    public readonly struct CbufRead
    {
        public readonly ulong Buffer; public readonly int Offset, Size; public readonly CbufUse Use;
        public CbufRead(ulong buffer, int offset, int size, CbufUse use) { Buffer = buffer; Offset = offset; Size = size; Use = use; }
    }

    /// <summary>往缓冲写一段数据（写回原值 / 改写值）。必须与之后的绘制同序生效。</summary>
    public interface IBufferPatcher { void Write(ulong buffer, int offset, ReadOnlySpan<byte> data); }

    [InlineArray(64)] public struct Bytes64 { byte _e; }

    public sealed class WidenFrame : IWidenHitSink
    {
        readonly WidenRewriter _rw;
        readonly Dictionary<uint, (int W0, int W1)> _wide = new();
        readonly CbufShadow _sh = new();   // 常量缓冲影子 + 各缓冲当前有效的改写区间（见 CbufShadow）
        readonly List<(int Off, int Len, WidenKind Kind)> _pending = new();
        readonly List<(int Lo, int Hi)> _chg = new();
        readonly byte[] _tmp = new byte[ScanChunk + 64];
        readonly List<(ulong Buf, int Lo)> _restored = new();

        readonly Dictionary<uint, int> _native = new();   // 原生宽贴图 → 等效 16:9 宽（= 宽 ÷ k）
        uint _rt0; int _wideRtW0, _wideRtW1; bool _rtNative;
        readonly uint[] _fragTex = new uint[256];
        int _fragHi;   // 片元槽位表用到的上界：[_fragHi, 256) 恒为 0（只增不减），逐笔扫描只扫这一截（11-02 塞尔达真机：每笔整扫 256 格占提交线程 5%，实际每笔 < 16 张）
        uint _lastDrawRt; readonly uint[] _lastDrawTex = new uint[256];
        uint _out;
        // 出图目标集合（10-23 jhz 实机巫师3 露台站着不动整帧光影周期性跳）：交换链两张图交替上屏，且上屏调用晚于下一帧的绘制——上屏 32 时最后一笔已在画下一帧的 26，
        // 原先只记一张 T_out（多数帧退回「刚上屏的那张」= 下一帧不画的那张），下一帧画 26 认不出出图目标、界面层按拉伸画；偶尔时序对上的帧界面又原尺寸居中，两种画法隔几帧一换。
        // 改为：交换链是两张交替上屏（最近三次上屏 A、B、A）时，两张里被选出过的都算出图目标（巫师3 交替选出 26 / 32，两张都在）；
        // 三张轮换的款（丝之歌 10 / 11 / 7、暗黑3、暗黑2）不启用：界面画在轮换的下一张上、改前就认不出，按登记的「HUD 左锚定」等画法画，
        // 收进集合会把它们改成原宽居中、且轮换不规则的帧时有时无（九款逐帧：丝之歌 6 帧界面整块挪 14300 像素）；「本帧第一次画它」改按目标记：被选出或上屏后的第一笔 = 色调映射合成，与上屏先后无关。
        // 常驻集合只收「选出的就是上屏图本身」的交换链图；按采样选出的合成源（≠ 上屏图）只当本次 T_out、下次选出别的就不算（10-23 暗黑2 物品栏：开局第一次上屏误选合成图 6，
        // 留在集合里后每帧画在 6 上的全画布压暗遮罩被判成界面层收进中间，16:9 边界亮度跳 7.6）
        readonly List<uint> _outs = new(2); readonly HashSet<uint> _outFresh = new(); uint _pres1, _pres2; bool _dbl;

        /// <summary>可选：每个改写命中都转告（诊断 / 录像核对用）。</summary>
        public IWidenHitSink Observer;

        public long Frames, Draws, DrawsWide, DrawsHud, DrawsHudCentered, DrawsCovered, DrawsPage, Restores, Reapplies, DrawsUiLayer, DrawsSubViewport, DrawsSubCentered, DrawsOutPost, DrawsUiWide;   // DrawsOutPost：输出目标上第一次合成之后、采样放宽贴图的全屏后处理（按 k 铺满）
        /// <summary>只扫变了的：上传字节；扫的量（整段扫的按字节，逐单元判的按矩阵窗口 16、浮点位置 4 计）。</summary>
        public long UpBytes, ScanBytes;
        /// <summary>可选：影子对照（测试用，旧整段扫描模型，见 IWidenCheck）。产品里为 null。</summary>
        public IWidenCheck Check;

        public WidenFrame(WidenRewriter rw) { _rw = rw; }

        /// <summary>游戏自己按屏幕比出图（第二层生效：原生层 s2a_widen_game() 回 1，services/aot/Compose.cs 传入）：只管界面层——不放宽任何贴图（放宽后游戏按客体宽算的 0..1 采样坐标会对不上，
        /// 只能把内容一起拉宽）；每次绘制按视口判原生宽：视口宽高比 ≈ 屏幕比的绘制，读到改写过的 16:9 投影就原尺寸居中在视口里（游戏常在大贴图里只画一块子矩形，
        /// 例如动森掌机 1920×1080 贴图里画 1564×720，不能按贴图尺寸判）。</summary>
        public bool GameWide;
        /// <summary>游戏界面布局也是宽的（GameWide 且第二层启用了界面布局尺寸点 lytsz：原生层 s2a_widen_layout() 回 1，services/aot/Compose.cs 传入）。
        /// 游戏按宽屏画布排界面、按真实宽屏像素算界面剪裁，读改写矩阵（Hor）的界面层局部剪裁不再收进中间（见 MapScissor）。</summary>
        public bool LayoutWide;
        float _vpX;   // GameWide：当前绘制视口的左边（原尺寸居中按视口区域算）
        // GameWide：本局按屏幕比视口画过的颜色目标（不放宽、也不按贴图尺寸登记原生宽，T_out 只能按「画过原生宽视口」认）。
        // 10-21 怪猎掌机档（场景视图撑到 1568×720）：界面画进 1568×720 的界面合成目标、再合成到 1920×1080 上屏贴图；原先 GameWide 下 _wide / _native 都空，
        // OnPresent 认不出 T_out（恒 0），规则 A 从不触发，没读改写矩阵的界面（RE 引擎界面按 1280 画布、视口拉满 1568）被横向拉宽约 1.22 倍
        readonly HashSet<uint> _gwDrawn = new();

        /// <summary>每次绘制前（GameWide 时）报当前视口 0：宽高比 ≈ 屏幕比 → 当前目标按原生宽处理，区域 = 视口。返回状态是否变了（变了要重发视口）。</summary>
        public bool OnViewport(float x, float width, float height, float resolutionScale = 1f)
        {
            if (!GameWide) return false;
            bool nat = _rw.On && height / resolutionScale >= 8 && Math.Abs(width / height / _rw.Aspect - 1) < 0.01f;
            int w1 = nat ? (int)Math.Round(width) : 0, w0 = nat ? (int)Math.Round(width / _rw.K) : 0;
            float rx = x; bool sub = false;
            if (nat) { if (_rt0 != 0 && (_rt0 != _gwRegRt || (x, w1, w0, height) != _gwRegLast)) { _gwRegion[_rt0] = (x, w1, w0, height); _gwRegRt = _rt0; _gwRegLast = (x, w1, w0, height); } }   // 和上次写的一样就不再写字典（10-24 直连每笔都写，采样里占挂点约 4%）
            // 子视口（10-23 jhz 实机暗黑3：怒气球液体 83×83、血条填充 231×21 各用自己的小视口画，视口宽高比不是屏幕比）：
            // 落在这张目标已认出的原生宽区域里的，同属该区域——没读改写矩阵时按界面层原尺寸居中（视口 / 裁剪同 CenterNative 换算），
            // 否则框（全区域视口、原尺寸居中）平移了 142 而液体 / 填充留在游戏坐标，两者错开
            // 只认小视口（宽、高都不超过区域一半：界面控件）；整块 16:9 视口（1280×720 画 16:9 内容）不是子视口，照旧不按原生宽
            else if (_rt0 != 0 && _gwRegion.TryGetValue(_rt0, out var rg) && x >= rg.X - 0.5f && x + width <= rg.X + rg.W1 + 0.5f && width * 2 <= rg.W1 && height * 2 <= rg.H)
            { nat = true; sub = true; w1 = rg.W1; w0 = rg.W0; rx = rg.X; }
            if (nat == _rtNative && w1 == _wideRtW1 && rx == _vpX && sub == _subVp) return false;
            _rtNative = nat; _wideRtW1 = w1; _wideRtW0 = w0; _vpX = rx; _subVp = sub;
            return true;
        }
        // GameWide：每张颜色目标最近一次按屏幕比视口画时的原生宽区域（视口左边、宽、对应 16:9 宽）；当前视口是区域里的子视口
        readonly Dictionary<uint, (float X, int W1, int W0, float H)> _gwRegion = new();
        uint _gwRegRt; (float X, int W1, int W0, float H) _gwRegLast;   // 上次写进 _gwRegion 的那一项
        bool _subVp;
        public bool SubViewport => _subVp;
        public WidenRewriter Rewriter => _rw;
        public uint OutTexture => _out;
        public uint LastDrawTarget => _lastDrawRt;
        public ReadOnlySpan<uint> LastDrawTextures => _lastDrawTex;

        // ---------- 贴图 ----------
        /// <summary>建贴图 / 视图时调用：返回实际要建的宽度；属放宽一族就登记。</summary>
        public int OnCreateTexture(uint id, int width, int height, float resolutionScale = 1f) => OnCreateTexture(id, width, height, resolutionScale, false);

        /// <param name="rebuildable">调用方能在运行中按更宽的宽重建这张贴图的存储（Vulkan 层，S2A_WIDEN_USE_REBUILD）：尺寸不属 16:9 一族的放进「未定」，
        /// 按内容判画布（Promote）</param>
        public int OnCreateTexture(uint id, int width, int height, float resolutionScale, bool rebuildable)
        {
            _undecided.Remove(id); _fixed.Remove(id);
            // 按需放宽过的（LayerWiden：分层图集 / 降采样链中间目标）同一张、同宽重登记：保留放宽。直连胶水在开遍前先放宽（wd_layer_widen），
            //   开遍时才第一次登记这张贴图（wd_tex，按序号缓存、之后不再登记），原先这里按「不属 16:9 一族」删掉放宽登记，核心此后一直按原宽画、存储却已放宽
            //   （11-07 小小梦魇3 真机逐目标导出：泛光链 24×23 / 48×45 / 12×12 存储已放宽，每笔追踪「target not widened」，放大回来的泛光只剩两侧带，中间黑）
            if (_layered.Contains(id) && _wide.TryGetValue(id, out var lw) && lw.W0 == width) return lw.W1;
            _layered.Remove(id);
            if (GameWide) { _wide.Remove(id); _native.Remove(id); _tall.Remove(id); return width; }
            _tall.Remove(id);
            if (_rw.Tall)   // 窄屏上下多画（10-26）：16:9 一族加高；放宽表也登记一份「宽不变」，判「画在放宽目标上 / 采样放宽图」的逻辑原样生效、x 换算都是 1
            {
                int h1 = _rw.WidenHeight(width, height);
                if (h1 != height) { _family.Add(((int)Math.Round(width / resolutionScale), (int)Math.Round(height / resolutionScale))); _wide[id] = (width, width); _tall[id] = (height, h1); _native.Remove(id); return width; }
                // 按内容判画布的竖向（11-02 银河2 Duo 外屏：场景画在 Wii EFB 1920×1584 左上 1280×720，EFB 不属 16:9 一族，原先竖向会话里不进「未定」、
                //   EFB 不加高，局内 3D 上下各差约 49 行）：同尺寸类判过画布的直接加高，否则能重建存储的进未定（同横向）
                var tc = ((int)Math.Round(width / resolutionScale), (int)Math.Round(height / resolutionScale));
                if (rebuildable && _canvas.Contains(tc) && (h1 = _rw.WidenAnyHeight(height)) != height) { _wide[id] = (width, width); _tall[id] = (height, h1); _native.Remove(id); if (_cornerOf.TryGetValue(tc, out int tcw)) _cornerW[id] = tcw; return width; }
                if (rebuildable && height / resolutionScale >= 360) _undecided[id] = (width, height, resolutionScale);
                _wide.Remove(id);
                // 原生高（11-05，同下方横向「原生宽」）：宽高比 ≈ 屏比（Duo 1.422 / iPad 1.333）的贴图 = 游戏按第一层报的加长分辨率（掌机 1280×900）自己画的高图，
                //   不再二次加高、不动视口（_tall 不登记，MapViewportY 原样）；读改写后 16:9 投影的界面层同横向按原尺寸居中
                if (height / resolutionScale >= 8 && Math.Abs((double)width / height / _rw.Aspect - 1) < 0.01) _native[id] = width;
                else _native.Remove(id);
                return width;
            }
            int w1 = _rw.WidenWidth(width, height);
            if (w1 != width) { _family.Add(((int)Math.Round(width / resolutionScale), (int)Math.Round(height / resolutionScale))); _wide[id] = (width, w1); _native.Remove(id); return w1; }
            if (rebuildable && _canvas.Contains(((int)Math.Round(width / resolutionScale), (int)Math.Round(height / resolutionScale))) && (w1 = _rw.WidenAnyWidth(width)) != width)
            { _wide[id] = (width, w1); _native.Remove(id); if (_cornerOf.TryGetValue(((int)Math.Round(width / resolutionScale), (int)Math.Round(height / resolutionScale)), out int ccw)) _cornerW[id] = ccw; return w1; }   // 同尺寸的画布之前判过（Promote）：直接按放宽建
            if (rebuildable && _rw.On && height / resolutionScale >= 360) _undecided[id] = (width, height, resolutionScale);
            _wide.Remove(id);
            if (_rw.On && height / resolutionScale >= 8 && Math.Abs((double)width / height / _rw.Aspect - 1) < 0.01) _native[id] = (int)Math.Round(width / _rw.K);
            else _native.Remove(id);
            return w1;
        }
        readonly HashSet<(int W, int H)> _family = new();   // 放宽过的 16:9 客体画面尺寸（去掉逐纹理分辨率倍率）

        // ---------- 按内容判画布（10-30 银河2）：放宽判据从「尺寸像 16:9」改成「内容是 16:9 画面」 ----------
        // 尺寸只是替身：银河2（Hagi，Wii 模拟层）把 16:9 场景按变形画法画进 1920×1584 的 EFB（640×528 × 3，宽高比 1.21），再缩拷进 16:9 目标。
        // 尺寸门不认它 → 场景绘制不进核心（进核心 2.8%、改写 0）→ 最后合成按 ScaleK 整幅横拉 1.222 倍。
        // 能重建存储的调用方（S2A_WIDEN_USE_REBUILD，Vulkan 层）建的、尺寸不属一族、高 ≥ 360 的附件目标先放进「未定」：快判对它返回 1，绘制照常交常量、按原样画（Keep）。
        // 未定目标上有一笔铺满视口（≥ 目标宽高 90%）、读到改写过的 16:9 镜头矩阵（核心认出的透视投影 / 视图投影）→ 判为画布：按 WidenAnyWidth 放宽、
        // 登记进 _canvas（之后同尺寸新建直接放宽）、进晋升队列；调用方在下次提交开头取走（TakePromoted）、重建存储。
        // 不设「多少帧没命中就否决」：银河2 开机 logo 阶段 EFB 上全是 2D，会被提前否决。代价是从不晋升的未定目标每笔多交一次常量扫描（S2A_WIDEN_PROF 能量）
        readonly Dictionary<uint, (int W, int H, float Scale)> _undecided = new();
        // 画布是左上一块的贴图（视口从原点起 16:9、比贴图窄）：贴图号 → 画布客体宽；同尺寸类与视图继承。Hor / 居中 / 剪刀的 pad 与「铺满」按画布算，
        //   不按整张贴图（10-30 银河2：EFB 1920 宽、画布 1280，按整张算 pad = 210、该是 140——场景右偏 70 列、界面层右偏 140 列，两侧露底）
        readonly Dictionary<uint, int> _cornerW = new(); readonly Dictionary<(int W, int H), int> _cornerOf = new();
        int _rtCornerW;   // 当前目标的左上画布宽（0 = 画布就是整张）
        int CanvasW0 => _rtCornerW != 0 ? _rtCornerW : _wideRtW0;
        int CanvasW1 => _rtCornerW != 0 ? (int)Math.Round(_rtCornerW * (double)_rw.K) : _wideRtW1;
        // 纵向画布（窄屏加高）：左上画布按它的 16:9 宽定高（宽 × 9/16），放高后按 WidenHeight 同一规则——银河2 EFB 1584 高里只画左上 720，pad 按存储算 (1934 − 1584)/2 = 175、
        //   应为 (878 − 720)/2 = 79（11-02）；不是左上画布时就是整张目标
        int CanvasH0 => _rtCornerW != 0 && _tallRtH1 != 0 ? (int)Math.Round(_rtCornerW * 9.0 / 16.0) : _tallRtH0;
        int CanvasH1 => _rtCornerW != 0 && _tallRtH1 != 0 ? _rw.WidenHeight(_rtCornerW, CanvasH0) : _tallRtH1;
        /// <summary>视图 id 继承父贴图的左上画布宽（WidenSession.View 调）。</summary>
        /// <summary>放宽目标上的这笔视口：从原点起、16:9、宽在目标原宽 60%–99% → 记为这张目标的左上画布（掌机档在主机尺寸缓冲里只画左上 1280×720；动态分辨率画左上一块）；
        /// 铺满整张（≥ 99%）→ 清掉。居中 / Hor / 剪刀的 pad 按画布算（CanvasW0 / CanvasW1）。原先左上画布只在按内容判画布（TryPromote）时登记，
        /// 一开始就按 16:9 一族放宽的窗口贴图从没登记过，pad 按整张贴图算（2346−1920）/2 = 213、应为（1564−1280）/2 = 142：10-31 丝之歌暂停页（帧回放定因）
        /// 原宽居中的压暗遮罩画在 [319, 2240)、左侧 318 列露出未压暗的旧帧，HUD 的 Hor 笔中心右移 71</summary>
        public void NoteCanvas(float vpX, float vpW, float vpH)
        {
            if (_rt0 == 0 || _wideRtW1 == 0 || _rtNative) return;
            float ah = MathF.Abs(vpH), w0 = _wideRtW0;
            if (MathF.Abs(vpX) >= 0.5f || ah <= 0) return;
            if (vpW >= 0.99f * w0) { if (_rtCornerW != 0) { _rtCornerW = 0; _cornerW.Remove(_rt0); } return; }
            if (MathF.Abs(vpW / ah / (16f / 9f) - 1) >= 0.01f || vpW < 0.6f * w0) return;
            int cw = (int)MathF.Round(vpW);
            if (cw != _rtCornerW) { _rtCornerW = cw; _cornerW[_rt0] = cw; }
        }
        public void InheritCorner(uint id, uint parent) { if (_cornerW.TryGetValue(parent, out int cw)) _cornerW[id] = cw; else _cornerW.Remove(id); }
        readonly HashSet<(int W, int H)> _canvas = new();
        readonly List<uint> _promoted = new();
        public long Promoted, PromoteTries, PromoteSmallVp, PromoteNoCam; int _promoteSaid;
        readonly Dictionary<uint, uint> _undecidedView = new();   // 未定贴图的同宽视图 → 贴图（Vulkan 层按视图号登记渲染目标）
        public bool IsUndecided(uint id) => _undecided.ContainsKey(id) || _undecidedView.ContainsKey(id);
        /// <summary>视图 id 是未定贴图 root 的同宽视图（WidenSession.View 调）：画在它上面同样按内容判画布，晋升的是 root。</summary>
        public void OnCreateViewUndecided(uint id, uint root) { if (_undecided.ContainsKey(root)) _undecidedView[id] = root; }
        uint UndecidedRoot(uint id) => _undecided.ContainsKey(id) ? id : _undecidedView.TryGetValue(id, out uint r) && _undecided.ContainsKey(r) ? r : 0;
        /// <summary>当前颜色目标是未定目标（快判据此返回 1：常量要交给核心看）。</summary>
        public bool TargetUndecided => _rt0 != 0 && UndecidedRoot(_rt0) != 0;
        /// <summary>当前未定目标上的一笔：铺满视口且读到改写过的镜头矩阵 → 晋升为画布，返回 true（这一笔仍按原样画，下次提交起按放宽）。</summary>
        public bool TryPromote(float vpW, float vpH, ReadOnlySpan<CbufRead> reads) => TryPromote(0, vpW, vpH, reads);
        /// <param name="vpX">视口左边。画布同原比例页（TryBeginPage）：整张目标（视口 ≥ 宽高 90%），或从原点起、16:9、不窄于目标宽 60% 的视口——
        /// 10-30 银河2 实局：EFB 1920×1584 上的场景绘制视口全是左上 1280×720（16:9 画面只占大缓冲的左上一块），按「铺满」判整局 0 晋升</param>
        public bool TryPromote(float vpX, float vpW, float vpH, ReadOnlySpan<CbufRead> reads)
        {
            uint root = _rt0 != 0 ? UndecidedRoot(_rt0) : 0; if (root == 0) return false;
            var (w, h, sc) = _undecided[root];
            PromoteTries++;
            float ah = MathF.Abs(vpH);
            bool whole = vpW >= 0.9f * w && ah >= 0.9f * h, corner = MathF.Abs(vpX) < 0.5f && ah > 0 && MathF.Abs(vpW / ah / (16f / 9f) - 1) < 0.01f && vpW >= 0.6f * w;
            bool small = !whole && !corner, cam = !small && ReadsCamMatrix(reads);
            if (small) PromoteSmallVp++; else if (!cam) PromoteNoCam++;
            if ((small || !cam) && _promoteSaid < 6 && (small ? PromoteSmallVp : PromoteNoCam) <= 3)
            {   // 前几次没晋升的理由（实局定因用：10-30 银河2 整局 0 晋升，要分清是视口没铺满还是没读到镜头矩阵）
                _promoteSaid++;
                Console.Error.WriteLine($"[宽屏·核心] 未定目标 {root}（{w}×{h}）这一笔不判画布：{(small ? $"视口 {vpX:F0},{vpW:F0}×{ah:F0} 既不铺满（90%）也不是左上 16:9 画布（≥ 60% 宽）" : $"读区间 {reads.Length} 段里没有核心认出的镜头矩阵")}");
            }
            if (!cam) return false;
            bool tall = _rw.Tall;   // 窄屏：按同一规则加高（宽不变），见 OnCreateTexture 竖向分支
            int w1 = tall ? w : _rw.WidenAnyWidth(w), h1 = tall ? _rw.WidenAnyHeight(h) : h; if (w1 == w && h1 == h) return false;
            // 画布按尺寸类认（_canvas）：已建好的同尺寸未定贴图一起晋升——同一遍的深度附件、双缓冲的另一张 EFB（10-30 银河2 三张 1920×1584：两张颜色 + 一张深度；
            //   只晋升画的那张时深度仍 1920 宽，渲染区按最窄附件截在左 1920 列，画面右移、两侧露底）
            var cls = ((int)Math.Round(w / sc), (int)Math.Round(h / sc)); _canvas.Add(cls); int n = 0;
            int cw = whole ? 0 : (int)Math.Round(vpW); if (cw != 0) _cornerOf[cls] = cw;
            foreach (var (id, u) in _undecided)
                if (((int)Math.Round(u.W / u.Scale), (int)Math.Round(u.H / u.Scale)) != cls) continue;
                else if (tall) { if (_rw.WidenAnyHeight(u.H) is int uh1 && uh1 != u.H) { _wide[id] = (u.W, u.W); _tall[id] = (u.H, uh1); _promoted.Add(id); if (cw != 0) _cornerW[id] = cw; n++; } }
                else if (_rw.WidenAnyWidth(u.W) is int uw1 && uw1 != u.W) { _wide[id] = (u.W, uw1); _promoted.Add(id); if (cw != 0) _cornerW[id] = cw; n++; }
            foreach (uint id in _promoted) _undecided.Remove(id);
            Promoted += n;
            Console.Error.WriteLine(tall ? $"[宽屏·核心] 按内容判画布：贴图 {root}（{w}×{h}，不属 16:9 一族）上的场景绘制读到 16:9 镜头矩阵 → 同尺寸 {n} 张加高 {h} → {h1}，下次提交起重建（累计 {Promoted} 张）"
                : $"[宽屏·核心] 按内容判画布：贴图 {root}（{w}×{h}，不属 16:9 一族）上的场景绘制读到 16:9 镜头矩阵 → 同尺寸 {n} 张放宽 {w} → {w1}，下次提交起重建（累计 {Promoted} 张）");
            return true;
        }
        /// <summary>这些绑定读到核心认出的镜头矩阵（投影 / 视图投影 / 逆投影），不论这段眼下是原值还是改写值：未定目标上的绘制按原样画，命中都被标成「写回原值」
        /// （ReadsRewritten 只认没写回的），10-30 银河2 实局整局 0 晋升。判画布看的是「内容是不是 16:9 镜头画面」，与这段常量当前给谁什么值无关</summary>
        bool ReadsCamMatrix(ReadOnlySpan<CbufRead> reads)
        {
            foreach (ref readonly CbufRead r in reads)
            {
                if (r.Use == null) continue;
                CbufShadow.Buf b = _sh.TryGet(r.Buffer);
                if (b == null || b.Hits.Count == 0) continue;
                Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
                for (int i = b.FirstHitEndingAfter(r.Offset); i < hs.Length && hs[i].Lo < r.Offset + r.Size; i++)
                {
                    ref readonly CbufShadow.Hit h = ref hs[i];
                    if (h.Kind <= WidenKind.InverseProjection && h.Lo >= r.Offset && h.Lo + h.Len <= r.Offset + r.Size && r.Use.Reads(r.Offset, r.Size, h.Lo, h.Lo + h.Len)) return true;
                }
            }
            return false;
        }
        /// <summary>取走本次以来新判成画布的贴图号（调用方重建存储并重新登记它的视图）；返回个数（超过 cap 的留到下次）。</summary>
        public int TakePromoted(Span<uint> ids)
        {
            int n = Math.Min(ids.Length, _promoted.Count);
            for (int i = 0; i < n; i++) ids[i] = _promoted[i];
            _promoted.RemoveRange(0, n); return n;
        }
        /// <summary>画面分层图集跟着放宽（10-23 八方2 走动右侧：景深近 / 远两层 448×252 竖拼成 448×544、中间 40 行护边，不是 16:9 没放宽；
        /// 景深散点按放宽源铺精灵，合成遍按放宽画布读它）。只在包装层认定「这张图第一次被读宽外延内容的绘制当目标」时调（WidenTexture.ForceWiden），
        /// 尺寸按各自倍率还原到客体像素比较：宽 = 某个已放宽 16:9 画面宽按级缩（÷2^n，n ≤ 3）、高在该级高的 2–2.5 倍（两层竖拼 + 护边）。放宽宽按目标实际像素计算。
        /// 满足就登记进放宽一族、返回放宽宽；否则返回原宽。GameWide / 已放宽 / 关闭时不动。</summary>
        public int LayerWiden(uint id, int w, int h, float resolutionScale = 1f)
        {
            if (GameWide || !_rw.On || _wide.ContainsKey(id)) return w;
            int guestW = (int)Math.Round(w / resolutionScale), guestH = (int)Math.Round(h / resolutionScale);
            foreach (var (fw, fh) in _family)
                for (int n = 0; n <= 3; n++)
                {
                    int lw = fw >> n, lh = fh >> n;
                    if (lw <= 0 || lh <= 0 || guestW != lw || guestH < 2 * lh || 2 * guestH > 5 * lh) continue;
                    int w1 = _rw.WidenWidth(w, (int)Math.Ceiling(lh * resolutionScale));
                    if (w1 == w) continue;
                    _wide[id] = (w, w1); _native.Remove(id); _layered.Add(id); LayerWidened++; return w1;
                }
            // 降采样链 / 可分离模糊的中间目标（11-07 满屏补丁线，jhz 手测小小梦魇3 中间暗两侧亮）：宽、高各是某个已放宽画面尺寸按 2 的幂缩出来的
            //   （⌊/2^a⌋ 或 ⌈/2^a⌉，两向级数差 ≤ 1：横向减半 20×23 ← 40×23、两向减半 20×12 ← 40×23），第一笔就读放宽内容 = 从放宽画面派生的同一画面，跟着放宽。
            //   原先这类不属 16:9 一族的小目标不放宽、也进不了「未定」（高 < 360），读它们的合成遍只按原宽居中画（诊断：目标 40×23 → 48、采样 20×23 / 20×12 都没放宽），
            //   缩小链只有中间 16:9 有效，合回整屏成了中间与两侧亮度不同、分界在 16:9 边上
            foreach (var (fw, fh) in _family)
                for (int a = 0; a <= 7; a++)
                {
                    if (!Level(fw, a, guestW)) continue;
                    for (int b = Math.Max(0, a - 1); b <= a + 1; b++)
                    {
                        if ((a == 0 && b == 0) || !Level(fh, b, guestH)) continue;
                        if (_rw.Tall)
                        {   // 窄屏（11-07 小小梦魇3 Duo：泛光链只在中间 16:9 行有效，顶上扩展带一条亮光）：同 OnCreateTexture 窄屏分支，宽不变、按同一规则加高
                            int h1 = _rw.WidenAnyHeight(h);
                            if (h1 == h) continue;
                            _wide[id] = (w, w); _tall[id] = (h, h1); _native.Remove(id); _layered.Add(id); ChainWidened++; return w;
                        }
                        int w1 = _rw.WidenAnyWidth(w);
                        if (w1 == w) continue;
                        _wide[id] = (w, w1); _native.Remove(id); _layered.Add(id); ChainWidened++; return w1;
                    }
                }
            return w;
        }
        /// <summary>v 是 full 按 2^n 缩的一级：⌊full / 2^n⌋ 或 ⌈full / 2^n⌉（降采样各级向下或向上取整都有）</summary>
        static bool Level(int full, int n, int v) => v > 0 && (v == full >> n || v == ((full + (1 << n) - 1) >> n));
        public long LayerWidened;   // 按画面分层图集放宽的张数
        public long ChainWidened;   // 按降采样链 / 可分离模糊中间目标放宽的张数

        /// <summary>视图：宽度由父贴图定（父放宽时 w1 = 父放宽宽度按级缩），只登记不重算。返回 w1。</summary>
        public int OnCreateView(uint id, int w0, int w1)
        {
            _native.Remove(id); _tall.Remove(id);
            if (w1 != w0) _wide[id] = (w0, w1); else _wide.Remove(id);
            return w1;
        }
        /// <summary>窄屏：视图的高由父定（父加高时 h1 = 父放高高按级缩），同 OnCreateView 的宽；登记成放宽（宽不变）+ 加高。返回 h1。</summary>
        public int OnCreateViewTall(uint id, int w0, int h0, int h1)
        {
            _native.Remove(id);
            if (h1 != h0) { _wide[id] = (w0, w0); _tall[id] = (h0, h1); } else { _wide.Remove(id); _tall.Remove(id); }
            return h1;
        }
        /// <summary>窄屏加高的贴图：原高、放高高（没加高返回 false）。</summary>
        public bool TryTall(uint id, out int h0, out int h1)
        {
            if (_tall.TryGetValue(id, out var b)) { h0 = b.H0; h1 = b.H1; return true; }
            h0 = h1 = 0; return false;
        }
        readonly Dictionary<uint, (int H0, int H1)> _tall = new();
        /// <summary>存储放不宽的贴图（包装层 / 胶水登记时不带 UseRt：游戏内存池、交换链等，见 WidenSession.Texture）：当颜色目标 0 时整遍不放宽，
        /// 不从深度目标继承放宽（11-02 饥荒：交换链 1920 宽当颜色、放宽过的 2346 深度当深度，按深度判成放宽目标，视口 0+2346 画出存储右侧被裁、整幅偏右）。</summary>
        public void OnFixedTexture(uint id) { OnReleaseTexture(id); _fixed.Add(id); }
        readonly HashSet<uint> _fixed = new();
        readonly HashSet<uint> _layered = new();   // 按需放宽过的贴图（LayerWiden），重登记时保留放宽
        public void OnReleaseTexture(uint id) { _layered.Remove(id); _fixed.Remove(id); _undecided.Remove(id); _cornerW.Remove(id); _undecidedView.Remove(id); _promoted.Remove(id); _tall.Remove(id); _gwRegion.Remove(id); _gwLastMode.Remove(id); _wide.Remove(id); _native.Remove(id); _gwDrawn.Remove(id); _pages.Remove(id); _pageSources.Remove(id); _bands.Remove(id); _screenCopy.Remove(id); _sidesAt.Remove(id); _drawnAt.Remove(id); }
        public bool IsNative(uint id) => _native.ContainsKey(id);
        public bool IsWide(uint id) => _wide.ContainsKey(id);
        public bool TryWide(uint id, out int w0, out int w1)
        {
            if (_wide.TryGetValue(id, out var b)) { w0 = b.W0; w1 = b.W1; return true; }
            w0 = w1 = 0; return false;
        }

        /// <summary>计算派发写放宽图像（原宽 w0、放宽 w1、高 h）：派发按像素铺（存在 2 的幂 Lx、Ly 使 gx = ⌈w0 / Lx⌉、gy = ⌈h / Ly⌉）时
        /// 返回铺满放宽宽度的 X 组数 ⌈w1 / Lx⌉（同绘制的视口按 k：着色器用组号 × 组宽 + 组内号当像素坐标，读写在放宽空间里一致）；不按像素铺（规约 / 一维）返回 −1。
        /// 10-22 巫师3 第三层：半分辨率 640×360 放宽成 782×360，游戏按 16×16 派 40×23 组、按 8×8 派 80×45 组，右边 142 列没人写，下一遍按 0..1 采样整张 → 画面偏移、重影。</summary>
        public static int WidenGroupsX(int gx, int gy, int w0, int w1, int h)
        {
            if (gx <= 0 || gy <= 0 || w0 <= 0 || w1 <= w0 || h <= 0) return -1;
            bool yOk = false;
            for (int ly = 1; ly <= 1024 && !yOk; ly <<= 1) yOk = (h + ly - 1) / ly == gy;
            if (!yOk) return -1;
            for (int lx = 1; lx <= 1024; lx <<= 1)
                if ((w0 + lx - 1) / lx == gx) return (w1 + lx - 1) / lx;
            return -1;
        }

        // ---------- 整屏副本（原生宽目标上的界面层外推判据，10-21 塞尔达菜单） ----------
        // 整屏副本 = 存储 16:9、内容是整屏画面缩拷的贴图（菜单底图：宽出图 1564×720 → 1280×720 → 640×360 → 320×180 模糊）。界面库按 16:9 画布铺满（UV 0..1），
        // 包装层让界面原尺寸居中后它只占中间 [142, 1422)、内容横向被压 k 倍、两侧黑（菜单底图缺两条）；面板推到屏幕边（越界顶点外推放行）= 按原比例还原整屏画面，不是拉伸。
        // 来历：最近一次铺满整张目标（视口覆盖整张）的绘制采样的全是整屏画面（宽 = 高 × 屏幕比）或整屏副本；游戏清掉这张目标（ClearRenderTargetColor）或释放就不再是。
        readonly HashSet<uint> _screenCopy = new();
        // 宽 = 高 × 屏幕比（差 ≤ 1 像素，取整误差）：1564×720、782×360、391×180、2346×1080、动态分辨率 1955×900 都是；界面图 483×224（差 3.6 像素，比例只差 0.75%）不是——按 1% 判会把塞尔达ポーチ页这张界面图当成整屏画面
        public bool IsScreenAspect(int width, int height, float resolutionScale = 1f) =>
            _rw.On && height / resolutionScale >= 8 && Math.Abs(width - height * (double)_rw.Aspect) / resolutionScale <= 1;
        public bool IsScreenCopy(uint id) => _screenCopy.Contains(id);

        /// <summary>纹理与目标可有不同分辨率倍率，先各自回到客体像素，再按整画布图片判定；宽屏比例不参与这次比较。</summary>
        public static bool IsPagePicture(int textureWidth, int textureHeight, float textureScale, int canvasWidth, float targetScale) =>
            textureHeight > 0 && Math.Abs(textureWidth * 9.0 / (textureHeight * 16.0) - 1) < 0.01 && textureWidth / textureScale >= canvasWidth / targetScale * 0.9;

        /// <summary>新起原比例页至少半个掌机屏，按客体高度判断，避免倍率改变视频 / 小后处理的分类。</summary>
        public static bool IsPageTarget(int height, float resolutionScale) => height / resolutionScale >= 360;
        public static bool IsSmallTexture(int width, int height, float resolutionScale, int maxSize) => width / resolutionScale <= maxSize && height / resolutionScale <= maxSize;
        /// <summary>铺满画布的界面层采样的这张贴图横向没有细节（10-29 喷3 房间列表暗化层 128×72 铺 1530 宽画布 = 放大 12 倍）：
        /// 夹边寻址（UV 越界取边，内容横向至多铺一遍）且客体宽 × FlatMag ≤ 画布宽——每个纹素已占 ≥ 4 列，再横向拉 k 倍看不出变形，层可以推满宽屏、两侧有确定内容。
        /// 横向平铺的贴图这里不算（铺几遍不知道；原尺寸居中层另按 OnlyBackground 的平铺规则推）；喷3 同页 512×256 的层（放大 3 倍）不算。</summary>
        public static bool IsFlatTexture(int width, float resolutionScale, bool tileU, float canvasWidth) => !tileU && width / resolutionScale * FlatMag <= canvasWidth;
        public const float FlatMag = 4f;
        /// <summary>一次铺满整张目标（width×height）的绘制：fromScreen = 它采样的都是整屏画面 / 整屏副本。目标是 16:9 或屏幕比（宽差 ≤ 1 像素）才记为整屏副本——
        /// 别的比例是局部裁拷（塞尔达冒険手帳页把整屏的一条 61×540 / 61×200 拷出来给毛玻璃面板，按副本外推会把面板拉宽、选中框变形）；没采样整屏不动（同一视口里叠画的小图标不改变底图来历）。</summary>
        public void OnTargetFilled(uint target, int width, int height, bool fromScreen, float resolutionScale = 1f)
        {
            if (!fromScreen || target == 0 || height / resolutionScale < 8) return;
            if (Math.Abs(width - height * 16.0 / 9.0) / resolutionScale <= 1 || IsScreenAspect(width, height, resolutionScale)) _screenCopy.Add(target);
        }
        /// <summary>本帧这张目标上已有一笔铺满画布、采放宽目标的 ScaleK 全屏合成（场景已合成进来，之后画在它上面的是叠加层：界面 / 遮罩 / 后处理，不是 3D 场景）。
        /// 与上屏轮换无关（规则 A 认出图目标只认单张 / 两张交替；10-31 丝之歌交换链三张 1 / 2 / 3 轮换，暂停遮罩那笔判不成界面层）。上屏或清屏后作废</summary>
        public void NoteComposited(uint target) { if (target != 0) _composited.Add(target); }
        public bool Composited(uint target) => _composited.Contains(target);
        readonly HashSet<uint> _composited = new();
        public void OnTargetCleared(uint target) { _composited.Remove(target); _screenCopy.Remove(target); _pageSources.Remove(target); _bands.Remove(target); NoteSidesWritten(target); }   // 清屏：内容来历（整屏副本 / 页 / 两侧）作废；两侧本帧有了确定内容

        // ---------- 两侧带本帧有没有确定内容（10-29 马车8 选轮胎页：游戏每帧不清屏、靠铺满画布的不透明底盖掉上一帧，放宽后底只盖中间，两侧一直留着旧帧） ----------
        // 放宽目标的两侧带不在游戏画布里，游戏「每帧盖一遍画布」的约定管不到它。本帧被清屏 / 起页清黑 / 整张拷贝 / 计算写过 = 有确定内容；
        // 本帧第一次画到这张目标时还没有 → 调用方先把两侧带清黑（WidenSession.Draw，同起页的 PageSides），之后本帧的绘制照常往上画
        readonly Dictionary<uint, long> _sidesAt = new(), _drawnAt = new();   // 目标 → 两侧有确定内容 / 第一次被画的帧号 + 1（0 = 没有）
        public void NoteSidesWritten(uint target) { if (target != 0) _sidesAt[target] = Frames + 1; }
        public bool SidesWrittenThisFrame(uint target) => _sidesAt.TryGetValue(target, out long f) && f == Frames + 1;
        /// <summary>本帧第一次画到 target：返回 true 并记下（之后同帧返回 false）。</summary>
        public bool FirstDrawThisFrame(uint target)
        {
            if (target == 0 || _drawnAt.TryGetValue(target, out long f) && f == Frames + 1) return false;
            _drawnAt[target] = Frames + 1; return true;
        }

        // ---------- 常量写入：上传时只扫内容变了的部分 ----------
        public CbufShadow Shadow => _sh;
        /// <summary>写缓冲：有影子的部分逐 16 字节比影子，只扫变了的区间（各外扩 48 字节：碰到变了字节的 64 字节窗口、跨粒的浮点对都在里面），
        /// 没变处的命中原样保留；没影子的部分（顶点 / 索引 / 只当存储用的数据）整段扫（同旧）。返回是否有命中叠在这次上传里：
        /// dst 装得下整段（dst.Length ≥ src.Length）→ dst[..src.Length] 是要真正写进去的数据（命中处叠了改写值），调用方发 dst；
        /// 装不下（大上传，10-22 巫师3 换场景：按上传大小长的临时缓冲一帧分配约 44 MB）→ 调用方须已把 src 原样发出，这里把命中处的改写值经 patcher 逐段补写。</summary>
        public bool OnBufferData(ulong buffer, int offset, ReadOnlySpan<byte> src, Span<byte> dst, IBufferPatcher patcher = null)
        {
            if (src.Length == 0) return false;
            int end = offset + src.Length;
            CbufShadow.Buf b = ScanUpload(buffer, offset, src);
            // 与这次上传相交的命中（新登记的 + 原样保留的）把改写值叠进要发的数据
            int i0 = b.FirstHitEndingAfter(offset);
            if (i0 >= b.Hits.Count || b.Hits[i0].Lo >= end) { Check?.Forward(buffer, offset, src); ScanStraddle(buffer, b, src, offset); return false; }
            bool whole = dst.Length >= src.Length;
            if (whole) src.CopyTo(dst);
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = i0; i < hs.Length && hs[i].Lo < end; i++)
            {
                ref CbufShadow.Hit h = ref hs[i];
                int lo = Math.Max(h.Lo, offset), hi = Math.Min(h.Lo + h.Len, end);
                ReadOnlySpan<byte> nv = ((ReadOnlySpan<byte>)h.New).Slice(lo - h.Lo, hi - lo);
                if (whole) nv.CopyTo(dst[(lo - offset)..]); else patcher?.Write(buffer, lo, nv);
                h.Restored = false;   // 同旧：上传后 GPU 上是改写值，之后读到再写回
            }
            if (Check != null) Check.Forward(buffer, offset, whole ? dst[..src.Length] : Sent(src, offset, hs, i0, end));
            ScanStraddle(buffer, b, src, offset);
            return true;
        }

        /// <summary>直连模式（graphics/nvn 回放层，常量就在游戏内存里、没有上传事件）：一次绘制绑到 [offset, offset+len) 的常量。建影子、比影子、只扫变了的（同上传的判法），
        /// 但不是一次上传——没变处的命中保留原来的「暂时写回原值」状态（通用模式里数据没变就没有上传，GPU 上的内容也不变）。本笔该看到什么由 Emit 按命中状态拼出。</summary>
        public CbufShadow.Buf OnGuestBound(ulong key, int offset, ReadOnlySpan<byte> src)
        {
            if (src.Length == 0) return null;
            _sh.Cover(key, offset, src.Length);
            return ScanUpload(key, offset, src);
        }

        /// <summary>同 OnGuestBound，调用方另给 ranges：这次与上一次交给同一段的内容只可能在这些区间（相对 offset）里不同（直连胶水按影子续拼的更新段）。
        /// 影子满足 CbufShadow.WriteRanges 的前提就只比这些区间，否则照整段比；判扫结果与整段比逐项相同。</summary>
        public CbufShadow.Buf OnGuestBoundRanges(ulong key, int offset, ReadOnlySpan<byte> src, ReadOnlySpan<(int Lo, int Hi)> ranges)
        {
            if (src.Length == 0) return null;
            _sh.Cover(key, offset, src.Length);
            return ScanUpload(key, offset, src, ranges, true);
        }
        /// <summary>只比更新段的绑定次数 / 前提不满足改整段比的次数 / 校验档（S2A_WIDEN_RANGES_CHECK=1）里只比更新段之后整段再比仍有变的次数（应恒 0）。</summary>
        public long RangeBinds, RangeFallbacks, RangeCheckMiss;
        static readonly bool s_rangesCheck = Environment.GetEnvironmentVariable("S2A_WIDEN_RANGES_CHECK") == "1";

        /// <summary>直连模式出数：[offset, offset+src.Length) 这段 GPU 该看到的内容 = 游戏原值叠上没写回原值的命中的改写值。
        /// 有叠的返回叠了几处（dst[..src.Length] 已写好）；没有返回 0（照原样零拷贝绑定，dst 不碰）；要叠但 dst 装不下返回 −1（dst 不碰）。</summary>
        public int Emit(ulong key, int offset, ReadOnlySpan<byte> src, Span<byte> dst)
        {
            CbufShadow.Buf b = _sh.TryGet(key);
            if (b == null || b.Hits.Count == 0 || src.Length == 0) return 0;
            int end = offset + src.Length, n = 0;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            int i0 = b.FirstHitEndingAfter(offset);
            for (int i = i0; i < hs.Length && hs[i].Lo < end; i++) if (!hs[i].Restored) n++;
            if (n == 0) return 0;
            if (dst.Length < src.Length) return -1;
            src.CopyTo(dst);
            for (int i = i0; i < hs.Length && hs[i].Lo < end; i++)
            {
                ref readonly CbufShadow.Hit h = ref hs[i];
                if (h.Restored) continue;
                int lo = Math.Max(h.Lo, offset), hi = Math.Min(h.Lo + h.Len, end);
                ((ReadOnlySpan<byte>)h.New).Slice(lo - h.Lo, hi - lo).CopyTo(dst[(lo - offset)..]);
            }
            return n;
        }

        /// <summary>直连出数缓存的状态版本（WidenSession.StateGen）：扫描改过命中表就加一（直连路径里命中只在这里增删）。</summary>
        public long ScanGen;
        /// <summary>同段未变跳过的次数（诊断）；SameSkipMiss = 校验档里「本会跳过」却扫出命中表变化的次数（应恒 0）。</summary>
        public long SameSkips, SameSkipMiss;
        readonly List<(int Lo, int Hi)> _rangeCheck = new();
        // S2A_WIDEN_SAMESKIP_CHECK=1：照常全扫，只数「本会跳过」与其中命中表变了的次数（核同段未变跳过等价）
        static readonly bool s_sameSkipCheck = Environment.GetEnvironmentVariable("S2A_WIDEN_SAMESKIP_CHECK") == "1";

        /// <summary>比影子、扫变了的、登记命中（上传与直连绑定共用；不叠改写值、不改已有命中的写回状态）。</summary>
        CbufShadow.Buf ScanUpload(ulong buffer, int offset, ReadOnlySpan<byte> src, ReadOnlySpan<(int Lo, int Hi)> ranges = default, bool ranged = false)
        {
            int end = offset + src.Length;
            Check?.Upload(buffer, offset, src);
            CbufShadow.Buf b;
            if (ranged && _sh.WriteRanges(buffer, offset, src, ranges, _chg, out b))
            {
                RangeBinds++; UpBytes += _sh.RangeBytes;   // 「比 N KB」只记真比了的字节
                // 校验：区间以外真与影子相同时，只比区间写完后影子已等于 src，整段再比必须一处不变
                if (s_rangesCheck && _sh.Write(buffer, offset, src, _rangeCheck, out _)) RangeCheckMiss++;
            }
            else { if (ranged) RangeFallbacks++; UpBytes += src.Length; _sh.Write(buffer, offset, src, _chg, out b); }
            // 同段未变跳过：这块缓冲上一次扫的正好是这一段、之后内容版本（命中表在扫描以外的增删 / 迁移 / 作废都换版本）与相机签名都没变、这次也没变字节——
            //   要重判的只剩上次自己在头尾 48 字节置的边缘位：跨这段边界的窗口在这一段里仍判不了，段内窗口上次已判过同样的字节，重扫只会再得同样结果、白加 ScanGen
            //   （10-26 八方2 真机 xctrace：游戏渲染线程每笔绘制重绑同一段常量，扫描 + 边缘位占 nx-103 约 16%）
            bool same = _chg.Count == 0 && b.ScanLo == offset && b.ScanEnd == end && b.ScanVer == b.Version && b.ScanCam == _rw.CameraVersion;
            if (same && !s_sameSkipCheck) { SameSkips++; return b; }
            int hits0 = b.Hits.Count; long ver0 = b.Version;
            CbufShadow.EdgeRuns(b, offset, end, _edge);
            long cam0 = _rw.CameraVersion;
            if (_chg.Count > 0 || _edge.Count > 0)
            {
                ScanGen++;
                foreach (var (lo, hi) in _chg) b.DropHits(lo, hi);
                if (_chg.Count == 1 && _chg[0].Lo == offset && _chg[0].Hi == end) ScanAll(b, src, offset);   // 整段都变了（没影子 / 影子未知）：旧整段扫描（块平方快筛，整段最快）
                else
                {
                    // 没变但带边缘位的粒也重判（命中不丢：内容没变，跨这次上传边界的旧命中照样保留）
                    if (_edge.Count > 0) MergeEdges();
                    ScanChanged(b, src, offset);
                }
                // 像素射线（C' = C − pad·A、A' = k·A）只对「贴图被放宽」成立；游戏自己出宽图（GameWide）时射线本来就按宽屏算，不扫（10-24：UI 模式读数里射线命中恒 0，扫描占直连挂点约 5%）
                if (_rw.On && !GameWide) foreach (var (lo, hi) in _chg) ScanRays(b, src, offset, lo, hi);
            }
            CbufShadow.MarkEdges(b, offset, end);
            // 签名表变了：之前在没变的数据里判过没中的系数对要按新签名重判 → 影子全部作废，下次上传整段重扫
            if (_rw.CameraVersion != cam0) { _sh.InvalidateAll(); ScanGen++; }
            if (same) { SameSkips++; if (b.Hits.Count != hits0 || b.Version != ver0) SameSkipMiss++; }
            b.ScanLo = offset; b.ScanEnd = end; b.ScanVer = b.Version; b.ScanCam = _rw.CameraVersion;
            return b;
        }

        /// <summary>跨两次上传的矩阵窗口：起点在这次上传之前、终点落在这次里（前缀取影子 / 前一次上传的末尾），或起点在这次里、终点越过末尾（后缀取影子 / 后一次上传的开头）。矩阵窗口原则上要整个落在一次上传里（ScanChanged），
        /// 游戏分两次传同一块常量、两次之间缓冲还被迁移过时（10-22 暗黑2 第 10 帧：前一截传进 895、迁到 1796 后从 c[16] 起再传），投影一直认不出、GPU 上是原值，
        /// 读它的云层 / 手光按 ScaleK 画、隔几帧抖一次。认出后登记成「暂时写回原值」（GPU 上两截都是原值），由之后整块读它的放宽绘制按常规补回改写值（Reapply）。
        /// 要在叠改写值之后登记：这次上传发出去的仍是原值，与 Restored 一致。</summary>
        void ScanStraddle(ulong buffer, CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset)
        {
            if ((offset & 15) == 0) ScanStraddleCore(buffer, b, src, offset);
            b.DropTails(offset, offset + src.Length);   // 被这次盖住的旧末尾 / 开头作废（内容换了）；正好接在两端的不相交、保留
            b.NoteTail(offset + src.Length, src);   // 这次的末尾 / 开头留给之后紧接着的上传（先判后记）
            if ((offset & 15) == 0) b.NoteHead(offset, src);
        }
        void ScanStraddleCore(ulong buffer, CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset)
        {
            int end = offset + src.Length;
            Span<byte> w = stackalloc byte[64];
            // 起点在这次之前的窗口：前缀取影子里已知的粒，或正好在 offset 结束的那次上传的末尾
            for (int p = (offset - 48 + 15) & ~15; p < offset; p += 16)
            {
                if (p < 0 || p + 64 > end || b.OverlapsHit(p, p + 64)) continue;
                int pre = offset - p;
                if (pre <= 0 || pre >= 64 || !b.ReadKnown(p, pre, w) && !b.ReadTail(offset, pre, w)) continue;
                src[..(64 - pre)].CopyTo(w[pre..]);
                if (TryStraddleHit(buffer, b, w, p)) p += 48;
            }
            // 终点越过这次末尾的窗口：后缀取影子里已知的粒，或正好从 end 开始的那次上传的开头（倒序分块上传，10-22 暗黑2：先传 [1331200, …) 再传 [1327104, 1331200)）
            if ((end & 15) == 0)
                for (int p = Math.Max(offset, end - 48); p < end; p += 16)
                {
                    int suf = p + 64 - end;
                    if (b.OverlapsHit(p, p + 64)) continue;
                    if (!b.ReadKnown(end, suf, w[(64 - suf)..]) && !b.ReadHead(end, suf, w[(64 - suf)..])) continue;
                    src[(p - offset)..].CopyTo(w);
                    if (TryStraddleHit(buffer, b, w, p)) break;
                }
        }
        bool TryStraddleHit(ulong buffer, CbufShadow.Buf b, ReadOnlySpan<byte> w, int p)
        {
            ReadOnlySpan<float> m = MemoryMarshal.Cast<byte, float>(w);
            if (!_rw.QuickWindow(m) || !_rw.RewriteWindow(m, _mw, out WidenKind kind, out _)) return false;
            var h = new CbufShadow.Hit { Lo = p, Len = 64, Kind = kind, Restored = true };
            w.CopyTo(h.Orig); MemoryMarshal.AsBytes(_mw.AsSpan()).CopyTo(h.New);
            b.InsertHit(h); _restored.Add((buffer, p)); StraddleHits++;
            Observer?.Hit(p, 64, kind, false);
            return true;
        }
        /// <summary>跨两次上传认出的矩阵个数（诊断）。</summary>
        public long StraddleHits;

        readonly List<(int Lo, int Hi)> _edge = new();
        readonly List<(int Lo, int Hi)> _mrg = new();

        /// <summary>_chg 与 _edge 各自按 Lo 升序：归并成按 Lo 升序的 _chg。不用 List.Sort：值元组排序在 NativeAOT 下每次分配 48 B
        /// （JIT 下不分配，回放 / 单测看不到；10-22 暗黑2 实机编码线程每帧约 29 KB）。</summary>
        void MergeEdges()
        {
            _mrg.Clear();
            int i = 0, j = 0;
            while (i < _chg.Count || j < _edge.Count)
                _mrg.Add(j >= _edge.Count || (i < _chg.Count && _chg[i].Lo <= _edge[j].Lo) ? _chg[i++] : _edge[j++]);
            _chg.Clear(); _chg.AddRange(_mrg);
        }
        readonly float[] _mw = new float[16], _fw = new float[4];
        static readonly Vector128<float> s_aLo = Vector128.Create(WidenRewriter.SrcAspect * (1 - 2e-4f)), s_aHi = Vector128.Create(WidenRewriter.SrcAspect * (1 + 2e-4f));

        /// <summary>只判碰到变了字节的单元（同旧整段扫描的判据与顺序：先矩阵、后浮点；矩阵窗口要整个落在这次上传里，同旧）：
        /// 变了的区间 [lo, hi) → 矩阵窗口起点 [lo−48, hi−16]（缓冲内 16 字节对齐）、浮点位置 [lo−4, hi)（4 字节对齐）。碰到已有命中的跳过。</summary>
        void ScanChanged(CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset)
        {
            int end = offset + src.Length, done = int.MinValue;
            int first = (offset + 15) & ~15, k = -1;   // k：命中表游标（OverlapsHitFrom；p 单调不减，登记命中后置 −1）
            foreach (var (lo, hi) in _chg)
            {
                int p = Math.Max(Math.Max(first, (lo - 48 + 15) & ~15), done), last = Math.Min(hi - 16, end - 64);
                for (; p <= last; p += 16)
                {
                    ScanBytes += 16;
                    ReadOnlySpan<float> m = MemoryMarshal.Cast<byte, float>(src.Slice(p - offset, 64));
                    if (!_rw.QuickWindow(m) || b.OverlapsHitFrom(ref k, p, p + 64)) continue;
                    if (!_rw.RewriteWindow(m, _mw, out WidenKind kind, out bool col)) continue;
                    AddHit(b, src, offset, p, 64, kind, MemoryMarshal.AsBytes(_mw.AsSpan())); k = -1;
                    p += 48;   // 之后三个窗口与它重叠（同旧命中后跳过）
                }
                done = Math.Max(done, p);
            }
            _rw.PrepareFloatFilter();
            var cLo = Vector128.Create(_rw.FilterMin); var cHi = Vector128.Create(_rw.FilterMax);
            int fdone = int.MinValue, fFirst = (offset + 3) & ~3; k = -1;
            foreach (var (lo, hi) in _chg)
            {
                int q = Math.Max(Math.Max(fFirst, (lo - 4) & ~3), fdone), qe = Math.Min(hi, end - 7);
                for (; q < qe; q += 4)
                {
                    int i = q - offset;
                    // 整粒快筛：4 个位置首元素都不在宽高比 / 签名范围、第 0 / 2 个浮点也不像屏幕宽 → 跳过这粒
                    if ((q & 15) == 0 && i + 16 <= src.Length)
                    {
                        ReadOnlySpan<float> g4 = MemoryMarshal.Cast<byte, float>(src.Slice(i, 16));
                        var x = Vector128.Create(g4);
                        bool any = ((Vector128.GreaterThanOrEqual(x, s_aLo) & Vector128.LessThanOrEqual(x, s_aHi)) | (Vector128.GreaterThanOrEqual(x, cLo) & Vector128.LessThanOrEqual(x, cHi))) != Vector128<float>.Zero
                            || (g4[0] >= 16 && g4[0] <= 16384) || (g4[2] >= 16 && g4[2] <= 16384) || WidenRewriter.IntMaxLead(g4[0]);
                        if (!any) { q += 12; continue; }
                    }
                    ScanBytes += 4;
                    int nf = Math.Min(4, (src.Length - i) >> 2);
                    ReadOnlySpan<float> v = MemoryMarshal.Cast<byte, float>(src.Slice(i, nf * 4));
                    bool al = (q & 15) == 0;
                    if (!_rw.QuickFloat(v[0], nf > 2 ? v[2] : 0, al && nf == 4) || b.OverlapsHitFrom(ref k, q, q + 8)) continue;
                    if (nf == 4 && b.OverlapsHitFrom(ref k, q, q + 16)) nf = 2;
                    int len = _rw.RewriteFloats(v[..nf], al, _fw, out WidenKind kind);
                    if (len == 0) continue;
                    AddHit(b, src, offset, q, len, kind, MemoryMarshal.AsBytes(_fw.AsSpan())[..len]); k = -1;
                    q += len - 4;
                }
                fdone = Math.Max(fdone, q);
            }
        }

        /// <summary>像素射线基（WidenRewriter.RayBasis / RewriteRayOrigin / RewriteRayStep）：变了的区间附近找相邻两行步长 A、B，再在 A 前两行到后四行里找左上像素射线 C，
        /// C、A 两行各登记一条命中（16 字节：C' = C − pad·A、A' = k·A）。三行都要在这次上传里（同矩阵窗口）。只变了 A 或只变了 C 时另一行上的旧命中不会被 DropHits 丢掉，按新值重算替换。</summary>
        void ScanRays(CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset, int lo, int hi)
        {
            int end = offset + src.Length, first = (offset + 15) & ~15;
            // A 在 p、B 在 p+16、C 最远在 p−32 / p+80：碰到 [lo, hi) 的 p 在 (lo − 96, hi + 32)
            for (int p = Math.Max(first, (lo - 80) & ~15); p < hi + 32 && p + 32 <= end; p += 16)
            {
                ReadOnlySpan<float> a = MemoryMarshal.Cast<byte, float>(src.Slice(p - offset, 16));
                if (!_rw.RayBasis(a, MemoryMarshal.Cast<byte, float>(src.Slice(p + 16 - offset, 16)), out int w, out int h, out float tx, out float ty)) continue;
                foreach (int d in s_rayRows)
                {
                    int c = p + 16 * d;
                    if (c < first || c + 16 > end) continue;
                    int k = b.FirstHitEndingAfter(c);
                    bool old = k < b.Hits.Count && b.Hits[k].Lo < c + 16;
                    if (old && (b.Hits[k].Kind != WidenKind.PixelRay || b.Hits[k].Lo != c)) continue;
                    if (!_rw.RewriteRayOrigin(a, MemoryMarshal.Cast<byte, float>(src.Slice(c - offset, 16)), w, h, tx, ty, _fw)) continue;
                    if (old) b.Hits.RemoveAt(k);
                    AddHit(b, src, offset, c, 16, WidenKind.PixelRay, MemoryMarshal.AsBytes(_fw.AsSpan()));
                    int ka = b.FirstHitEndingAfter(p);
                    if (ka < b.Hits.Count && b.Hits[ka].Lo < p + 16) { if (b.Hits[ka].Kind != WidenKind.PixelStep || b.Hits[ka].Lo != p) break; b.Hits.RemoveAt(ka); }
                    _rw.RewriteRayStep(a, _fw);
                    AddHit(b, src, offset, p, 16, WidenKind.PixelStep, MemoryMarshal.AsBytes(_fw.AsSpan()));
                    break;
                }
            }
        }
        static readonly int[] s_rayRows = { 2, 3, 4, 5, -1, -2 };

        void AddHit(CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset, int lo, int len, WidenKind kind, ReadOnlySpan<byte> neu)
        {
            var h = new CbufShadow.Hit { Lo = lo, Len = len, Kind = kind };
            src.Slice(lo - offset, len).CopyTo(h.Orig); neu.CopyTo(h.New);
            if (_collect != null) _collect.Add(h); else b.InsertHit(h);
            Observer?.Hit(lo, len, kind, false);
        }
        void IWidenHitSink.Hit(int off, int len, WidenKind kind, bool col) => _pending.Add((off, len, kind));

        /// <summary>整段扫描按块（ScanChunk 字节、后面多带 64 字节重叠：跨块的 64 字节矩阵窗口与 16 字节浮点条目在前一块里整个看得到）：临时缓冲与改写器的块平方数组都按块，
        /// 不随上传大小涨（10-22 巫师3 换场景第一次来十几 MB 的上传：旧做法按整段长 _tmp 与块平方数组，编码线程一帧分配约 44 MB）。
        /// 每块只收起点在本块里的命中；与前一块已收命中相交的不收（同整段扫描命中后跳过重叠窗口）。</summary>
        // S2A_WIDEN_HIT_BATCH=1（缺省关，测试机2 同包 A/B 后翻）：ScanAll 的命中先攒起来、扫完一次插入（见 CbufShadow.Buf.InsertHits）
        static readonly bool s_hitBatch = Environment.GetEnvironmentVariable("S2A_WIDEN_HIT_BATCH") == "1";
        readonly List<CbufShadow.Hit> _batch = new();
        List<CbufShadow.Hit> _collect;
        void ScanAll(CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset)
        {
            if (!s_hitBatch) { ScanAllCore(b, src, offset); return; }
            _batch.Clear(); _collect = _batch;
            try { ScanAllCore(b, src, offset); }
            finally { _collect = null; }
            b.InsertHits(_batch);
            _batch.Clear();
        }
        void ScanAllCore(CbufShadow.Buf b, ReadOnlySpan<byte> src, int offset)
        {
            ScanBytes += src.Length;
            int doneEnd = int.MinValue;
            for (int c0 = 0; c0 < src.Length; c0 += ScanChunk)
            {
                int c1 = Math.Min(src.Length, c0 + ScanChunk), e = Math.Min(src.Length, c1 + 64);
                _pending.Clear();
                ReadOnlySpan<byte> s = src[c0..e]; Span<byte> t = _tmp.AsSpan(0, s.Length);
                if (!_rw.Rewrite(s, offset + c0, t, this)) continue;
                int last = doneEnd;
                foreach (var (off, len, kind) in _pending)
                {
                    if (off >= offset + c1 || off < doneEnd) continue;
                    AddHit(b, src, offset, off, len, kind, t.Slice(off - offset - c0, len));
                    last = Math.Max(last, off + len);
                }
                doneEnd = last;
            }
        }
        const int ScanChunk = 64 * 1024;
        /// <summary>把与 [offset, offset+length) 相交的命中的改写值经 patcher 逐段写出（不扫描、不改登记状态）。给「数据交出去后就不能再读」的上传用
        /// （帧率能耗线上传租约：内层拷完当场还租约，> 1 MB 的独立缓冲随之释放）：先 OnBufferData(…, default, null) 只扫描登记，交出数据，再调它补写。</summary>
        public void WriteHits(ulong buffer, int offset, int length, IBufferPatcher patcher)
        {
            CbufShadow.Buf b = _sh.TryGet(buffer);
            if (b == null || patcher == null) return;
            int end = offset + length;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = b.FirstHitEndingAfter(offset); i < hs.Length && hs[i].Lo < end; i++)
            {
                int lo = Math.Max(hs[i].Lo, offset), hi = Math.Min(hs[i].Lo + hs[i].Len, end);
                patcher.Write(buffer, lo, ((ReadOnlySpan<byte>)hs[i].New).Slice(lo - hs[i].Lo, hi - lo));
            }
        }
        /// <summary>补写方式下给对照（Check）拼「发出去的整段」：原样 + 命中处改写值（只在测试挂对照时用）。</summary>
        byte[] Sent(ReadOnlySpan<byte> src, int offset, Span<CbufShadow.Hit> hs, int i0, int end)
        {
            byte[] o = src.ToArray();
            for (int i = i0; i < hs.Length && hs[i].Lo < end; i++)
            {
                int lo = Math.Max(hs[i].Lo, offset), hi = Math.Min(hs[i].Lo + hs[i].Len, end);
                ((ReadOnlySpan<byte>)hs[i].New).Slice(lo - hs[i].Lo, hi - lo).CopyTo(o.AsSpan(lo - offset));
            }
            return o;
        }

        /// <summary>绑成常量缓冲（包装层 SetUniformBuffers 时调）：给这段建影子（按 4 KB 页）。</summary>
        public void OnUniformBound(ulong buffer, int offset, int size) => _sh.Cover(buffer, offset, size);
        /// <summary>缓冲间拷贝：目标那段换成源在 GPU 上的内容——影子作废、源里整个落在拷贝区间的命中搬过去（CbufShadow.CopyHits，暂时写回原值的登记待补回）。
        /// 清缓冲：命中丢掉、影子作废。</summary>
        public void OnCopyBuffer(ulong src, ulong dst, int srcOffset, int dstOffset, int size) { _sh.CopyHits(src, dst, srcOffset, dstOffset, size, _restored); Check?.Copy(src, dst, srcOffset, dstOffset, size); }
        public void OnClearBuffer(ulong buffer, int offset, int size, uint value) { _sh.Overwritten(buffer, offset, size); Check?.Clear(buffer, offset, size, value); }
        public void OnDeleteBuffer(ulong buffer)
        {
            _sh.Delete(buffer);
            int n = 0;
            for (int i = 0; i < _restored.Count; i++) if (_restored[i].Buf != buffer) _restored[n++] = _restored[i];
            _restored.RemoveRange(n, _restored.Count - n);
            Check?.Delete(buffer);
        }

        /// <summary>这块绑定里着色器会读到的部分是否含改写过的矩阵（投影 / 视图投影 / 逆投影）。</summary>
        public bool ReadsRewritten(ulong buffer, int offset, int size, CbufUse use)
        {
            CbufShadow.Buf b = _sh.TryGet(buffer);
            if (b == null || b.Hits.Count == 0) return false;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = b.FirstHitEndingAfter(offset); i < hs.Length && hs[i].Lo < offset + size; i++)
            {
                ref readonly CbufShadow.Hit h = ref hs[i];
                // 矩阵要整个落在这次绑定区间里才算这次绘制的（10-21 暗黑2：流式常量缓冲里场景的「正交 × 视图」紧挨在界面那块之前、尾 16 字节伸进界面绑定，
                // 界面着色器按动态下标整段读 → 判成读到放宽矩阵、整层按 Hor 拉宽，场景矩阵恰好紧挨的帧界面就跳：「UI 帧级被拉伸和回放」）
                if (h.Kind <= WidenKind.InverseProjection && !h.Restored && h.Lo >= offset && h.Lo + h.Len <= offset + size && use.Reads(offset, size, h.Lo, h.Lo + h.Len)) return true;
            }
            return false;
        }

        /// <summary>这些绑定读到了改写过的镜头量（投影 / 视图投影 / 逆投影，或相机系数对 / 宽高比常量对——改了投影的横向缩放）：几何按原尺寸画在放宽目标中间（不论画法判成 Hor 还是 ScaleK）。
        /// 10-29 马车8 选轮胎页蓝底：透视投影 P00 1.358 / P11 2.4142 被当相机系数对改成 P00 ÷ K，不算「读改写矩阵」，画法判成 ScaleK，几何却只占中间 16:9。</summary>
        public bool ReadsCamScale(ReadOnlySpan<CbufRead> reads)
        {
            foreach (ref readonly CbufRead r in reads)
            {
                if (r.Use == null) continue;
                CbufShadow.Buf b = _sh.TryGet(r.Buffer);
                if (b == null || b.Hits.Count == 0) continue;
                Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
                for (int i = b.FirstHitEndingAfter(r.Offset); i < hs.Length && hs[i].Lo < r.Offset + r.Size; i++)
                {
                    ref readonly CbufShadow.Hit h = ref hs[i];
                    if (!(h.Kind <= WidenKind.AspectPair || h.Kind == WidenKind.CameraPair) || h.Restored || h.Lo < r.Offset || h.Lo + h.Len > r.Offset + r.Size) continue;
                    if (r.Use.Reads(r.Offset, r.Size, h.Lo, h.Lo + h.Len)) return true;
                }
            }
            return false;
        }

        /// <summary>这块绑定里着色器会读到的部分是否含界面正交投影（WidenRewriter.IsUiOrtho：像素空间画布，只登记不改）。</summary>
        /// <summary>这些绑定里有没有整段读到某类只登记的命中（UiOrthoWide 等）。</summary>
        bool ReadsKind(ReadOnlySpan<CbufRead> reads, WidenKind kind)
        {
            foreach (ref readonly CbufRead r in reads)
            {
                if (r.Use == null) continue;
                CbufShadow.Buf b = _sh.TryGet(r.Buffer);
                if (b == null || b.Hits.Count == 0) continue;
                Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
                for (int i = b.FirstHitEndingAfter(r.Offset); i < hs.Length && hs[i].Lo < r.Offset + r.Size; i++)
                {
                    ref readonly CbufShadow.Hit h = ref hs[i];
                    if (h.Kind == kind && h.Lo >= r.Offset && h.Lo + h.Len <= r.Offset + r.Size && r.Use.Reads(r.Offset, r.Size, h.Lo, h.Lo + h.Len)) return true;
                }
            }
            return false;
        }
        /// <summary>这次绑定读到游戏自己已按屏幕比算的镜头（WidenKind.WideProjection，只登记不改写）：按它画的 3D 笔按 k 放宽视口不拉伸。</summary>
        public bool ReadsWideProjection(ulong buffer, int offset, int size, CbufUse use)
        {
            CbufShadow.Buf b = _sh.TryGet(buffer);
            if (b == null || b.Hits.Count == 0) return false;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = b.FirstHitEndingAfter(offset); i < hs.Length && hs[i].Lo < offset + size; i++)
            {
                ref readonly CbufShadow.Hit h = ref hs[i];
                if (h.Kind == WidenKind.WideProjection && h.Lo >= offset && h.Lo + h.Len <= offset + size && use.Reads(offset, size, h.Lo, h.Lo + h.Len)) return true;
            }
            return false;
        }
        public bool ReadsUiOrtho(ulong buffer, int offset, int size, CbufUse use)
        {
            CbufShadow.Buf b = _sh.TryGet(buffer);
            if (b == null || b.Hits.Count == 0) return false;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = b.FirstHitEndingAfter(offset); i < hs.Length && hs[i].Lo < offset + size; i++)
            {
                ref readonly CbufShadow.Hit h = ref hs[i];
                if (h.Kind == WidenKind.UiOrtho && h.Lo >= offset && h.Lo + h.Len <= offset + size && use.Reads(offset, size, h.Lo, h.Lo + h.Len)) return true;   // 同上：整个落在绑定里
            }
            return false;
        }

        // ---------- 管线状态 ----------
        public void OnRenderTargets(uint color0, uint depth)
        {
            _rt0 = color0;
            if (GameWide) return;   // 原生宽与否按每次绘制的视口判（OnViewport）
            _rtNative = false;
            // 颜色目标 0 的存储放不宽（OnFixedTexture）：整遍按原宽画，不看深度目标
            if (color0 != 0 && _fixed.Contains(color0)) { _tallRtH0 = _tallRtH1 = 0; _rtCornerW = 0; _wideRtW0 = _wideRtW1 = 0; return; }
            if (!TryTall(color0, out _tallRtH0, out _tallRtH1) && !TryTall(depth, out _tallRtH0, out _tallRtH1)) _tallRtH0 = _tallRtH1 = 0;
            _rtCornerW = 0;
            if (TryWide(color0, out _wideRtW0, out _wideRtW1)) { _cornerW.TryGetValue(color0, out _rtCornerW); return; }
            if (TryWide(depth, out _wideRtW0, out _wideRtW1)) { _cornerW.TryGetValue(depth, out _rtCornerW); return; }
            uint n = _native.ContainsKey(color0) ? color0 : _native.ContainsKey(depth) ? depth : 0;
            if (n != 0) { _rtNative = true; _wideRtW0 = _native[n]; _wideRtW1 = (int)Math.Round(_wideRtW0 * (double)_rw.K); return; }
            _wideRtW0 = _wideRtW1 = 0;
        }
        public bool TargetWide => _wideRtW1 != 0;
        int _tallRtH0, _tallRtH1;   // 当前目标的原高 / 放高高（窄屏；没加高为 0）
        public int TargetH0 => _tallRtH0;
        public int TargetH1 => _tallRtH1;
        /// <summary>当前目标的纵向放高比（窄屏加高的目标；否则 null）。</summary>
        public float? TargetScaleY => _tallRtH1 != 0 ? (float)_tallRtH1 / _tallRtH0 : null;
        /// <summary>当前目标的横向放宽比（未放宽返回 null）。</summary>
        public float? TargetScaleX => _wideRtW1 != 0 ? (_rtNative ? 1f : (float)_wideRtW1 / _wideRtW0) : null;   // 原生宽：片元坐标本来就是游戏坐标
        public bool TargetNative => _rtNative;
        public uint Target0 => _rt0;   // 当前颜色目标 0
        public int TargetW0 => _wideRtW0;   // 当前放宽目标的原宽（客体宽）；没放宽为 0
        // 当前目标放宽后的宽 / 原生宽区域左边（GameWide：视口 0 的左边；否则 0）
        public int TargetW1 => _wideRtW1;
        public float NativeX => _rtNative ? _vpX : 0f;
        public void OnFragmentTexture(int binding, uint tex) { if ((uint)binding < (uint)_fragTex.Length) { _fragTex[binding] = tex; if (tex != 0 && binding >= _fragHi) _fragHi = binding + 1; } }

        /// <summary>每次绘制前调用：reads = 本次绘制各常量绑定（缓冲、区间、读法）。必要时经 patcher 写回原值 / 改写值。返回视口换算方式。</summary>
        public ViewportMode OnDraw(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, out DrawClass cls) => OnDraw(reads, patcher, out cls, false);

        /// <param name="page">本次绘制属 16:9 原比例页（包装层按「采样整画布 16:9 图片」判出、BeginPage 登记过）：同没放宽的目标一样把读到的改写常量写回原值，返回 Page</param>
        public ViewportMode OnDraw(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, out DrawClass cls, bool page) => OnDraw(reads, patcher, out cls, page, false);

        /// <param name="fragY">本次绘制的程序读片元坐标（y 已去缩放、包装层按目标放宽比写 render_scale[0]）：放宽目标上按 ScaleK / Hor 画时它看到的是客体 x 坐标，
        /// 读到的屏幕尺寸常量要是原值（10-22 巫师3：屏幕尺寸 1280 → 1564 再叠上片元坐标 ÷ k，屏幕空间算法取图只覆盖 0..0.82 → 整幅放大 + 重影）；
        /// 计算着色器、不读片元坐标的程序看到的是真实宽像素，照用改写值</param>
        public ViewportMode OnDraw(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, out DrawClass cls, bool page, bool fragY)
        {
            _guestX = fragY;
            ViewportMode m = OnDrawCore(reads, patcher, out cls, page);
            if (m is ViewportMode.ScaleK or ViewportMode.Hor or ViewportMode.CenterNative)   // 放宽目标（没放宽 / 原比例页已在 OnDrawCore 整个写回原值）
            {
                bool gx = fragY && !_rtNative && m != ViewportMode.CenterNative;
                if (fragY && !gx && _restored.Count > 0) Reapply(patcher, reads, false);   // 最终不按客体坐标画：之前为它留着原值的屏幕尺寸补回改写值
                foreach (ref readonly CbufRead r in reads) RestoreFor(r, reads, patcher, gx);
            }
            _guestX = false;
            return m;
        }
        bool _guestX;

        /// <summary>最近一次绘制在放宽目标上读到了改写过的镜头矩阵（没放宽的目标 / 原比例页内的绘制为 false）：包装层据此记内容来历 CamContent。</summary>
        public bool DrawReadCam;
        /// <summary>这些绑定读到改写过的镜头矩阵（计算派发用，同 OnDraw 的判法）。</summary>
        public bool ReadsCam(ReadOnlySpan<CbufRead> reads)
        {
            foreach (ref readonly CbufRead r in reads) if (r.Use != null && ReadsRewritten(r.Buffer, r.Offset, r.Size, r.Use)) return true;
            return false;
        }

        /// <summary>写深度 3D 笔旁路（WidenSession.DrawLight）可用：游戏自出宽图（GameWide）、目标是原生宽区域、整幅（不是子视口）、不是出图目标（出图目标第一笔要动 _outFresh）。</summary>
        public bool LightTarget => GameWide && _rtNative && !_subVp && _rt0 != 0 && _rt0 != _out && !(_dbl && _outs.Contains(_rt0)) && Check == null;
        /// <summary>旁路笔的记账：与这类笔走全量 OnDrawCore 判出 ScaleK 时改的状态一一对应（Draws / 上一笔目标与采样表 / _gwDrawn / _gwLastMode / 页来源）。
        /// 全量路径里没写到的那几处（Reapply、读改写统计）只在这笔读到命中时才有，旁路前提是不读（WidenSession 校验档逐笔核）。</summary>
        public void OnDrawLight()
        {
            Draws++; DrawReadCam = false; DrawsWide++;
            _lastDrawRt = _rt0; _fragTex.AsSpan(0, _fragHi).CopyTo(_lastDrawTex);
            _gwDrawn.Add(_rt0); _gwLastMode[_rt0] = ViewportMode.ScaleK;
            if (SamplesPageSource()) _pageSources.Add(_rt0); else _pageSources.Remove(_rt0);
        }

        ViewportMode OnDrawCore(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, out DrawClass cls, bool page)
        {
            ViewportMode m = OnDrawMode(reads, patcher, out cls, page);
            if (GameWide && _rtNative && !_subVp && _rt0 != 0) _gwLastMode[_rt0] = m;   // 铺满区域的绘制：记下界面层当前方式（子视口跟它走）
            // 页来源传播（按内容记、不按帧号）：ScaleK（全屏合成）采样了页来源 → 标当前目标为页来源；Hor（新 3D 场景）→ 清标记；其余（Page / CenterNative / Keep）不变
            if (_rt0 != 0)
            {
                if (m == ViewportMode.Hor) _pageSources.Remove(_rt0);
                else if (m == ViewportMode.ScaleK) { if (SamplesPageSource()) _pageSources.Add(_rt0); else _pageSources.Remove(_rt0); }
            }
            return m;
        }
        readonly Dictionary<uint, ViewportMode> _gwLastMode = new();
        ViewportMode OnDrawMode(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, out DrawClass cls, bool page)
        {
            Draws++; DrawReadCam = false;
            Check?.Draw(reads);
            if (_rt0 != 0) { _lastDrawRt = _rt0; _fragTex.AsSpan(0, _fragHi).CopyTo(_lastDrawTex); }   // [_fragHi, 256) 两边都恒为 0
            if (!TargetWide || page && !_rtNative)
            {
                foreach (ref readonly CbufRead r in reads) RestoreOriginals(r, patcher);
                if (TargetWide) { DrawsWide++; DrawsPage++; cls = DrawClass.Scene; return ViewportMode.Page; }
                cls = DrawClass.NotWide; return ViewportMode.Keep;
            }
            if (_restored.Count > 0) Reapply(patcher, reads, _guestX && !_rtNative);
            if (GameWide && _rt0 != 0) _gwDrawn.Add(_rt0);
            DrawsWide++;
            bool cov = false;
            foreach (ref readonly CbufRead r in reads) if (r.Use != null && ReadsRewritten(r.Buffer, r.Offset, r.Size, r.Use)) { cov = true; break; }
            // GameWide 原生宽区域里的子视口（见 OnViewport）= 界面元素：读到的改写值全部写回原值（同原比例页：子视口里的小 3D 物件如暗黑3 怒气液体球
            // 按自己的透视画，不用宽镜头），视口 / 裁剪同界面层原尺寸居中。读改写矩阵也照此——否则按 Hor 留在游戏坐标，和居中的框错开 142
            // 跟同一目标上最近一次铺满区域的绘制（界面层的框 / 底）走：它原尺寸居中，子视口也居中；它没居中（按游戏坐标画），子视口也不动（同改前：写回原值、视口原样）
            if (_subVp)
            {
                foreach (ref readonly CbufRead r in reads) RestoreOriginals(r, patcher);
                DrawReadCam = false; DrawsSubViewport++;
                if (_gwLastMode.TryGetValue(_rt0, out ViewportMode lm) && lm == ViewportMode.CenterNative) { cls = DrawClass.Hud; DrawsHud++; DrawsHudCentered++; DrawsSubCentered++; return ViewportMode.CenterNative; }
                cls = DrawClass.NotWide; return ViewportMode.Keep;
            }
            if (cov) DrawsCovered++;
            DrawReadCam = cov;
            if (_rt0 != 0 && (_rt0 == _out || _dbl && _outs.Contains(_rt0)))
            {
                if (_outFresh.Remove(_rt0)) { cls = DrawClass.FirstToOut; return ViewportMode.ScaleK; }
                // 采样了放宽一族贴图的（读的是场景画面本身）= 第一次合成之后的又一道全屏后处理（调色 / 抗锯齿 / 合成），不是界面层（界面层采样界面图集）：按 k 铺满。
                //   10-25 数码宝贝 GL 第三层：第二道全屏合成被判成界面层原宽居中，中间一块 16:9、两侧拼着下面那层，竖接缝
                if (!cov && SamplesWide()) { cls = DrawClass.Scene; DrawsOutPost++; return ViewportMode.ScaleK; }
                // 读宽排版界面正交（WidenRewriter.IsUiOrthoWide：画布 = 放宽后的屏幕比）= 游戏按宽分辨率自己排的界面，坐标已经铺满原生宽区域：原样画，不收回中间 16:9。
                //   10-26 暗黑2 直连菜单（第二层自动表，flags 0x5 没有 LAYOUT 位）：2085 笔被收进中间 1280，右侧露黑 160 像素、界面不居中，菜单认不出
                if (!cov && ReadsKind(reads, WidenKind.UiOrthoWide)) { cls = DrawClass.Scene; DrawsUiWide++; return ViewportMode.ScaleK; }
                cls = DrawClass.Hud; DrawsHud++;
                if (cov) return ViewportMode.Hor;
                DrawsHudCentered++;
                return ViewportMode.CenterNative;
            }
            // 界面层（画在单独的界面目标上、最后才合成：10-21 暗黑2）：读界面正交投影、没读改写矩阵、片元贴图里没有放宽贴图（图集，不是整屏后处理）→ 原尺寸居中，不按 k 拉宽。
            // 原尺寸居中与放宽后的世界逐点对齐（两者都把 16:9 画面原比例放进中间），世界坐标换算出的界面元素（头顶血条等）不错位
            if (!cov && !SamplesWide())
                foreach (ref readonly CbufRead r in reads)
                    if (r.Use != null && ReadsUiOrtho(r.Buffer, r.Offset, r.Size, r.Use)) { cls = DrawClass.Hud; DrawsHud++; DrawsHudCentered++; DrawsUiLayer++; return ViewportMode.CenterNative; }
            cls = DrawClass.Scene;
            if (cov) return ViewportMode.Hor;
            // 没读到改写镜头、没采样放宽贴图、采样了没放宽且不属 16:9 一族的渲染目标（游戏按原比例画的特效离屏层）：原尺寸居中，与按 Hor 放宽的世界逐点对齐。
            //   按 k 整幅拉宽会把原比例内容以中心为轴往外拉开：11-02 你裁我剪登场光晕（离屏 1024×512）合成笔带模型缩放的透视矩阵，改写器有时认不出，
            //   认出的帧按 Hor 对齐、认不出的帧按 ScaleK 拉开 1.22 倍，角色旁一闪一闪多出淡紫色副本。横向无细节的层（泛光等）照旧由推满规则铺满宽屏
            if (DrawSamplesNarrowRt && !SamplesWide()) { DrawsNarrowCentered++; return ViewportMode.CenterNative; }
            return ViewportMode.ScaleK;
        }
        /// <summary>本次绘制采样了已登记但没放宽的渲染目标（WidenSession.Draw 按实际采样的贴图填）。</summary>
        public bool DrawSamplesNarrowRt;
        public long DrawsNarrowCentered;

        /// <summary>本次绘制是否采样放宽 / 整屏贴图：包装层按当前程序实际采样的绑定算好填进来（槽位里可能留着上一次绘制的旧绑定，10-21 暗黑2 界面层因此全被挡）；
        /// 没填（单独用 WidenFrame）时按槽位判。</summary>
        public bool? DrawSamplesWide;
        bool SamplesWide()
        {
            if (DrawSamplesWide is bool v) return v;
            foreach (uint t in _fragTex.AsSpan(0, _fragHi)) if (t != 0 && (IsWide(t) || IsNative(t) || IsScreenCopy(t))) return true;
            return false;
        }

        /// <summary>本次绘制片元采样的贴图里有页来源（页目标本身或从页目标传播来的合成目标），且没有内容不是页的放宽贴图（真宽的场景 / 后处理，同包装层来源②的排除）。</summary>
        bool SamplesPageSource()
        {
            bool any = false;
            foreach (uint t in _fragTex.AsSpan(0, _fragHi))
            {
                if (t == 0) continue;
                if (_pageSources.Contains(t)) any = true;
                else if (IsWide(t) || IsNative(t) || IsScreenCopy(t)) return false;
            }
            return any;
        }

        /// <summary>贴图 tex 的内容是原比例页（页 → 合成链传播）：上屏时用，对应 s2a_widen_present 返回 1。</summary>
        public bool IsPageSource(uint tex) => _pageSources.Contains(tex);
        /// <summary>贴图拷贝 / 解析把源的内容整个搬到目的：目的的「页来源」随源（11-02 马里奥和索尼克东京2020：原比例页起在画布 3、每帧拷进交换链 1 / 2，
        /// 上屏的交换链认不出是页 → 判据报黑带红，自动分层分不了）。源是页来源就标目的，不是就清</summary>
        public void OnCopyPageSource(uint dst, bool srcIsPage) { if (srcIsPage) _pageSources.Add(dst); else _pageSources.Remove(dst); }

        // ---------- 上屏两侧来历（同包装层 WidenTexture.Bands，10-28 八方2 直连读档页） ----------
        // 按内容记、不按帧号：放宽目标被铺满画布的 Hor 绘制（含收缩后推满宽屏的纯色底）画过，或被采样了带标记贴图的铺满画布 ScaleK 画过 → 两侧是放宽内容画的；
        // 清屏 / 释放作废。上屏贴图带标记 → s2a_widen_present 返回 2（出图层只免纯黑带，贴边暗带照判）
        readonly HashSet<uint> _bands = new();
        public void MarkBands(uint target) { if (target != 0) _bands.Add(target); }
        public bool IsBands(uint tex) => _bands.Contains(tex);

        void RestoreOriginals(in CbufRead r, IBufferPatcher patcher) => RestoreOriginals(r, patcher, null);
        /// <summary>原画框外推的绘制（10-23 马车8：外推片元看到的是原画框坐标，中间区与 k=1 相同，读到的逆投影 / 屏幕尺寸等镜头常量却是放宽改写值，
        /// 按片元坐标重建的视线横向差 K 倍，反光 / 高光错位）：这笔读到的改写命中一律写回原值（之后要改写值的绘制照常补回）。</summary>
        public void RestoreForExtrap(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher) { foreach (ref readonly CbufRead r in reads) RestoreOriginals(r, patcher); }
        /// <param name="only">只写回这一种命中（null = 全部）</param>
        void RestoreOriginals(in CbufRead r, IBufferPatcher patcher, WidenKind? only)
        {
            if (r.Use == null) return;
            CbufShadow.Buf b = _sh.TryGet(r.Buffer);
            if (b == null || b.Hits.Count == 0) return;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = b.FirstHitEndingAfter(r.Offset); i < hs.Length && hs[i].Lo < r.Offset + r.Size; i++)
            {
                ref CbufShadow.Hit h = ref hs[i];
                if (h.Restored || only is WidenKind k && h.Kind != k || !r.Use.Reads(r.Offset, r.Size, h.Lo, h.Lo + h.Len)) continue;
                patcher?.Write(r.Buffer, h.Lo, ((ReadOnlySpan<byte>)h.Orig)[..h.Len]);
                h.Restored = true; Restores++;
                _restored.Add((r.Buffer, h.Lo));
            }
        }

        /// <summary>写回过原值的命中改回改写值；本次绘制要原值的（NeedsOriginal）留着。</summary>
        void Reapply(IBufferPatcher patcher, ReadOnlySpan<CbufRead> reads, bool guestX)
        {
            int n = 0;
            for (int e = 0; e < _restored.Count; e++)
            {
                var (buf, lo) = _restored[e];
                CbufShadow.Buf b = _sh.TryGet(buf);
                if (b == null) continue;
                int i = b.FirstHitEndingAfter(lo);
                Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
                if (i >= hs.Length || hs[i].Lo != lo || !hs[i].Restored) continue;
                ref CbufShadow.Hit h = ref hs[i];
                if (NeedsOriginal(h, buf, reads, guestX)) { _restored[n++] = (buf, lo); continue; }
                patcher?.Write(buf, h.Lo, ((ReadOnlySpan<byte>)h.New)[..h.Len]);
                h.Restored = false; Reapplies++;
            }
            _restored.RemoveRange(n, _restored.Count - n);
        }
        /// <summary>放宽目标上这次绘制读这个命中时要不要原值：
        /// ① 有绑定只读到它的一部分（命中跨绑定边界，或整个在绑定里但着色器只读其中几个 vec4）、没有绑定整块读它——只读到一截的多半不是在用这个矩阵（10-22 暗黑2 场景闪烁：流式常量缓冲里
        ///    3 列旧相机残留 + 新写的逐材质块首个 vec4 (0.4,0,1,1) 凑成「正交 × 视图」被改写，材质块绑定只盖住末 16 字节，地面系数 0.4 → 0.327，约 1/3 帧变暗）；
        ///    例外：命中整个在绑定里、改写动过的每个 vec4 都读到了（ReadsChanged）——用的就是改写的那部分（10-22 暗黑2 人物界面光照剔除只读逆投影 c[17].x = 1/P00：
        ///    旧规则写回原值，光照块的视锥只铺到中间 16:9，两侧放宽区的块拿不到灯）。凑出来的假矩阵列存时每个 vec4 都被改、只读一截的绑定照旧写回原值；
        /// ② 按客体 x 坐标画（读片元坐标的程序，guestX）读到的屏幕尺寸；不按客体坐标画的（片元坐标即放宽像素、计算着色器）读到的像素射线步长 A
        ///    （它们要 C' + x'·A，客体坐标的要 C' + (x'/k)·(k·A)，见 WidenRewriter 像素射线基）。都没读到它 → 不管。</summary>
        static bool NeedsOriginal(in CbufShadow.Hit h, ulong buf, ReadOnlySpan<CbufRead> reads, bool guestX)
        {
            bool part = false;
            foreach (ref readonly CbufRead r in reads)
            {
                if (r.Use == null || r.Buffer != buf) continue;
                int lo = Math.Max(h.Lo, r.Offset), hi = Math.Min(h.Lo + h.Len, r.Offset + r.Size);
                if (lo >= hi || !r.Use.Reads(r.Offset, r.Size, lo, hi)) continue;
                if (h.Lo >= r.Offset && h.Lo + h.Len <= r.Offset + r.Size && (r.Use.ReadsAll(r.Offset, h.Lo, h.Lo + h.Len) || ReadsChanged(h, r))) return guestX ? h.Kind == WidenKind.ScreenSize : h.Kind == WidenKind.PixelStep;   // 有绑定整块读它 / 读遍改动过的 vec4：用改写值
                part = true;
            }
            return part;
        }
        /// <summary>改写动过的每个 vec4（原值 ≠ 改写值）这个绑定都读到；一个都没动过返回 false。</summary>
        static bool ReadsChanged(in CbufShadow.Hit h, in CbufRead r)
        {
            bool any = false; ReadOnlySpan<byte> o = h.Orig, n = h.New;
            for (int c = 0; c < h.Len; c += 16)
            {
                int e = Math.Min(c + 16, h.Len);
                if (o[c..e].SequenceEqual(n[c..e])) continue;
                if (!r.Use.Reads(r.Offset, r.Size, h.Lo + c, h.Lo + e)) return false;
                any = true;
            }
            return any;
        }
        /// <summary>计算派发之前（同绘制的写回原值规则）：只写没放宽的图像（narrowOnly，如 32³ 调色 LUT）= 同画到没放宽的目标，读到的命中全部写回原值；
        /// 其余（写放宽图像 / 没有图像输出）按 NeedsOriginal——只读到一截的写回原值（10-22 暗黑2：调色 LUT 混合权重 0.542 接在旧相机残留后被认成「正交 × 视图」改成 0.444，
        /// 读它的是计算派发，不经过 OnDraw，整张 LUT 偏暗约 9%）。</summary>
        public void OnDispatch(ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, bool narrowOnly)
        {
            if (narrowOnly) { foreach (ref readonly CbufRead r in reads) RestoreOriginals(r, patcher); return; }
            if (_restored.Count > 0) Reapply(patcher, reads, false);
            foreach (ref readonly CbufRead r in reads) RestoreFor(r, reads, patcher, false);
        }

        /// <summary>这次绘制要原值的命中（NeedsOriginal）写回原值。</summary>
        void RestoreFor(in CbufRead r, ReadOnlySpan<CbufRead> reads, IBufferPatcher patcher, bool guestX)
        {
            if (r.Use == null) return;
            CbufShadow.Buf b = _sh.TryGet(r.Buffer);
            if (b == null || b.Hits.Count == 0) return;
            Span<CbufShadow.Hit> hs = CollectionsMarshal.AsSpan(b.Hits);
            for (int i = b.FirstHitEndingAfter(r.Offset); i < hs.Length && hs[i].Lo < r.Offset + r.Size; i++)
            {
                ref CbufShadow.Hit h = ref hs[i];
                if (h.Restored || !NeedsOriginal(h, r.Buffer, reads, guestX)) continue;
                patcher?.Write(r.Buffer, h.Lo, ((ReadOnlySpan<byte>)h.Orig)[..h.Len]);
                h.Restored = true; Restores++;
                _restored.Add((r.Buffer, h.Lo));
            }
        }

        /// <summary>上屏：定下一帧的 T_out。</summary>
        public void OnPresent(uint presented)
        {
            Frames++; _composited.Clear(); _rw.EndFrame();
            _sh.EndFrame();
            uint next = 0;
            if (_lastDrawRt == presented && presented != 0)
            {
                foreach (uint t in _lastDrawTex) if (t != 0 && t != presented && OutCandidate(t)) { next = t; break; }
                if (next == 0 && OutCandidate(presented)) next = presented;
            }
            else if (OutCandidate(presented)) next = presented;
            // 两张交替上屏（最近三次 A、B、A；开局只上屏过两张不同图时先按交替算，三张轮换第 3 次上屏就退出）
            _dbl = presented != 0 && presented != _pres1 && (presented == _pres2 || _pres2 == 0);
            _pres2 = _pres1; _pres1 = presented;
            if (_out != 0 && _out != next && !_outs.Contains(_out)) _outFresh.Remove(_out);
            _out = next;
            if (_outs.Contains(presented)) _outFresh.Add(presented);   // 集合里的图每次上屏后重新算「没画过」：下一笔是新一帧的合成
            if (next == 0) return;
            _outFresh.Add(next);
            // 常驻只收选出的上屏图本身；合成源 ≠ 上屏图时上屏图不算（它上面后续的绘制不是界面层，同改前）
            // 选出的上屏图本身一直记最近两张（巫师3 开局第 3 次上屏就误选合成图 559，那时才刚认出两张交替）；只在两张交替时当出图目标用
            if (next == presented) { _outs.Remove(next); _outs.Add(next); if (_outs.Count > 2) { _outFresh.Remove(_outs[0]); _outs.RemoveAt(0); } }
        }

        bool OutCandidate(uint t) => IsWide(t) || IsNative(t) || GameWide && _gwDrawn.Contains(t);

        // ---------- 越界外推 / 片元倍率 / 上屏裁剪：两种图形模式共用的判定（通用包装层与直连导出调同一份） ----------
        /// <summary>原尺寸居中的界面层改成「全宽视口 + 着色器横向收缩、画布边顶点推到屏幕边」的前提（再要片元只采小图 / 平铺贴图，调用方判，见 WidenPipeline.OnlyBackground）：
        /// 写颜色、CenterNative、不是子视口（收缩绕本次视口中心缩，只有视口 = 整个区域才等于原尺寸居中）、顶点着色器能外推。</summary>
        public bool ShrinkCandidate(ViewportMode m, bool colorOut, bool pushable) => colorOut && m == ViewportMode.CenterNative && !_subVp && pushable;
        /// <summary>原生宽目标上读改写矩阵（Hor）的界面层把画布边的顶点推到屏幕边的前提（再要片元只采小图，调用方判，见 WidenPipeline.OnlySmall）。</summary>
        public bool PushCandidate(ViewportMode m, bool colorOut, bool pushable) => pushable && colorOut && m == ViewportMode.Hor && _rtNative;
        /// <summary>着色器读的外推参数（支持缓冲 s2a_widen.x / .y / .z）：on = 本笔外推，shrink = 本笔是收缩层。不外推全 0（= 原样）。</summary>
        public void PushParams(bool on, bool shrink, out float push, out float thr2, out float shrinkZ)
        {
            (thr2, push) = on ? SpirvEdgePush.Params(_rw.K) : (0f, 0f);
            // 不收缩的外推也给极小收缩量 NoBandZ：着色器「收缩量 > 0 时画布边上及外一律推」，等于撤掉 16:9 边界窄带（x 只缩百万分之一）。
            // 窄带 10-23 是预防性加的（没有反例；暗黑3 当时的真问题是子视口，已另修），却挡住了动森圆形转场：黑板顶点在画布外 ±1.15，两侧各露约 70 像素（10-24）
            shrinkZ = !on ? 0f : shrink ? 1f - 1f / _rw.K : NoBandZ;
        }
        public const float NoBandZ = 1e-6f;
        /// <summary>读片元坐标、按客体坐标画的程序（guestCoords）在放宽目标上片元 x 要乘的倍率（render_scale[0] 去掉原分辨率倍率的部分）；其余 1。</summary>
        public float FragScaleX(ViewportMode m, bool guestCoords) => guestCoords && (m == ViewportMode.ScaleK || m == ViewportMode.Hor) && TargetScaleX is float kx ? kx : 1f;
        /// <summary>同 FragScaleX 的纵向（窄屏加高的目标）：片元 y 要乘的倍率（render_scale_y，Ryujinx 补丁 0206 分轴）；其余 1。</summary>
        public float FragScaleY(ViewportMode m, bool guestCoords) => guestCoords && (m == ViewportMode.ScaleK || m == ViewportMode.Hor) && TargetScaleY is float ky ? ky : 1f;
        /// <summary>上屏裁剪：上屏贴图放宽了，横向裁剪按它的放宽比换算、宽高比按屏幕比（aspectX = 0 表示不限比例，原样）。</summary>
        public void MapCrop(uint tex, ref int left, ref int right, ref float aspectX, float aspectY)
        {
            if (tex == 0 || !TryWide(tex, out _, out _)) return;
            left = MapX(tex, left);
            if (right != 0) right = MapX(tex, right);
            if (aspectX != 0) aspectX = aspectY * _rw.Aspect;
        }
        /// <summary>通用层（包装层，不加高渲染目标）在比 16:9 高的屏上的上屏宽高比 x 分量（y 分量不变）：上屏贴图本身比 16:9 高 1% 以上
        /// （游戏读了加长的显示分辨率、自己按 1280×900 出图）才按屏幕比；否则画面仍是 16:9，按 16:9 上屏（上下留黑），不竖向拉 Ky 倍。
        /// 只看贴图、不看裁剪：动态分辨率横向缩放的源矩形比 16:9 窄，贴图本身不变。不是高屏（Ky = 1）或宽高比缺失（0）原样返回。
        /// 11-05 审计 #1565 P1-117 读数（Mac 1920×1350 通用层）：异度神剑3 没读显示分辨率、出图 1920×1080 取 [0,1280)×[0,720)，
        /// 上屏宽高比却是 12.8:9（MapCrop 按屏幕比给的）→ 铺满整屏、竖向拉 1.25 倍；没放宽登记的贴图则停在 16:9，游戏真出了高图也被压进 16:9。</summary>
        public float GenericPresentAspectX(float aspectX, float aspectY, int texW, int texH)
        {
            if (!_rw.Tall || aspectX == 0 || aspectY == 0 || texW <= 0 || texH <= 0) return aspectX;
            bool tallTex = (double)texH * WidenRewriter.SrcAspect > texW * 1.01;
            return aspectY * (tallTex ? _rw.Aspect : WidenRewriter.SrcAspect);
        }
        /// <summary>上屏裁剪的纵向（窄屏）：上屏贴图加高了，上 / 下边按它的放高比换算（0 = 不裁、原样）。</summary>
        public void MapCropY(uint tex, ref int top, ref int bottom)
        {
            if (tex == 0 || !TryTall(tex, out int h0, out int h1)) return;
            // 整数算（10-26 Duo 真机：720 → 878 时浮点 720 × (878 / 720) = 878.0000001，向上取整成 879，比贴图多一行，上屏整帧被拒、全黑）
            top = (int)((long)top * h1 / h0);
            if (bottom != 0) bottom = (int)(((long)bottom * h1 + h0 - 1) / h0);
        }

        // ---------- 视口 / 裁剪换算（当前目标放宽时） ----------
        public void MapViewport(ViewportMode mode, ref float x, ref float width)
        {
            if (mode == ViewportMode.Keep || _wideRtW1 == 0) return;
            float pad = (CanvasW1 - CanvasW0) * 0.5f, k = (float)_wideRtW1 / _wideRtW0;   // 左上画布：pad 按画布（见 _cornerW）
            // 横向这里保持浮点 pad（10-28 审计核过）：界面层内容按真 k 缩放，中心落在放宽贴图正中，奇数宽差时就是 x.5（用例手算 142.5）；
            // 剪刀侧取整数是近似，且页面条带由 PageShift（Math.Round）给出、本来就整数——横向没有纵向那种「条带 + 视口」错位。
            if (_rtNative)   // 游戏视口已按全宽给：只有没读改写矩阵的界面层收进中间 16:9
            {
                if (mode == ViewportMode.CenterNative) { x = _vpX + pad + (x - _vpX) / k; width /= k; }   // 原尺寸居中在原生区域（非 GameWide 时区域 = 整张贴图，_vpX = 0）
                return;
            }
            if (mode == ViewportMode.Page) { x += (float)PageShiftNow; return; }
            if (mode == ViewportMode.CenterNative) { x += pad; return; }
            // 读改写矩阵的绘制：投影 x 已乘 1/K，视口宽就乘 K（不是目标实际放宽比 宽1/宽0）——两者严格抵消，中间区与 k=1 逐点对齐（中心 = 客体中心 + pad）。
            // 宽度按整数取（WidenWidth 规则②）时宽1/宽0 ≠ K：10-22 八方2 动态分辨率 896 → 1094（1.22098 对 K 1.221875），按宽1/宽0 乘时中间区边缘错 0.33 像素，
            // 像素画纹理在边缘一片发糊（中间区对 k=1 差左右两侧最大）。视口可带小数（896·K = 1094.8，左边 −0.4），超出目标的部分本来就被裁掉
            if (mode == ViewportMode.Hor) { float c = x + width * 0.5f + pad; width *= _rw.K; x = c - width * 0.5f; return; }
            x *= k; width *= k;
        }
        /// <summary>窄屏加高的页起始行（整数）：视口、剪刀、清黑条带三处必须同口径，否则奇数加高量时第 pad 行半清半画（10-28 B06：一级视图 540→675 差 135）。</summary>
        int PagePadY => (CanvasH1 - CanvasH0) / 2;
        /// <summary>视口纵向（窄屏加高的目标，10-26）：同 MapViewport 的横向。读改写投影的 3D（Hor）：中心下移 pad、高乘 Ky（投影 y 已乘 1/Ky，两者抵消、中间区逐点对齐，
        /// 上下多出的就是新视野）；界面层原尺寸（CenterNative）：同 Hor 上下居中（11-02 起；原先贴底，与 Hor 界面笔错开 pad）；
        /// 原比例页（Page）：上下居中；其余全屏遍（ScaleK）：y、高都乘 放高比。</summary>
        public void MapViewportY(ViewportMode mode, ref float y, ref float height)
        {
            if (mode == ViewportMode.Keep || _tallRtH1 == 0) return;
            float pad = (CanvasH1 - CanvasH0) * 0.5f, k = (float)CanvasH1 / CanvasH0;   // 左上画布：按画布（见 CanvasH0 / CanvasH1）
            if (mode == ViewportMode.Page) { y += PagePadY; return; }   // 整数 pad：与剪刀 / 清黑条带同口径（奇数加高量原先 67.5 对 67，第 67 行半清半画）
            // 界面层原尺寸（CenterNative）同 Hor 居中（11-02 jhz Duo 丝之歌暂停页：原先贴底下移 h1−h0、Hor 的界面笔因投影抵消只下移 pad，同一画布两种笔差 pad——
            //   选中项菱形（Hor）浮在「退出至菜单」文字（CenterNative）上方 135 行）。横向两种也都是居中；整数 pad 与剪刀 / 原比例页同口径
            if (mode == ViewportMode.CenterNative) { y += PagePadY; return; }
            if (mode == ViewportMode.Hor) { float c = y + height * 0.5f + pad; height *= _rw.Ky; y = c - height * 0.5f; return; }
            y *= k; height *= k;
        }
        public void MapScissorY(ViewportMode mode, ref int y, ref int height)
        {
            if (mode == ViewportMode.Keep || _tallRtH1 == 0 || height >= 0xffff || y + height >= 0xffff) return;
            int pad = PagePadY;
            if (mode == ViewportMode.Page) { y += pad; return; }
            if (mode == ViewportMode.CenterNative) { y += pad; return; }   // 居中：同 MapViewportY
            if (mode == ViewportMode.Hor)
            {
                if (y <= 0 && y + height >= CanvasH0) { y = 0; height = CanvasH1; }   // 覆盖客体全高：铺满加高目标（上下新视野要画出来）
                else y += pad;
                return;
            }
            long h0 = CanvasH0, h1 = CanvasH1, e = y + height;   // 整数算，同 MapCropY（浮点向上取整会多出一行）
            int y0 = (int)Math.Floor((double)((long)y * h1) / h0), y1 = (int)(e >= 0 ? (e * h1 + h0 - 1) / h0 : -((-e * h1) / h0));
            y = y0; height = y1 - y0;
        }
        public void MapScissor(ViewportMode mode, ref int x, ref int width)
        {
            if (mode == ViewportMode.Keep || _wideRtW1 == 0 || width >= 0xffff || x + width >= 0xffff) return;
            int pad = (CanvasW1 - CanvasW0) / 2;   // 左上画布：pad 与「覆盖全宽」按画布（见 _cornerW）
            if (_rtNative)
            {
                // 原生宽目标：界面层（读改写矩阵的 Hor、没读的 CenterNative）内容都收进中间原生区，游戏按「16:9 画布拉满全宽」算的剪裁也要同样收进来
                // （10-20 动森小地图：剪裁没收、内容收了 → 地形左边约三分之一被裁掉，iPhone / Mac 宽屏都复现，16:9 正常）。覆盖全宽的剪裁不收（外推到屏幕边的元素要画出来）
                // 游戏界面布局也是宽的（LayoutWide，10-23 塞尔达雷达）：剪裁本来就按真实宽屏像素算好、已包住改写后的内容（雷达游戏剪裁 1187+210、改写后内容 1213..1371），
                // 再收一次 = 重复换算（收成 1113+173，雷达右半被切）；只有 CenterNative（没读改写矩阵、内容由视口收进中间）照收
                bool full = x <= (int)_vpX && x + width >= (int)_vpX + _wideRtW1;
                if (mode == ViewportMode.CenterNative || mode == ViewportMode.Hor && !full && !LayoutWide)
                { double kn = (double)_wideRtW1 / _wideRtW0; int vx = (int)_vpX, nx0 = vx + pad + (int)Math.Floor((x - vx) / kn), nx1 = vx + pad + (int)Math.Ceiling((x + width - vx) / kn); x = nx0; width = nx1 - nx0; }
                return;
            }
            if (mode == ViewportMode.Page) { x += (int)Math.Round(PageShiftNow); return; }
            if (mode == ViewportMode.CenterNative) { x += pad; return; }
            if (mode == ViewportMode.Hor)
            {
                if (x <= 0 && x + width >= CanvasW0) { x = 0; width = CanvasW1; }   // 覆盖客体全宽：铺满加宽目标（两侧新视野要画出来）
                else x += pad;
                return;
            }
            double kk = (double)_wideRtW1 / _wideRtW0;
            int x0 = (int)Math.Floor(x * kk), x1 = (int)Math.Ceiling((x + width) * kk);
            x = x0; width = x1 - x0;
        }
        // ---------- 16:9 原比例页（10-21：游戏画死 16:9、没有更宽内容可补的页面——标题图、视频——原比例居中、两侧黑，不拉伸）----------
        // 页面 = 一块客体画布 [X0, X0+W)（整张贴图，或掌机档在主机尺寸缓冲里只用的左上 16:9 视口），放宽后它占 [X0·k, (X0+W)·k)；
        // 原尺寸内容平移 s = (k − 1)·(X0 + W/2) 落在正中 [X0+s, X0+W+s)，两侧到页面放宽区边为黑边。整张贴图时 s = (宽1 − 宽0)/2，与界面层居中同一偏移。
        struct PageRec { public long Frame; public double Shift; public int X0, W; }
        readonly Dictionary<uint, PageRec> _pages = new();   // 目标 → 本帧登记的原比例页（帧号对不上 = 本帧不是页）
        // 内容是原比例页的目标（页目标本身 + 全屏合成传下去的）：按内容记、不按帧号——页内容不变时游戏不重画页（八方2 标题视频约隔一帧才重画一次），
        // 照样把同一张页目标合成上屏；被 Hor / 不采样页的 ScaleK 画过、清屏或释放才作废（上屏免判用）
        readonly HashSet<uint> _pageSources = new();

        /// <summary>页面平移量 s（客体画布 [x0, x0+w) 在贴图 tex 里；贴图没放宽返回 0）。取整像素：多出奇数列的贴图（320 → 391 中心偏 35.5）按半像素平移会让页内容整体重采样、
        /// 被采样时取的原宽副本也对不齐（10-21 马车8 选 Mii 页背景模糊链 320×180：中间区差异 >8 的像素 18908 → 285197），页面差半像素不居中看不出，逐像素一致更要紧。</summary>
        public double PageShift(uint tex, double x0, double w) => TryWide(tex, out int w0, out int w1) ? Math.Round((double)(w1 - w0) * (x0 + w * 0.5) / w0, MidpointRounding.AwayFromZero) : 0;

        /// <summary>登记：目标 tex 本帧余下的绘制是 16:9 原比例页，画布 [x0, x0+w)（客体坐标）。返回内容区 [c0, c1) 与页面放宽区 [m0, m1)（放宽贴图坐标，两侧条带 = 放宽区减内容区，调用方清黑）。</summary>
        public bool BeginPage(uint tex, int x0, int w, out int c0, out int c1, out int m0, out int m1)
        {
            c0 = c1 = m0 = m1 = 0;
            if (!TryWide(tex, out _, out _) || w <= 0) return false;
            double s = PageShift(tex, x0, w);
            _pages[tex] = new PageRec { Frame = Frames, Shift = s, X0 = x0, W = w };
            _pageSources.Add(tex);   // 页目标本身即页来源，传播链从此开始
            c0 = (int)Math.Round(x0 + s); c1 = c0 + w; m0 = MapX(tex, x0); m1 = MapX(tex, x0 + w);
            return true;
        }
        /// <summary>当前颜色目标 0 本帧已是原比例页。</summary>
        public bool PageActive => _rt0 != 0 && _pages.TryGetValue(_rt0, out PageRec p) && p.Frame == Frames;
        /// <summary>当前目标的原比例页内容区 [c0, c1)（放宽贴图坐标；本帧不是页返回 false）：本帧余下的绘制剪到这里。</summary>
        public bool PageClip(out int c0, out int c1)
        {
            c0 = c1 = 0;
            if (_rt0 == 0 || !_pages.TryGetValue(_rt0, out PageRec p) || p.Frame != Frames) return false;
            c0 = (int)Math.Round(p.X0 + p.Shift); c1 = c0 + p.W; return true;
        }
        /// <summary>窄屏加高的目标（10-28 B06）：当前颜色目标 0 本帧是原比例页时，页内容只占中间 [c0, c1) = [pad, pad+h0) 行（MapViewportY Page 模式 y += pad），
        /// 上下条带 [r0, c0) [c1, r1) 没人写，调用方在起页那笔之前清黑（同横向两侧条带）。目标没加高或本帧不是页返回 false。</summary>
        public bool PageRows(out int r0, out int c0, out int c1, out int r1)
        {
            r0 = c0 = c1 = r1 = 0;
            if (!PageActive || !TryTall(_rt0, out int h0, out int h1) || h1 <= h0) return false;
            // 按画布高（CanvasH0 / CanvasH1）：掌机档画在主机尺寸缓冲左上 1280×720 时，画布 720 → 900、pad 90，条带 [0,90) [810,900)。
            //   11-05 前按整张缓冲高（1080 → 1350）算出 [0,90) [1170,1350)：底条带落在画布外、画布内 [810,900) 没清（旷野之息 Duo 交换链）。整张目标就是画布时两者相同
            int pad = PagePadY;   // 与 MapViewportY / MapScissorY 同一整数 pad
            c0 = pad; c1 = pad + CanvasH0; r1 = CanvasH1; return true;
        }
        double PageShiftNow => _rt0 != 0 && _pages.TryGetValue(_rt0, out PageRec p) ? p.Shift : 0;

        /// <summary>按区域拷贝 / 上屏裁剪：横向坐标按该贴图自己的放宽比换算。</summary>
        public int MapX(uint tex, int x) => TryWide(tex, out int w0, out int w1) ? (int)Math.Round(x * (double)w1 / w0) : x;
    }

    /// <summary>影子对照（测试用）：包装层把缓冲写入事件、实际发给 GPU 的上传、每次绘制的读法转告，对照模型按旧「上传即整段改写」算同一份内容，
    /// 比「这次读到的字节」新旧是否一致（tests/visual/galplay --widen-check、widen_scanbench --check）。产品里不挂。</summary>
    public interface IWidenCheck
    {
        void Upload(ulong buffer, int offset, ReadOnlySpan<byte> data);
        /// <summary>这次上传实际发给 GPU 的数据（命中处叠了改写值）。</summary>
        void Forward(ulong buffer, int offset, ReadOnlySpan<byte> sent);
        void Copy(ulong src, ulong dst, int srcOffset, int dstOffset, int size);
        void Clear(ulong buffer, int offset, int size, uint value);
        void Delete(ulong buffer);
        void Draw(ReadOnlySpan<CbufRead> reads);
    }
}
