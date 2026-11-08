using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Utilities;
using Ryujinx.HLE.HOS.Services.Nifm.StaticService.GeneralService;
using Ryujinx.HLE.HOS.Services.Nifm.StaticService.Types;
using System;
using System.Net.NetworkInformation;
using System.Runtime.CompilerServices;

namespace Ryujinx.HLE.HOS.Services.Nifm.StaticService
{
    class IGeneralService : DisposableIpcService
    {
        private readonly GeneralServiceDetail _generalServiceDetail;

        private IPInterfaceProperties _targetPropertiesCache = null;
        private UnicastIPAddressInformation _targetAddressInfoCache = null;
        private string _cacheChosenInterface = null;

        // S2Arm: an offline console never looks at the host's network — subscribing to NetworkChange starts the runtime's host
        // network-change listener (SCDynamicStore session on Apple), and the cache it invalidates is only used with internet access
        private readonly bool _watchHostNetwork;

        public IGeneralService(ServiceCtx context)
        {
            _generalServiceDetail = new GeneralServiceDetail
            {
                ClientId = GeneralServiceManager.Count,
                IsAnyInternetRequestAccepted = !context.Device.DirtyHacks.IsEnabled(DirtyHack.NifmServiceDisableIsAnyInternetRequestAccepted), // NOTE: Why not accept any internet request?
            };

            _watchHostNetwork = context.Device.Configuration.EnableInternetAccess;

            if (_watchHostNetwork)
            {
                NetworkChange.NetworkAddressChanged += LocalInterfaceCacheHandler;
            }

            GeneralServiceManager.Add(_generalServiceDetail);
        }

        [CommandCmif(1)]
        // GetClientId() -> buffer<nn::nifm::ClientId, 0x1a, 4>
        public ResultCode GetClientId(ServiceCtx context)
        {
            ulong position = context.Request.RecvListBuff[0].Position;

            context.Response.PtrBuff[0] = context.Response.PtrBuff[0].WithSize(sizeof(int));

            context.Memory.Write(position, _generalServiceDetail.ClientId);

            return ResultCode.Success;
        }

        [CommandCmif(4)]
        // CreateRequest(u32 version) -> object<nn::nifm::detail::IRequest>
        public ResultCode CreateRequest(ServiceCtx context)
        {
            uint version = context.RequestData.ReadUInt32();

            MakeObject(context, new IRequest(context.Device.System, version));

            // Doesn't occur in our case.
            // return ResultCode.ObjectIsNull;

            Logger.Stub?.PrintStub(LogClass.ServiceNifm, new { version });

            return ResultCode.Success;
        }

        [CommandCmif(5)]
        // GetCurrentNetworkProfile() -> buffer<nn::nifm::detail::sf::NetworkProfileData, 0x1a, 0x17c>
        public ResultCode GetCurrentNetworkProfile(ServiceCtx context)
        {
            ulong networkProfileDataPosition = context.Request.RecvListBuff[0].Position;

            (IPInterfaceProperties interfaceProperties, UnicastIPAddressInformation unicastAddress) = GetLocalInterface(context);

            if (interfaceProperties == null || unicastAddress == null)
            {
                return ResultCode.NoInternetConnection;
            }

            Logger.Info?.Print(LogClass.ServiceNifm, $"Console's local IP is \"{unicastAddress.Address}\".");

            context.Response.PtrBuff[0] = context.Response.PtrBuff[0].WithSize((uint)Unsafe.SizeOf<NetworkProfileData>());

            NetworkProfileData networkProfile = new()
            {
                Uuid = Random.Shared.NextUInt128(),
            };

            networkProfile.IpSettingData.IpAddressSetting = new IpAddressSetting(interfaceProperties, unicastAddress);
            networkProfile.IpSettingData.DnsSetting = new DnsSetting(interfaceProperties);

            "RyujinxNetwork"u8.CopyTo(networkProfile.Name.AsSpan());

            context.Memory.Write(networkProfileDataPosition, networkProfile);

            return ResultCode.Success;
        }

        [CommandCmif(101)]
        // GetCurrentNetworkProfile (Switch 2 SDK, nn::nifm::GetCurrentNetworkProfile(NetworkProfileDataV2*)) -> buffer<nn::nifm::detail::sf::NetworkProfileDataV2, 0x1a, 0x1b4>
        // S2Arm: wire format from the Zelda OoT (Switch 2) sdk proxy (C buffer fixed 0x1b4, no in-data, no pid). Without internet access the console has no
        //   current network: same reply as command 5 (NoInternetConnection; SDK GetCurrentProxySetting passes it up, the game skips the proxy).
        //   With internet access the V2 layout (0x1b4 vs V1 0x17c) is not known: reported red, never a made-up profile.
        public ResultCode GetCurrentNetworkProfileV2(ServiceCtx context)
        {
            (IPInterfaceProperties interfaceProperties, UnicastIPAddressInformation unicastAddress) = GetLocalInterface(context);

            if (interfaceProperties == null || unicastAddress == null)
            {
                return ResultCode.NoInternetConnection;
            }

            throw new NotImplementedException("IGeneralService 命令 101 GetCurrentNetworkProfile（V2）：联网时 NetworkProfileDataV2（0x1b4 字节）的布局不知道");
        }

