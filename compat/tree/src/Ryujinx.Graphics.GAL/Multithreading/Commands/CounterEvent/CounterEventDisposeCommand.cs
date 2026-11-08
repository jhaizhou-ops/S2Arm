using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.CounterEvent
{
    struct CounterEventDisposeCommand : IGALCommand, IGALCommand<CounterEventDisposeCommand>
    {
        public readonly CommandType CommandType => CommandType.CounterEventDispose;
        private TableRef<ThreadedCounterEvent> _event;

        public void Set(TableRef<ThreadedCounterEvent> evt)
        {
            _event = evt;
        }

        public static void Run(ref CounterEventDisposeCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedCounterEvent evt = command._event.Get(threaded);
            evt.Base.Dispose();
            threaded.S2ACounterDropped(evt);   // S2Arm: back in the pool once its result is handled too
        }
    }
}
