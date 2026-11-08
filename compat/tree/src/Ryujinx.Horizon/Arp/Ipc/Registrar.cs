using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Arp;
using Ryujinx.Horizon.Sdk.Arp.Detail;
using Ryujinx.Horizon.Sdk.Ns;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;

namespace Ryujinx.Horizon.Arp.Ipc
{
    partial class Registrar : IRegistrar, IServiceObject
    {
        private readonly ApplicationInstance _applicationInstance;
        private readonly ApplicationInstanceManager _manager;
        private readonly ulong _instanceId;

        public Registrar(ApplicationInstanceManager manager, ulong instanceId, ApplicationInstance applicationInstance)
        {
            _manager = manager;
            _instanceId = instanceId;
            _applicationInstance = applicationInstance;
        }

        [CmifCommand(0)]
        public Result Issue(out ulong applicationInstanceId)
        {
            lock (_manager.Entries)
            {
                applicationInstanceId = 0;
                if (_instanceId >= (ulong)_manager.Entries.Length ||
                    !ReferenceEquals(_manager.Entries[_instanceId], _applicationInstance))
                    return ArpResult.InvalidInstanceId;
                applicationInstanceId = _instanceId;
                return Result.Success;
            }
        }

        [CmifCommand(1)]
        public Result SetApplicationLaunchProperty(ApplicationLaunchProperty applicationLaunchProperty)
        {
            if (_applicationInstance.LaunchProperty != null)
            {
                return ArpResult.DataAlreadyBound;
            }

            _applicationInstance.LaunchProperty = applicationLaunchProperty;

            return Result.Success;
        }

        [CmifCommand(2)]
        public Result SetApplicationControlProperty([Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias | HipcBufferFlags.FixedSize, 0x4000)] in ApplicationControlProperty applicationControlProperty)
        {
            if (_applicationInstance.ControlProperty != null)
            {
                return ArpResult.DataAlreadyBound;
            }

            _applicationInstance.ControlProperty = applicationControlProperty;

            return Result.Success;
        }
    }
}
