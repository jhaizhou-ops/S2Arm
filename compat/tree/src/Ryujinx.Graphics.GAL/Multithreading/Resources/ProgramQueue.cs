using Ryujinx.Graphics.GAL.Multithreading.Resources.Programs;
using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    /// <summary>
    /// A structure handling multithreaded compilation for programs.
    /// </summary>
    class ProgramQueue
    {
        private const int MaxConcurrentCompilations = 8;

        private readonly IRenderer _renderer;

        private readonly Queue<IProgramRequest> _toCompile;
        private readonly List<ThreadedProgram> _inProgress;

        public ProgramQueue(IRenderer renderer)
        {
            _renderer = renderer;

            _toCompile = new Queue<IProgramRequest>();
            _inProgress = [];
        }

        public void Add(IProgramRequest request)
        {
            lock (_toCompile)
            {
                _toCompile.Enqueue(request);
            }
        }

        public void ProcessQueue()
        {
            for (int i = 0; i < _inProgress.Count; i++)
            {
                ThreadedProgram program = _inProgress[i];

                ProgramLinkStatus status = program.Base.CheckProgramLink(false);

                if (status != ProgramLinkStatus.Incomplete)
                {
                    program.S2ARecord(status);
                    program.Compiled = true;
                    _inProgress.RemoveAt(i--);
                }
            }

            int freeSpace = MaxConcurrentCompilations - _inProgress.Count;

            for (int i = 0; i < freeSpace; i++)
            {
                // Begin compilation of some programs in the compile queue.
                IProgramRequest program;

                lock (_toCompile)
                {
                    if (!_toCompile.TryDequeue(out program))
                    {
                        break;
                    }
                }

                if (program.Threaded.Base != null)
                {
                    ProgramLinkStatus status = program.Threaded.Base.CheckProgramLink(false);

                    if (status != ProgramLinkStatus.Incomplete)
                    {
                        // This program is already compiled. Keep going through the queue.
                        program.Threaded.S2ARecord(status);
                        program.Threaded.Compiled = true;
                        i--;
                        continue;
                    }
                }
                else
                {
                    program.Threaded.Base = program.Create(_renderer);
                }

                _inProgress.Add(program.Threaded);
            }
        }

        /// <summary>
        /// Process the queue until the given program has finished compiling.
        /// This will begin compilation of other programs on the queue as well.
        /// </summary>
        /// <param name="program">The program to wait for</param>
        public void WaitForProgram(ThreadedProgram program)
        {
            // S2A：不自旋轮询——对所等的程序阻塞查询，后端在本线程就地编（或等已在编的作业）；还在排队没建的当场建。
            // 原先只轮询 CheckProgramLink(false)：所等程序的作业排在后台低优先级现编队列后面、或卡在写缓存，渲染线程就一直转，
            // 出图停 60 秒以上（10-24 原生层线 xc3 / 怪猎 / 巫师3 / 马车8 九局同形）
            if (program.Compiled)
            {
                return;
            }

            ProcessQueue();

            if (!program.Compiled && (program.Base != null || S2ACreateQueued(program)))
            {
                program.S2ARecord(program.Base.CheckProgramLink(true));
                program.Compiled = true;
                return;
            }

            Span<SpinWait> spinWait = stackalloc SpinWait[1];

            while (!program.Compiled)
            {
                ProcessQueue();

                if (!program.Compiled)
                {
                    spinWait[0].SpinOnce(-1);
                }
            }
        }

        /// <summary>
        /// S2A：所等程序还在待编队列里（在编的已满 MaxConcurrentCompilations）：当场建它的宿主程序。
        /// 它出队时走「Base 已有」那一支（查状态、记已编），不会再建一次
        /// </summary>
        private bool S2ACreateQueued(ThreadedProgram program)
        {
            IProgramRequest request = null;

            lock (_toCompile)
            {
                foreach (IProgramRequest r in _toCompile)
                {
                    if (r.Threaded == program)
                    {
                        request = r;
                        break;
                    }
                }
            }

            if (request == null)
            {
                return false;
            }

            program.Base = request.Create(_renderer);

            return true;
        }
    }
}
