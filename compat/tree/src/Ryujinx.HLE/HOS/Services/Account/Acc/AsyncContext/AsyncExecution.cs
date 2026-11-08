using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel.Threading;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace Ryujinx.HLE.HOS.Services.Account.Acc.AsyncContext
{
    class AsyncExecution
    {
        private readonly CancellationTokenSource _tokenSource;
        private readonly CancellationToken _token;

        public KEvent SystemEvent { get; }
        public ResultCode Result { get; }
        public bool IsInitialized { get; private set; }
        public bool IsRunning { get; private set; }
        // S2Arm: completion state of the task itself. HasDone / GetResult answer from it, not from the event: the SDK attaches the event as an
        //   auto-clear nn::os::SystemEvent, so waiting on it resets the signal, and nn::account::AsyncContext's destructor aborts when HasDone says
        //   false (Zelda: Ocarina of Time's EnsureIdTokenCacheAsync, Break 2162-0001 at boot). Set before the event is signalled
        private volatile bool _done;
        public bool IsDone => _done;

        public AsyncExecution(KEvent asyncEvent, ResultCode result = ResultCode.Success)
        {
            SystemEvent = asyncEvent;
            Result = result;

            _tokenSource = new CancellationTokenSource();
            _token = _tokenSource.Token;
        }

        public void Initialize(int timeout, Func<CancellationToken, Task> taskAsync)
        {
            Task.Run(async () =>
            {
                IsRunning = true;

                _tokenSource.CancelAfter(timeout);

                try
                {
                    await taskAsync(_token);
                }
                catch (Exception ex)
                {
                    Logger.Warning?.Print(LogClass.ServiceAcc, $"Exception: {ex.Message}");
                }

                IsRunning = false;
                _done = true;

                SystemEvent.ReadableEvent.Signal();
            }, _token);

            IsInitialized = true;
        }

        public void Cancel()
        {
            _tokenSource.Cancel();
        }
    }
}
