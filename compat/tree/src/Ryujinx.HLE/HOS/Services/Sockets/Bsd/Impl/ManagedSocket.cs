using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Types;
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl
{
    class ManagedSocket : ISocket
    {
        public int Refcount { get; set; }

        public AddressFamily AddressFamily => Socket.AddressFamily;

        public SocketType SocketType => Socket.SocketType;

        public ProtocolType ProtocolType => Socket.ProtocolType;

        public bool Blocking { get => Socket.Blocking; set => Socket.Blocking = value; }

        public nint Handle => nint.Zero;

        public IPEndPoint RemoteEndPoint => Socket.RemoteEndPoint as IPEndPoint;

        public IPEndPoint LocalEndPoint => Socket.LocalEndPoint as IPEndPoint;

        public ISocketImpl Socket { get; }

        public ManagedSocket(AddressFamily addressFamily, SocketType socketType, ProtocolType protocolType, string lanInterfaceId, bool offline)
        {
            Socket = SocketHelpers.CreateSocket(addressFamily, socketType, protocolType, lanInterfaceId, offline);
            Refcount = 1;
        }

        private ManagedSocket(ISocketImpl socket)
        {
            Socket = socket;
            Refcount = 1;
        }

        // Horizon's per-call non-blocking flags: DontWait (MSG_DONTWAIT) and Nbio (MSG_NBIO, 0x4000, FreeBSD's per-call non-blocking I/O; the caller turns
        // the socket non-blocking for this one call). S2Arm 11-06: Mortal Kombat 11 recvfrom()s with Nbio on its loopback UDP socket on the main thread before
        // its second frame; Nbio was left as an "unsupported flag", the call blocked on the offline socket with no sender, and the game stayed on frame 1
        private static bool IsNonBlockingCall(BsdSocketFlags flags) => (flags & (BsdSocketFlags.DontWait | BsdSocketFlags.Nbio)) != 0;

        private static SocketFlags ConvertBsdSocketFlags(BsdSocketFlags bsdSocketFlags)
        {
            SocketFlags socketFlags = SocketFlags.None;

            if (bsdSocketFlags.HasFlag(BsdSocketFlags.Oob))
            {
                socketFlags |= SocketFlags.OutOfBand;
            }

            if (bsdSocketFlags.HasFlag(BsdSocketFlags.Peek))
            {
                socketFlags |= SocketFlags.Peek;
            }

            if (bsdSocketFlags.HasFlag(BsdSocketFlags.DontRoute))
            {
                socketFlags |= SocketFlags.DontRoute;
            }

            if (bsdSocketFlags.HasFlag(BsdSocketFlags.Trunc))
            {
                socketFlags |= SocketFlags.Truncated;
            }

            if (bsdSocketFlags.HasFlag(BsdSocketFlags.CTrunc))
            {
                socketFlags |= SocketFlags.ControlDataTruncated;
            }

            bsdSocketFlags &= ~(BsdSocketFlags.Oob |
                BsdSocketFlags.Peek |
                BsdSocketFlags.DontRoute |
                BsdSocketFlags.DontWait |
                BsdSocketFlags.Nbio |
                BsdSocketFlags.Trunc |
                BsdSocketFlags.CTrunc);

            if (bsdSocketFlags != BsdSocketFlags.None)
            {
                Logger.Warning?.Print(LogClass.ServiceBsd, $"Unsupported socket flags: {bsdSocketFlags}");
            }

            return socketFlags;
        }

        public LinuxError Accept(out ISocket newSocket)
        {
            try
            {
                newSocket = new ManagedSocket(Socket.Accept());

                IPEndPoint remoteEndPoint = newSocket.RemoteEndPoint;
                bool isPrivateIp = remoteEndPoint.Address.ToString().StartsWith("192.168.");
                Logger.Info?.PrintMsg(LogClass.ServiceBsd,
                    isPrivateIp
                        ? $"Accepted connection from {ProtocolType}/{remoteEndPoint.Address}:{remoteEndPoint.Port}"
                        : $"Accepted connection from {ProtocolType}/***:{remoteEndPoint.Port}");

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                newSocket = null;

                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public LinuxError Bind(IPEndPoint localEndPoint)
        {
            Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Socket binding to: {ProtocolType}/{localEndPoint.Port}");
            try
            {
                Socket.Bind(localEndPoint);

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public void Close()
        {
            Socket.Close();
        }

        public LinuxError Connect(IPEndPoint remoteEndPoint)
        {
            bool isLDNPrivateIP = remoteEndPoint.Address.ToString().StartsWith("192.168.");
            if (isLDNPrivateIP)
            {
                Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Connecting to: {ProtocolType}/{remoteEndPoint.Address}:{remoteEndPoint.Port}");
            }
            else
            {
                Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Connecting to: {ProtocolType}/***:{remoteEndPoint.Port}");
            }

            try
            {
                Socket.Connect(remoteEndPoint);

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (!Blocking && exception.ErrorCode == (int)WsaError.WSAEWOULDBLOCK)
                {
                    return LinuxError.EINPROGRESS;
                }
                else
                {
                    if (exception.SocketErrorCode != SocketError.WouldBlock)
                    {
                        Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                    }

                    return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
                }
            }
        }

        public void Disconnect()
        {
            Logger.Info?.Print(LogClass.ServiceBsd, "Socket disconnecting");
            Socket.Disconnect(true);
        }

        public void Dispose()
        {
            Logger.Info?.Print(LogClass.ServiceBsd, "Socket closed");
            Socket.Close();
            Socket.Dispose();
        }

        public LinuxError Listen(int backlog)
        {
            try
            {
                Socket.Listen(backlog);

                Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Socket listening: {ProtocolType}/{(Socket.LocalEndPoint as IPEndPoint).Port}");

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public bool Poll(int microSeconds, SelectMode mode)
        {
            return Socket.Poll(microSeconds, mode);
        }

        public LinuxError Shutdown(BsdSocketShutdownFlags how)
        {
            try
            {
                Socket.Shutdown((SocketShutdown)how);

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        private bool _hasEmittedBlockingWarning;

        public LinuxError Receive(out int receiveSize, Span<byte> buffer, BsdSocketFlags flags)
        {
            LinuxError result;

            bool shouldBlockAfterOperation = false;

            try
            {
                if (Blocking && IsNonBlockingCall(flags))
                {
                    Blocking = false;
                    shouldBlockAfterOperation = true;
                }

                if (Blocking && !_hasEmittedBlockingWarning)
                {
                    Logger.Warning?.PrintMsg(LogClass.ServiceBsd, "Blocking socket operations are not yet working properly. Expect network errors.");
                    _hasEmittedBlockingWarning = true;
                }

                receiveSize = Socket.Receive(buffer, ConvertBsdSocketFlags(flags));

                result = LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                receiveSize = -1;

                result = WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }

            if (shouldBlockAfterOperation)
            {
                Blocking = true;
            }

            return result;
        }

        public LinuxError ReceiveFrom(out int receiveSize, Span<byte> buffer, int size, BsdSocketFlags flags, out IPEndPoint remoteEndPoint)
        {
            remoteEndPoint = new IPEndPoint(IPAddress.Any, 0);

            LinuxError result;

            bool shouldBlockAfterOperation = false;

            try
            {
                EndPoint temp = new IPEndPoint(IPAddress.Any, 0);

                if (Blocking && IsNonBlockingCall(flags))
                {
                    Blocking = false;
                    shouldBlockAfterOperation = true;
                }

                if (Blocking && !_hasEmittedBlockingWarning)
                {
                    Logger.Warning?.PrintMsg(LogClass.ServiceBsd, "Blocking socket operations are not yet working properly. Expect network errors.");
                    _hasEmittedBlockingWarning = true;
                }

                if (!Socket.IsBound)
                {
                    receiveSize = -1;

                    return LinuxError.EOPNOTSUPP;
                }

                receiveSize = Socket.ReceiveFrom(buffer[..size], ConvertBsdSocketFlags(flags), ref temp);

                remoteEndPoint = (IPEndPoint)temp;
                result = LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                receiveSize = -1;

                result = WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }

            if (shouldBlockAfterOperation)
            {
                Blocking = true;
            }

            return result;
        }

        public LinuxError Send(out int sendSize, ReadOnlySpan<byte> buffer, BsdSocketFlags flags)
        {
            try
            {
                sendSize = Socket.Send(buffer, ConvertBsdSocketFlags(flags));

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                sendSize = -1;

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public LinuxError SendTo(out int sendSize, ReadOnlySpan<byte> buffer, int size, BsdSocketFlags flags, IPEndPoint remoteEndPoint)
        {
            try
            {
                sendSize = Socket.SendTo(buffer[..size], ConvertBsdSocketFlags(flags), remoteEndPoint);

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                sendSize = -1;

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public LinuxError GetSocketOption(BsdSocketOption option, SocketOptionLevel level, Span<byte> optionValue)
        {
            try
            {
                LinuxError result = WinSockHelper.ValidateSocketOption(option, level, write: false);

                if (result != LinuxError.SUCCESS)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Invalid GetSockOpt Option: {option} Level: {level}");

                    return result;
                }

                if (!WinSockHelper.TryConvertSocketOption(option, level, out SocketOptionName optionName))
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Unsupported GetSockOpt Option: {option} Level: {level}");
                    optionValue.Clear();

                    return LinuxError.EOPNOTSUPP;
                }

                byte[] tempOptionValue = new byte[optionValue.Length];

                Socket.GetSocketOption(level, optionName, tempOptionValue);

                tempOptionValue.AsSpan().CopyTo(optionValue);

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public LinuxError SetSocketOption(BsdSocketOption option, SocketOptionLevel level, ReadOnlySpan<byte> optionValue)
        {
            try
            {
                LinuxError result = WinSockHelper.ValidateSocketOption(option, level, write: true);

                if (result != LinuxError.SUCCESS)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Invalid SetSockOpt Option: {option} Level: {level}");

                    return result;
                }

                if (!WinSockHelper.TryConvertSocketOption(option, level, out SocketOptionName optionName))
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Unsupported SetSockOpt Option: {option} Level: {level}");

                    return LinuxError.EOPNOTSUPP;
                }

                // S2Arm: a value shorter than the option is EINVAL, as on the console (it used to throw out of the service command for a 0-byte value)
                if (optionValue.Length < WinSockHelper.SetSocketOptionMinLength(option, level))
                {
                    return LinuxError.EINVAL;
                }

                int value = optionValue.Length >= 4 ? MemoryMarshal.Read<int>(optionValue) : MemoryMarshal.Read<byte>(optionValue);

                if (level == SocketOptionLevel.Socket && option == BsdSocketOption.SoLinger)
                {
                    int value2 = 0;

                    if (optionValue.Length >= 8)
                    {
                        value2 = MemoryMarshal.Read<int>(optionValue[4..]);
                    }

                    Socket.SetSocketOption(level, SocketOptionName.Linger, new LingerOption(value != 0, value2));
                }
                else
                {
                    Socket.SetSocketOption(level, optionName, value);
                }

                return LinuxError.SUCCESS;
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public LinuxError Read(out int readSize, Span<byte> buffer)
        {
            return Receive(out readSize, buffer, BsdSocketFlags.None);
        }

        public LinuxError Write(out int writeSize, ReadOnlySpan<byte> buffer)
        {
            return Send(out writeSize, buffer, BsdSocketFlags.None);
        }

        private bool CanSupportMMsgHdr(BsdMMsgHdr message)
        {
            for (int i = 0; i < message.Messages.Length; i++)
            {
                if (message.Messages[i].Name != null ||
                    message.Messages[i].Control != null)
                {
                    return false;
                }
            }

            return true;
        }

        private static ArraySegment<byte>[] ConvertMessagesToBuffer(BsdMMsgHdr message)
        {
            int segmentCount = 0;
            int index = 0;

            foreach (BsdMsgHdr msgHeader in message.Messages)
            {
                segmentCount += msgHeader.Iov.Length;
            }

            ArraySegment<byte>[] buffers = new ArraySegment<byte>[segmentCount];

            foreach (BsdMsgHdr msgHeader in message.Messages)
            {
                foreach (byte[] iov in msgHeader.Iov)
                {
                    buffers[index++] = new ArraySegment<byte>(iov);
                }

                // Clear the length
                msgHeader.Length = 0;
            }

            return buffers;
        }

        private static void UpdateMessages(out int vlen, BsdMMsgHdr message, int transferedSize)
        {
            int bytesLeft = transferedSize;
            int index = 0;

            while (bytesLeft > 0)
            {
                // First ensure we haven't finished all buffers
                if (index >= message.Messages.Length)
                {
                    break;
                }

                BsdMsgHdr msgHeader = message.Messages[index];

                int possiblyTransferedBytes = 0;

                foreach (byte[] iov in msgHeader.Iov)
                {
                    possiblyTransferedBytes += iov.Length;
                }

                int storedBytes;

                if (bytesLeft > possiblyTransferedBytes)
                {
                    storedBytes = possiblyTransferedBytes;
                    index++;
                }
                else
                {
                    storedBytes = bytesLeft;
                }

                msgHeader.Length = (uint)storedBytes;
                bytesLeft -= storedBytes;
            }

            Debug.Assert(bytesLeft == 0);

            vlen = index + 1;
        }

        // S2Arm (LDN G13): FreeBSD recvmmsg semantics on a socket without a host socket — each message receives one datagram
        // (gathered, then scattered over its iovs; the length is the datagram size). Only the first receive follows the socket's
        // blocking mode; later messages are filled only while a datagram is already queued. An error after the first datagram
        // ends the batch with what was received.
        private LinuxError ProxyRecvMMsg(out int vlen, BsdMMsgHdr message, BsdSocketFlags flags)
        {
            vlen = 0;
            SocketFlags socketFlags = ConvertBsdSocketFlags(flags);

            foreach (BsdMsgHdr msgHeader in message.Messages)
            {
                if (vlen > 0 && !Socket.Poll(0, SelectMode.SelectRead))
                {
                    break;
                }

                int capacity = 0;

                foreach (byte[] iov in msgHeader.Iov)
                {
                    capacity += iov.Length;
                }

                byte[] datagram = new byte[capacity];
                int size;

                try
                {
                    size = Socket.Receive(datagram, socketFlags, out SocketError socketError);

                    if (socketError != SocketError.Success)
                    {
                        return vlen > 0 ? LinuxError.SUCCESS : WinSockHelper.ConvertSocketError(socketError);
                    }
                }
                catch (SocketException exception)
                {
                    return vlen > 0 ? LinuxError.SUCCESS : WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
                }

                int offset = 0;

                foreach (byte[] iov in msgHeader.Iov)
                {
                    int count = Math.Min(iov.Length, size - offset);

                    if (count <= 0)
                    {
                        break;
                    }

                    datagram.AsSpan(offset, count).CopyTo(iov);
                    offset += count;
                }

                msgHeader.Length = (uint)size;
                vlen++;
            }

            return LinuxError.SUCCESS;
        }

        // S2Arm (LDN G13): FreeBSD sendmmsg semantics — each message is one datagram (its iovs gathered) to the connected peer
        private LinuxError ProxySendMMsg(out int vlen, BsdMMsgHdr message, BsdSocketFlags flags)
        {
            vlen = 0;
            SocketFlags socketFlags = ConvertBsdSocketFlags(flags);

            foreach (BsdMsgHdr msgHeader in message.Messages)
            {
                int length = 0;

                foreach (byte[] iov in msgHeader.Iov)
                {
                    length += iov.Length;
                }

                byte[] datagram = new byte[length];
                int offset = 0;

                foreach (byte[] iov in msgHeader.Iov)
                {
                    iov.CopyTo(datagram, offset);
                    offset += iov.Length;
                }

                try
                {
                    int sent = Socket.Send(datagram, socketFlags, out SocketError socketError);

                    if (socketError != SocketError.Success)
                    {
                        return vlen > 0 ? LinuxError.SUCCESS : WinSockHelper.ConvertSocketError(socketError);
                    }

                    msgHeader.Length = (uint)sent;
                }
                catch (SocketException exception)
                {
                    return vlen > 0 ? LinuxError.SUCCESS : WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
                }

                vlen++;
            }

            return LinuxError.SUCCESS;
        }

        // TODO: Find a way to support passing the timeout somehow without changing the socket ReceiveTimeout.
        public LinuxError RecvMMsg(out int vlen, BsdMMsgHdr message, BsdSocketFlags flags, TimeVal timeout)
        {
            vlen = 0;

            if (message.Messages.Length == 0)
            {
                return LinuxError.SUCCESS;
            }

            if (!CanSupportMMsgHdr(message))
            {
                Logger.Warning?.Print(LogClass.ServiceBsd, "Unsupported BsdMMsgHdr");

                return LinuxError.EOPNOTSUPP;
            }

            if (message.Messages.Length == 0)
            {
                return LinuxError.SUCCESS;
            }

            // S2Arm (LDN G13): an LDN proxy socket takes one datagram per message like FreeBSD recvmmsg
            if (Socket is Ldn.UserServiceCreator.LdnRyu.Proxy.LdnProxySocket)
            {
                return ProxyRecvMMsg(out vlen, message, flags);
            }

            // S2Arm: scatter / gather goes straight to the host socket; an offline socket has neither and does not support it
            if (Socket is not DefaultSocket)
            {
                Logger.Warning?.Print(LogClass.ServiceBsd, "RecvMMsg on a socket without a host socket is not supported");

                return LinuxError.EOPNOTSUPP;
            }

            try
            {
                int receiveSize = (Socket as DefaultSocket).BaseSocket.Receive(ConvertMessagesToBuffer(message), ConvertBsdSocketFlags(flags), out SocketError socketError);

                if (receiveSize > 0)
                {
                    UpdateMessages(out vlen, message, receiveSize);
                }

                return WinSockHelper.ConvertSocketError(socketError);
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }

        public LinuxError SendMMsg(out int vlen, BsdMMsgHdr message, BsdSocketFlags flags)
        {
            vlen = 0;

            if (message.Messages.Length == 0)
            {
                return LinuxError.SUCCESS;
            }

            if (!CanSupportMMsgHdr(message))
            {
                Logger.Warning?.Print(LogClass.ServiceBsd, "Unsupported BsdMMsgHdr");

                return LinuxError.EOPNOTSUPP;
            }

            if (message.Messages.Length == 0)
            {
                return LinuxError.SUCCESS;
            }

            // S2Arm (LDN G13): an LDN proxy socket sends one datagram per message like FreeBSD sendmmsg
            if (Socket is Ldn.UserServiceCreator.LdnRyu.Proxy.LdnProxySocket)
            {
                return ProxySendMMsg(out vlen, message, flags);
            }

            // S2Arm: scatter / gather goes straight to the host socket; an offline socket has neither and does not support it
            if (Socket is not DefaultSocket)
            {
                Logger.Warning?.Print(LogClass.ServiceBsd, "SendMMsg on a socket without a host socket is not supported");

                return LinuxError.EOPNOTSUPP;
            }

            try
            {
                int sendSize = (Socket as DefaultSocket).BaseSocket.Send(ConvertMessagesToBuffer(message), ConvertBsdSocketFlags(flags), out SocketError socketError);

                if (sendSize > 0)
                {
                    UpdateMessages(out vlen, message, sendSize);
                }

                return WinSockHelper.ConvertSocketError(socketError);
            }
            catch (SocketException exception)
            {
                if (exception.SocketErrorCode != SocketError.WouldBlock)
                {
                    Logger.Warning?.Print(LogClass.ServiceBsd, $"Socket Exception: {exception}");
                }

                return WinSockHelper.ConvertError((WsaError)exception.ErrorCode);
            }
        }
    }
}
