// 宽屏层不能包加载失败的程序：上层靠 IProgramBinaryLoadFailure 的原因认失败，包一层就认不出来。
// 不需要真实后端：底层渲染器只用到 LoadProgramBinary。
using System;
using System.Reflection;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen.Gal;

static class LoadFailureCheck
{
    class Plain : IProgram
    {
        public ProgramLinkStatus CheckProgramLink(bool blocking) => ProgramLinkStatus.Success;
        public byte[] GetBinary() => [];
        public void Dispose() { }
    }

    sealed class Loaded(string reason) : Plain, IProgramBinaryLoadFailure
    {
        public string ProgramBinaryLoadFailure => reason;
    }

    class FakeRenderer : DispatchProxy
    {
        public IProgram Next;
        protected override object Invoke(MethodInfo method, object[] args)
        {
            if (method.Name == nameof(IRenderer.LoadProgramBinary)) return Next;
            throw new NotSupportedException(method.Name);
        }
    }

    static IProgram Load(IProgram next)
    {
        IRenderer inner = DispatchProxy.Create<IRenderer, FakeRenderer>();
        ((FakeRenderer)(object)inner).Next = next;
        return new WidenRenderer(inner, 2868f / 1320).LoadProgramBinary([], true, new ShaderInfo(-1, default, false));
    }

    public static void Run()
    {
        var failed = new Loaded("IDENTITY: test");
        if (!ReferenceEquals(Load(failed), failed)) throw new InvalidOperationException("带原因的失败要原样返回同一对象");
        if (Load(new Loaded(null)).GetType().Name != "WidenProgram") throw new InvalidOperationException("原因为空表示还在处理，要照常包");
        if (Load(new Plain()).GetType().Name != "WidenProgram") throw new InvalidOperationException("普通程序要照常包");
        Console.WriteLine("LoadFailureCheck 通过");
    }
}
