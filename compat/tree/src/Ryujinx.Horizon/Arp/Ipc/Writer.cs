using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Arp;
using Ryujinx.Horizon.Sdk.Arp.Detail;
using Ryujinx.Horizon.Sdk.OsTypes;
using Ryujinx.Horizon.Sdk.Sf;

namespace Ryujinx.Horizon.Arp.Ipc
{
    partial class Writer : IWriter, IServiceObject
    {
        private readonly ApplicationInstanceManager _applicationInstanceManager;

        public Writer(ApplicationInstanceManager applicationInstanceManager)
        {
            _applicationInstanceManager = applicationInstanceManager;
        }

        [CmifCommand(0)]
        public Result AcquireRegistrar(out IRegistrar registrar)
        {
            lock (_applicationInstanceManager.Entries)
            {
                for (int i = 0; i < _applicationInstanceManager.Entries.Length; i++)
                {
                    if (_applicationInstanceManager.Entries[i] == null)
                    {
                        ApplicationInstance instance = new();
                        _applicationInstanceManager.Entries[i] = instance;
                        registrar = new Registrar(_applicationInstanceManager, (ulong)i, instance);
                        return Result.Success;
                    }
                }
                registrar = null;
                return ArpResult.NoFreeInstance;
            }
        }

        [CmifCommand(1)]
        public Result UnregisterApplicationInstance(ulong applicationInstanceId)
        {
            lock (_applicationInstanceManager.Entries)
            {
                if (applicationInstanceId >= (ulong)_applicationInstanceManager.Entries.Length)
                    return ArpResult.InvalidInstanceId;
                _applicationInstanceManager.Entries[applicationInstanceId] = null;
            }

            Os.SignalSystemEvent(ref _applicationInstanceManager.SystemEvent);

            return Result.Success;
        }

        [CmifCommand(2)]
        public Result AcquireApplicationProcessPropertyUpdater(out IUpdater updater, ulong applicationInstanceId)
        {
            updater = new Updater(_applicationInstanceManager, applicationInstanceId, false);

            return Result.Success;
        }

        [CmifCommand(3)]
        public Result AcquireApplicationCertificateUpdater(out IUpdater updater, ulong applicationInstanceId)
        {
            updater = new Updater(_applicationInstanceManager, applicationInstanceId, true);

            return Result.Success;
        }
    }
}
