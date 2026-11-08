using System;
using System.Runtime.InteropServices;
using System.Text;
using S2A.Android.Aot;

static unsafe class TransportTests
{
    static int calls, cancels, mode;
    static AndroidHostApi.Header Header(int n) => new() { Size = (uint)n, Version = 1 };
    [UnmanagedCallersOnly] static int Text(nint host, byte* output, nuint capacity) {
        byte[] bytes = Encoding.UTF8.GetBytes("US\0");
        bytes.CopyTo(new Span<byte>(output, (int)capacity)); return 0;
    }
    [UnmanagedCallersOnly] static int Set(nint host, uint value) => 0;
    [UnmanagedCallersOnly] static int Read(nint host, AndroidHostApi.InputState* input) {
        *input = new() { Size = (uint)sizeof(AndroidHostApi.InputState), Version = 1 }; return 0;
    }
    [UnmanagedCallersOnly] static void Stop(nint host, uint reason, byte* text) { }
    [UnmanagedCallersOnly] static int Begin(nint host, byte* text, ulong* id) { *id = 17; return mode == 4 ? -4 : 0; }
    [UnmanagedCallersOnly] static int Cancel(nint host, ulong id) { cancels++; return 0; }
    [UnmanagedCallersOnly] static int Wait(nint host, ulong id, int timeout, byte* output, nuint capacity, nuint* length) {
        calls++;
        if (mode == 1) return -4;
        if (mode == 2) return -1;
        if (mode == 3) { *length = capacity; return 0; }
        if (calls == 1) return -6;
        byte[] bytes = Encoding.UTF8.GetBytes("你好😀\0");
        bytes.CopyTo(new Span<byte>(output, (int)capacity)); *length = (nuint)bytes.Length - 1; return 0;
    }
    internal static void Run(Action<bool> check, Action<Action> reject) {
        AndroidHostApi.User user = new() { Header = Header(sizeof(AndroidHostApi.User)), Language = &Text, Region = &Text, TimeZone = &Text };
        AndroidHostApi.Input input = new() { Header = Header(sizeof(AndroidHostApi.Input)), Read = &Read };
        AndroidHostApi.Display display = new() { Header = Header(sizeof(AndroidHostApi.Display)), Info = 1, SetMode = &Set };
        AndroidHostApi.Stop stop = new() { Header = Header(sizeof(AndroidHostApi.Stop)), Request = &Stop };
        AndroidHostApi.Ui ui = new() { Header = Header(sizeof(AndroidHostApi.Ui)), Begin = &Begin, Wait = &Wait, Cancel = &Cancel };
        AndroidHostApi.Api api = new() { Header = Header(sizeof(AndroidHostApi.Api)), Capabilities = 1 | 4 | 8 | 16 | 64,
            User = &user, Input = &input, Display = &display, Stop = &stop, Ui = (nint)(&ui) };
        var host = new AndroidHostApi((nint)(&api), 0);
        check(host.ExchangeUi("{}") == "你好😀" && calls == 2 && cancels == 1);
        mode = 1; check(host.ExchangeUi("{}") == null && cancels == 2);
        mode = 2; reject(() => host.ExchangeUi("{}")); check(cancels == 3);
        mode = 3; reject(() => host.ExchangeUi("{}")); check(cancels == 4);
        mode = 4; reject(() => host.ExchangeUi("{}")); check(cancels == 4);
        api.Capabilities &= ~16UL; reject(() => host.ExchangeUi("{}"));
        api.Capabilities |= 16; ui.Header.Version = 2; reject(() => host.ExchangeUi("{}"));
    }
}
