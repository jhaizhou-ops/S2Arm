using System;
using System.IO;
using System.Text;

namespace Ryujinx.Common
{
    // S2Arm differential IPC record: when S2A_IPC_RECORD=<file> is set, every service request handled by the HLE (IpcService)
    // and Horizon (ServiceDispatchTableBase) frameworks appends one text line. The same files are applied to S2Arm and to the
    // reference desktop Ryujinx, so the two records can be compared line by line (sequence of (service, command), raw data /
    // buffer content hashes, result codes, handle counts). Handle values and buffer addresses are never recorded: they differ
    // between the two hosts by construction.
    public static class S2ARecord
    {
        public static readonly bool Enabled = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_IPC_RECORD"));

        private static readonly object _lock = new();
        private static StreamWriter _writer;
        private static long _seq;

        public static void Line(StringBuilder body)
        {
            lock (_lock)
            {
                _writer ??= new StreamWriter(Environment.GetEnvironmentVariable("S2A_IPC_RECORD"), append: false, new UTF8Encoding(false)) { AutoFlush = true };
                _writer.Write(++_seq);
                _writer.Write('\t');
                _writer.WriteLine(body);
            }
        }

        // FNV-1a 64
        public static ulong Hash(ReadOnlySpan<byte> data)
        {
            ulong h = 0xcbf29ce484222325UL;

            foreach (byte b in data)
            {
                h = (h ^ b) * 0x100000001b3UL;
            }

            return h;
        }

        // Up to 64 bytes are written as hex (values such as pids, times and ids stay readable in a diff); longer data as length:hash
        public static void AppendHash(StringBuilder sb, string key, ReadOnlySpan<byte> data)
        {
            sb.Append('\t').Append(key).Append('=').Append(data.Length).Append(':');

            if (data.Length <= 64)
            {
                sb.Append('#').Append(Convert.ToHexString(data));
            }
            else
            {
                sb.Append(Hash(data).ToString("x16"));
            }
        }

        // Several buffers of one kind: key=size:hash,size:hash (omitted when there are none)
        public static void AppendBuffers(StringBuilder sb, string key, int count, Func<int, (ulong Address, ulong Size)> get, Action<ulong, Span<byte>> read)
        {
            if (count == 0)
            {
                return;
            }

            sb.Append('\t').Append(key).Append('=');

            for (int i = 0; i < count; i++)
            {
                (ulong address, ulong size) = get(i);

                if (i != 0)
                {
                    sb.Append(',');
                }

                sb.Append(size);

                if (address != 0 && size != 0 && size <= 64UL << 20)
                {
                    byte[] buf = new byte[size];

                    try
                    {
                        read(address, buf);
                        sb.Append(':').Append(buf.Length <= 64 ? "#" + Convert.ToHexString(buf) : Hash(buf).ToString("x16"));
                    }
                    catch (Exception)
                    {
                        sb.Append(":unreadable");
                    }
                }
            }
        }
    }
}
