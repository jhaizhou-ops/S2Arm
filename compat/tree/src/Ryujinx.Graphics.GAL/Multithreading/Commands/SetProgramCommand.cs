using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands
{
    struct SetProgramCommand : IGALCommand, IGALCommand<SetProgramCommand>
    {
        public readonly CommandType CommandType => CommandType.SetProgram;
        private TableRef<IProgram> _program;

        public void Set(TableRef<IProgram> program)
        {
            _program = program;
        }

        public static void Run(ref SetProgramCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedProgram program = command._program.GetAs<ThreadedProgram>(threaded);

            threaded.Programs.WaitForProgram(program);

            if (program.Base is IProgramBinaryLoadFailure failure &&
                failure.ProgramBinaryLoadFailure is string reason)
            {
                // Android uses the direct renderer, where the lazy materializer handles this
                // before wrapping. A threaded backend reaches this point after its deferred
                // create; fail precisely instead of casting a placeholder to a ShaderCollection.
                throw new System.InvalidOperationException($"Rejected host program reached SetProgram: {reason}");
            }

            renderer.Pipeline.SetProgram(program.Base);
        }
    }
}
