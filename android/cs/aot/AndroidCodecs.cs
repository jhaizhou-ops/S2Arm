using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot
{
    // Single-library build: Opus and VP8 decoding through the shims the service layer binds
    // (services/opus/s2a_opus.c for Horizon's HardwareOpusDecoder, services/vpx/s2a_vp8.c for
    // Nvdec's VpxVp8Decoder), built for the NDK by codecs/build.sh and linked with DirectPInvoke.
    public static unsafe class AndroidCodecs
    {
        [DllImport("s2a_opus")] static extern nint opus_get_version_string();
        [DllImport("s2a_opus")] static extern nint opus_encoder_create(int fs, int channels, int application, int* error);
        [DllImport("s2a_opus")] static extern int opus_encode(nint st, short* pcm, int frameSize, byte* data, int maxBytes);
        [DllImport("s2a_opus")] static extern void opus_encoder_destroy(nint st);
        [DllImport("s2a_opus")] static extern nint s2a_opus_open(int rate, int channels, int streams, int coupled, byte* mapping, int* err);
        [DllImport("s2a_opus")] static extern int s2a_opus_decode(nint h, byte* data, int len, short* pcm, int frameSize);
        [DllImport("s2a_opus")] static extern void s2a_opus_reset(nint h);
        [DllImport("s2a_opus")] static extern void s2a_opus_close(nint h);
        [DllImport("s2a_opus")] static extern int s2a_opus_packet_samples(byte* data, int len, int rate);
        [DllImport("s2a_vpx")] static extern nint vpx_codec_version_str();
        [DllImport("s2a_vpx")] static extern nint s2a_vp8_open();
        [DllImport("s2a_vpx")] static extern int s2a_vp8_decode(nint h, byte* data, uint len, byte** planes, int* strides, int* wh);
        [DllImport("s2a_vpx")] static extern void s2a_vp8_close(nint h);

        const int Rate = 48000, Frame = 960, Frames = 25, OpusApplicationAudio = 2049;
        const double MinSnrDb = 25;   // host x86_64 build of the same libopus: 40.7 / 43.9 dB

        // Two 64x48 VP8 frames (a key frame, then an inter frame with the picture moved by
        // (3, 2)), encoded by the host's libvpx 1.15.0, and FNV-1a 64 of the visible Y / U / V
        // pixels the plain-C reference decoder produced. VP8 decoding is exact, so the NEON
        // decoder here must give the same pixels.
        static readonly string[] Vp8Frames =
        {
            "MBEAnQEqQAAwAAIHCIWFiIWEiAICAdwvzX8h+YH2wMBbACfB+pv4X+Ef7D+o/hB8aewv6D/oDzWYi/xD7nea/2U5T+AK8TsaVvDxEjteR4H+fKYMXEYUcLsv9qhC3eDcwlGMw3aPObXqn0gcc53GX+AXy0bM6P0KxbpFVxdoELVpX7Nc16a+v7dp4ZASR5udyOHw/vsmy9hvnmpkt/Gw2vhha1JkFwX5BgZGWqEPRL1+UZhzamS85A+NTPC4Si///a+PNtZzSqB4C//+8iTx4GvO85MUN5+plj5Idy46/6BUSqsuUBxbS6aSWxObXECnvXmhDHaxcu5245MUaFWN1nsWieJonOkJfZUV3VuCSNGILJGobpojNgEAqnaIoEkugRusvtT8+ciFZLWGcWh5AWDZ9dLyFyaPtWW2QC8P2GtgMpvX7DudsSnzdx5aaZMCoDk2NM0/+Ev5T+8JGuj82pVUC7Mzp4QIekUWZVEDj67UtLdltC527sZwqUvkzeQeVjiTZ362YG7lNCQ2l8fBkkOv8R7M1OmfMisEQwqYnVOi9JwEpBt3Zv2qeSUHVkL6NlyCTOWctiIFk4UURxDLRFOoqV0Ak+u0oTwin9nYH0Ur6f0H7Gj8EQLpcZ0NGtkPfW4D34U/VIkzZzQs1kX98xB/Eyjve24POfn8iFXUVPRWiZASAnhzoTb0tkEhkuVfRnYG0GUhmfflwAv2ippzgKcoq5gZRmuzjlVThgzrcWZeeMuKzw2O/n42r+XOx3sQqCaGVE1XlnQut1UnBUJsvbeK6Z9L9CVIPooVToEBUFZnkN+CMI0IY5sUs6cOJefSQF9CJ8Nxtuh0fsz9fPhJy5EA2R7nw4ltee2PPaiMyVOxmaPB1lutahr+VE3wVG3zAsrUu5y15oxAAA==",
            "UQgACBAQABgLb6iNAu1f//HY///D/tAWGpRAi4v+A/kZ/Ab6hvdCG/cDuMntu1L+u4h84A0ATDSU+2+WUmMVixY+mdIY/pB//6NhKHv/0F0H3saAf2yhm3/gGo8/cWdXxk4PU8LH84qhX3wv//44NN5iDm2E9gZjN+/0Cxs+NH6iXjmW+rees7dXevARHpYVzt6aSlqMkGXWP1KZ0XY+Jn+OQNZdUc0/HiHG/spHQs+nQYzT+Jd+mcAzdCZPgj5VJV0PMX3iiFjqlLYUJkVf8ELJGK0KNetiYrdyu/UPu7EIv4vSkUUPyrXkHDs1kVEP4NvVo4T+KasGHf1HgA==",
        };
        static readonly ulong[][] Vp8Planes =
        {
            new[] { 0xe0b3966c27496bdcUL, 0x79a0b65760acf67dUL, 0x96f1e26aa1b9216fUL },
            new[] { 0xcffc2c94f653def6UL, 0xb51303df5027e74cUL, 0x0f585a03cc8d5305UL },
        };

        [UnmanagedCallersOnly(EntryPoint = "s2a_android_codec_selftest")]
        public static int Run(byte* buffer, int length)
        {
            int failures = 0;
            string report;
            try
            {
                report = Opus(ref failures) + "; " + Vp8(ref failures);
            }
            catch (Exception e)
            {
                failures++;
                report = $"FAILED {e.GetType().Name} {e.Message}";
            }
            byte[] text = System.Text.Encoding.UTF8.GetBytes(report);
            int n = Math.Min(text.Length, length - 1);
            text.AsSpan(0, n).CopyTo(new Span<byte>(buffer, length));
            buffer[n] = 0;
            return failures;
        }

        // 0.5 s of stereo tones (440 Hz left, 1 kHz right) encoded here, then decoded the way
        // HardwareOpusDecoder does, once single-stream (no mapping) and once multistream.
        static string Opus(ref int failures)
        {
            int n = Frame * Frames;
            short[] pcm = new short[2 * n];
            for (int i = 0; i < n; i++)
            {
                pcm[2 * i] = (short)(8000 * Math.Sin(2 * Math.PI * 440 * i / Rate));
                pcm[2 * i + 1] = (short)(6000 * Math.Sin(2 * Math.PI * 1000 * i / Rate));
            }
            int err;
            nint enc = opus_encoder_create(Rate, 2, OpusApplicationAudio, &err);
            if (enc == 0) { failures++; return $"Opus: FAILED encoder create ({err})"; }
            var packets = new byte[Frames][];
            byte[] buf = new byte[1500];
            fixed (short* p = pcm)
            fixed (byte* b = buf)
            {
                for (int f = 0; f < Frames; f++)
                {
                    int k = opus_encode(enc, p + 2 * f * Frame, Frame, b, buf.Length);
                    if (k <= 0) { opus_encoder_destroy(enc); failures++; return $"Opus: FAILED encode ({k})"; }
                    packets[f] = buf.AsSpan(0, k).ToArray();
                }
            }
            opus_encoder_destroy(enc);
            int bytes = 0;
            foreach (byte[] packet in packets) bytes += packet.Length;
            string version = Marshal.PtrToStringUTF8(opus_get_version_string()) ?? "libopus";
            string single = Decode(pcm, packets, null, ref failures);
            string multi = Decode(pcm, packets, new byte[] { 0, 1 }, ref failures);
            return $"Opus ({version}): {Frames} packets / {bytes} bytes; single-stream {single}; multistream {multi}";
        }

        static string Decode(short[] pcm, byte[][] packets, byte[] mapping, ref int failures)
        {
            int n = Frame * Frames, err;
            nint h;
            fixed (byte* m = mapping) h = s2a_opus_open(Rate, 2, 1, 1, m, &err);
            if (h == 0) { failures++; return $"FAILED open ({err})"; }
            short[] output = new short[2 * n];
            try
            {
                fixed (short* o = output)
                {
                    for (int f = 0; f < Frames; f++)
                    {
                        fixed (byte* p = packets[f])
                        {
                            int samples = s2a_opus_packet_samples(p, packets[f].Length, Rate);
                            int got = s2a_opus_decode(h, p, packets[f].Length, o + 2 * f * Frame, Frame);
                            if (samples != Frame || got != Frame) { failures++; return $"FAILED packet {f}: {samples} samples, decoded {got}"; }
                        }
                    }
                    // After a reset the decoder takes a packet again (the service resets on request).
                    s2a_opus_reset(h);
                    short[] again = new short[2 * Frame];
                    fixed (byte* p = packets[0])
                    fixed (short* a = again)
                    {
                        int got = s2a_opus_decode(h, p, packets[0].Length, a, Frame);
                        if (got != Frame) { failures++; return $"FAILED decode after reset ({got})"; }
                    }
                }
            }
            finally
            {
                s2a_opus_close(h);
            }
            // The decoder's output trails the input by the encoder's lookahead. Both channels
            // together find it: the two tones only repeat together every 1200 samples.
            int lag = 0;
            double best = double.MinValue;
            for (int d = 0; d <= 1000; d++)
            {
                double c = 0;
                for (int i = 2 * Frame; i < 2 * Frame + 2400; i++)
                    c += pcm[2 * i] * (double)output[2 * (i + d)] + pcm[2 * i + 1] * (double)output[2 * (i + d) + 1];
                if (c > best) { best = c; lag = d; }
            }
            var snr = new double[2];
            for (int ch = 0; ch < 2; ch++)
            {
                double s = 0, e = 0;
                for (int i = 2 * Frame; i < n - lag; i++)
                {
                    double x = pcm[2 * i + ch], y = output[2 * (i + lag) + ch];
                    s += x * x;
                    e += (x - y) * (x - y);
                }
                snr[ch] = 10 * Math.Log10(s / Math.Max(e, 1));
            }
            bool ok = snr[0] >= MinSnrDb && snr[1] >= MinSnrDb;
            if (!ok) failures++;
            return $"{(ok ? "ok" : "FAILED")} (delay {lag} samples, SNR {snr[0]:F1} / {snr[1]:F1} dB)";
        }

        static string Vp8(ref int failures)
        {
            string version = Marshal.PtrToStringUTF8(vpx_codec_version_str()) ?? "libvpx";
            nint h = s2a_vp8_open();
            if (h == 0) { failures++; return "VP8: FAILED open"; }
            var results = new string[Vp8Frames.Length];
            byte** planes = stackalloc byte*[3];
            int* strides = stackalloc int[3];
            int* wh = stackalloc int[2];
            try
            {
                for (int f = 0; f < Vp8Frames.Length; f++)
                {
                    byte[] data = Convert.FromBase64String(Vp8Frames[f]);
                    int r;
                    fixed (byte* p = data) r = s2a_vp8_decode(h, p, (uint)data.Length, planes, strides, wh);
                    if (r != 0 || wh[0] != 64 || wh[1] != 48) { failures++; return $"VP8 ({version}): FAILED frame {f}: result {r}, {wh[0]}x{wh[1]}"; }
                    bool exact = true;
                    for (int i = 0; i < 3; i++)
                    {
                        int w = i == 0 ? 64 : 32, rows = i == 0 ? 48 : 24;
                        if (Fnv(planes[i], strides[i], w, rows) != Vp8Planes[f][i]) exact = false;
                    }
                    if (!exact) failures++;
                    results[f] = exact ? "exact" : "DIFFERENT";
                }
            }
            finally
            {
                s2a_vp8_close(h);
            }
            // A damaged frame is an error result, not a crash (fresh decoder: the first frame must be a key frame).
            nint bad = s2a_vp8_open();
            if (bad == 0) { failures++; return $"VP8 ({version}): FAILED second open"; }
            int damaged;
            byte[] junk = new byte[64];
            Array.Fill(junk, (byte)0xff);
            fixed (byte* p = junk) damaged = s2a_vp8_decode(bad, p, (uint)junk.Length, planes, strides, wh);
            s2a_vp8_close(bad);
            if (damaged != -1) failures++;
            return $"VP8 ({version}): key frame {results[0]}, inter frame {results[1]} (64x48, against the reference decoder); "
                + $"damaged frame {(damaged == -1 ? "refused" : "NOT refused (" + damaged + ")")}";
        }

        static ulong Fnv(byte* plane, int stride, int width, int rows)
        {
            ulong x = 0xcbf29ce484222325UL;
            for (int r = 0; r < rows; r++)
                for (int c = 0; c < width; c++)
                    x = (x ^ plane[r * stride + c]) * 0x100000001b3UL;
            return x;
        }
    }
}
