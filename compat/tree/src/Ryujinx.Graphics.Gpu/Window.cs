using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Texture;
using Ryujinx.Memory.Range;
using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Ryujinx.Graphics.Gpu
{
    /// <summary>
    /// GPU image presentation window.
    /// </summary>
    public class Window
    {
        private readonly GpuContext _context;

        /// <summary>
        /// Texture presented on the window.
        /// </summary>
        private readonly struct PresentationTexture
        {
            /// <summary>
            /// Texture cache where the texture might be located.
            /// </summary>
            public TextureCache Cache { get; }

            /// <summary>
            /// Texture information.
            /// </summary>
            public TextureInfo Info { get; }

            /// <summary>
            /// Physical memory locations where the texture data is located.
            /// </summary>
            public MultiRange Range { get; }

            /// <summary>
            /// Texture crop region.
            /// </summary>
            public ImageCrop Crop { get; }

            /// <summary>
            /// Texture acquire callback.
            /// </summary>
            public Action<GpuContext, object> AcquireCallback { get; }

            /// <summary>
            /// Texture release callback.
            /// </summary>
            public Action<object> ReleaseCallback { get; }

            /// <summary>
            /// User defined object, passed to the various callbacks.
            /// </summary>
            public object UserObj { get; }

            /// <summary>
            /// Creates a new instance of the presentation texture.
            /// </summary>
            /// <param name="cache">Texture cache used to look for the texture to be presented</param>
            /// <param name="info">Information of the texture to be presented</param>
            /// <param name="range">Physical memory locations where the texture data is located</param>
            /// <param name="crop">Texture crop region</param>
            /// <param name="acquireCallback">Texture acquire callback</param>
            /// <param name="releaseCallback">Texture release callback</param>
            /// <param name="userObj">User defined object passed to the release callback, can be used to identify the texture</param>
            public PresentationTexture(
                TextureCache cache,
                TextureInfo info,
                MultiRange range,
                ImageCrop crop,
                Action<GpuContext, object> acquireCallback,
                Action<object> releaseCallback,
                object userObj)
            {
                Cache = cache;
                Info = info;
                Range = range;
                Crop = crop;
                AcquireCallback = acquireCallback;
                ReleaseCallback = releaseCallback;
                UserObj = userObj;
            }
        }

        private readonly ConcurrentQueue<PresentationTexture> _frameQueue;

        private int _framesAvailable;

        public bool IsFrameAvailable => _framesAvailable != 0;

        /// <summary>
        /// Creates a new instance of the GPU presentation window.
        /// </summary>
        /// <param name="context">GPU emulation context</param>
        public Window(GpuContext context)
        {
            _context = context;

            _frameQueue = new ConcurrentQueue<PresentationTexture>();
        }

        /// <summary>
        /// Enqueues a frame for presentation.
        /// This method is thread safe and can be called from any thread.
        /// When the texture is presented and not needed anymore, the release callback is called.
        /// It's an error to modify the texture after calling this method, before the release callback is called.
        /// </summary>
        /// <param name="pid">Process ID of the process that owns the texture pointed to by <paramref name="address"/></param>
        /// <param name="address">CPU virtual address of the texture data</param>
        /// <param name="width">Texture width</param>
        /// <param name="height">Texture height</param>
        /// <param name="stride">Texture stride for linear texture, should be zero otherwise</param>
        /// <param name="isLinear">Indicates if the texture is linear, normally false</param>
        /// <param name="gobBlocksInY">GOB blocks in the Y direction, for block linear textures</param>
        /// <param name="format">Texture format</param>
        /// <param name="bytesPerPixel">Texture format bytes per pixel (must match the format)</param>
        /// <param name="crop">Texture crop region</param>
        /// <param name="acquireCallback">Texture acquire callback</param>
        /// <param name="releaseCallback">Texture release callback</param>
        /// <param name="userObj">User defined object passed to the release callback</param>
        /// <exception cref="ArgumentException">Thrown when <paramref name="pid"/> is invalid</exception>
        /// <returns>True if the frame was added to the queue, false otherwise</returns>
        private sealed class S2AFrameSize
        {
            public readonly int Width, Height, GobBlocksInY, Size;
            public readonly byte BytesPerPixel;

            public S2AFrameSize(int width, int height, byte bytesPerPixel, int gobBlocksInY, int size)
            {
                Width = width;
                Height = height;
                BytesPerPixel = bytesPerPixel;
                GobBlocksInY = gobBlocksInY;
                Size = size;
            }
        }

        private volatile S2AFrameSize _s2aFrameSize;

        public bool EnqueueFrameThreadSafe(
            ulong pid,
            ulong address,
            int width,
            int height,
            int stride,
            bool isLinear,
            int gobBlocksInY,
            Format format,
            byte bytesPerPixel,
            ImageCrop crop,
            Action<GpuContext, object> acquireCallback,
            Action<object> releaseCallback,
            object userObj)
        {
            if (!_context.PhysicalMemoryRegistry.TryGetValue(pid, out PhysicalMemory physicalMemory))
            {
                return false;
            }

            FormatInfo formatInfo = new(format, 1, 1, bytesPerPixel, 4);

            TextureInfo info = new(
                0UL,
                width,
                height,
                1,
                1,
                1,
                1,
                stride,
                isLinear,
                gobBlocksInY,
                1,
                1,
                Target.Texture2D,
                formatInfo);

            // S2Arm: SizeCalculator builds four per-level arrays every call (4 x int[1] = 128 B for a frame buffer); the compositor calls
            // this every frame with the same size (10-21 iPhone: compositor 128 B per frame, the last steady allocation on that thread).
            // Remember the last size: immutable memo swapped as one reference, so concurrent callers never mix fields of two sizes
            S2AFrameSize memo = _s2aFrameSize;
            int size;

            if (memo != null && memo.Width == width && memo.Height == height && memo.BytesPerPixel == bytesPerPixel && memo.GobBlocksInY == gobBlocksInY)
            {
                size = memo.Size;
            }
            else
            {
                size = SizeCalculator.GetBlockLinearTextureSize(
                    width,
                    height,
                    1,
                    1,
                    1,
                    1,
                    1,
                    bytesPerPixel,
                    gobBlocksInY,
                    1,
                    1).TotalSize;

                _s2aFrameSize = new S2AFrameSize(width, height, bytesPerPixel, gobBlocksInY, size);
            }

            MultiRange range = new(address, (ulong)size);

            _frameQueue.Enqueue(new PresentationTexture(
                physicalMemory.TextureCache,
                info,
                range,
                crop,
                acquireCallback,
                releaseCallback,
                userObj));

            return true;
        }

        /// <summary>
        /// Presents a texture on the queue.
        /// If the queue is empty, then no texture is presented.
        /// </summary>
        /// <param name="swapBuffersCallback">Callback method to call when a new texture should be presented on the screen</param>
        public void Present(Action swapBuffersCallback)
        {
            _context.AdvanceSequence();

            if (_frameQueue.TryDequeue(out PresentationTexture pt))
            {
                long s2aA = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0; // S2A：渲染线程分配拆账（上屏各步）
                pt.AcquireCallback(_context, pt.UserObj);
                if (S2AAllocTrace.On) { long t = S2AAllocTrace.Now(); S2AAllocTrace.Raw(0x40_0008, t - s2aA); s2aA = t; }

                Image.Texture texture = pt.Cache.FindOrCreateTexture(null, TextureSearchFlags.WithUpscale, pt.Info, 0, range: pt.Range);

                pt.Cache.Tick();

                texture.SynchronizeMemory();
                if (S2AAllocTrace.On) { long t = S2AAllocTrace.Now(); S2AAllocTrace.Raw(0x40_0009, t - s2aA); s2aA = t; }

                ImageCrop crop = new(
                    (int)(pt.Crop.Left * texture.ScaleFactor),
                    (int)MathF.Ceiling(pt.Crop.Right * texture.ScaleFactor),
                    (int)(pt.Crop.Top * texture.ScaleFactor),
                    (int)MathF.Ceiling(pt.Crop.Bottom * texture.ScaleFactor),
                    pt.Crop.FlipX,
                    pt.Crop.FlipY,
                    pt.Crop.IsStretched,
                    pt.Crop.AspectRatioX,
                    pt.Crop.AspectRatioY);

                if (texture.Info.Width > pt.Info.Width || texture.Info.Height > pt.Info.Height)
                {
                    int top = crop.Top;
                    int bottom = crop.Bottom;
                    int left = crop.Left;
                    int right = crop.Right;

                    if (top == 0 && bottom == 0)
                    {
                        bottom = Math.Min(texture.Info.Height, pt.Info.Height);
                    }

                    if (left == 0 && right == 0)
                    {
                        right = Math.Min(texture.Info.Width, pt.Info.Width);
                    }

                    crop = new ImageCrop(left, right, top, bottom, crop.FlipX, crop.FlipY, crop.IsStretched, crop.AspectRatioX, crop.AspectRatioY);
                }

                _context.Renderer.Window.Present(texture.HostTexture, crop, swapBuffersCallback);
                if (S2AAllocTrace.On) { long t = S2AAllocTrace.Now(); S2AAllocTrace.Raw(0x40_000a, t - s2aA); s2aA = t; }

                pt.ReleaseCallback(pt.UserObj);
                if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_000b, S2AAllocTrace.Now() - s2aA);
            }
        }

        /// <summary>
        /// Indicate that a frame on the queue is ready to be acquired.
        /// </summary>
        public void SignalFrameReady()
        {
            Interlocked.Increment(ref _framesAvailable);
            _context.GPFifo.S2AWake(); // S2A：S2A_FIFO_WAIT_MS 设了时，就绪即唤醒渲染循环（不靠超时轮询）
        }

        /// <summary>
        /// Determine if any frames are available, and decrement the available count if there are.
        /// </summary>
        /// <returns>True if a frame is available, false otherwise</returns>
        public bool ConsumeFrameAvailable()
        {
            if (Interlocked.CompareExchange(ref _framesAvailable, 0, 0) != 0)
            {
                Interlocked.Decrement(ref _framesAvailable);

                return true;
            }

            return false;
        }
    }
}