        [CommandCmif(12)]
        // GetCurrentIpAddress() -> nn::nifm::IpV4Address
        public ResultCode GetCurrentIpAddress(ServiceCtx context)
        {
            (_, UnicastIPAddressInformation unicastAddress) = GetLocalInterface(context);

            if (unicastAddress == null)
            {
                return ResultCode.NoInternetConnection;
            }

            context.ResponseData.WriteStruct(new IpV4Address(unicastAddress.Address));

            Logger.Info?.Print(LogClass.ServiceNifm, $"Console's local IP is \"{unicastAddress.Address}\".");

            return ResultCode.Success;
        }

        [CommandCmif(15)]
        // GetCurrentIpConfigInfo() -> (nn::nifm::IpAddressSetting, nn::nifm::DnsSetting)
        public ResultCode GetCurrentIpConfigInfo(ServiceCtx context)
        {
            (IPInterfaceProperties interfaceProperties, UnicastIPAddressInformation unicastAddress) = GetLocalInterface(context);

            if (interfaceProperties == null || unicastAddress == null)
            {
                return ResultCode.NoInternetConnection;
            }

            Logger.Info?.Print(LogClass.ServiceNifm, $"Console's local IP is \"{unicastAddress.Address}\".");

            context.ResponseData.WriteStruct(new IpAddressSetting(interfaceProperties, unicastAddress));
            context.ResponseData.WriteStruct(new DnsSetting(interfaceProperties));

            return ResultCode.Success;
        }

        [CommandCmif(18)]
        // GetInternetConnectionStatus() -> nn::nifm::detail::sf::InternetConnectionStatus
        public ResultCode GetInternetConnectionStatus(ServiceCtx context)
        {
            if (!context.Device.Configuration.EnableInternetAccess || !NetworkInterface.GetIsNetworkAvailable())
            {
                return ResultCode.NoInternetConnection;
            }

            InternetConnectionStatus internetConnectionStatus = new()
            {
                Type = InternetConnectionType.WiFi,
                WifiStrength = 3,
                State = InternetConnectionState.Connected,
            };

            context.ResponseData.WriteStruct(internetConnectionStatus);

            return ResultCode.Success;
        }

        [CommandCmif(21)]
        // IsAnyInternetRequestAccepted(buffer<nn::nifm::ClientId, 0x19, 4>) -> bool
        public ResultCode IsAnyInternetRequestAccepted(ServiceCtx context)
        {
            ulong position = context.Request.PtrBuff[0].Position;
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            ulong size = context.Request.PtrBuff[0].Size;
#pragma warning restore IDE0059

            int clientId = context.Memory.Read<int>(position);

            context.ResponseData.Write(GeneralServiceManager.Get(clientId).IsAnyInternetRequestAccepted);

            return ResultCode.Success;
        }

        // S2Arm: without internet access the console is offline — no current network profile / IP / IP config
        // (a real offline console returns NoInternetConnection here; reporting the host's IP made Diablo II try Battle.net
        // authentication, fail and bounce back to the title screen forever)
        private (IPInterfaceProperties, UnicastIPAddressInformation) GetLocalInterface(ServiceCtx context)
        {
            if (!context.Device.Configuration.EnableInternetAccess || !NetworkInterface.GetIsNetworkAvailable())
            {
                return (null, null);
            }

            string chosenInterface = context.Device.Configuration.MultiplayerLanInterfaceId;

            if (_targetPropertiesCache == null || _targetAddressInfoCache == null || _cacheChosenInterface != chosenInterface)
            {
                _cacheChosenInterface = chosenInterface;

                (_targetPropertiesCache, _targetAddressInfoCache) = NetworkHelpers.GetLocalInterface(chosenInterface);
            }

            return (_targetPropertiesCache, _targetAddressInfoCache);
        }

        private void LocalInterfaceCacheHandler(object sender, EventArgs e)
        {
            Logger.Info?.Print(LogClass.ServiceNifm, "NetworkAddress changed, invalidating cached data.");

            _targetPropertiesCache = null;
            _targetAddressInfoCache = null;
        }

        protected override void Dispose(bool isDisposing)
        {
            if (isDisposing)
            {
                if (_watchHostNetwork)
                {
                    NetworkChange.NetworkAddressChanged -= LocalInterfaceCacheHandler;
                }

                GeneralServiceManager.Remove(_generalServiceDetail.ClientId);
            }
        }
    }
}
