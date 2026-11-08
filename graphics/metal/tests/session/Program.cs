// 真 ThreadedRenderer + NxGal：同进程反复建渲染器、GPU 清屏/读回/呈现，再关停重建。
// 不加载游戏，不替换 GAL 或宿主符号。无窗口时生产 nxgal_present 仍定格、提交 GPU，回调仅记实际命令执行次数。
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static unsafe class Program
{
    const int Frames = 120;
    const int Resources = 10032; // 超过 ThreadedRenderer 的 10000 项命令环。
    static delegate* unmanaged<byte*, nuint, void> s_bufferNote;
    static delegate* unmanaged<void*, int, int*, int*, int> s_screenshot;
    static bool s_stopBackendFirst;

    static void Require(bool ok, string message)
    {
        if (!ok) throw new InvalidOperationException(message);
    }

    static void Session(int round)
    {
        NxRenderer nx = new();
        ThreadedRenderer renderer = new(nx);
        using ManualResetEventSlim gpuDone = new(false), backendDone = new(false);
        Exception error = null;
        int presented = 0;
        BufferHandle[] buffers = new BufferHandle[Resources];
        Thread gpu = null;
        ThreadedRenderer.S2AStartThread = (_, body) =>
        {
            gpu = new Thread(() => body()) { IsBackground = true, Name = "Session.Gpu" };
            gpu.Start();
        };
        Thread backend = new(() =>
        {
            try
            {
                renderer.Initialize(GraphicsDebugLevel.None);
                renderer.RunLoop(() =>
                {
                    try
                    {
                        TextureCreateInfo info = new(16, 16, 1, 1, 1, 1, 1, 4,
                            Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
                            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
                        ITexture texture = renderer.CreateTexture(info);
                        renderer.Pipeline.SetRenderTargets(new[] { texture }, null);
                        renderer.Pipeline.SetScissors(new[] { new Rectangle<int>(0, 0, 16, 16) });
                        ImageCrop crop = new(0, 0, 0, 0, false, false, false, 1, 1);
                        byte* captured = stackalloc byte[16 * 16 * 4];
                        for (int frame = 0; frame < Frames; frame++)
                        {
                            int red = (frame + round) & 1;
                            renderer.Pipeline.ClearRenderTargetColor(0, 0, 1, 15, new ColorF(red, 0, 1, 1));
                            renderer.Window.Present(texture, crop, () => Interlocked.Increment(ref presented));
                            using PinnedSpan<byte> pixels = texture.GetData();
                            ReadOnlySpan<byte> data = pixels.Get();
                            Require(data.Length == 16 * 16 * 4, "GPU 读回尺寸不符");
                            for (int i = 0; i < data.Length; i += 4)
                                Require(data[i] == red * 255 && data[i + 1] == 0 && data[i + 2] == 255 && data[i + 3] == 255,
                                    $"第 {round} 局第 {frame} 帧 GPU 读回不符，像素 {i / 4}");
                            int width = 0, height = 0;
                            Require(s_screenshot(captured, 16 * 16 * 4, &width, &height) == 16 * 16 * 4 && width == 16 && height == 16,
                                $"第 {round} 局第 {frame} 帧实际呈现定格图缺失，回调计数不能证明呈现成功");
                            for (int i = 0; i < 16 * 16 * 4; i += 4)
                                Require(captured[i] == 255 && captured[i + 1] == 0 && captured[i + 2] == red * 255 && captured[i + 3] == 255,
                                    $"第 {round} 局第 {frame} 帧实际呈现定格图像素 {i / 4} 不符（BGRA）");
                        }
                        texture.Release();
                        for (int i = 0; i < buffers.Length; i++) buffers[i] = renderer.CreateBuffer(16, BufferAccess.Default);
                        renderer.SetBufferData(buffers[^1], 0, new byte[] { 0x17, 0x53, 0xa9, 0xe2 });
                        using (PinnedSpan<byte> bytes = renderer.GetBufferData(buffers[^1], 0, 4))
                            Require(bytes.Get().SequenceEqual(new byte[] { 0x17, 0x53, 0xa9, 0xe2 }), "最后一个小缓冲的实际读回不符");
                        renderer.FlushThreadedCommands();
                    }
                    catch (Exception e) { error = e; }
                    finally { gpuDone.Set(); }
                });
            }
            catch (Exception e) { error = e; }
            finally { backendDone.Set(); }
        }) { IsBackground = true, Name = "Session.Backend" };
        backend.Start();
        if (!gpuDone.Wait(15000))
            throw new TimeoutException($"第 {round} 局 GPU 线程未完成，已执行呈现 {Volatile.Read(ref presented)}（S2A_THREADED_TRACE=1 查看队列）");
        Require(gpu != null && gpu.Join(3000), "GPU 生产者未 join，不能进入资源析构");
        if (error != null) throw error;
        nx.RequestStop();
        Require(BufferNote().StartsWith($"GAL 缓冲 {Resources} 个 ", StringComparison.Ordinal), "实际 Metal 缓冲数量不符");
        if (s_stopBackendFirst)
        {
            renderer.S2AStopBackend();
            Require(backendDone.Wait(3000) && backend.Join(3000), "旧顺序反证：编码线程未停");
        }
        using ManualResetEventSlim resourcesReleased = new(false);
        Thread cleanup = new(() =>
        {
            try
            {
                foreach (BufferHandle buffer in buffers) renderer.DeleteBuffer(buffer);
                renderer.S2ADrainForShutdown(3000);
            }
            catch (Exception e) { error = e; }
            finally { resourcesReleased.Set(); }
        }) { IsBackground = true, Name = "Session.Dispose" };
        cleanup.Start();
        Require(resourcesReleased.Wait(5000) && cleanup.Join(3000), "资源释放队列堵住：编码线程不能先于 GpuContext 资源析构退出");
        if (error != null) throw error;
        Require(BufferNote().StartsWith("GAL 缓冲 0 个 ", StringComparison.Ordinal), "Renderer.Dispose 前仍有实际 Metal 缓冲未释放");
        renderer.S2AStopBackend();
        Require(backendDone.Wait(3000) && backend.Join(3000), "编码线程未退出，保留旧资源");
        if (error != null) throw error;
        Require(presented == Frames, $"呈现回调 {presented}，预期 {Frames}");
        nx.RequestStop();
        renderer.Dispose();
        ThreadedRenderer.S2AStartThread = null;
        Console.WriteLine($"ThreadedRenderer session {round}: {presented}/{Frames} presents + GPU readback; {Resources} Metal buffers released before renderer disposal");
    }

    static string BufferNote()
    {
        byte* text = stackalloc byte[2048];
        s_bufferNote(text, 2048);
        int length = 0;
        while (length < 2048 && text[length] != 0) length++;
        return Encoding.UTF8.GetString(text, length);
    }

    sealed class NativeSession
    {
        public int Round;
        public Exception Error;
        public readonly ManualResetEventSlim Done = new(false);
    }

    [UnmanagedCallersOnly]
    static void NativeEntry(nint arg)
    {
        NativeSession state = (NativeSession)GCHandle.FromIntPtr(arg).Target;
        try { Session(state.Round); }
        catch (Exception e) { state.Error = e; }
        finally { state.Done.Set(); }
    }

    static void OnNativeThread(int round)
    {
        NativeSession state = new() { Round = round };
        GCHandle handle = GCHandle.Alloc(state);
        nint thread;
        int rc;
        fixed (byte* name = "Session.Restart\0"u8)
            rc = NxThread.StartJoinable(&NativeEntry, GCHandle.ToIntPtr(handle), 0x21, name, out thread);
        Require(rc == 0, $"原生会话线程创建失败 {rc}");
        Require(state.Done.Wait(20000), "原生会话线程未完成");
        NxThread.Join(ref thread);
        handle.Free();
        state.Done.Dispose();
        if (state.Error != null) throw state.Error;
    }

    static int Main(string[] args)
    {
        try
        {
            string library = Environment.GetEnvironmentVariable("NXGAL_LIB") ?? throw new InvalidOperationException("请指定生产 NXGAL_LIB 路径");
            nint native = NativeLibrary.Load(library);
            s_bufferNote = (delegate* unmanaged<byte*, nuint, void>)NativeLibrary.GetExport(native, "gal_buf_va_note");
            s_screenshot = (delegate* unmanaged<void*, int, int*, int*, int>)NativeLibrary.GetExport(native, "nxgal_screenshot");
            s_stopBackendFirst = Array.IndexOf(args, "--stop-backend-before-disposal") >= 0;
            for (int i = 1; i <= 10; i++)
            {
                if (i > 1 && Array.IndexOf(args, "--native-create") >= 0) OnNativeThread(i);
                else Session(i);
            }
            NativeLibrary.Free(native);
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            // 超时可能仍有阻塞的渲染线程；不可释放它还在用的资源。
            Environment.Exit(1);
            return 1;
        }
    }
}
