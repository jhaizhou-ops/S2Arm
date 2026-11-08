using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Proxy;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Sockets;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy
{
    static class SocketHelpers
    {
        private static LdnProxy _proxy;

        public static void Select(List<ISocketImpl> readEvents, List<ISocketImpl> writeEvents, List<ISocketImpl> errorEvents, int timeout)
        {
            List<Socket> readDefault = readEvents.Select(x => (x as DefaultSocket)?.BaseSocket).Where(x => x != null).ToList();
            List<Socket> writeDefault = writeEvents.Select(x => (x as DefaultSocket)?.BaseSocket).Where(x => x != null).ToList();
            List<Socket> errorDefault = errorEvents.Select(x => (x as DefaultSocket)?.BaseSocket).Where(x => x != null).ToList();

            // S2Arm: offline sockets have no host socket; they wait on the offline network (all sockets are offline sockets, or none is)
            List<OfflineSocket> readOffline = readEvents.OfType<OfflineSocket>().ToList();
            List<OfflineSocket> writeOffline = writeEvents.OfType<OfflineSocket>().ToList();
            List<OfflineSocket> errorOffline = errorEvents.OfType<OfflineSocket>().ToList();

            if (readDefault.Count != 0 || writeDefault.Count != 0 || errorDefault.Count != 0)
            {
                Socket.Select(readDefault, writeDefault, errorDefault, timeout);
            }

            if (readOffline.Count != 0 || writeOffline.Count != 0 || errorOffline.Count != 0)
            {
                OfflineSocket.Select(readOffline, writeOffline, errorOffline, readDefault.Count + writeDefault.Count + errorDefault.Count != 0 ? 0 : timeout);
            }

            void FilterSockets(List<ISocketImpl> removeFrom, List<Socket> selectedSockets, Func<LdnProxySocket, bool> ldnCheck, List<OfflineSocket> selectedOffline)
            {
                removeFrom.RemoveAll(socket =>
                {
                    switch (socket)
                    {
                        case DefaultSocket dsocket:
                            return !selectedSockets.Contains(dsocket.BaseSocket);
                        case LdnProxySocket psocket:
                            return !ldnCheck(psocket);
                        case OfflineSocket osocket:
                            return !selectedOffline.Contains(osocket);
                        default:
                            throw new NotImplementedException();
                    }
                });
            }

            FilterSockets(readEvents, readDefault, (socket) => socket.Readable, readOffline);
            FilterSockets(writeEvents, writeDefault, (socket) => socket.Writable, writeOffline);
            FilterSockets(errorEvents, errorDefault, (socket) => socket.Error, errorOffline);
        }

        public static void RegisterProxy(LdnProxy proxy)
        {
            if (_proxy != null)
            {
                UnregisterProxy();
            }

            _proxy = proxy;
        }

        public static void UnregisterProxy()
        {
            _proxy?.Dispose();
            _proxy = null;
        }

        public static ISocketImpl CreateSocket(AddressFamily domain, SocketType type, ProtocolType protocol, string lanInterfaceId, bool offline)
        {
            // S2Arm: local wireless works without internet access (a console in a local-play room has no internet either),
            // so sockets go on the LDN network first whenever one is joined
            if (_proxy != null && _proxy.Supported(domain, type, protocol))
            {
                Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Socket is using LDN proxy");
                return new LdnProxySocket(domain, type, protocol, _proxy);
            }

            // S2Arm: without internet access the console is offline — its sockets live on the offline network, never on a host socket
            if (offline)
            {
                Logger.Info?.PrintMsg(LogClass.ServiceBsd, "Offline console: socket on the loopback-only network (no host socket)");

                return new OfflineSocket(domain, type, protocol);
            }

            if (_proxy != null)
            {
                Logger.Warning?.PrintMsg(LogClass.ServiceBsd, $"LDN proxy does not support socket {domain}, {type}, {protocol}");
            }
            else
            {
                Logger.Info?.PrintMsg(LogClass.ServiceBsd, $"Opening socket using host networking stack");
            }

            return new DefaultSocket(domain, type, protocol, lanInterfaceId);
        }
    }
}
