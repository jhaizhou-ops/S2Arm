// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using LibHac.Loader;
using LibHac.Ncm;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS;

internal static class Program
{
    private static readonly string[] Expected = {
        "dispose:Application", "dispose:Account", "dispose:Am", "dispose:Ns", "dispose:Pm", "dispose:Sdb",
        "unregister:bcat:u", "unregister:bcat:s", "unregister:bcat:m", "unregister:bcat:a", "dispose:Bcat",
        "unregister:arp:r", "destroy:Arp", "dispose:Ryujinx", "dispose:Fs"
    };
    private static int _tests, _failed;
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static Exception Capture(Action action) { try { action(); return null; } catch (Exception e) { return e; } }
    private static LibHacHorizonManager Create(bool full = true)
    {
        Calls.Reset();
        var manager = new LibHacHorizonManager();
        if (full)
        {
            manager.InitializeSystemClients();
            manager.InitializeApplicationClient(new ProgramId(), new Npdm());
            manager.InitializeBcatServer();
            manager.InitializeFsServer(new VirtualFileSystem());
            manager.InitializeArpServer();
        }
        return manager;
    }
    private static void AssertReleased(LibHacHorizonManager manager, string[] expected)
    {
        Check(Calls.Events.SequenceEqual(expected), "cleanup sequence: " + string.Join(",", Calls.Events));
        Check(manager.ApplicationClient == null && manager.AccountClient == null && manager.AmClient == null &&
              manager.BcatClient == null && manager.FsClient == null && manager.NsClient == null && manager.PmClient == null &&
              manager.SdbClient == null && manager.RyujinxClient == null && manager.ArpIReader == null, "ownership retained");
        Calls.Hook = null;
        int count = Calls.Events.Count;
        Check(Capture(manager.Dispose) == null, "repeat dispose throws");
        Check(Calls.Events.Count == count, "repeat disposal replays cleanup");
    }
    private static void Test(string name, Action action)
    {
        _tests++;
        try { action(); Console.WriteLine("PASS " + name); }
        catch (Exception e) { _failed++; Console.WriteLine("FAIL " + name + ": " + e.Message); }
    }
    private static int Main()
    {
        Test("normal and repeat", () => { var m = Create(); m.Dispose(); AssertReleased(m, Expected); });
        foreach (string failure in Expected.Where(x => !x.StartsWith("unregister:")))
        {
            Test("failure at " + failure, () => {
                var m = Create(); var error = new InvalidOperationException(failure);
                Calls.Failures.Add(failure, error);
                Exception actual = Capture(m.Dispose);
                Check(ReferenceEquals(actual, error), "single original error not preserved");
                Check(actual.StackTrace.Contains(nameof(Calls.Record)), "original failure stack lost");
                AssertReleased(m, Expected);
            });
        }
        foreach (string service in new[] { "bcat:u", "bcat:s", "bcat:m", "bcat:a", "arp:r" })
        {
            Test("unregister result failure " + service, () => {
                var m = Create(); Calls.UnregisterFailures.Add(service);
                Check(Capture(m.Dispose) == null, "unregister failure must not throw");
                AssertReleased(m, Expected);
                Check(Ryujinx.Common.Logging.Logger.Messages.SequenceEqual(new[] {
                    $"LibHac service unregister failed: {service}, result=0x00001234" }), "missing/duplicate failure warning");
            });
        }
        Test("multiple failures", () => {
            var m = Create(); var errors = new[] { new Exception("first"), new Exception("second") };
            Calls.Failures.Add(Expected[0], errors[0]); Calls.Failures.Add("dispose:Fs", errors[1]);
            var actual = Capture(m.Dispose) as AggregateException;
            Check(actual != null && actual.InnerExceptions.SequenceEqual(errors), "multiple errors not retained in order");
            AssertReleased(m, Expected);
        });
        Test("partially initialized unregister failure", () => {
            var m = Create(false); Calls.UnregisterFailures.Add("arp:r");
            Check(Capture(m.Dispose) == null, "partial init unregister must not throw");
            AssertReleased(m, new[] { "unregister:arp:r", "dispose:Ryujinx" });
        });
        Test("unregister failure with warning disabled", () => {
            var m = Create(); Calls.UnregisterFailures.Add("arp:r");
            Ryujinx.Common.Logging.Logger.Warning = null;
            Check(Capture(m.Dispose) == null, "disabled warning affects cleanup");
            AssertReleased(m, Expected);
        });
        Test("reentrant disposal", () => {
            var m = Create(); bool entered = false;
            Calls.Hook = _ => { if (!entered) { entered = true; m.Dispose(); } };
            m.Dispose(); AssertReleased(m, Expected);
        });
        Console.WriteLine($"LibHac horizon disposal: {_tests - _failed}/{_tests} passed");
        return _failed == 0 ? 0 : 1;
    }
}
