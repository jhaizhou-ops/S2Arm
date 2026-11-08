// CPU-only host seams. No binding allocation, reservation or capacity logic lives here.
using System;
using Ryujinx.Graphics.GAL;
namespace Ryujinx.Common.Logging
{
    enum LogClass { Gpu }
    static class Logger { public static LogSink Error => new(); }
    class LogSink { public void Print(LogClass _, string message) => throw new Exception(message); }
}
namespace Ryujinx.Graphics.GAL
{
    interface IRenderer { }
    public class ComputeTranslationProfile
    {
        public bool StorageWindowClamp => throw new NotSupportedException();
        public bool StorageOobRecord => throw new NotSupportedException();
        public void RequireCapabilities(in Capabilities _) => throw new NotSupportedException();
    }
}
namespace Ryujinx.Graphics.GAL.Multithreading
{
    class ThreadedRenderer : IRenderer { public IRenderer BaseRenderer => throw new NotSupportedException(); }
}
namespace Ryujinx.Graphics.Gpu
{
    class GpuContext { public IRenderer Renderer = null; public Capabilities Capabilities; }
}
namespace Ryujinx.Graphics.Gpu.Image
{
    struct FormatInfo { public Format Format => throw new NotSupportedException(); }
    static class FormatTable
    {
        public static bool TryGetTextureFormat(uint _, bool __, out FormatInfo info) => throw new NotSupportedException();
    }
}
namespace Ryujinx.Graphics.Shader
{
    interface IGpuAccessor
    {
        bool QueryHostSupportsViewportIndexVertexTessellation();
        bool QueryHostSupportsViewportMask();
        bool QueryGeometryInputFixed() => false;   // 同真接口缺省（直连离线几何才答真，ResourceReservations 问）
    }
}
