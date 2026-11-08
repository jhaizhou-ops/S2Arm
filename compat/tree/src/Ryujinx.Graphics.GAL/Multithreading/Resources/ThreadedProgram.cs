using Ryujinx.Graphics.GAL.Multithreading.Commands.Program;
using Ryujinx.Graphics.GAL.Multithreading.Model;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    class ThreadedProgram : IProgram, IProgramBinaryLoadFailure, IS2APipelineWarm
    {
        private readonly ThreadedRenderer _renderer;

        public IProgram Base;

        internal bool Compiled;

        // S2A（10-24）：渲染线程得出的链接结果（-1 = 还没得出），GPU 模拟线程不经命令往返就能读（ThreadedRenderer.S2ALinkStatusNoWait）
        internal volatile int S2AStatus = -1;

        // S2A：要存进磁盘缓存的程序（ShaderCache 入队时置位）：渲染线程得出链接成功时顺手取好二进制，GPU 模拟线程取时不再发命令等渲染线程
        internal volatile bool S2AWantBinary;
        internal byte[] S2ABinary;

        /// <summary>S2A：渲染线程上记下链接结果（要二进制的先取好再记，读的一方先看到结果就一定看到二进制）</summary>
        internal void S2ARecord(ProgramLinkStatus status)
        {
            if (status == ProgramLinkStatus.Success && S2AWantBinary && S2ABinary == null)
            {
                S2ABinary = Base.GetBinary();
            }

            S2AStatus = (int)status;
        }

        public ThreadedProgram(ThreadedRenderer renderer)
        {
            _renderer = renderer;
        }

        string IProgramBinaryLoadFailure.ProgramBinaryLoadFailure =>
            (Base as IProgramBinaryLoadFailure)?.ProgramBinaryLoadFailure;

        private TableRef<T> Ref<T>(T reference)
        {
            return new TableRef<T>(_renderer, reference);
        }

        public unsafe void Dispose()
        {
            if (_renderer.S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层对象不逐个释放（ThreadedRenderer.S2ADiscardFrees）
            }

            _renderer.New<ProgramDisposeCommand>()->Set(Ref(this));
            _renderer.QueueCommand();
        }

        public unsafe byte[] GetBinary()
        {
            ResultBox<byte[]> box = new();
            _renderer.New<ProgramGetBinaryCommand>()->Set(Ref(this), Ref(box));
            _renderer.InvokeCommand();

            return box.Result;
        }

        /// <summary>
        /// S2A：加载屏预热。GPU 线程上不能直接碰下层 Vulkan 程序，交给渲染线程：
        /// 先让 ProgramQueue 建好 / 链接 Base（ShaderCollection），再等它的后台管线预建。
        /// </summary>
        public bool S2AWaitForBackgroundPipeline(int timeoutMs)
        {
            if (!_renderer.IsGpuThread())
            {
                return false;
            }

            bool waited = false;
            _renderer.S2AOnRenderThread(() =>
            {
                _renderer.Programs.WaitForProgram(this);
                if (Base is IS2APipelineWarm warmable)
                {
                    waited = warmable.S2AWaitForBackgroundPipeline(timeoutMs);
                }
            });
            return waited;
        }

        public unsafe ProgramLinkStatus CheckProgramLink(bool blocking)
        {
            ResultBox<ProgramLinkStatus> box = new();
            _renderer.New<ProgramCheckLinkCommand>()->Set(Ref(this), blocking, Ref(box));
            _renderer.InvokeCommand();

            return box.Result;
        }
    }
}
