// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Real HLE class, real loopback TCP and SslStream. No remote server or trust-store change.
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Ryujinx.HLE.HOS.Services.Ssl;

internal static class Program
{
    private static readonly Assembly Hle = typeof(ResultCode).Assembly;
    private static readonly Type Connection = Hle.GetType("Ryujinx.HLE.HOS.Services.Ssl.SslService.SslManagedSocketConnection", true)!;
    private static readonly Type Version = Hle.GetType("Ryujinx.HLE.HOS.Services.Ssl.Types.SslVersion", true)!;
    private static int _passed;
    private static int _failed;

    private static object Invoke(MethodInfo method, object instance, params object[] args)
    {
        try { return method.Invoke(instance, args)!; }
        catch (TargetInvocationException e) when (e.InnerException != null)
        {
            ExceptionDispatchInfo.Capture(e.InnerException).Throw();
            throw;
        }
    }

    private static object NewConnection(Socket socket, uint version = 1u << 5)
    {
        Type native = Hle.GetType("Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy.DefaultSocket", true)!;
        Type managed = Hle.GetType("Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl.ManagedSocket", true)!;
        object proxy = Activator.CreateInstance(native, socket, "0")!;
        object wrapper = Activator.CreateInstance(managed, BindingFlags.Instance | BindingFlags.NonPublic,
            null, new[] { proxy }, null)!;
        // Handshake never uses BsdContext. The test owns/disposes the real socket itself;
        // do not invoke the connection's descriptor-table Dispose with a null context.
        return Activator.CreateInstance(Connection, null, Enum.ToObject(Version, version), -1, wrapper)!;
    }

    private static void Check(string name, bool condition, string actual)
    {
        if (condition) { _passed++; Console.WriteLine($"PASS {name}: {actual}"); }
        else { _failed++; Console.WriteLine($"FAIL {name}: {actual}"); }
    }

    private static async Task PeerClosed(bool blocking, bool reset)
    {
        using var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        listener.Listen(1);
        using var client = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        client.ReceiveTimeout = 3000;
        client.SendTimeout = 3000;
        await client.ConnectAsync(listener.LocalEndPoint!);
        using Socket peer = await listener.AcceptAsync();
        peer.ReceiveTimeout = 3000;
        client.Blocking = blocking;
        object connection = NewConnection(client);
        // Read ClientHello before closing: guarantees a mid-handshake disconnect, not a connect failure.
        Task<int> closePeer = Task.Run(() =>
        {
            int read = peer.Receive(new byte[4096]);
            if (reset) peer.LingerState = new LingerOption(true, 0);
            else peer.Shutdown(SocketShutdown.Both);
            peer.Close();
            return read;
        });
        string name = $"peer-{(reset ? "reset" : "eof")}/blocking={blocking}";
        ResultCode? result = null;
        Exception escaped = null;
        try { result = (ResultCode)Invoke(Connection.GetMethod("Handshake")!, connection, "localhost"); }
        catch (Exception e) { escaped = e; }
        int hello = await closePeer.WaitAsync(TimeSpan.FromSeconds(5));
        Check(name + "/clienthello", hello > 0, $"bytes={hello}");
        // EOF has no SocketError; RST has ConnectionReset. These expectations come from #1037,
        // not from calling the production exception translator.
        ResultCode expected = reset ? ResultCode.ConnectionReset : ResultCode.ConnectionAbort;
        Check(name + "/result", escaped == null && result == expected,
            escaped == null ? $"expected={expected}, actual={result}" : $"escaped={escaped.GetType().Name}");
        Check(name + "/restore", client.Blocking == blocking, $"expected={blocking}, actual={client.Blocking}");
    }

