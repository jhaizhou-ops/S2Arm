using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using System;
using System.Collections.Generic;

namespace Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator
{
    class AccessPoint : IDisposable
    {
        private byte[] _advertiseData;

        private readonly IUserLocalCommunicationService _parent;

        public NetworkInfo NetworkInfo;
        public Array8<NodeLatestUpdate> LatestUpdates = new();
        public bool Connected { get; private set; }

        public ProxyConfig Config => _parent.NetworkClient.Config;

        public AccessPoint(IUserLocalCommunicationService parent)
        {
            _parent = parent;

            _parent.NetworkClient.NetworkChange += NetworkChanged;
        }

        // S2A（审计 #748 P1）：选举改指换中继客户端时接入点对象不重建——游戏已写的广告数据只存在本对象（客户端建房前不收），
        //   重建就丢成空。只把网络变化订阅从旧客户端挪到新客户端（换客户端前后各调一次）
        internal void S2AUnbindClient()
        {
            if (_parent.NetworkClient != null)
            {
                _parent.NetworkClient.NetworkChange -= NetworkChanged;
            }
        }

        internal void S2ABindClient()
        {
            _parent.NetworkClient.NetworkChange += NetworkChanged;
        }

        public void Dispose()
        {
            if (_parent?.NetworkClient != null)
            {
                _parent.NetworkClient.DisconnectNetwork();

                _parent.NetworkClient.NetworkChange -= NetworkChanged;
            }
        }

        private void NetworkChanged(object sender, NetworkChangeEventArgs e)
        {
            S2AFilterNewStations(NetworkInfo.Ldn.Nodes, e.Info.Ldn.Nodes);
            LatestUpdates.CalculateLatestUpdate(NetworkInfo.Ldn.Nodes, e.Info.Ldn.Nodes);

            NetworkInfo = e.Info;

            if (Connected != e.Connected)
            {
                Connected = e.Connected;

                if (Connected)
                {
                    _parent.SetState(NetworkState.AccessPointCreated);
                }
                else
                {
                    _parent.SetDisconnectReason(e.DisconnectReasonOrDefault(DisconnectReason.DestroyedBySystem));
                }
            }
            else
            {
                _parent.SetState();
            }
        }

        public ResultCode SetAdvertiseData(byte[] advertiseData)
        {
            _advertiseData = advertiseData;

            _parent.NetworkClient.SetAdvertiseData(_advertiseData);

            return ResultCode.Success;
        }

        public ResultCode SetStationAcceptPolicy(AcceptPolicy acceptPolicy)
        {
            _acceptPolicy = acceptPolicy;
            _parent.NetworkClient.SetStationAcceptPolicy(acceptPolicy);

            return ResultCode.Success;
        }

        // S2Arm (LDN G12): the station accept filter (nn::ldn AddAcceptFilterEntry / ClearAcceptFilter). The relay enforces AcceptAll /
        // RejectAll and lets BlackList / WhiteList stations in; the host then rejects a newly joined station whose MAC the list does
        // not allow (relay Reject → that station gets Rejected + Disconnect), the same outcome as the access point refusing it.
        private AcceptPolicy _acceptPolicy;
        private readonly HashSet<ulong> _acceptFilter = new();

        public void AddAcceptFilterEntry(ReadOnlySpan<byte> macAddress)
        {
            lock (_acceptFilter)
            {
                _acceptFilter.Add(S2AMacKey(macAddress));
            }
        }

        public void ClearAcceptFilter()
        {
            lock (_acceptFilter)
            {
                _acceptFilter.Clear();
            }
        }

        internal static ulong S2AMacKey(ReadOnlySpan<byte> mac)
        {
            ulong key = 0;

            for (int i = 0; i < 6; i++)
            {
                key = key << 8 | mac[i];
            }

            return key;
        }

        // BlackList: listed MACs are refused; WhiteList: only listed MACs are let in; AcceptAll / RejectAll are the relay's
        internal static bool S2AAllowed(AcceptPolicy policy, HashSet<ulong> filter, ulong mac) => policy switch
        {
            AcceptPolicy.BlackList => !filter.Contains(mac),
            AcceptPolicy.WhiteList => filter.Contains(mac),
            _ => true,
        };

        private void S2AFilterNewStations(Array8<NodeInfo> before, Array8<NodeInfo> after)
        {
            if (!Connected || (_acceptPolicy != AcceptPolicy.BlackList && _acceptPolicy != AcceptPolicy.WhiteList))
            {
                return;
            }

            for (int i = 1; i < after.Length; i++)   // node 0 is this access point
            {
                if (after[i].IsConnected == 0 || before[i].IsConnected != 0)
                {
                    continue;
                }

                bool allowed;

                lock (_acceptFilter)
                {
                    allowed = S2AAllowed(_acceptPolicy, _acceptFilter, S2AMacKey(after[i].MacAddress.AsSpan()));
                }

                if (!allowed)
                {
                    _parent.NetworkClient.Reject(DisconnectReason.Rejected, after[i].NodeId);
                }
            }
        }

        public ResultCode CreateNetwork(SecurityConfig securityConfig, UserConfig userConfig, NetworkConfig networkConfig)
        {
            CreateAccessPointRequest request = new()
            {
                SecurityConfig = securityConfig,
                UserConfig = userConfig,
                NetworkConfig = networkConfig,
            };

            bool success = _parent.NetworkClient.CreateNetwork(request, _advertiseData ?? []);

            return success ? ResultCode.Success : ResultCode.InvalidState;
        }

        public ResultCode CreateNetworkPrivate(SecurityConfig securityConfig, SecurityParameter securityParameter, UserConfig userConfig, NetworkConfig networkConfig, AddressList addressList)
        {
            CreateAccessPointPrivateRequest request = new()
            {
                SecurityConfig = securityConfig,
                SecurityParameter = securityParameter,
                UserConfig = userConfig,
                NetworkConfig = networkConfig,
                AddressList = addressList,
            };

            bool success = _parent.NetworkClient.CreateNetworkPrivate(request, _advertiseData ?? []);   // S2A：没写过广告数据按空广告（同公开建房），不把空引用交给编码

            return success ? ResultCode.Success : ResultCode.InvalidState;
        }
    }
}
