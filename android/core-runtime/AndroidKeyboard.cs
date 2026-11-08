using System;
using System.IO;
using System.Text;
using System.Text.Json;

namespace S2A.Android.Aot
{
    // Local Android keyboard protocol proposal, not a new public HostApi ABI.
    // Other applet kinds and unsupported keyboard modes continue to fail closed.
    internal static class AndroidKeyboard
    {
        internal enum Outcome { Accepted, UserCancelled, HostRevoked }
        internal static bool Valid(string text, int minimum, int maximum, uint mode)
        {
            if (text == null || text.Length < minimum || text.Length > maximum || text.Contains('\0')) return false;
            try { _ = new UTF8Encoding(false, true).GetByteCount(text); }
            catch (EncoderFallbackException) { return false; }
            foreach (char ch in text)
                if ((mode == 1 && !(ch >= '0' && ch <= '9') && ch != '.') || (mode == 2 && ch > 127)) return false;
            return true;
        }
        internal static Outcome Show(Func<string, string> exchange, uint mode, string header, string subtitle,
            string guide, string initial, string submit, int minimum, int maximum, out string text)
        {
            text = null;
            if (mode > 3 && mode != 5) throw new NotSupportedException("Android keyboard mode is not implemented: " + mode);
            if (minimum < 0 || maximum < minimum || maximum > 1024)
                throw new ArgumentException("Invalid Android keyboard length bounds");
            using var stream = new MemoryStream();
            using (var json = new Utf8JsonWriter(stream))
            {
                json.WriteStartObject();
                json.WriteNumber("version", 1); json.WriteString("type", "software-keyboard");
                json.WriteNumber("mode", mode); json.WriteNumber("min", minimum); json.WriteNumber("max", maximum);
                json.WriteString("header", header ?? ""); json.WriteString("subtitle", subtitle ?? "");
                json.WriteString("guide", guide ?? ""); json.WriteString("initial", initial ?? "");
                json.WriteString("submit", submit ?? ""); json.WriteEndObject();
            }
            if (stream.Length > 4096) throw new ArgumentException("Android keyboard request is too large");
            string reply = exchange(Encoding.UTF8.GetString(stream.ToArray()));
            if (reply == null) return Outcome.HostRevoked;
            using JsonDocument document = JsonDocument.Parse(reply);
            JsonElement root = document.RootElement;
            if (root.GetProperty("version").GetInt32() != 1 || root.GetProperty("type").GetString() != "software-keyboard")
                throw new InvalidDataException("Android keyboard reply type/version mismatch");
            string status = root.GetProperty("status").GetString();
            if (status == "cancel") return Outcome.UserCancelled;
            if (status != "ok") throw new NotSupportedException("Android keyboard producer rejected request: " + status);
            string value = root.GetProperty("text").GetString();
            if (!Valid(value, minimum, maximum, mode)) throw new InvalidDataException("Android keyboard reply violates request constraints");
            text = value;
            return Outcome.Accepted;
        }
    }
}