    private static async Task UntrustedCertificate(bool blocking)
    {
        // Ephemeral original certificate, never trusted or saved: verify authentication failures
        // remain errors, rather than accidentally accepting a bad server to make TLS succeed.
        using RSA key = RSA.Create(2048);
        var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using X509Certificate2 certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        using var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        listener.Listen(1);
        using var client = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        client.ReceiveTimeout = 3000;
        client.SendTimeout = 3000;
        await client.ConnectAsync(listener.LocalEndPoint!);
        using Socket peer = await listener.AcceptAsync();
        using var server = new SslStream(new NetworkStream(peer, false));
        Task authenticate = server.AuthenticateAsServerAsync(certificate, false, SslProtocols.Tls12, false);
        client.Blocking = blocking;
        Exception escaped = null;
        ResultCode? result = null;
        try { result = (ResultCode)Invoke(Connection.GetMethod("Handshake")!, NewConnection(client), "localhost"); }
        catch (Exception e) { escaped = e; }
        Check($"untrusted/blocking={blocking}/result", escaped == null && result == ResultCode.ConnectionAbort,
            escaped == null ? $"expected=ConnectionAbort, actual={result}" : $"escaped={escaped.GetType().Name}");
        Check($"untrusted/blocking={blocking}/restore", client.Blocking == blocking,
            $"expected={blocking}, actual={client.Blocking}");
        client.Close();
        try { await authenticate.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (AuthenticationException) { }
        catch (IOException) { }
    }

    private static async Task UnsupportedProtocol()
    {
        using var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        listener.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        listener.Listen(1);
        using var client = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        await client.ConnectAsync(listener.LocalEndPoint!);
        using Socket peer = await listener.AcceptAsync();
        client.Blocking = false;
        object connection = NewConnection(client, 0);
        Exception escaped = null;
        try { Invoke(Connection.GetMethod("Handshake")!, connection, "localhost"); }
        catch (Exception e) { escaped = e; }
        Check("unsupported/not-swallowed", escaped is NotImplementedException,
            escaped?.GetType().Name ?? "no exception");
        Check("unsupported/restore", !client.Blocking, $"expected=False, actual={client.Blocking}");
    }

    private static void Mapping()
    {
        MethodInfo map = Connection.GetMethod("TranslateHandshakeException", BindingFlags.NonPublic | BindingFlags.Static);
        if (map == null) { Check("mapping helper", false, "not present on baseline"); return; }
        (string, Exception, ResultCode)[] cases =
        {
            ("authentication", new AuthenticationException("synthetic"), ResultCode.ConnectionAbort),
            ("io-eof", new IOException("synthetic"), ResultCode.ConnectionAbort),
            ("direct-reset", new SocketException((int)SocketError.ConnectionReset), ResultCode.ConnectionReset),
            ("direct-timeout", new SocketException((int)SocketError.TimedOut), ResultCode.Timeout),
            ("direct-abort", new SocketException((int)SocketError.ConnectionAborted), ResultCode.ConnectionAbort),
            ("other-socket", new SocketException((int)SocketError.HostUnreachable), ResultCode.ConnectionAbort),
            ("io-reset", new IOException("synthetic", new SocketException((int)SocketError.ConnectionReset)), ResultCode.ConnectionReset),
            ("auth-io-timeout", new AuthenticationException("synthetic", new IOException("synthetic", new SocketException((int)SocketError.TimedOut))), ResultCode.Timeout),
        };
        foreach (var (name, error, expected) in cases)
        {
            ResultCode actual = (ResultCode)Invoke(map, null, error);
            Check("mapping/" + name, actual == expected, $"expected={expected}, actual={actual}");
        }
    }

    private static async Task<int> Main(string[] args)
    {
        // Loopback-only mode is the red/green and reverted-catch control, independent of the new helper.
        foreach (bool blocking in new[] { false, true })
            foreach (bool reset in new[] { false, true })
                await PeerClosed(blocking, reset);
        if (!args.Contains("--loopback-only"))
        {
            Mapping();
            await UnsupportedProtocol();
            await UntrustedCertificate(false);
            await UntrustedCertificate(true);
        }
        Console.WriteLine($"SSL handshake: passed={_passed}, failed={_failed}");
        return _failed == 0 ? 0 : 1;
    }
}
