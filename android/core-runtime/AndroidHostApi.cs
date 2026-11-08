using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;

namespace S2A.Android.Aot
{
    // Exact managed view of runtime/include/s2a_hostapi.h. Tables are borrowed
    // for the process lifetime; callbacks always receive the original host.
    internal sealed unsafe class AndroidHostApi
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct Header { public uint Size, Version; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Api
        {
            public Header Header;
            public ulong Capabilities;
            public nint Host;
            public User* User;
            public nint Memory;
            public Input* Input;
            public Display* Display;
            public nint Ui, Decode;
            public Stop* Stop;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct User
        {
            public Header Header;
            public delegate* unmanaged<nint, byte*, nuint, int> Language, Region, TimeZone;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Input
        {
            public Header Header;
            public delegate* unmanaged<nint, InputState*, int> Read;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Display
        {
            public Header Header;
            public nint Info;
            public delegate* unmanaged<nint, uint, int> SetMode;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Stop
        {
            public Header Header;
            public delegate* unmanaged<nint, uint, byte*, void> Request;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Ui
        {
            public Header Header;
            public delegate* unmanaged<nint, byte*, ulong*, int> Begin;
            public delegate* unmanaged<nint, ulong, int, byte*, nuint, nuint*, int> Wait;
            public delegate* unmanaged<nint, ulong, int> Cancel;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct InputState
        {
            public uint Size, Version, Buttons, Reserved;
            public int LeftX, LeftY, RightX, RightY;
            public ulong TimestampNs;
        }

        // s2a_host_display_info v1: the game Surface (not the physical panel) in pixels.
        [StructLayout(LayoutKind.Sequential)]
        internal struct DisplayInfo
        {
            public uint Size, AbiVersion, Width, Height, RefreshMilliHz, Rotation, DpiX, DpiY;
        }

        private readonly Api* _api;
        private static readonly UTF8Encoding Utf8 = new(false, true);
        internal string Language { get; }
        internal string Region { get; }
        internal string TimeZone { get; }

        internal AndroidHostApi(nint pointer, uint consoleMode)
        {
            if (pointer == 0 || consoleMode > 1) throw new ArgumentException("HostApi and console mode are required");
            _api = (Api*)pointer;
            Validate(_api->Header, sizeof(Api));
            const ulong required = 1 | 4 | 8 | 64;
            if ((_api->Capabilities & required) != required || (_api->Capabilities & ~127UL) != 0 ||
                _api->User == null || _api->Input == null || _api->Display == null || _api->Stop == null)
                throw new ArgumentException("HostApi user/input/display/stop capabilities are required");
            Validate(_api->User->Header, sizeof(User));
            Validate(_api->Input->Header, sizeof(Input));
            Validate(_api->Display->Header, sizeof(Display));
            Validate(_api->Stop->Header, sizeof(Stop));
            if (_api->User->Language == null || _api->User->Region == null || _api->User->TimeZone == null ||
                _api->Input->Read == null || _api->Display->Info == 0 || _api->Display->SetMode == null || _api->Stop->Request == null)
                throw new ArgumentException("HostApi required callback is absent");
            Language = ReadText(_api->User->Language, false);
            Region = ReadText(_api->User->Region, true);
            TimeZone = ReadText(_api->User->TimeZone, false);
            if (Region.Length != 0 && (Region.Length != 2 || Region[0] < 'A' || Region[0] > 'Z' || Region[1] < 'A' || Region[1] > 'Z'))
                throw new ArgumentException("HostApi region must be ISO alpha-2 or absent");
            if (_api->Display->SetMode(_api->Host, consoleMode) != 0)
                throw new InvalidOperationException("HostApi rejected the frozen BootSpec console mode");
            ReadInput(); // Validate the actual input response before publishing its consumer.
        }

        private static void Validate(Header header, int size)
        {
            if (header.Version != 1 || header.Size < size)
                throw new ArgumentException("Unsupported HostApi table prefix");
        }

        private string ReadText(delegate* unmanaged<nint, byte*, nuint, int> read, bool allowEmpty)
        {
            Span<byte> bytes = stackalloc byte[256];
            bytes.Fill(0xff);
            fixed (byte* p = bytes)
                if (read(_api->Host, p, (nuint)bytes.Length) != 0)
                    throw new InvalidOperationException("HostApi text query failed");
            int end = bytes.IndexOf((byte)0);
            if (end < 0 || (!allowEmpty && end == 0)) throw new ArgumentException("HostApi text is empty or unterminated");
            return Utf8.GetString(bytes[..end]);
        }

        internal InputState ReadInput()
        {
            InputState input = new() { Size = (uint)sizeof(InputState) };
            int rc = _api->Input->Read(_api->Host, &input);
            if (rc != 0 || input.Size < sizeof(InputState) || input.Version != 1 || input.Reserved != 0 ||
                input.LeftX is < -32768 or > 32767 || input.LeftY is < -32768 or > 32767 ||
                input.RightX is < -32768 or > 32767 || input.RightY is < -32768 or > 32767)
                throw new InvalidOperationException("HostApi returned an invalid input snapshot");
            return input;
        }

        // Actual game Surface size from the current window lease. Android only reports it; the
        // guest display contract uses the normalized native width and 1080 baseline.
        internal DisplayInfo ReadDisplay()
        {
            DisplayInfo info = new() { Size = (uint)sizeof(DisplayInfo) };
            var read = (delegate* unmanaged<nint, DisplayInfo*, int>)_api->Display->Info;
            int rc = read(_api->Host, &info);
            if (rc != 0 || info.Size < sizeof(DisplayInfo) || info.AbiVersion != 1 ||
                info.Width == 0 || info.Height == 0 || info.Rotation > 3)
                throw new InvalidOperationException("HostApi returned an invalid display description");
            return info;
        }

        internal void RequestStop(uint reason, string detail)
        {
            byte[] bytes = Utf8.GetBytes(detail + "\0");
            fixed (byte* p = bytes) _api->Stop->Request(_api->Host, reason, p);
        }

        // Only the guest's ordinary service thread waits; no UI/render thread.
        // Storage is reused across timeouts. The native broker owns cancellation
        // on Activity replacement and terminal stop, and retains RANGE answers.
        internal string ExchangeUi(string request)
        {
            if ((_api->Capabilities & 16) == 0 || _api->Ui == 0)
                throw new NotSupportedException("Android host UI producer is unavailable");
            Ui* ui = (Ui*)_api->Ui;
            Validate(ui->Header, sizeof(Ui));
            if (ui->Begin == null || ui->Wait == null || ui->Cancel == null)
                throw new InvalidOperationException("Android host UI callbacks are absent");
            byte[] input = Utf8.GetBytes(request + "\0");
            if (input.Length > 4097) throw new ArgumentException("UI request exceeds 4096 UTF-8 bytes");
            ulong id = 0;
            fixed (byte* data = input)
                if (ui->Begin(_api->Host, data, &id) != 0 || id == 0)
                    throw new InvalidOperationException("Android host UI request was not admitted");
            try
            {
                byte[] output = new byte[8193];
                fixed (byte* data = output)
                {
                    for (;;)
                    {
                        nuint length = 0;
                        int result = ui->Wait(_api->Host, id, 500, data, (nuint)output.Length, &length);
                        if (result == -6) continue; // S2A_HOST_E_TIMEOUT, still pending.
                        if (result == -4) return null; // Broker unavailable/stop revokes this admitted wait.
                        if (result != 0 || length >= (nuint)output.Length || data[length] != 0)
                            throw new InvalidDataException("Android host UI response is invalid: " + result);
                        return Utf8.GetString(output, 0, checked((int)length));
                    }
                }
            }
            finally { ui->Cancel(_api->Host, id); }
        }

        internal static string ReadPath(byte* pointer)
        {
            if (pointer == null) throw new ArgumentException("Session path is absent");
            int length = 0;
            while (length < 4096 && pointer[length] != 0) length++;
            if (length is 0 or 4096) throw new ArgumentException("Session path is empty or too long");
            return Utf8.GetString(new ReadOnlySpan<byte>(pointer, length));
        }
    }
}
