using System;
using System.Threading;

namespace Ryujinx.Audio.Renderer.Utils
{
    /// <summary>
    /// A simple generic message queue for unmanaged types.
    /// </summary>
    /// <typeparam name="T">The target unmanaged type used</typeparam>
    public class Mailbox<T> : IDisposable where T : unmanaged
    {
        // S2Arm: one-slot handoff on two semaphores instead of BlockingCollection<T>(1). Same bounded semantics
        // (Add blocks while the slot is full, Take blocks while empty), but a blocking BlockingCollection.Take
        // creates a linked CancellationTokenSource and callback registrations every time, and the audio processor
        // hands off through this mailbox every 5 ms (zero steady-state allocation, 方案 §3-4).
        private sealed class Slot : IDisposable
        {
            private readonly SemaphoreSlim _empty = new(1, 1);
            private readonly SemaphoreSlim _full = new(0, 1);
            private T _value;

            public void Put(T value)
            {
                _empty.Wait();
                _value = value;
                _full.Release();
            }

            public T Take()
            {
                _full.Wait();
                T value = _value;
                _empty.Release();
                return value;
            }

            public void Dispose()
            {
                _empty.Dispose();
                _full.Dispose();
            }
        }

        private readonly Slot _messageQueue;
        private readonly Slot _responseQueue;

        public Mailbox()
        {
            _messageQueue = new Slot();
            _responseQueue = new Slot();
        }

        public void SendMessage(T data)
        {
            _messageQueue.Put(data);
        }

        public void SendResponse(T data)
        {
            _responseQueue.Put(data);
        }

        public T ReceiveMessage()
        {
            return _messageQueue.Take();
        }

        public T ReceiveResponse()
        {
            return _responseQueue.Take();
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _messageQueue.Dispose();
                _responseQueue.Dispose();
            }
        }
    }
}
