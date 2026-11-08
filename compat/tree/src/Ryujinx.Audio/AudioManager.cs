using System;
using System.Threading;

namespace Ryujinx.Audio
{
    /// <summary>
    /// Manage audio input and output system.
    /// </summary>
    public class AudioManager : IDisposable
    {
        /// <summary>
        /// Lock used to control the waiters registration.
        /// </summary>
        private readonly Lock _lock = new();

        /// <summary>
        /// Events signaled when the driver played audio buffers.
        /// </summary>
        private readonly ManualResetEvent[] _updateRequiredEvents;

        /// <summary>
        /// Action to execute when the driver played audio buffers.
        /// </summary>
        private readonly Action[] _actions;

        /// <summary>
        /// The worker thread in charge of handling sessions update.
        /// </summary>
        private readonly Thread _workerThread;

        private bool _isRunning;

        /// <summary>
        /// Create a new <see cref="AudioManager"/>.
        /// </summary>
        public AudioManager()
        {
            _updateRequiredEvents = new ManualResetEvent[2];
            _actions = new Action[2];
            _isRunning = false;

            // Termination event.
            _updateRequiredEvents[1] = new ManualResetEvent(false);

            _workerThread = new Thread(Update)
            {
                Name = "AudioManager.Worker",
            };
        }

        /// <summary>
        /// Start the <see cref="AudioManager"/>.
        /// </summary>
        public void Start()
        {
            if (_workerThread.IsAlive)
            {
                throw new InvalidOperationException();
            }

            _isRunning = true;
            _workerThread.Start();
        }

        /// <summary>
        /// Initialize update handlers.
        /// </summary>
        /// <param name="updatedRequiredEvent ">The driver event that will get signaled by the device driver when an audio buffer finished playing/being captured</param>
        /// <param name="outputCallback">The callback to call when an audio buffer finished playing</param>
        /// <param name="inputCallback">The callback to call when an audio buffer was captured</param>
        public void Initialize(ManualResetEvent updatedRequiredEvent, Action outputCallback, Action inputCallback)
        {
            lock (_lock)
            {
                _updateRequiredEvents[0] = updatedRequiredEvent;
                _actions[0] = outputCallback;
                _actions[1] = inputCallback;
            }
        }

        /// <summary>
        /// Entrypoint of the <see cref="_workerThread"/> in charge of updating the <see cref="AudioManager"/>.
        /// </summary>
        private void Update()
        {
            while (_isRunning)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("声音输出 / 输入更新"); // S2Arm: per-thread allocation accounting

                int index = WaitHandle.WaitAny(_updateRequiredEvents);

                // Last index is here to indicate thread termination.
                if (index + 1 == _updateRequiredEvents.Length)
                {
                    break;
                }

                lock (_lock)
                {
                    // S2Arm: reset before running the updates, not after: a driver signal raised while they run (e.g. a buffer
                    // queued and consumed meanwhile) was cleared by the late Reset and its buffers waited for an unrelated event
                    _updateRequiredEvents[0].Reset();

                    foreach (Action action in _actions)
                    {
                        action?.Invoke();
                    }
                }
            }
        }

        /// <summary>
        /// Stop updating the <see cref="AudioManager"/> without stopping the worker thread.
        /// </summary>
        public void StopUpdates()
        {
            _isRunning = false;
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
                _updateRequiredEvents[1].Set();
                _workerThread.Join();

                _updateRequiredEvents[1].Dispose();
            }
        }
    }
}
