using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;

internal static class Program
{
    private const int Rate = 48000, Frames = 1024, BytesPerFrame = 4;
    private readonly record struct State(ulong PlayedBefore, ulong PlayedAfter, uint PrimeConsumedMask,
        bool? TargetConsumed, bool UpdateSignaled);
    private static long Us(long ticks) => (long)((Int128)ticks * 1_000_000 / Stopwatch.Frequency);
    // Preserve the existing production TSV's unchecked multiplication for alignment.
    private static long LegacyUs(long ticks) => unchecked(ticks * 1_000_000 / Stopwatch.Frequency);
    private static object Clock(long ticks) => new { ticks, us = Us(ticks), legacyDiagUs = LegacyUs(ticks) };

    private static int Main(string[] args)
    {
        if (args.Length == 0 || (args.Length == 1 && args[0] == "--help"))
        {
            Console.WriteLine("--run --cushion on|off --out NEW_DIRECTORY; requires matching S2A_AUDIO_CUSHION=1|0, S2A_AUDIO_CH2=1 and S2A_AUDIO_WAV=OUT/queue. Exit 0 only completes collection; analyze.py determines the regression result.");
            return 0;
        }
        if (args.Length != 5 || args[0] != "--run" || args[1] != "--cushion" ||
            (args[2] != "on" && args[2] != "off") || args[3] != "--out")
            throw new ArgumentException("Expected --run --cushion on|off --out NEW_DIRECTORY");
        if (!OperatingSystem.IsMacOS()) throw new PlatformNotSupportedException("Real macOS CoreAudio is required.");
        string cushion = args[2];
        if (Environment.GetEnvironmentVariable("S2A_AUDIO_CUSHION") != (cushion == "on" ? "1" : "0"))
            throw new ArgumentException("Set S2A_AUDIO_CUSHION before starting this independent process.");
        if (Environment.GetEnvironmentVariable("S2A_AUDIO_CH2") != "1")
            throw new ArgumentException("Set S2A_AUDIO_CH2=1 to avoid an unrelated surround-device probe.");
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
            if (((string)entry.Key).StartsWith("S2A_AUDIO_TEST_", StringComparison.Ordinal) && !string.IsNullOrEmpty((string)entry.Value))
                throw new ArgumentException($"Remove unrelated production test hook {entry.Key}.");
        string output = Path.GetFullPath(args[4]);
        if (Directory.Exists(output) || File.Exists(output)) throw new IOException("Output must be a new directory.");
        string wav = Environment.GetEnvironmentVariable("S2A_AUDIO_WAV");
        if (string.IsNullOrEmpty(wav) || !Path.IsPathRooted(wav) || Path.GetDirectoryName(wav) != output)
            throw new ArgumentException("S2A_AUDIO_WAV must be an absolute file prefix directly inside --out.");
        Directory.CreateDirectory(output);
        using var events = new StreamWriter(Path.Combine(output, "events.jsonl"), false) { AutoFlush = true };
        void Log(string kind, object data) => events.WriteLine(JsonSerializer.Serialize(new
        {
            kind, clock = Clock(Stopwatch.GetTimestamp()), data
        }));
        Log("begin", new { cushion, frequency = Stopwatch.Frequency, rate = Rate, channels = 2, format = "PCM16",
            prime_frames = 4 * Frames, target_frames = Frames, wav_prefix = wav,
            boundary = "AudioQueue buffer hand-back accounting, not physical speaker playback" });

        // Own real PCM through the same public Data path as HardwareDeviceImpl.
        // Keep the actual pointers pinned until after the real session is disposed.
        using var p0 = new Pcm(1, 440);
        using var p1 = new Pcm(2, 440);
        using var p2 = new Pcm(3, 440);
        using var p3 = new Pcm(4, 440);
        using var target = new Pcm(5, 880);
        AudioBuffer[] prime = [p0.Buffer, p1.Buffer, p2.Buffer, p3.Buffer];
        using var driver = new AppleHardwareDeviceDriver();
        using var session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, Rate, 2);
        foreach (AudioBuffer buffer in prime)
        {
            if (!session.RegisterBuffer(buffer)) throw new InvalidOperationException("PCM registration failed.");
            session.QueueBuffer(buffer);
        }
        if (!session.RegisterBuffer(target.Buffer)) throw new InvalidOperationException("Target registration failed.");
        var update = driver.GetUpdateRequiredEvent();
        State? last = null;
        State Observe(string phase, bool targetQueued)
        {
            long begin = Stopwatch.GetTimestamp();
            ulong before = session.GetPlayedSampleCount();
            uint mask = 0;
            for (int i = 0; i < prime.Length; i++)
                if (session.WasBufferFullyConsumed(prime[i])) mask |= 1u << i;
            bool? consumed = targetQueued ? session.WasBufferFullyConsumed(target.Buffer) : null;
            ulong after = session.GetPlayedSampleCount();
            bool signaled = update.WaitOne(0);
            if (signaled) update.Reset(); // Coalescing notification, not a callback count.
            long end = Stopwatch.GetTimestamp();
            var state = new State(before, after, mask, consumed, signaled);
            // Retain unchanged target reads: they are required positive pending evidence.
            if (targetQueued || last != state)
                Log("public_sample", new { phase, read_begin = Clock(begin), read_end = Clock(end),
                    played_before = before, played_after = after, prime_consumed_mask = mask,
                    target_consumed = consumed, update_signaled_coalesced = signaled });
            last = state;
            return state;
        }
        Log("start_before", new { });
        session.Start();
        Log("start_after", new { });
        long deadline = Stopwatch.GetTimestamp() + 2 * Stopwatch.Frequency;
        while (true)
        {
            State s = Observe("prime", false);
            if (s.PlayedAfter == 4 * Frames && s.PrimeConsumedMask == 15) break;
            if (s.PlayedAfter > 4 * Frames) throw new InvalidOperationException("Played count exceeds real priming frames.");
            if (Stopwatch.GetTimestamp() >= deadline) throw new TimeoutException("Priming did not complete within 2 seconds.");
            Thread.Sleep(1);
        }
        long drained = Stopwatch.GetTimestamp();
        Log("public_prime_drained", new { observed = Clock(drained) });
        Thread.Sleep(20); // Natural empty queue; never call Returned or synthesize callbacks.
        Log("target_queue_intent", new { });
        long queueBegin = Stopwatch.GetTimestamp();
        if (queueBegin - drained >= Stopwatch.Frequency)
            throw new TimeoutException("Scheduling exceeded the observed <1-second append window.");
        session.QueueBuffer(target.Buffer);
        long queueEnd = Stopwatch.GetTimestamp();
        Log("target_queue_return", new { call_begin = Clock(queueBegin), call_end = Clock(queueEnd),
            since_public_drain_us = Us(queueBegin - drained) });
        long firstConsumed = 0;
        deadline = Stopwatch.GetTimestamp() + 2 * Stopwatch.Frequency;
        while (true)
        {
            State s = Observe("target", true);
            long now = Stopwatch.GetTimestamp();
            if (s.PlayedAfter > 5 * Frames) throw new InvalidOperationException("Played count exceeds all real submitted frames.");
            if (s.TargetConsumed == true && s.PlayedAfter == 5 * Frames)
            {
                if (firstConsumed == 0) firstConsumed = now;
                if (now - firstConsumed >= Stopwatch.Frequency / 4) break;
            }
            if (now >= deadline) throw new TimeoutException("Target did not complete within 2 seconds.");
            Thread.Sleep(1);
        }
        Log("sequence_complete", new { collection_only = true });
        session.Stop();
        // Production's diagnostic writer drains every 100ms. Give it time; the
        // analyzer still requires all actual q/c rows and never assumes a flush.
        Thread.Sleep(150);
        return 0;
    }

    private sealed class Pcm : IDisposable
    {
        private readonly GCHandle _pin;
        public AudioBuffer Buffer { get; }
        public Pcm(ulong tag, int frequency)
        {
            byte[] data = new byte[Frames * BytesPerFrame];
            for (int frame = 0; frame < Frames; frame++)
            {
                short sample = (short)(256 * Math.Sin(2 * Math.PI * frequency * frame / Rate));
                for (int channel = 0; channel < 2; channel++)
                    System.Buffers.Binary.BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(frame * BytesPerFrame + channel * 2, 2), sample);
            }
            _pin = GCHandle.Alloc(data, GCHandleType.Pinned);
            Buffer = new AudioBuffer { BufferTag = tag, DataPointer = (ulong)_pin.AddrOfPinnedObject(), Data = data, DataSize = (ulong)data.Length };
        }
        public void Dispose() => _pin.Free();
    }
}
