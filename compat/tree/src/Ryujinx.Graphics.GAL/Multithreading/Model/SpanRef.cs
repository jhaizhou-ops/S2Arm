using System;
using System.Runtime.CompilerServices;

namespace Ryujinx.Graphics.GAL.Multithreading.Model
{
    readonly struct SpanRef<T> where T : unmanaged
    {
        private readonly int _packedLengthId;

        public SpanRef(ThreadedRenderer renderer, T[] data)
        {
            _packedLengthId = -(renderer.AddTableRef(data) + 1);
        }

        public SpanRef(int length)
        {
            _packedLengthId = length;
        }

        public Span<T> Get(ThreadedRenderer renderer)
        {
            if (_packedLengthId >= 0)
            {
                return renderer.SpanPool.Get<T>(_packedLengthId);
            }
            else
            {
                T[] array = (T[])renderer.RemoveTableRef(-(_packedLengthId + 1));
                renderer.S2AReleasePayload((long)array.Length * Unsafe.SizeOf<T>()); // S2A：环形池放不下的新分配在入队时计入过在途载荷

                return new Span<T>(array);
            }
        }

        public void Dispose(ThreadedRenderer renderer)
        {
            if (_packedLengthId > 0)
            {
                renderer.SpanPool.Dispose<T>(_packedLengthId);
            }
        }
    }
}
