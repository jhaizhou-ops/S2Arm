using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Arp;
using Ryujinx.Horizon.Sdk.Ns;
using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Threading.Tasks;

internal static class ArpRegistrationTests
{
    // Only the unrelated kernel event constructor is omitted. Writer, Registrar,
    // Reader, Updater, instance storage, Result and Application's orchestration
    // below are the actual production types/IL. No GPU/HLE initialization claim.
    private sealed class ActualArp
    {
        internal readonly IWriter Writer;
        internal readonly IReader Reader;
        internal readonly Array Entries;
        internal ActualArp()
        {
            Assembly assembly = typeof(IWriter).Assembly;
            Type managerType = assembly.GetType("Ryujinx.Horizon.Sdk.Arp.Detail.ApplicationInstanceManager", true);
            object manager = RuntimeHelpers.GetUninitializedObject(managerType);
            FieldInfo field = managerType.GetField("Entries");
            Entries = Array.CreateInstance(field.FieldType.GetElementType(), 2);
            field.SetValue(manager, Entries);
            Writer = (IWriter)Activator.CreateInstance(assembly.GetType("Ryujinx.Horizon.Arp.Ipc.Writer", true), manager);
            Reader = (IReader)Activator.CreateInstance(assembly.GetType("Ryujinx.Horizon.Arp.Ipc.Reader", true), manager);
        }
    }

    internal static void Run(Action<bool, string> check, bool issueOnly)
    {
        var actual = new ActualArp();
        actual.Writer.AcquireRegistrar(out IRegistrar first).AbortOnFailure();
        check(actual.Reader.GetApplicationInstanceId(out _, 47).IsFailure,
            "real reader cannot find a pid before its updater binds it");
        first.Issue(out ulong firstId).AbortOnFailure();
        check(firstId == 0, "first registrar returns its real allocated slot");
        actual.Writer.AcquireRegistrar(out IRegistrar second).AbortOnFailure();
        second.Issue(out ulong secondId).AbortOnFailure();
        check(secondId == 1, "second registrar must not alias instance zero");
        Result exhausted = actual.Writer.AcquireRegistrar(out IRegistrar absent);
        check(exhausted == new Result(157, 101) && absent == null, "real slot exhaustion is observable");
        // Simulate completed unregister without signalling a kernel event: this
        // fixture intentionally has no native kernel. The issue-owner check is real.
        actual.Entries.SetValue(null, 0);
        actual.Writer.AcquireRegistrar(out IRegistrar reused).AbortOnFailure();
        check(first.Issue(out _) == new Result(157, 102), "stale registrar cannot issue reused slot");
        reused.Issue(out ulong reusedId).AbortOnFailure();
        check(reusedId == 0, "current registrar owns reused slot");
        for (int run = 0; run < 10; run++)
        {
            var parallel = new ActualArp();
            var results = new Result[8]; var slots = new ulong[8];
            Parallel.For(0, 8, n =>
            {
                results[n] = parallel.Writer.AcquireRegistrar(out IRegistrar registrar);
                if (results[n].IsSuccess) results[n] = registrar.Issue(out slots[n]);
            });
            int won = 0, slotSum = 0;
            for (int i = 0; i < results.Length; i++)
            {
                if (results[i].IsSuccess) { won++; slotSum += (int)slots[i]; }
                else check(results[i] == new Result(157, 101), "concurrent exhausted result");
            }
            check(won == 2 && slotSum == 1, "concurrent acquire has two distinct actual owners");
        }
        if (issueOnly) return;

        var shared = new ActualArp();
        Register(shared.Writer, 47);
        Register(shared.Writer, 53);
        shared.Reader.GetApplicationInstanceId(out ulong id47, 47).AbortOnFailure();
        shared.Reader.GetApplicationInstanceId(out ulong id53, 53).AbortOnFailure();
        check(id47 == 0 && id53 == 1, "shared production registration binds both real instances");
        shared.Reader.GetApplicationControlProperty(out _, id53).AbortOnFailure();
        shared.Reader.GetApplicationLaunchProperty(out _, id53).AbortOnFailure();
        shared.Reader.GetApplicationProcessProperty(out var process, id53).AbortOnFailure();
        check(process.ProgramIndex == 0, "real ARP data readable after production registration");
        for (int failAt = 1; failAt <= 6; failAt++)
        {
            var injected = new FailingArp(new ActualArp().Writer, failAt);
            bool failed = false;
            try { Register(injected, 47); }
            catch (InvalidResultException) { failed = true; }
            check(failed && injected.Calls == failAt,
                "actual production ARP Result failure stops the chain at " + failAt);
        }
    }

    private static void Register(IWriter writer, ulong pid)
    {
        MethodInfo method = typeof(S2A.Services.Application).GetMethod("RegisterArp", BindingFlags.NonPublic | BindingFlags.Static);
        if (method == null) throw new InvalidOperationException("Production RegisterArp consumer is absent");
        try { method.Invoke(null, new object[] { writer, pid, default(ApplicationControlProperty) }); }
        catch (TargetInvocationException e) when (e.InnerException != null)
        { ExceptionDispatchInfo.Capture(e.InnerException).Throw(); throw; }
    }

    // Inject a real Result failure at each external service operation while all
    // other calls use actual Writer/Registrar/Updater. No success is synthesized.
    private sealed class FailingArp : IWriter, IRegistrar, IUpdater
    {
        private readonly IWriter _writer;
        private readonly int _failAt;
        private IRegistrar _registrar;
        private IUpdater _updater;
        internal int Calls;
        internal FailingArp(IWriter writer, int failAt) { _writer = writer; _failAt = failAt; }
        private bool Fail() => ++Calls == _failAt;
        private static Result Error => new(157, 30);
        public Result AcquireRegistrar(out IRegistrar registrar)
        {
            registrar = null;
            if (Fail()) return Error;
            Result result = _writer.AcquireRegistrar(out _registrar);
            if (result.IsSuccess) registrar = this;
            return result;
        }
        public Result SetApplicationControlProperty(in ApplicationControlProperty control) =>
            Fail() ? Error : _registrar.SetApplicationControlProperty(control);
        public Result SetApplicationLaunchProperty(ApplicationLaunchProperty launch) =>
            Fail() ? Error : _registrar.SetApplicationLaunchProperty(launch);
        public Result Issue(out ulong id)
        { id = 0; return Fail() ? Error : _registrar.Issue(out id); }
        public Result AcquireApplicationProcessPropertyUpdater(out IUpdater updater, ulong id)
        {
            updater = null;
            if (Fail()) return Error;
            Result result = _writer.AcquireApplicationProcessPropertyUpdater(out _updater, id);
            if (result.IsSuccess) updater = this;
            return result;
        }
        public Result SetApplicationProcessProperty(ulong pid, ApplicationProcessProperty property) =>
            Fail() ? Error : _updater.SetApplicationProcessProperty(pid, property);
        public Result UnregisterApplicationInstance(ulong id) => throw new NotSupportedException();
        public Result AcquireApplicationCertificateUpdater(out IUpdater updater, ulong id) => throw new NotSupportedException();
        public Result Issue() => throw new NotSupportedException();
        public Result DeleteApplicationProcessProperty() => throw new NotSupportedException();
        public Result SetApplicationCertificate(ApplicationCertificate certificate) => throw new NotSupportedException();
    }
}
