using Microsoft.Win32.SafeHandles;
using System;
using System.Buffers.Text;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;

namespace S2A.Android.Aot
{
    // 复用 PR209 (wdjwxh, 3cf0a48e) 的显式诊断生产者。每帧状态归 GPU 线程。
    // 每帧同步写文件有开销；这是成功排队后的 CPU 节拍，不是显示/GPU 时间。
    // The control thread only publishes a one-shot MARK request.
    public sealed class AndroidRunMetrics : IDisposable
    {
        private readonly SafeFileHandle _frames;
        private readonly Func<long> _clock;
        private readonly Thread _control;
        private readonly ManualResetEventSlim _stop = new(false);
        private readonly object _intervalLock = new();
        private readonly long[] _intervalTime = new long[8];
        private int _interval = -1, _markRequested;
        private long _intervalAt, _offset, _previous, _allocated, _pauseTicks, _frame;
        private readonly long _startUs;
        private long _markFrame = -1, _markUs = -1, _lastUs = -1, _endUs = -1;
        private float _refresh = 60;
        private bool _disposed;
        private string _failure;
        public string DirectoryPath { get; }
        public string Id { get; }

        public static AndroidRunMetrics TryStart(string state, ulong session)
        {
            if (!File.Exists(Path.Combine(state, "metrics.enable"))) return null;
            return new AndroidRunMetrics(state, session, BootMicroseconds);
        }

        // Explicit clock injection lets host tests run this actual producer without Bionic.
        public AndroidRunMetrics(string state, ulong session, Func<long> clock)
        {
            _clock = clock ?? throw new ArgumentNullException(nameof(clock));
            _startUs = _clock();
            Id = $"metrics-{session}-{Environment.ProcessId}-{Guid.NewGuid():N}";
            DirectoryPath = Path.Combine(state, Id);
            Directory.CreateDirectory(DirectoryPath);
            _frames = File.OpenHandle(Path.Combine(DirectoryPath, "frames.tsv"), FileMode.CreateNew,
                FileAccess.Write, FileShare.Read);
            Write("frame\twall_us\talloc_b\tgc0\tgc1\tgc2\tgc_pause_us\tboot_us\n"u8);
            Metadata("capturing");
            File.WriteAllText(Path.Combine(state, "metrics-active.txt"), Id + "\n");
            Console.Error.WriteLine($"[Android metrics] id={Id}; clock=CLOCK_BOOTTIME; frameSource=guest-present; event=successful-queue-present-return; synchronousFileIo=true");
            _control = new Thread(Control) { Name = "S2A.Metrics", IsBackground = true };
            _control.Start();
        }

        public void SetRefresh(float hz)
        {
            if (!float.IsFinite(hz) || hz <= 0) throw new ArgumentOutOfRangeException(nameof(hz));
            _refresh = hz;
        }

        public void FrameInterval(float seconds)
        {
            if (!float.IsFinite(seconds) || seconds < 0) return;
            int interval = seconds == 0 ? 0 : Math.Clamp((int)Math.Round(seconds * _refresh), 1, 7);
            lock (_intervalLock)
            {
                if (_disposed) return;
                long now = _clock();
                if (_interval >= 0) _intervalTime[_interval] += now - _intervalAt;
                _interval = interval; _intervalAt = now;
                Console.Error.WriteLine("[gal] " + IntervalLine(interval, now));
            }
        }

        // 声明行尾自带 CLOCK_BOOTTIME 微秒（与 frames.tsv boot_us 同钟）：分析侧按本局
        // BOOTTIME−MONOTONIC 偏移换算后与 actualPresentTime 分段对齐；戳放行尾保住
        // 「[gal] 帧节拍：交换间隔…」固定前缀，下游按 fullmatch 消费的工具照认旧行。
        private string IntervalLine(int interval, long us) => interval == 0
            ? $"帧节拍：交换间隔 0，每帧 0.0 ms（0 帧/秒） boot_us={us}"
            : string.Create(CultureInfo.InvariantCulture,
                $"帧节拍：交换间隔 {interval}，每帧 {interval * 1000.0 / _refresh:F1} ms（{_refresh / interval:F1} 帧/秒） boot_us={us}");

        public void RequestMark() => Interlocked.Exchange(ref _markRequested, 1);

