using Ryujinx.Common.Logging.Targets;
using Ryujinx.Common.SystemInterop;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;

namespace Ryujinx.Common.Logging
{
    public static class Logger
    {
        // S2Arm: stubs hit every frame (e.g. pctl IsFreeCommunicationAvailable) formatted a message, raised an event and wrote a
        // log line per call. Hits are now counted per (class, caller, message) without allocating; the event only fires on the
        // first hit. S2AStubHits() returns the full counts (caller / message are compile-time constants here).
        private static readonly Dictionary<(LogClass, string, string), long> _s2aStubHits = new();

        private static bool S2AStubHit(LogClass logClass, string caller, string message)
        {
            long n;

            lock (_s2aStubHits)
            {
                (LogClass, string, string) key = (logClass, caller, message);
                _s2aStubHits.TryGetValue(key, out n);
                _s2aStubHits[key] = ++n;
            }

            return n == 1;
        }

        public static List<(string Name, long Count)> S2AStubHits()
        {
            lock (_s2aStubHits)
            {
                return _s2aStubHits.Select(kv => ($"{kv.Key.Item1} {kv.Key.Item2}: Stubbed. {kv.Key.Item3}".TrimEnd(), kv.Value)).ToList();
            }
        }

        public static void S2AResetStubHits()
        {
            lock (_s2aStubHits) _s2aStubHits.Clear();
        }

        private static readonly Stopwatch _time;

        private static readonly bool[] _enabledClasses;

        private static readonly List<ILogTarget> _logTargets;

        private static readonly StdErrAdapter _stdErrAdapter;

        public static event EventHandler<LogEventArgs> Updated;

