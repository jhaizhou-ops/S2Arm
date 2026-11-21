using System.Buffers.Binary;
using System;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Ryujinx.Common.Utilities
{
    public static class NetworkHelpers
    {
        private static (IPInterfaceProperties, UnicastIPAddressInformation) GetLocalInterface(NetworkInterface adapter, bool isPreferred)
        {
            IPInterfaceProperties properties = adapter.GetIPProperties();

            if (isPreferred || (properties.GatewayAddresses.Count > 0 && properties.DnsAddresses.Count > 0))
            {
                foreach (UnicastIPAddressInformation info in properties.UnicastAddresses)
                {
                    // Only accept an IPv4 address
                    if (info.Address.GetAddressBytes().Length == 4)
                    {
                        return (properties, info);
                    }
                }
            }

            return (null, null);
        }

        public static (IPInterfaceProperties, UnicastIPAddressInformation) GetLocalInterface(string lanInterfaceId = "0")
        {
            if (!NetworkInterface.GetIsNetworkAvailable())
            {
                return (null, null);
            }

            IPInterfaceProperties targetProperties = null;
            UnicastIPAddressInformation targetAddressInfo = null;

            NetworkInterface[] interfaces = NetworkInterface.GetAllNetworkInterfaces();

            string guid = lanInterfaceId;
            bool hasPreference = guid != "0";

            foreach (NetworkInterface adapter in interfaces)
            {
                bool isPreferred = adapter.Id == guid;

                // Ignore loopback and non IPv4 capable interface.
                if (isPreferred || (targetProperties == null && adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback && adapter.Supports(NetworkInterfaceComponent.IPv4)))
                {
                    (IPInterfaceProperties properties, UnicastIPAddressInformation info) = GetLocalInterface(adapter, isPreferred);

                    if (properties != null)
                    {
                        targetProperties = properties;
                        targetAddressInfo = info;

                        if (isPreferred || !hasPreference)
                        {
                            break;
                        }
                    }
                }
            }

            return (targetProperties, targetAddressInfo);
        }

        // Pick the local IPv4 address the OS would actually use for a target. Enumeration order is
        // not a route: machines can have Ethernet, Wi-Fi and VPN adapters on the same subnet, and
        // only the target route identifies the source address that can reach the peer.
        public static (IPInterfaceProperties properties, UnicastIPAddressInformation address) GetLocalInterfaceForTarget(
            string lanInterfaceId,
            IPAddress remoteAddress)
        {
            if (remoteAddress != null && remoteAddress.AddressFamily != AddressFamily.InterNetwork)
            {
                remoteAddress = null;
            }

            if (remoteAddress != null && IPAddress.IsLoopback(remoteAddress))
            {
                var loopback = FindInterfaceByAddress(IPAddress.Loopback);
                return loopback.properties != null ? loopback : (null, null);
            }

            NetworkInterface[] interfaces = NetworkInterface.GetAllNetworkInterfaces();
            NetworkInterface preferred = string.IsNullOrEmpty(lanInterfaceId) || lanInterfaceId == "0"
                ? null
                : Array.Find(interfaces, adapter => adapter.Id == lanInterfaceId);
            UnicastIPAddressInformation preferredAddress = GetIpv4Unicast(preferred);

            if (remoteAddress != null)
            {
                IPAddress source = ProbeRouteSource(remoteAddress, preferredAddress?.Address);
                if (source != null)
                {
                    var routed = FindInterfaceByAddress(source);
                    if (routed.properties != null)
                    {
                        return routed;
                    }
                }

                // An explicit interface remains authoritative while it is active. This also covers
                // targets for which a connect-only UDP probe cannot expose a source address.
                if (preferredAddress != null && preferred is { OperationalStatus: OperationalStatus.Up })
                {
                    return (preferred.GetIPProperties(), preferredAddress);
                }
            }
            else if (preferredAddress != null && preferred is { OperationalStatus: OperationalStatus.Up })
            {
                return (preferred.GetIPProperties(), preferredAddress);
            }

            // A default-route probe resolves the usual "which adapter wins?" ambiguity without
            // sending traffic. Tunnel results are rejected when a physical LAN adapter exists.
            IPAddress probeTarget = remoteAddress ?? new IPAddress(new byte[] { 192, 0, 2, 1 });
            IPAddress defaultSource = ProbeRouteSource(probeTarget, null);
            if (defaultSource != null)
            {
                var routed = FindInterfaceByAddress(defaultSource);
                NetworkInterface routedAdapter = FindAdapterByAddress(defaultSource);
                if (routed.properties != null &&
                    (remoteAddress == null
                        ? !IsTunnel(routedAdapter)
                        : !IsLocalTarget(remoteAddress) || !IsTunnel(routedAdapter)))
                {
                    return routed;
                }
            }

            return SelectBestLocalInterface(interfaces, remoteAddress, preferredAddress?.Address);
        }

        private static IPAddress ProbeRouteSource(IPAddress remoteAddress, IPAddress preferredSource)
        {
            if (remoteAddress == null ||
                remoteAddress.Equals(IPAddress.Any) ||
                remoteAddress.Equals(IPAddress.None))
            {
                return null;
            }

            try
            {
                using Socket socket = new(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);

                if (preferredSource != null)
                {
                    socket.Bind(new IPEndPoint(preferredSource, 0));
                }

                socket.Connect(remoteAddress, 0);

                return socket.LocalEndPoint is IPEndPoint endpoint ? endpoint.Address : null;
            }
            catch (SocketException)
            {
                return null;
            }
            catch (ObjectDisposedException)
            {
                return null;
            }
        }

        private static (IPInterfaceProperties properties, UnicastIPAddressInformation address) FindInterfaceByAddress(IPAddress address)
        {
            if (address == null)
            {
                return (null, null);
            }

            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                UnicastIPAddressInformation unicast = GetIpv4Unicast(adapter);
                if (unicast != null && unicast.Address.Equals(address))
                {
                    return (adapter.GetIPProperties(), unicast);
                }
            }

            return (null, null);
        }

        private static NetworkInterface FindAdapterByAddress(IPAddress address)
        {
            if (address == null)
            {
                return null;
            }

            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                UnicastIPAddressInformation unicast = GetIpv4Unicast(adapter);
                if (unicast != null && unicast.Address.Equals(address))
                {
                    return adapter;
                }
            }

            return null;
        }

        private static UnicastIPAddressInformation GetIpv4Unicast(NetworkInterface adapter)
        {
            if (adapter == null || !adapter.Supports(NetworkInterfaceComponent.IPv4))
            {
                return null;
            }

            foreach (UnicastIPAddressInformation info in adapter.GetIPProperties().UnicastAddresses)
            {
                if (info.Address.AddressFamily == AddressFamily.InterNetwork)
                {
                    return info;
                }
            }

            return null;
        }

        private static (IPInterfaceProperties properties, UnicastIPAddressInformation address) SelectBestLocalInterface(
            NetworkInterface[] interfaces,
            IPAddress remoteAddress,
            IPAddress preferredAddress)
        {
            IPInterfaceProperties bestProperties = null;
            UnicastIPAddressInformation bestAddress = null;
            int bestScore = int.MinValue;

            foreach (NetworkInterface adapter in interfaces)
            {
                if (adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                UnicastIPAddressInformation address = GetIpv4Unicast(adapter);
                if (address == null)
                {
                    continue;
                }

                IPInterfaceProperties properties = adapter.GetIPProperties();
                int score = 0;

                if (adapter.OperationalStatus == OperationalStatus.Up) score += 100;
                if (properties.GatewayAddresses.Count > 0) score += 40;
                if (properties.DnsAddresses.Count > 0) score += 10;
                if (adapter.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211) score += 80;
                if (IsTunnel(adapter)) score -= 500;
                if (address.Address.Equals(preferredAddress)) score += 10000;

                if (remoteAddress != null && IsSameSubnet(address, remoteAddress))
                {
                    score += 1000;
                }

                if (address.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                {
                    score -= 200;
                }

                if (score > bestScore)
                {
                    bestScore = score;
                    bestProperties = properties;
                    bestAddress = address;
                }
            }

            return (bestProperties, bestAddress);
        }

        private static bool IsSameSubnet(UnicastIPAddressInformation local, IPAddress remote)
        {
            if (local.IPv4Mask == null)
            {
                return false;
            }

            byte[] localBytes = local.Address.GetAddressBytes();
            byte[] remoteBytes = remote.GetAddressBytes();
            byte[] mask = local.IPv4Mask.GetAddressBytes();

            for (int i = 0; i < localBytes.Length; i++)
            {
                if ((localBytes[i] & mask[i]) != (remoteBytes[i] & mask[i]))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool IsTunnel(NetworkInterface adapter)
        {
            if (adapter == null)
            {
                return false;
            }

            string name = adapter.Name ?? string.Empty;
            return adapter.NetworkInterfaceType is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp ||
                   name.StartsWith("utun", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("tun", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("ipsec", StringComparison.OrdinalIgnoreCase) ||
                   name.StartsWith("ppp", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsLocalTarget(IPAddress address)
        {
            if (address.Equals(IPAddress.Broadcast) || address.Equals(IPAddress.None))
            {
                return true;
            }

            byte[] bytes = address.GetAddressBytes();
            if (bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 169 && bytes[1] == 254))
            {
                return true;
            }

            return (bytes[0] & 0xF0) == 0xE0;
        }

        public static bool SupportsDynamicDns()
        {
            return RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        }

        public static uint ConvertIpv4Address(IPAddress ipAddress)
        {
            return BinaryPrimitives.ReadUInt32BigEndian(ipAddress.GetAddressBytes());
        }

        public static uint ConvertIpv4Address(string ipAddress)
        {
            return ConvertIpv4Address(IPAddress.Parse(ipAddress));
        }

        public static IPAddress ConvertUint(uint ipAddress)
        {
            return new IPAddress(new byte[] { (byte)((ipAddress >> 24) & 0xFF), (byte)((ipAddress >> 16) & 0xFF), (byte)((ipAddress >> 8) & 0xFF), (byte)(ipAddress & 0xFF) });
        }
    }
}