        public void Present(ulong queuedPresent)
        {
            if (_failure != null || _disposed) return;
            try
            {
                long now = _clock(), allocated = GC.GetTotalAllocatedBytes(false);
                long pause = GC.GetTotalPauseDuration().Ticks;
                Span<byte> row = stackalloc byte[256]; int n = 0;
                Add(row, ref n, _frame, '\t');
                Add(row, ref n, _frame == 0 ? 0 : now - _previous, '\t');
                Add(row, ref n, _frame == 0 ? 0 : Math.Max(0, allocated - _allocated), '\t');
                Add(row, ref n, GC.CollectionCount(0), '\t');
                Add(row, ref n, GC.CollectionCount(1), '\t');
                Add(row, ref n, GC.CollectionCount(2), '\t');
                Add(row, ref n, _frame == 0 ? 0 : Math.Max(0, (pause - _pauseTicks) / 10), '\t');
                Add(row, ref n, now, '\n');
                Write(row[..n]);
                _previous = _lastUs = now; _allocated = allocated; _pauseTicks = pause;
                if (_frame > 0 && _markFrame < 0 && Interlocked.Exchange(ref _markRequested, 0) != 0)
                {
                    _markFrame = _frame; _markUs = now;
                    Console.Error.WriteLine($"S2A 标记 MARK：帧 {_frame}");
                    Console.Error.WriteLine($"[Android metrics] MARK boot_us={now}; queued_present={queuedPresent}");
                }
                _frame++;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                _failure = error.Message;
                Console.Error.WriteLine("[Android metrics] capture failed: " + error.Message);
            }
        }

        private static void Add(Span<byte> bytes, ref int offset, long value, char delimiter)
        {
            if (!Utf8Formatter.TryFormat(value, bytes[offset..], out int count)) throw new InvalidOperationException("metrics row overflow");
            offset += count; bytes[offset++] = (byte)delimiter;
        }

        private void Write(ReadOnlySpan<byte> bytes)
        {
            RandomAccess.Write(_frames, bytes, _offset); _offset += bytes.Length;
        }

        private void Control()
        {
            string request = Path.Combine(DirectoryPath, "mark.request");
            while (!_stop.Wait(250))
            {
                try
                {
                    if (File.Exists(request)) { File.Delete(request); RequestMark(); }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    Console.Error.WriteLine("[Android metrics] MARK request failed: " + error.Message);
                }
            }
        }

        private void Metadata(string status)
        {
            string path = Path.Combine(DirectoryPath, "runtime-metrics.json");
            string json = JsonSerializer.Serialize(new MetadataRecord
            {
                id = Id, status = status, frameSource = "guest-present", clock = "CLOCK_BOOTTIME",
                frames = _frame, markFrame = _markFrame, markBootUs = _markUs,
                startBootUs = _startUs, lastFrameBootUs = _lastUs, endBootUs = _endUs,
                error = _failure,
            }, MetricsJsonContext.Default.MetadataRecord);
            File.WriteAllText(path + ".tmp", json + "\n");
            File.Move(path + ".tmp", path, true);
        }

        public void Dispose()
        {
            lock (_intervalLock)
            {
                if (_disposed) return;
                // GPU 已停，但 SurfaceFlinger 节拍回调仍可能在途；先排空同锁回调，
                // 再采结束钟并结算，不能让回调把 _intervalAt 推进到结束钟之后。
                _endUs = _clock();
                _disposed = true;
                if (_interval >= 0)
                {
                    _intervalTime[_interval] += _endUs - _intervalAt;
                    int best = 0;
                    for (int i = 1; i < 8; i++) if (_intervalTime[i] > _intervalTime[best]) best = i;
                    Console.Error.WriteLine("[gal] 收局 " + IntervalLine(best, _endUs));
                }
            }
            // 不持节拍锁等待控制线程或磁盘 IO。
            _stop.Set(); _control.Join();
            try { RandomAccess.FlushToDisk(_frames); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { _failure = error.Message; }
            finally { _frames.Dispose(); }
            try { Metadata(_failure == null ? "completed" : "failed"); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Console.Error.WriteLine("[Android metrics] final metadata failed; capture is invalid: " + error.Message);
            }
            _stop.Dispose();
        }

        [StructLayout(LayoutKind.Sequential)] private struct Timespec { public long Seconds, Nanoseconds; }
        [DllImport("libc", SetLastError = true)] private static extern int clock_gettime(int clock, out Timespec value);
        private static long BootMicroseconds()
        {
            if (clock_gettime(7, out Timespec time) != 0) throw new IOException("CLOCK_BOOTTIME unavailable");
            return checked(time.Seconds * 1_000_000 + time.Nanoseconds / 1000);
        }

        public sealed class MetadataRecord
        {
            public string id { get; set; }
            public string status { get; set; }
            public string frameSource { get; set; }
            public string clock { get; set; }
            public long frames { get; set; }
            public long markFrame { get; set; }
            public long markBootUs { get; set; }
            public long startBootUs { get; set; }
            public long lastFrameBootUs { get; set; }
            public long endBootUs { get; set; }
            public string error { get; set; }
        }
    }

    [JsonSerializable(typeof(AndroidRunMetrics.MetadataRecord))]
    internal partial class MetricsJsonContext : JsonSerializerContext { }
}
