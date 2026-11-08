using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Common
{
    /// <summary>Explicitly enabled Android debug capture; no file or P/Invoke on normal builds.</summary>
    public static class S2ACompileEvents
    {
        public enum Kind : uint { Translation = 1, GraphicsPipeline = 2, ComputePipeline = 3 }
        public enum Result : uint { Hit = 1, Miss = 2, Failure = 3 }

        [DllImport("s2a_native", EntryPoint = "s2a_ce_init")]
        private static extern int Init([MarshalAs(UnmanagedType.LPUTF8Str)] string directory, ulong session);
        [DllImport("s2a_native", EntryPoint = "s2a_ce_enabled")]
        private static extern int EnabledNative();
        [DllImport("s2a_native", EntryPoint = "s2a_ce_now")]
        private static extern ulong Now();
        [DllImport("s2a_native", EntryPoint = "s2a_ce_record")]
        private static extern int Record(uint kind, uint result, ulong begin, ulong end);
        [DllImport("s2a_native", EntryPoint = "s2a_ce_flush")]
        private static extern int Flush();

        private static readonly object Gate = new();
        private static volatile bool _enabled;
        private static int _active;

        public static bool BeginSession(string directory, ulong session)
        {
            lock (Gate)
            {
                if (_active != 0 || _enabled) return false;
                if (Init(directory, session) != 0) return false;
                _enabled = EnabledNative() != 0;
                return true;
            }
        }

        public static Scope Begin(Kind kind)
        {
            if (!_enabled) return null;
            lock (Gate)
            {
                if (!_enabled) return null;
                _active++;
                return new Scope(kind, Now());
            }
        }

        public static bool EndSession()
        {
            lock (Gate)
            {
                if (!_enabled) return true;
                _enabled = false;
                // A timed-out worker may still emit events; never certify a partial capture.
                if (_active != 0) return false;
                return Flush() == 0;
            }
        }

        public sealed class Scope : IDisposable
        {
            private readonly Kind _kind;
            private readonly ulong _start;
            private Result _result = Result.Failure;
            private bool _closed;
            internal Scope(Kind kind, ulong start) { _kind = kind; _start = start; }
            public void Complete(Result result) { _result = result; }
            public void Dispose()
            {
                lock (Gate)
                {
                    if (_closed) return;
                    _closed = true;
                    // The native producer counts malformed timestamps as lost.
                    Record((uint)_kind, (uint)_result, _start, Now());
                    _active--;
                }
            }
        }
    }
}
