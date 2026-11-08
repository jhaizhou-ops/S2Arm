using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace S2A.Android.Probe
{
    // Exercises the runtime pieces the service layer needs: GC, exception unwinding,
    // threads, the thread pool, timers and native callbacks. Writes one line of results.
    public static unsafe class Probe
    {
        [UnmanagedCallersOnly(EntryPoint = "s2a_cs_probe")]
        public static int Run(byte* buffer, int length)
        {
            var sb = new StringBuilder();
            int failures = 0;
            void Check(string name, Func<string> test)
            {
                try { sb.Append(name).Append('=').Append(test()).Append("; "); }
                catch (Exception e) { failures++; sb.Append(name).Append("=FAILED ").Append(e.GetType().Name).Append(' ').Append(e.Message).Append("; "); }
            }
            var clock = Stopwatch.StartNew();
            Check("runtime", () => RuntimeInformation.FrameworkDescription + " " + RuntimeInformation.RuntimeIdentifier);
            Check("cpus", () => Environment.ProcessorCount.ToString());
            Check("gc", () =>
            {
                var keep = new object[4096];
                for (int i = 0; i < 200_000; i++) keep[i & 4095] = new byte[i & 1023];
                int before = GC.CollectionCount(0);
                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
                return $"{GC.CollectionCount(0) - before} gen0+, heap {GC.GetTotalMemory(false) >> 10} KiB";
            });
            Check("exceptions", () =>
            {
                try { Throw(3); } catch (InvalidOperationException e) { return e.StackTrace != null ? "caught with trace" : "caught"; }
                return "not caught";
            });
            Check("null-ref", () =>
            {
                try { return Deref(null).ToString(); } catch (NullReferenceException) { return "caught"; }
            });
            Check("thread", () =>
            {
                int v = 0;
                var t = new Thread(() => v = Environment.CurrentManagedThreadId) { IsBackground = true };
                t.Start(); t.Join();
                return v != Environment.CurrentManagedThreadId ? "ok" : "same id";
            });
            Check("threadpool", () =>
            {
                var tasks = new Task<int>[8];
                for (int i = 0; i < tasks.Length; i++) { int k = i; tasks[i] = Task.Run(() => k * k); }
                Task.WaitAll(tasks);
                int sum = 0; foreach (var t in tasks) sum += t.Result;
                return sum == 140 ? "ok" : sum.ToString();
            });
            Check("timer", () =>
            {
                using var done = new ManualResetEventSlim();
                using var timer = new Timer(_ => done.Set(), null, 10, Timeout.Infinite);
                return done.Wait(2000) ? "ok" : "timeout";
            });
            // Ryujinx HLE hashes NROs (IRoInterface) and makes random numbers (Spl) through
            // System.Security.Cryptography; on Linux most of it is OpenSSL, which Android
            // does not offer to apps.
            // .NET's crypto on Linux (RandomNumberGenerator, SHA-256, AES) goes through its OpenSSL
            // shim, which calls abort() when it finds no usable libssl (InitializeOpenSSLShim,
            // Android 15). The shim's Android path dlopens "libssl.so", which openssl/build.sh
            // packages; only use crypto when that loads, and check against known answers.
            bool ssl = NativeLibrary.TryLoad("libssl.so", out _);
            Check("openssl", () => ssl ? "libssl.so loadable" : "no libssl.so (crypto would abort the process)");
            if (ssl)
            {
                Check("random", () => RandomNumberGenerator.GetBytes(16).Length == 16 ? "ok" : "short");
                Check("sha256", () => Convert.ToHexString(SHA256.HashData("abc"u8)).StartsWith("BA7816BF") ? "ok" : throw new CryptographicException("wrong SHA-256"));
                Check("aes", () =>
                {
                    using var aes = Aes.Create();
                    aes.Key = new byte[16];
                    return Convert.ToHexString(aes.EncryptEcb(new byte[16], PaddingMode.None)).StartsWith("66E94BD4") ? "ok" : throw new CryptographicException("wrong AES block");
                });
            }
            sb.Append($"total {clock.ElapsedMilliseconds} ms");
            byte[] text = Encoding.UTF8.GetBytes(sb.ToString());
            int n = Math.Min(text.Length, length - 1);
            text.AsSpan(0, n).CopyTo(new Span<byte>(buffer, length));
            buffer[n] = 0;
            return failures;
        }

        // The service layer finds optional host exports through the main program handle
        // (services/S2A.Services/InputPump.cs, Native.cs). On Android the main program is
        // app_process64, and app libraries live in their own linker namespace.
        [UnmanagedCallersOnly(EntryPoint = "s2a_cs_lookup")]
        public static int Lookup(byte* name) =>
            NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), Marshal.PtrToStringUTF8((IntPtr)name), out _) ? 1 : 0;

        [MethodImpl(MethodImplOptions.NoInlining)]
        static void Throw(int depth)
        {
            if (depth == 0) throw new InvalidOperationException("probe");
            Throw(depth - 1);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        static int Deref(int[] a) => a[0];
    }
}
