// 通用镜头位姿（每帧信号，自动玩家判「输入有没有驱动镜头 / 角色」用）：从写进缓冲的常量里认透视视图投影矩阵 VP，
// 取本帧「绘制最多的深度目标」上被最多绘制读到的那个当主镜头，直接由 VP 解出镜头位置与朝向。不依赖 Ryujinx、不按游戏，零配置。
//
// 认 VP（行存、列存都试，统一转成行存 r0..r3）：w 行 xyz 模 ≈ 1（视图矩阵是刚体）、x / y 行 xyz 与 w 行两两正交且非零、z 行 xyz 与 w 行平行。
//   纯投影 P（w 行恰为 (0,0,±1,0)：镜头在原点不动）与正交投影（w 行 xyz 为 0：界面 / 平行光阴影）不算。
//   逐物体的 MVP（P·V·M，M 为刚体）同样满足——动森一帧上传约 200 个——所以候选池要大，靠「被多少次绘制读到」选：场景 VP 被成百上千次读，逐物体 MVP 各 ~1 次。
// 位姿：镜头中心 C 满足裁剪空间 x = y = w = 0，即 [r0;r1;r3]·[C;1] = 0，解 3×3；前向 = w 行 xyz 归一（w 随离镜头远而增大）。
//   偏航 / 俯仰按 Y 朝上给（yaw = atan2(fx, fz)，pitch = asin(fy)，度）；Z 朝上的引擎看前向三分量 fx / fy / fz 即可。
// 读到才判（10-21）：不在上传时扫；抽样绘制计数时只在着色器真读的 4 连下标起点上判「自上次判过后被写过」的窗口（常量缓冲影子 CbufShadow 的镜头脏位、数据取影子），
//   上屏选主镜头前，窗口被写过、本帧没再判的候选丢掉（同旧：旧在上传时就把被覆盖的候选作废）。
// 选主镜头：每 32 次绘制抽 1 次，把它读到的候选按「当前深度目标」计数（只按着色器真读的常量下标查起点，散列表定位，不扫整段绑定）；
//   上屏时取绘制最多的深度目标，再取在它上面被读最多的候选（阴影图、界面层自然落选）。本帧深度目标上没有绘制（30 帧游戏重复上屏）沿用上一帧结果。
// 每帧零分配：候选池、散列表、计数都是定长数组。
using System;
using System.Threading;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    public sealed class CameraTrack
    {
        const int MaxCand = 1024, MaxDepth = 8, HBits = 12, Sample = 32, DynSweep = 4096, CacheN = 64, CacheHits = 4;
        readonly ulong[] _buf = new ulong[MaxCand]; readonly int[] _off = new int[MaxCand]; readonly bool[] _live = new bool[MaxCand];
        readonly int[] _hnext = new int[MaxCand]; readonly int[] _head = new int[1 << HBits];   // 散列：键 (缓冲, 起点偏移) → 候选链
        readonly int[] _free = new int[MaxCand]; int _nfree;
        readonly long[] _age = new long[MaxCand]; long _clock;   // 池满时挤掉最旧的
        readonly float[] _m = new float[MaxCand * 16];   // 行存
        readonly int[] _cnt = new int[MaxCand * MaxDepth];
        readonly uint[] _depth = new uint[MaxDepth]; readonly int[] _depthDraws = new int[MaxDepth];
        int _drawTick;
        // 读法缓存：很多绘制绑同一段常量（同缓冲 / 偏移 / 长度 / 读法）——命中就直接加计数，不再逐下标查；候选有增删（_epoch 变）即全部作废
        readonly ulong[] _cBuf = new ulong[CacheN]; readonly int[] _cOff = new int[CacheN], _cSize = new int[CacheN], _cN = new int[CacheN]; readonly long[] _cEpoch = new long[CacheN];
        readonly CbufUse[] _cUse = new CbufUse[CacheN]; readonly int[] _cHit = new int[CacheN * CacheHits]; long _epoch = 1;
        readonly long[] _cVer = new long[CacheN];   // 缓存时那个缓冲的影子版本：版本变了（有新写入、可能有新的脏窗口）就重查
        readonly CbufShadow _sh;

        /// <summary>主镜头结果（上屏时更新；本帧没有深度绘制时沿用上一帧）：有透视主镜头时 Valid = true。</summary>
        public bool Valid; public float X, Y, Z, Fx, Fy, Fz, Yaw, Pitch; public int Draws;
        public int FrameDepthDraws, FrameLive;   // 诊断：本帧（抽样后）深度目标上的绘制数、存活候选数
        public long Found, Frames, ValidFrames;
        public uint DiagD1, DiagD2; public int DiagN1, DiagN2, DiagBest, DiagCand;   // 诊断（直连读数行）：末帧前两名深度目标与抽样绘制数、主深度上最高候选计数、主深度上有计数的候选数   // ValidFrames：上屏时有主镜头的帧数（直连读数行：认出率）
        /// <summary>开关（缺省开；回放器 --cam-off 对拍开销用）。</summary>
        public static bool Enabled = true;
        /// <summary>计时（回放器 --cam 打开）：识别与计数累计的 Stopwatch 刻度。</summary>
        public static bool Profile; public long TicksScan, TicksDraw, TicksInval, ScanBytes, QuickPass;
        /// <summary>诊断：本帧前三名候选的计数与位置 z（回放器打印）。</summary>
        public readonly int[] TopCnt = new int[3]; public readonly float[] TopZ = new float[3];   // 上一帧选中的矩阵：「上一帧 VP」（运动矢量 / 时域抗锯齿用）与它相同，和本帧 VP 计数接近时让位

        /// <param name="shadow">缓冲影子（与 WidenFrame 共用一份：WidenRenderer 传 Frame.Shadow）</param>
        public CameraTrack(CbufShadow shadow)
        {
            _sh = shadow;
            Array.Fill(_head, -1);
            for (int i = 0; i < MaxCand; i++) _free[i] = MaxCand - 1 - i;
            _nfree = MaxCand;
        }

        static int H(ulong buf, int off) => (int)(((buf * 0x9E3779B97F4A7C15UL) ^ (ulong)(off >> 4) * 0xC2B2AE3D27D4EB4FUL) >> (64 - HBits));

        int Find(ulong buf, int off)
        {
            for (int c = _head[H(buf, off)]; c >= 0; c = _hnext[c]) if (_buf[c] == buf && _off[c] == off) return c;
            return -1;
        }

        void Remove(int c)
        {
            int h = H(_buf[c], _off[c]);
            if (_head[h] == c) _head[h] = _hnext[c];
            else for (int p = _head[h]; p >= 0; p = _hnext[p]) if (_hnext[p] == c) { _hnext[p] = _hnext[c]; break; }
            _live[c] = false; _free[_nfree++] = c; _epoch++;
        }

        int Alloc()
        {
            if (_nfree == 0)
            {
                int old = 0; for (int i = 1; i < MaxCand; i++) if (_age[i] < _age[old]) old = i;   // 池满（少见）：挤掉最旧的
                Remove(old);
            }
            return _free[--_nfree];
        }

        /// <summary>缓冲删了：它上面的候选全丢（缓冲号可能被新缓冲复用）。</summary>
        public void OnDeleteBuffer(ulong buffer)
        {
            for (int c = 0; c < MaxCand; c++) if (_live[c] && _buf[c] == buffer) Remove(c);
        }

        /// <summary>起点 off 的窗口自上次判过后被写过（镜头脏位）：丢旧候选、按影子重判（同旧上传时的判法），清脏。</summary>
        void Validate(CbufShadow.Buf b, ulong buffer, int off)
        {
            if (b == null || !b.DcGet(off)) return;
            long t0 = Profile ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
            b.DcClear(off);
            int old = Find(buffer, off); if (old >= 0) Remove(old);
            Span<float> w = stackalloc float[16];
            if ((off & 15) == 0 && b.ReadWindow(off, w)) Judge(buffer, off, w);
            if (Profile) { TicksScan += System.Diagnostics.Stopwatch.GetTimestamp() - t0; ScanBytes += 64; }
        }

        void Judge(ulong buffer, int off, ReadOnlySpan<float> m)
        {
            // 快筛：行存 w 行 = m[12..14]，列存 w 行 = m[3], m[7], m[11]；模要 ≈ 1
            float a = m[12] * m[12] + m[13] * m[13] + m[14] * m[14], b = m[3] * m[3] + m[7] * m[7] + m[11] * m[11];
            bool ra = MathF.Abs(a - 1) < 2e-3f, rb = MathF.Abs(b - 1) < 2e-3f;
            if (!ra && !rb) return;
            if (Profile) QuickPass++;
            Span<float> r = stackalloc float[16];
            for (int col = 0; col < 2; col++)
            {
                if (col == 0 ? !ra : !rb) continue;
                if (!Ortho(m, col == 1)) continue;   // 原地先判 x / y 行与 w 行正交，过了才拷
                for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) r[i * 4 + j] = col == 0 ? m[i * 4 + j] : m[j * 4 + i];
                if (!IsVP(r)) continue;
                int s = Alloc(), h = H(buffer, off);
                _buf[s] = buffer; _off[s] = off; _live[s] = true; _age[s] = ++_clock; _hnext[s] = _head[h]; _head[h] = s; _epoch++;
                r.CopyTo(_m.AsSpan(s * 16, 16)); _cnt.AsSpan(s * MaxDepth, MaxDepth).Clear(); Found++;
                return;
            }
        }

        static bool Ortho(ReadOnlySpan<float> m, bool col)
        {
            int ri = col ? 1 : 4, cj = col ? 4 : 1;   // 元素 (i, j) 在 m[i·ri + j·cj]
            float wx = m[3 * ri], wy = m[3 * ri + cj], wz = m[3 * ri + 2 * cj];
            float x0 = m[0], x1 = m[cj], x2 = m[2 * cj], y0 = m[ri], y1 = m[ri + cj], y2 = m[ri + 2 * cj];
            float xx = x0 * x0 + x1 * x1 + x2 * x2, yy = y0 * y0 + y1 * y1 + y2 * y2;
            if (!(xx > 1e-6f) || !(yy > 1e-6f)) return false;
            float xw = x0 * wx + x1 * wy + x2 * wz, yw = y0 * wx + y1 * wy + y2 * wz;
            return xw * xw <= 1e-6f * xx && yw * yw <= 1e-6f * yy;
        }

        static bool IsVP(ReadOnlySpan<float> r)
        {
            foreach (float v in r) if (!float.IsFinite(v)) return false;
            float wx = r[12], wy = r[13], wz = r[14];
            if (MathF.Abs(wx) < 1e-6f && MathF.Abs(wy) < 1e-6f && MathF.Abs(MathF.Abs(wz) - 1) < 1e-6f && MathF.Abs(r[15]) < 1e-6f) return false;   // 纯投影：镜头不动
            float xx = r[0] * r[0] + r[1] * r[1] + r[2] * r[2], yy = r[4] * r[4] + r[5] * r[5] + r[6] * r[6];
            if (xx < 1e-6f || yy < 1e-6f) return false;
            float xw = r[0] * wx + r[1] * wy + r[2] * wz, yw = r[4] * wx + r[5] * wy + r[6] * wz, xy = r[0] * r[4] + r[1] * r[5] + r[2] * r[6];
            if (MathF.Abs(xw) > 1e-3f * MathF.Sqrt(xx) || MathF.Abs(yw) > 1e-3f * MathF.Sqrt(yy) || MathF.Abs(xy) > 1e-3f * MathF.Sqrt(xx * yy)) return false;
            float zx = r[8], zy = r[9], zz = r[10];   // z 行 xyz ∥ w 行：叉积 ≈ 0 且非零
            float cx = zy * wz - zz * wy, cy = zz * wx - zx * wz, cz = zx * wy - zy * wx, zn = zx * zx + zy * zy + zz * zz;
            return zn > 1e-8f && cx * cx + cy * cy + cz * cz < 1e-6f * zn;
        }

        /// <summary>每次绘制：depth = 当前深度附件（0 = 没有，不计）；reads = 本次绘制的常量绑定与读法。每 8 次抽 1 次计数。</summary>
        public void OnDraw(uint depth, ReadOnlySpan<CbufRead> reads)
        {
            if (depth == 0 || !Tick()) return;
            OnDrawSampled(depth, reads);
        }
        /// <summary>这笔绘制抽不抽（每 Sample 笔抽 1 笔）：直连会话先问它，抽中才建读列表（不抽的绘制零开销）。</summary>
        public bool Tick() => Enabled && (++_drawTick & (Sample - 1)) == 0;
        /// <summary>已抽中的一笔：按深度目标计数它读到的镜头候选。</summary>
        public void OnDrawSampled(uint depth, ReadOnlySpan<CbufRead> reads)
        {
            if (depth == 0) return;
            long t0 = Profile ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
            CountDraw(depth, reads);
            if (Profile) TicksDraw += System.Diagnostics.Stopwatch.GetTimestamp() - t0;
        }

        void CountDraw(uint depth, ReadOnlySpan<CbufRead> reads)
        {
            int d = -1;
            for (int i = 0; i < MaxDepth; i++) if (_depth[i] == depth && _depthDraws[i] > 0) { d = i; break; }
            if (d < 0) { for (int i = 0; i < MaxDepth; i++) if (_depthDraws[i] == 0) { d = i; _depth[i] = depth; break; } }
            if (d < 0) return;
            _depthDraws[d]++;
            foreach (ref readonly CbufRead r in reads)
            {
                if (r.Use == null || r.Size < 64) continue;
                int ci = (int)(((r.Buffer * 0x9E3779B97F4A7C15UL) ^ (ulong)r.Offset * 0xC2B2AE3D27D4EB4FUL ^ (ulong)r.Use.GetHashCode()) >> 58) & (CacheN - 1);
                CbufShadow.Buf sb = _sh.TryGet(r.Buffer); _curBuf = sb;
                long ver = sb?.Ver ?? -1;
                if (_cEpoch[ci] == _epoch && _cVer[ci] == ver && _cBuf[ci] == r.Buffer && _cOff[ci] == r.Offset && _cSize[ci] == r.Size && ReferenceEquals(_cUse[ci], r.Use))
                {
                    for (int k = 0; k < _cN[ci]; k++) _cnt[_cHit[ci * CacheHits + k] * MaxDepth + d]++;
                    continue;
                }
                _cBuf[ci] = r.Buffer; _cOff[ci] = r.Offset; _cSize[ci] = r.Size; _cUse[ci] = r.Use; _cN[ci] = 0; _cVer[ci] = ver; _cur = ci;
                _cEpoch[ci] = 0;   // 填的过程中判出新候选会改 _epoch：填完再记
                bool ok = true;
                if (r.Use.Dynamic)   // 动态下标：读哪几个不知道，只查绑定开头一段的每个起点
                {
                    int lim = Math.Min(r.Size, DynSweep);
                    for (int o = 0; o + 64 <= lim; o += 16) ok &= Count(r.Buffer, r.Offset + o, d);
                }
                else
                {
                    ReadOnlySpan<int> ix = r.Use.Indices;   // 着色器真读的常量下标：连读 4 个（i..i+3，一个 4×4 矩阵）的起点才查
                    for (int k = 0; k + 3 < ix.Length; k++)
                        if (ix[k + 3] == ix[k] + 3 && 16 * ix[k] + 64 <= r.Size) ok &= Count(r.Buffer, r.Offset + 16 * ix[k], d);
                }
                if (ok) _cEpoch[ci] = _epoch;
            }
        }

        int _cur;   // 正在填的读法缓存槽
        /// <summary>返回 false = 这段候选超过 4 个，不缓存。</summary>
        CbufShadow.Buf _curBuf;   // 正在计数的那段绑定的缓冲影子（一段查一次）
        bool Count(ulong buf, int off, int d)
        {
            Validate(_curBuf, buf, off);
            int c = Find(buf, off); if (c < 0) return true;
            _cnt[c * MaxDepth + d]++;
            if (_cN[_cur] < CacheHits) { _cHit[_cur * CacheHits + _cN[_cur]++] = c; return true; }
            return false;
        }

        /// <summary>上屏：定本帧主镜头、算位姿、清计数。本帧深度目标上没有绘制时沿用上一帧结果。</summary>
        public void OnPresent()
        {
            Frames++;
            // 窗口自判过后被写过、本帧没再判的候选：旧在上传时就作废了，这里补上（计数随之丢掉）
            long ti = Profile ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
            for (int c = 0; c < MaxCand; c++)
            {
                if (!_live[c]) continue;
                CbufShadow.Buf b = _sh.TryGet(_buf[c]);
                // 页被回收了（久没绑，见 CbufShadow.KeepFrames）：之后的写入不再记脏位，候选丢掉
                if (b == null || b.DcGet(_off[c]) || b.PageAt(_off[c]) == null) Remove(c);
            }
            if (Profile) TicksInval += System.Diagnostics.Stopwatch.GetTimestamp() - ti;
            int tot = 0, live = 0; foreach (int v in _depthDraws) tot += v; foreach (bool v in _live) live += v ? 1 : 0;
            FrameDepthDraws = tot; FrameLive = live;
            if (tot == 0) return;
            // 主深度目标：在「计到过透视候选」的深度目标里取绘制最多的，且不少于全帧最多那个的 1/4。阴影图只读正交矩阵、从来没有候选，
            //   绘制再多也不选（10-25 动森直连：阴影深度 54 笔、场景深度 49 笔，原先按绘制最多选中阴影图，有主镜头的帧只有 3%）；
            //   菜单里的小预览（角色头像等）绘制远少于全帧最多的那个，不会被选成主镜头
            int top = 0; for (int i = 0; i < MaxDepth; i++) top = Math.Max(top, _depthDraws[i]);
            int d = -1, best = 0;
            for (int i = 0; i < MaxDepth; i++)
            {
                if (_depthDraws[i] <= best || _depthDraws[i] * 4 < top) continue;
                bool any = false; for (int c = 0; c < MaxCand && !any; c++) any = _live[c] && _cnt[c * MaxDepth + i] > 0;
                if (any) { best = _depthDraws[i]; d = i; }
            }
            if (d < 0) for (int i = 0; i < MaxDepth; i++) if (_depthDraws[i] > best) { best = _depthDraws[i]; d = i; }   // 都没有候选：照旧取绘制最多的（本帧无主镜头）
            { int d2 = -1, b2 = 0; for (int i = 0; i < MaxDepth; i++) if (i != d && _depthDraws[i] > b2) { b2 = _depthDraws[i]; d2 = i; }
              DiagD1 = _depth[d]; DiagN1 = best; DiagD2 = d2 >= 0 ? _depth[d2] : 0; DiagN2 = b2; DiagBest = 0; DiagCand = 0;
              for (int c = 0; c < MaxCand; c++) if (_live[c] && _cnt[c * MaxDepth + d] > 0) { DiagCand++; DiagBest = Math.Max(DiagBest, _cnt[c * MaxDepth + d]); } }
            int bc = -1, bn = 0;
            for (int c = 0; c < MaxCand; c++) if (_live[c] && _cnt[c * MaxDepth + d] > bn) { bn = _cnt[c * MaxDepth + d]; bc = c; }
            if (bc >= 0)   // 并列（≥ 头名 90%）里取（缓冲, 偏移）最小的：同一份常量里常并排放本帧与早几帧的 VP（运动矢量用），被同样的绘制读到；固定取同一个槽，序列才平滑
                for (int c = 0; c < MaxCand; c++)
                    if (_live[c] && _cnt[c * MaxDepth + d] * 10 >= bn * 9 && (_buf[c] < _buf[bc] || (_buf[c] == _buf[bc] && _off[c] < _off[bc]))) bc = c;
            if (Profile)
            {
                Array.Clear(TopCnt); Array.Fill(TopZ, float.NaN);
                for (int c = 0; c < MaxCand; c++)
                {
                    if (!_live[c]) continue; int v = _cnt[c * MaxDepth + d];
                    for (int k = 0; k < 3; k++) if (v > TopCnt[k]) { for (int q = 2; q > k; q--) { TopCnt[q] = TopCnt[q - 1]; TopZ[q] = TopZ[q - 1]; } TopCnt[k] = v; TopZ[k] = Pose(_m.AsSpan(c * 16, 16)) ? Z : float.NaN; break; }
                }
            }
            Valid = bc >= 0 && Pose(_m.AsSpan(bc * 16, 16));
            if (Valid) ValidFrames++;
            Draws = bc >= 0 ? _cnt[bc * MaxDepth + d] : 0;
            Draws = bn;
            Array.Clear(_cnt); Array.Clear(_depthDraws); Array.Clear(_depth);
        }

        /// <summary>由行存 VP 解位姿（单测直接调）。</summary>
        public bool Pose(ReadOnlySpan<float> r)
        {
            // [r0;r1;r3]·[C;1] = 0 → A·C = −t
            double a00 = r[0], a01 = r[1], a02 = r[2], a10 = r[4], a11 = r[5], a12 = r[6], a20 = r[12], a21 = r[13], a22 = r[14];
            double b0 = -r[3], b1 = -r[7], b2 = -r[15];
            double det = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (a10 * a21 - a11 * a20);
            if (Math.Abs(det) < 1e-12) return false;
            X = (float)((b0 * (a11 * a22 - a12 * a21) - a01 * (b1 * a22 - a12 * b2) + a02 * (b1 * a21 - a11 * b2)) / det);
            Y = (float)((a00 * (b1 * a22 - a12 * b2) - b0 * (a10 * a22 - a12 * a20) + a02 * (a10 * b2 - b1 * a20)) / det);
            Z = (float)((a00 * (a11 * b2 - b1 * a21) - a01 * (a10 * b2 - b1 * a20) + b0 * (a10 * a21 - a11 * a20)) / det);
            double n = Math.Sqrt(a20 * a20 + a21 * a21 + a22 * a22);
            Fx = (float)(a20 / n); Fy = (float)(a21 / n); Fz = (float)(a22 / n);
            Yaw = (float)(Math.Atan2(Fx, Fz) * 180 / Math.PI); Pitch = (float)(Math.Asin(Math.Clamp(Fy, -1f, 1f)) * 180 / Math.PI);
            return float.IsFinite(X) && float.IsFinite(Y) && float.IsFinite(Z);
        }

        // 自动玩家在线读镜头位姿（测试层 s2a_ap_cam，导出见 gal/WidenExports.cs）：渲染线程每次上屏发布一份快照，任意线程按序号锁读（奇数 = 正在写，读到一半被改就重读），零分配
        static long s_camSeq; static float s_cx, s_cy, s_cz; static ulong s_cFrame; static bool s_cValid;
        public static void ResetPublished() { s_camSeq = 0; s_cx = s_cy = s_cz = 0; s_cFrame = 0; s_cValid = false; }
        public static void Publish(CameraTrack c, ulong frame)
        {
            Interlocked.Increment(ref s_camSeq);
            s_cValid = c.Valid; s_cx = c.X; s_cy = c.Y; s_cz = c.Z; s_cFrame = frame;
            Interlocked.Increment(ref s_camSeq);
        }
        /// <summary>最近一次上屏的主镜头位置（同 frames.tsv cam_x / cam_y / cam_z）；没有透视主镜头返回 false。frame = 包装层上屏计数。</summary>
        public static bool ReadCam(Span<float> pos, out ulong frame)
        {
            for (;;)
            {
                long s0 = Volatile.Read(ref s_camSeq);
                if ((s0 & 1) != 0) { Thread.SpinWait(8); continue; }
                bool v = s_cValid; float x = s_cx, y = s_cy, z = s_cz; ulong f = s_cFrame;
                Interlocked.MemoryBarrier();
                if (Volatile.Read(ref s_camSeq) != s0) continue;
                frame = f;
                if (!v || pos.Length < 3) return false;
                pos[0] = x; pos[1] = y; pos[2] = z; return true;
            }
        }
    }
}
