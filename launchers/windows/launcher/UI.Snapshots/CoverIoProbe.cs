// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Ensure unavailable/slow library storage cannot block the Avalonia UI thread while loading cover art.
using System.Diagnostics;
using System.Reflection;
using Avalonia.Threading;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class CoverIoProbe
{
    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var folder = Path.Combine(outDir, "library", "Absolum");
        var coverPath = Path.Combine(folder, "cover.jpg");
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var reads = 0;
        var window = new EnvironmentWindow { Width = 1280, Height = 900 };
        try
        {
            SetW(window, "connectedFolder", Path.Combine(outDir, "library"));
            SetW(window, "coverBitmapReader", (Func<string, int, Avalonia.Media.Imaging.Bitmap?>)((_, _) =>
            {
                Interlocked.Increment(ref reads);
                entered.Set();
                if (!release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("test cover reader was not released");
                return null;
            }));
            var game = new LibraryGame("absolum", "Absolum", "1.2.1", coverPath, false, [],
                Location: new GameLocation("ok", "", folder, "", false), Banner: Path.Combine(folder, "banner.jpg"));

            // The watchdog also lets the deliberate synchronous negative control finish so it can report red.
            _ = Task.Run(() => { if (entered.Wait(TimeSpan.FromSeconds(3))) { Thread.Sleep(1200); release.Set(); } });
            var timer = Stopwatch.StartNew();
            CallHero(window, game);
            CallHero(window, game);
            CallCover(window, game);
            CallCover(window, game);
            timer.Stop();
            if (timer.ElapsedMilliseconds >= 500)
                throw new InvalidOperationException($"cover/banner rendering blocked the UI for {timer.ElapsedMilliseconds} ms");
            if (!entered.Wait(TimeSpan.FromSeconds(2))) throw new InvalidOperationException("background cover reader did not start");
            if (Volatile.Read(ref reads) != 2) throw new InvalidOperationException($"cover/banner queued {reads} reads instead of two (one per path)");

            release.Set();
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(3))
            {
                Dispatcher.UIThread.RunJobs();
                if (GetW(window, "pendingCovers") is System.Collections.IDictionary pending && pending.Count == 0) break;
                Thread.Sleep(10);
            }
            if (GetW(window, "pendingCovers") is System.Collections.IDictionary remaining && remaining.Count != 0)
                throw new InvalidOperationException("cover load did not settle after the reader was released");

            Console.WriteLine("✓ Cover I/O probe: cover and banner renders < 500 ms, two background reads total, both duplicate requests coalesced");
            return 0;
        }
        catch (Exception error)
        {
            Console.WriteLine($"✗ Cover I/O probe: {error.GetType().Name}: {error.Message}");
            return 1;
        }
        finally
        {
            release.Set();
            try { window.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { }
        }
    }

    static void CallCover(EnvironmentWindow window, LibraryGame game)
        => (window.GetType().GetMethod("GameCoverImage", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingMethodException("GameCoverImage")).Invoke(window, [game, 96]);

    static void CallHero(EnvironmentWindow window, LibraryGame game)
        => (window.GetType().GetMethod("HeroBanner", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingMethodException("HeroBanner")).Invoke(window, [game]);

    static void SetW(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingFieldException(field);
        fi.SetValue(obj, value);
    }

    static object? GetW(object obj, string field)
        => obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(obj);
}
