using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot
{
    // Private Android composition ABI, mirrored by runtime/runtime/services_abi.h.
    // This reports services readiness, not guest execution or graphics acceptance.
    internal enum ServiceState : uint { Created, Starting, Ready, Failed, StopRequested, Stopped }
    internal enum ServiceError { Ok, Argument = -1, Version = -2, AlreadyUsed = -3,
        Provider = -4, Host = -5, Initialize = -6, Gpu = -7, StopRequested = -8, Cleanup = -9 }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct AndroidServicesRequest
    {
        public uint Size, Version;
        public ulong Session;
        public nint NativeOwner, HostApi;
        public byte* GameDataDirectory;
        public byte* StateDirectory;
        public nint LeaseApi;
        public uint ConsoleMode, Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AndroidServicesStatus
    {
        public uint Size, Version;
        public ulong Session;
        public uint State;
        public int Error;
    }

    // One process, one session. A failed start cannot be recycled: core/provider,
    // Horizon static state and HostApi lifetime all belong to the process owner.
    internal sealed class AndroidServiceState
    {
        private readonly object _lock = new();
        private ulong _session;
        private ServiceState _state;
        private ServiceError _error;

        internal ServiceError Begin(ulong session)
        {
            lock (_lock)
            {
                if (session == 0) return ServiceError.Argument;
                if (_state != ServiceState.Created) return ServiceError.AlreadyUsed;
                _session = session;
                _state = ServiceState.Starting;
                return ServiceError.Ok;
            }
        }

        internal ServiceError Complete()
        {
            lock (_lock)
            {
                if (_state == ServiceState.Starting) _state = ServiceState.Ready;
                return _state == ServiceState.Ready ? ServiceError.Ok : _error == ServiceError.Ok ? ServiceError.AlreadyUsed : _error;
            }
        }

        internal void Fail(ServiceError error)
        {
            lock (_lock)
            {
                if (_state != ServiceState.Failed) _error = error;
                _state = ServiceState.Failed;
            }
        }

        internal ServiceError RequestStop(ulong session)
        {
            lock (_lock)
            {
                if (session == 0 || session != _session) return ServiceError.Argument;
                if (_state != ServiceState.Failed && _state != ServiceState.Stopped)
                {
                    _state = ServiceState.StopRequested;
                    _error = ServiceError.StopRequested;
                }
                return ServiceError.Ok;
            }
        }

        // Only the real shutdown owner calls this, after Cleanup returned with
        // every owned resource retired. Partial startup cleanup never calls it.
        internal void CleanupComplete()
        {
            lock (_lock)
            {
                if (_state == ServiceState.StopRequested)
                {
                    _state = ServiceState.Stopped;
                    _error = ServiceError.Ok;
                }
            }
        }

        internal AndroidServicesStatus Snapshot()
        {
            lock (_lock) return new AndroidServicesStatus
            {
                Size = 24, Version = 1, Session = _session, State = (uint)_state, Error = (int)_error,
            };
        }
    }
}
