using Ryujinx.Graphics.GAL.Multithreading.Commands.Sampler;
using Ryujinx.Graphics.GAL.Multithreading.Model;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    class ThreadedSampler : ISampler
    {
        private readonly ThreadedRenderer _renderer;
        public ISampler Base;

        public ThreadedSampler(ThreadedRenderer renderer)
        {
            _renderer = renderer;
        }

        public unsafe void Dispose()
        {
            if (_renderer.S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层对象不逐个释放（ThreadedRenderer.S2ADiscardFrees）
            }

            _renderer.New<SamplerDisposeCommand>()->Set(new TableRef<ThreadedSampler>(_renderer, this));
            _renderer.QueueCommand();
        }
    }
}