        public readonly struct Log
        {
            private static readonly string _homeDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            private static readonly string _homeDirRedacted = Path.Combine(Directory.GetParent(_homeDir)!.FullName, "[redacted]");

            internal readonly LogLevel Level;

            internal Log(LogLevel level)
            {
                Level = level;
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void PrintMsg(LogClass logClass, string message)
            {
                if (_enabledClasses[(int)logClass])
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, string.Empty, message)));
                }
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void Print(LogClass logClass, string message, [CallerMemberName] string caller = "")
            {
                if (_enabledClasses[(int)logClass])
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, caller, message)));
                }
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void Print(LogClass logClass, string message, object data, [CallerMemberName] string caller = "")
            {
                if (_enabledClasses[(int)logClass])
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, caller, message), data));
                }
            }

            [StackTraceHidden]
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void PrintStack(LogClass logClass, string message, [CallerMemberName] string caller = "")
            {
                if (_enabledClasses[(int)logClass])
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, caller, message), new StackTrace(true)));
                }
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void PrintStub(LogClass logClass, string message = "", [CallerMemberName] string caller = "")
            {
                if (_enabledClasses[(int)logClass] && S2AStubHit(logClass, caller, message))
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, caller, "Stubbed. " + message)));
                }
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void PrintStub(LogClass logClass, object data, [CallerMemberName] string caller = "")
            {
                if (_enabledClasses[(int)logClass] && S2AStubHit(logClass, caller, ""))
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, caller, "Stubbed."), data));
                }
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void PrintStub(LogClass logClass, string message, object data, [CallerMemberName] string caller = "")
            {
                if (_enabledClasses[(int)logClass] && S2AStubHit(logClass, caller, message))
                {
                    Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, FormatMessage(logClass, caller, "Stubbed. " + message), data));
                }
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void PrintRawMsg(string message)
            {
                Updated?.Invoke(null, new LogEventArgs(Level, _time.Elapsed, Thread.CurrentThread.Name, message));
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            private static string FormatMessage(LogClass logClass, string caller, string message)
            {
                message = message.Replace(_homeDir, _homeDirRedacted);

                return $"{logClass} {caller}: {message}";
            }
        }

        public static Log? Debug { get; private set; }
        public static Log? Info { get; private set; }
        public static Log? Warning { get; private set; }
        public static Log? Error { get; private set; }
        public static Log? Guest { get; private set; }
        public static Log? AccessLog { get; private set; }
        public static Log? NetLog { get; private set; }
        public static Log? Stub { get; private set; }
        public static Log? Trace { get; private set; }
        public static Log Notice { get; } // Always enabled

        static Logger()
        {
            _enabledClasses = new bool[Enum.GetNames<LogClass>().Length];

            for (int index = 0; index < _enabledClasses.Length; index++)
            {
                _enabledClasses[index] = true;
            }

            _logTargets = [];

            _time = Stopwatch.StartNew();

            SetConsoleTargetEnabled(true);

            Notice = new Log(LogLevel.Notice);

            // Enable important log levels before configuration is loaded
            Error = new Log(LogLevel.Error);
            Warning = new Log(LogLevel.Warning);
            Info = new Log(LogLevel.Info);
            Trace = new Log(LogLevel.Trace);

            // S2Arm: do not redirect the process's fd 2 into a pipe read back by the logger: the native layer logs to
            // stderr and the test layer matches its contract lines literally (the adapter re-prefixed them), and lines
            // still in the pipe were lost on abort
            _stdErrAdapter = null;
        }

        public static void RestartTime()
        {
            _time.Restart();
        }

        private static ILogTarget GetTarget(string targetName)
            => _logTargets.FirstOrDefault(target => target.Name.Equals(targetName));

        public static void AddTarget(ILogTarget target)
        {
            if (_logTargets.Any(t => t.Name == target.Name))
            {
                target.Dispose();
                return;
            }

            _logTargets.Add(target);

            Updated += target.Log;
        }

        public static void SetConsoleTargetEnabled(bool enabled)
        {
            if (enabled)
            {
                AddTarget(new AsyncLogTargetWrapper(
                    new ConsoleLogTarget("console"),
                    1000,
                    AsyncLogTargetOverflowAction.Discard));
            }
            else
            {
                RemoveTarget("console");
            }
        }

        public static void RemoveTarget(string target)
        {
            ILogTarget logTarget = GetTarget(target);

            if (logTarget != null)
            {
                Updated -= logTarget.Log;

                _logTargets.Remove(logTarget);

                logTarget.Dispose();
            }
        }

        public static void Flush()
        {
            foreach (ILogTarget target in _logTargets)
            {
                if (target is AsyncLogTargetWrapper asyncTarget)
                {
                    asyncTarget.Flush();
                }
            }
        }

        public static void Shutdown()
        {
            Updated = null;

            _stdErrAdapter?.Dispose();

            foreach (ILogTarget target in _logTargets)
            {
                target.Dispose();
            }

            _logTargets.Clear();
        }

        public static IReadOnlyCollection<LogLevel> GetEnabledLevels()
        {
            Log?[] logs = [Debug, Info, Warning, Error, Guest, AccessLog, Stub, Trace];
            List<LogLevel> levels = new(logs.Length);
            foreach (Log? log in logs)
            {
                if (log.HasValue)
                    levels.Add(log.Value.Level);
            }

            return levels;
        }

        public static void SetEnable(LogLevel logLevel, bool enabled)
        {
            switch (logLevel)
            {
#pragma warning disable IDE0055 // Disable formatting
                case LogLevel.Debug     : Debug     = enabled ? new Log(LogLevel.Debug)     : null; break;
                case LogLevel.Info      : Info      = enabled ? new Log(LogLevel.Info)      : null; break;
                case LogLevel.Warning   : Warning   = enabled ? new Log(LogLevel.Warning)   : null; break;
                case LogLevel.Error     : Error     = enabled ? new Log(LogLevel.Error)     : null; break;
                case LogLevel.Guest     : Guest     = enabled ? new Log(LogLevel.Guest)     : null; break;
                case LogLevel.AccessLog : AccessLog = enabled ? new Log(LogLevel.AccessLog) : null; break;
                case LogLevel.NetLog    : NetLog    = enabled ? new Log(LogLevel.NetLog)    : null; break;
                case LogLevel.Stub      : Stub      = enabled ? new Log(LogLevel.Stub)      : null; break;
                case LogLevel.Trace     : Trace     = enabled ? new Log(LogLevel.Trace)     : null; break;
                case LogLevel.Notice    : break;
                default: throw new ArgumentException("Unknown Log Level", nameof(logLevel));
#pragma warning restore IDE0055
            }
        }

        public static void SetEnable(LogClass logClass, bool enabled)
        {
            _enabledClasses[(int)logClass] = enabled;
        }
    }
}
