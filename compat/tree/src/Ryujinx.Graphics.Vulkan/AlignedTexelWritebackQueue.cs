using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>
    /// S2A（PR #1487 修复①）：未对齐 texel 写视图的回写挂账分两段——
    /// 描述符绑定阶段先进 pending，使用它的 draw/dispatch 记录完成后由渲染线程
    /// promote 进 armed；flush 只消费 armed。这样「绑定 → 真正绘制」之间发生的
    /// 宿主侧访问（同 holder 上第二个视图的 CreateView、GetBuffer、SignalWrite 等）
    /// 不会提前把还没被 GPU 写过的影子拷回源缓冲、也不会提前销毁影子和视图。
    /// 队列内部加锁：后台线程可以安全读状态（报红判定），但只在渲染线程取账。
    /// </summary>
    /// <typeparam name="T">影子缓冲句柄类型（BufferHolder 用 Auto&lt;DisposableBuffer&gt;）。</typeparam>
    internal sealed class AlignedTexelWritebackQueue<T> where T : class
    {
        internal readonly struct Entry
        {
            public readonly T Shadow;
            public readonly int SrcOffset;
            public readonly int Size;

            public Entry(T shadow, int srcOffset, int size)
            {
                Shadow = shadow;
                SrcOffset = srcOffset;
                Size = size;
            }
        }

        private readonly object _lock = new();
        private List<Entry> _pending;
        private List<Entry> _armed;

        /// <summary>挂一笔写回（pending）。同一份影子重复挂账按影子去重。</summary>
        /// <returns>true = 新挂入；false = 该影子已在 pending/armed 中（调用方不要再加引用计数）。</returns>
        public bool Arm(T shadow, int srcOffset, int size)
        {
            lock (_lock)
            {
                if (Contains(_pending, shadow) || Contains(_armed, shadow))
                {
                    return false;
                }

                (_pending ??= []).Add(new Entry(shadow, srcOffset, size));
                return true;
            }
        }

        /// <summary>
        /// draw/dispatch 记录完成后调用：pending 全部转为 armed。
        /// <paramref name="keepAlive"/> 返回 false 的账说明影子已失效（缓存被清），
        /// 直接丢弃并返回给调用方——不能拿旧影子去盖后来写进源的新数据。
        /// </summary>
        /// <returns>被丢弃的账（含影子引用，调用方负责释放）；无则 null。</returns>
        public List<Entry> Promote(Func<Entry, bool> keepAlive)
        {
            lock (_lock)
            {
                if (_pending == null)
                {
                    return null;
                }

                List<Entry> dropped = null;

                foreach (Entry entry in _pending)
                {
                    if (keepAlive(entry))
                    {
                        (_armed ??= []).Add(entry);
                    }
                    else
                    {
                        (dropped ??= []).Add(entry);
                    }
                }

                _pending = null;
                return dropped;
            }
        }

        /// <summary>取走并清空全部 armed 账（pending 不动）。无账返回 null。</summary>
        public List<Entry> TakeArmed()
        {
            lock (_lock)
            {
                List<Entry> armed = _armed;
                _armed = null;
                return armed;
            }
        }

        /// <summary>取走并清空 pending + armed（Dispose 用）。无账返回 null。</summary>
        public List<Entry> TakeAll()
        {
            lock (_lock)
            {
                if (_pending == null)
                {
                    List<Entry> armed = _armed;
                    _armed = null;
                    return armed;
                }

                List<Entry> all = _armed ?? [];
                all.AddRange(_pending);
                _pending = null;
                _armed = null;
                return all;
            }
        }

        /// <summary>pending 或 armed 中是否还有账（后台路径报红判定用）。</summary>
        public bool HasAny
        {
            get
            {
                lock (_lock)
                {
                    return _pending != null || _armed != null;
                }
            }
        }

        /// <summary>armed 中是否已有可落账（渲染线程快速判空用）。</summary>
        public bool HasArmed
        {
            get
            {
                lock (_lock)
                {
                    return _armed != null;
                }
            }
        }

        private static bool Contains(List<Entry> list, T shadow)
        {
            if (list == null)
            {
                return false;
            }

            foreach (Entry entry in list)
            {
                if (ReferenceEquals(entry.Shadow, shadow))
                {
                    return true;
                }
            }

            return false;
        }
    }
}
