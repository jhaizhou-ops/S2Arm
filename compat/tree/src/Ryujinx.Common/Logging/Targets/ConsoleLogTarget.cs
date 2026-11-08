using Ryujinx.Common.Logging.Formatters;
using System;

namespace Ryujinx.Common.Logging.Targets
{
    public class ConsoleLogTarget : ILogTarget
    {
        private readonly DefaultLogFormatter _formatter;

        private readonly string _name;

        // S2Arm: console colors throw PlatformNotSupportedException on iOS / tvOS / Android / browser
        private static readonly bool _colors = !(OperatingSystem.IsIOS() || OperatingSystem.IsTvOS() || OperatingSystem.IsAndroid() || OperatingSystem.IsBrowser());

        string ILogTarget.Name { get => _name; }

        private static ConsoleColor GetLogColor(LogLevel level) => level switch
        {
            LogLevel.Info => ConsoleColor.White,
            LogLevel.Warning => ConsoleColor.Yellow,
            LogLevel.Error => ConsoleColor.Red,
            LogLevel.Stub => ConsoleColor.DarkGray,
            LogLevel.Notice => ConsoleColor.Cyan,
            LogLevel.Trace => ConsoleColor.DarkCyan,
            _ => ConsoleColor.Gray,
        };

        public ConsoleLogTarget(string name)
        {
            _formatter = new DefaultLogFormatter();
            _name = name;
        }

        public void Log(object sender, LogEventArgs args)
        {
            if (!_colors)
            {
                Console.WriteLine(_formatter.Format(args));
                return;
            }

            Console.ForegroundColor = GetLogColor(args.Level);
            Console.WriteLine(_formatter.Format(args));
            Console.ResetColor();
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);

            if (_colors)
            {
                Console.ResetColor();
            }
        }
    }
}
