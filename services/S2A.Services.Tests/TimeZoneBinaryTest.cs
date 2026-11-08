using System;
using System.Buffers.Binary;
using System.IO;
using Ryujinx.HLE.HOS.Services.Time;
using Ryujinx.HLE.HOS.Services.Time.TimeZone;

namespace S2A.Services.Tests
{
    public static class TimeZoneBinaryTest
    {
        public static void Run(Action<string, object, object> check)
        {
            // TZif standard/wall and UT/local indicators are independently optional.
            foreach (bool standard in new[] { false, true })
            foreach (bool gmt in new[] { false, true })
            {
                string name = $"TZif STD={standard} GMT={gmt}";
                TimeZoneRule rules = new();
                TimeZoneManager manager = new();
                using MemoryStream stream = new(Fixture(standard, gmt));
                check(name + " parse", ResultCode.Success, manager.ParseTimeZoneRuleBinary(ref rules, stream));
                check(name + " standard[0]", standard, rules.Ttis[0].IsStandardTimeDaylight);
                check(name + " standard[1]", false, rules.Ttis[1].IsStandardTimeDaylight);
                check(name + " GMT[0]", false, rules.Ttis[0].IsGMT);
                check(name + " GMT[1]", gmt, rules.Ttis[1].IsGMT);
                check(name + " calendar result", ResultCode.Success, manager.ToCalendarTime(in rules, 0, out CalendarInfo calendar));
                check(name + " calendar", "1970-01-01 05:30:00",
                    $"{calendar.Time.Year:D4}-{calendar.Time.Month:D2}-{calendar.Time.Day:D2} {calendar.Time.Hour:D2}:{calendar.Time.Minute:D2}:{calendar.Time.Second:D2}");
                check(name + " offset", 19800, calendar.AdditionalInfo.GmtOffset);
            }

            byte[] invalid = Fixture(false, true);
            invalid[^3] = 2;
            TimeZoneRule rejected = new();
            check("TZif rejects invalid GMT indicator", false,
                Ryujinx.HLE.HOS.Services.Time.TimeZone.TimeZone.ParseTimeZoneBinary(ref rejected, new MemoryStream(invalid)));
            byte[] truncated = Fixture(true, true)[..^3];
            check("TZif rejects truncated indicators", false,
                Ryujinx.HLE.HOS.Services.Time.TimeZone.TimeZone.ParseTimeZoneBinary(ref rejected, new MemoryStream(truncated)));
        }

        private static byte[] Fixture(bool standard, bool gmt)
        {
            using MemoryStream stream = new();
            using BinaryWriter writer = new(stream);
            writer.Write("TZif2"u8);
            writer.Write(new byte[15]);
            foreach (int count in new[] { gmt ? 2 : 0, standard ? 2 : 0, 0, 0, 2, 8 })
                WriteBigEndian(writer, count);
            WriteBigEndian(writer, 19800);
            writer.Write(new byte[] { 0, 0 });
            WriteBigEndian(writer, 23400);
            writer.Write(new byte[] { 1, 4 });
            writer.Write("STD\0DST\0"u8);
            if (standard) writer.Write(new byte[] { 1, 0 });
            if (gmt) writer.Write(new byte[] { 0, 1 });
            writer.Write("\n\n"u8);
            return stream.ToArray();
        }

        private static void WriteBigEndian(BinaryWriter writer, int value)
        {
            Span<byte> bytes = stackalloc byte[4];
            BinaryPrimitives.WriteInt32BigEndian(bytes, value);
            writer.Write(bytes);
        }
    }
}
