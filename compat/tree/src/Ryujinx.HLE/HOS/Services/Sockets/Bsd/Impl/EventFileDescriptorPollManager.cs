using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl
{
    class EventFileDescriptorPollManager : IPollManager
    {
        private static EventFileDescriptorPollManager _instance;

        public static EventFileDescriptorPollManager Instance
        {
            get
            {
                _instance ??= new EventFileDescriptorPollManager();

                return _instance;
            }
        }

        public bool IsCompatible(PollEvent evnt)
        {
            return evnt.FileDescriptor is EventFileDescriptor;
        }

        public LinuxError Poll(List<PollEvent> events, int timeoutMilliseconds, out int updatedCount)
        {
            updatedCount = 0;

            List<ManualResetEvent> waiters = [];

            for (int i = 0; i < events.Count; i++)
            {
                PollEvent evnt = events[i];

                EventFileDescriptor socket = (EventFileDescriptor)evnt.FileDescriptor;

                bool isValidEvent = false;

                if (evnt.Data.InputEvents.HasFlag(PollEventTypeMask.Input) ||
                    evnt.Data.InputEvents.HasFlag(PollEventTypeMask.UrgentInput))
                {
                    waiters.Add(socket.ReadEvent);

                    isValidEvent = true;
                }

                if (evnt.Data.InputEvents.HasFlag(PollEventTypeMask.Output))
                {
                    waiters.Add(socket.WriteEvent);

                    isValidEvent = true;
                }

                if (!isValidEvent)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Unsupported Poll input event type: {evnt.Data.InputEvents}");

                    return LinuxError.EINVAL;
                }
            }

            // S2Arm: shutdown ends the wait as a timeout (Ryujinx.Common.S2AShutdown)
            waiters.Add(S2AShutdown.Event);

            int index = WaitHandle.WaitAny(waiters.ToArray(), timeoutMilliseconds);

            if (index == waiters.Count - 1)
            {
                index = WaitHandle.WaitTimeout;
            }

            if (index != WaitHandle.WaitTimeout)
            {
                for (int i = 0; i < events.Count; i++)
                {
                    PollEventTypeMask outputEvents = 0;

                    PollEvent evnt = events[i];

                    EventFileDescriptor socket = (EventFileDescriptor)evnt.FileDescriptor;

                    if (socket.ReadEvent.WaitOne(0))
                    {
                        if (evnt.Data.InputEvents.HasFlag(PollEventTypeMask.Input))
                        {
                            outputEvents |= PollEventTypeMask.Input;
                        }

                        if (evnt.Data.InputEvents.HasFlag(PollEventTypeMask.UrgentInput))
                        {
                            outputEvents |= PollEventTypeMask.UrgentInput;
                        }
                    }

                    if ((evnt.Data.InputEvents.HasFlag(PollEventTypeMask.Output))
                        && socket.WriteEvent.WaitOne(0))
                    {
                        outputEvents |= PollEventTypeMask.Output;
                    }

                    if (outputEvents != 0)
                    {
                        evnt.Data.OutputEvents = outputEvents;

                        updatedCount++;
                    }
                }
            }
            else
            {
                return LinuxError.ETIMEDOUT;
            }

            return LinuxError.SUCCESS;
        }

        // S2Arm: upstream left this a TODO returning EOPNOTSUPP (select on an eventfd never waited and never reported ready).
        // Same wait as Poll; timeout is in microseconds (IClient.Select), -1 = forever. An eventfd has no error condition,
        // so error-only entries never become ready and just take part in the wait.
        public LinuxError Select(List<PollEvent> events, int timeout, out int updatedCount)
        {
            int timeoutMilliseconds = timeout < 0 ? -1 : (int)((timeout + 999L) / 1000);
            List<PollEvent> waitable = events.FindAll(e => e.Data.InputEvents.HasFlag(PollEventTypeMask.Input) || e.Data.InputEvents.HasFlag(PollEventTypeMask.Output));

            if (waitable.Count == 0)
            {
                updatedCount = 0;
                S2AShutdown.Event.WaitOne(timeoutMilliseconds);   // S2Arm: a sleep that shutdown ends

                return LinuxError.SUCCESS;
            }

            LinuxError result = Poll(waitable, timeoutMilliseconds, out updatedCount);

            return result == LinuxError.ETIMEDOUT ? LinuxError.SUCCESS : result;
        }
    }
}
