// Test the actual managed attach boundary against a native failure producer.
// UIKit presentation and guest suspension still require iOS validation.
using System;
using System.IO;
using System.Runtime.InteropServices;
using NxGal;

namespace Ryujinx.Graphics.GAL { public interface IRenderer { } }
namespace NxGal
{
    static partial class N
    {
        const string Lib = "ios_attach_fixture";
        [DllImport(Lib)] internal static extern void fixture_result(int result);
        [DllImport(Lib)] internal static extern int fixture_reports();
    }
}

static class Program
{
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static void Main(string[] args)
    {
        NativeLibrary.SetDllImportResolver(typeof(NxIosLayer).Assembly, (name, asm, path) => NativeLibrary.Load(args[0]));
        N.fixture_result(-1);
        bool typed = false;
        try { NxIosLayer.Attach(null); } catch (IosLayerAttachException) { typed = true; }
        Check(typed && N.fixture_reports() == 0, "Attach must distinguish attach failure from unrelated renderer exceptions");
        var original = Console.Error;
        var log = new StringWriter();
        bool attached;
        Console.SetError(log);
        try { attached = NxIosLayer.TryAttach(null); }
        finally { Console.SetError(original); }
        Check(!attached && N.fixture_reports() == 1, "Failed attach must return without throwing and notify the shell exactly once");
        Check(log.ToString().Contains(nameof(IosLayerAttachException)) && log.ToString().Contains("NxIosLayer.Attach"), "Failure must preserve the exception and managed stack in the log");
        N.fixture_result(0);
        Check(NxIosLayer.TryAttach(null) && N.fixture_reports() == 0, "Successful attach must not notify failure");
        Console.WriteLine("PASS iOS attach: typed failure, caught failure + shell notification, stack log, success");
    }
}
