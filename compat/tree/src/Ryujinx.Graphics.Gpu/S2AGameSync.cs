// S2A: 本文件为 S2A 新增（非 Ryujinx 原版）。
using System;
using System.Threading;

namespace Ryujinx.Graphics.Gpu
{
    /// <summary>
    /// S2A「游戏已确认的 GPU 进度」（帧率能耗线 10-23）：游戏在 CPU 上等 GPU 走 nvhost-ctrl 同步点等待（NVN nvnSyncWait / 事件等待），
    /// 等到值的那一刻起才算「同步过」到这个同步点。这里把（同步点，值）映射到推进时的宿主同步号，游戏确认一个值就把 G 推到对应宿主同步号。
    /// 回写时要等的宿主同步号 > G = 游戏还没等过这批 GPU 结果（Switch 上此时 CPU 读到的是内存现值、不阻塞）。
    /// 记录在同步点推进处（GpuContext.S2AIncrementSyncpointAfterHostSync），确认在 NvHostCtrl 当场到值与 NvHostEvent 到值回调
    /// </summary>
    public static class S2AGameSync
    {
        private const int Ids = 192, Ring = 64;
        private static readonly uint[,] _val = new uint[Ids, Ring];
        private static readonly ulong[,] _sync = new ulong[Ids, Ring];
        private static readonly int[] _n = new int[Ids];
        private static readonly object _lock = new();
        private static long _g;

        /// <summary>游戏已确认的最大宿主同步号（没确认过任何同步点 = 0）</summary>
        public static ulong G => (ulong)Interlocked.Read(ref _g);

        public static void Record(uint id, uint value, ulong hostSync)
        {
            if (id >= Ids) return;
            lock (_lock)
            {
                int k = _n[id]++ % Ring;
                _val[id, k] = value;
                _sync[id, k] = hostSync;
            }
        }

        // 游戏没等过就读、按 Switch 语义放行（不回写）的贴图句柄：G 推过它们要等的同步号时整段设回「GPU 改过」，游戏醒来再读就走正常回写
        private static Image.TextureGroupHandle[] _pend = new Image.TextureGroupHandle[64];
        private static ulong[] _pendSync = new ulong[64];
        private static int _pendN;

        internal static void Pend(Image.TextureGroupHandle h, ulong needed)
        {
            lock (_lock)
            {
                if (_pendN == _pend.Length)
                {
                    Array.Resize(ref _pend, _pendN * 2);
                    Array.Resize(ref _pendSync, _pendN * 2);
                }

                _pend[_pendN] = h;
                _pendSync[_pendN++] = needed;
            }
        }

        // 缓冲：未同步放行过的子页段（地址、长度、要等的同步号）
        private static ulong[] _rA = new ulong[64], _rS = new ulong[64], _rN = new ulong[64];
        private static int _rn;

        // All guest/service callbacks and GPU workers must have stopped before this reset.
        // Retiring a session drops its addresses and handles without reprotecting freed guest memory.
        internal static void ResetSession()
        {
            lock (_lock)
            {
                Array.Clear(_val);
                Array.Clear(_sync);
                Array.Clear(_n);
                Interlocked.Exchange(ref _g, 0);
                Array.Clear(_pend);
                Array.Clear(_pendSync);
                _pendN = 0;
                Array.Clear(_rA);
                Array.Clear(_rS);
                Array.Clear(_rN);
                _rn = 0;
            }
        }

        internal static unsafe void ServeRange(ulong addr, ulong size, ulong needed)
        {
            if (Ryujinx.Memory.Tracking.MemoryTracking.S2AReprotect != null)
            {
                Ryujinx.Memory.Tracking.MemoryTracking.S2AReprotect(addr, size, (int)Ryujinx.Memory.MemoryPermission.Read);
            }

            lock (_lock)
            {
                if (_rn == _rA.Length)
                {
                    Array.Resize(ref _rA, _rn * 2); Array.Resize(ref _rS, _rn * 2); Array.Resize(ref _rN, _rn * 2);
                }

                _rA[_rn] = addr; _rS[_rn] = size; _rN[_rn++] = needed;
            }
        }

        // 设回：重叠 [ovA, ovA+ovS)（ovS > 0）或要等的同步号 ≤ upTo 的段，在写跟踪层设回「GPU 改过」（None）。不分配（设回时才建一次小数组）
        private static unsafe void RearmWhere(ulong ovA, ulong ovS, ulong upTo)
        {
            ulong[] a = null, s = null; int k = 0;
            lock (_lock)
            {
                for (int i = 0; i < _rn; )
                {
                    bool hit = ovS != 0 ? _rA[i] < ovA + ovS && ovA < _rA[i] + _rS[i] : _rN[i] <= upTo;

                    if (hit)
                    {
                        a ??= new ulong[_rn]; s ??= new ulong[_rn];
                        a[k] = _rA[i]; s[k++] = _rS[i];
                        _rn--; _rA[i] = _rA[_rn]; _rS[i] = _rS[_rn]; _rN[i] = _rN[_rn];
                    }
                    else i++;
                }
            }

            if (Ryujinx.Memory.Tracking.MemoryTracking.S2AReprotect != null)
            {
                for (int i = 0; i < k; i++)
                {
                    Ryujinx.Memory.Tracking.MemoryTracking.S2AReprotect(a[i], s[i], (int)Ryujinx.Memory.MemoryPermission.None);
                }
            }
        }

        internal static void RearmOverlap(ulong addr, ulong size)
        {
            if (Volatile.Read(ref _rn) == 0) return;
            RearmWhere(addr, size, 0);
        }

        public static void Observe(uint id, uint value)
        {
            if (id >= Ids) return;
            ulong best = 0;
            lock (_lock)
            {
                int n = Math.Min(_n[id], Ring);
                for (int i = 0; i < n; i++)
                {
                    // 同步点值按 32 位回绕比较：已到值 = value - v >= 0
                    if ((int)(value - _val[id, i]) >= 0 && _sync[id, i] > best) best = _sync[id, i];
                }
            }
            long cur;
            do { cur = Interlocked.Read(ref _g); if ((ulong)cur >= best) return; } while (Interlocked.CompareExchange(ref _g, (long)best, cur) != cur);

            // G 前进：放行过的句柄里要等的同步号已被游戏确认的，整段设回（在唤醒游戏之前，调用方同步调本函数）
            Image.TextureGroupHandle[] due = null; int nd = 0;
            lock (_lock)
            {
                for (int i = 0; i < _pendN; )
                {
                    if (_pendSync[i] <= best)
                    {
                        due ??= new Image.TextureGroupHandle[_pendN];
                        due[nd++] = _pend[i];
                        _pend[i] = _pend[--_pendN];
                        _pendSync[i] = _pendSync[_pendN];
                        _pend[_pendN] = null;
                    }
                    else i++;
                }
            }

            for (int i = 0; i < nd; i++)
            {
                due[i].S2AUnsyncRearm();
            }

            if (Volatile.Read(ref _rn) != 0)
            {
                RearmWhere(0, 0, best);
            }
        }
    }
}
