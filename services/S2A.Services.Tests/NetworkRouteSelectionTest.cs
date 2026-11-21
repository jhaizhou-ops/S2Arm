using Ryujinx.Common.Utilities;
using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator;
using System;
using System.Net;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--network-route-selection")]
        private static int NetworkRouteSelection()
        {
            var local = NetworkHelpers.GetLocalInterfaceForTarget("0", IPAddress.Loopback);
            bool loopbackSelected = local.address?.Address.Equals(IPAddress.Loopback) == true;
            var fallback = NetworkHelpers.GetLocalInterfaceForTarget("interface-that-does-not-exist", IPAddress.Loopback);
            bool fallbackSelected = fallback.address?.Address.Equals(IPAddress.Loopback) == true;

            // Negative control: the old enumeration-order API deliberately skips loopback, so it
            // cannot satisfy this target-based contract even when the new API does.
            var legacy = NetworkHelpers.GetLocalInterface("0");
            bool legacyWouldMissLoopback = legacy.Item2 == null || !legacy.Item2.Address.Equals(IPAddress.Loopback);

            Console.WriteLine(
                $"network-route-selection: loopback={local.address?.Address}, fallback={fallback.address?.Address}, " +
                $"legacy={legacy.Item2?.Address}, checks={loopbackSelected}/{fallbackSelected}/{legacyWouldMissLoopback}");
            return loopbackSelected && fallbackSelected && legacyWouldMissLoopback ? 0 : 1;
        }

        [SoloTest("--ldn-auto-mode-selection")]
        private static int LdnAutoModeSelection()
        {
            string oldAuto = Environment.GetEnvironmentVariable("S2A_LDN_AUTO");
            string oldMitm = Environment.GetEnvironmentVariable("S2A_LDN_MITM");
            string oldServer = Environment.GetEnvironmentVariable("S2A_LDN_SERVER");

            try
            {
                // The settings page defaults to auto, so an untouched environment must select
                // auto too; explicit relay / forced-switch modes still win.
                Environment.SetEnvironmentVariable("S2A_LDN_AUTO", null);
                Environment.SetEnvironmentVariable("S2A_LDN_MITM", null);
                Environment.SetEnvironmentVariable("S2A_LDN_SERVER", null);
                int probeCalls = 0;
                MultiplayerMode defaultNoProvider = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.Disabled,
                    () => { probeCalls++; return false; });

                Environment.SetEnvironmentVariable("S2A_LDN_AUTO", "1");
                Environment.SetEnvironmentVariable("S2A_LDN_MITM", "0");

                MultiplayerMode noProvider = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.Disabled,
                    () => { probeCalls++; return false; });
                MultiplayerMode providerNoSwitch = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.LdnRyu,
                    () => { probeCalls++; return false; });
                MultiplayerMode providerSwitch = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.LdnRyu,
                    () => { probeCalls++; return true; });

                Environment.SetEnvironmentVariable("S2A_LDN_MITM", "1");
                MultiplayerMode forced = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.Disabled,
                    () => { probeCalls++; return false; });

                Environment.SetEnvironmentVariable("S2A_LDN_AUTO", "0");
                Environment.SetEnvironmentVariable("S2A_LDN_MITM", "0");
                MultiplayerMode disabled = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.Disabled,
                    () => { probeCalls++; return false; });

                Environment.SetEnvironmentVariable("S2A_LDN_AUTO", null);
                Environment.SetEnvironmentVariable("S2A_LDN_SERVER", "10.0.0.5");
                MultiplayerMode explicitServer = IUserLocalCommunicationService.SelectAutoMode(
                    MultiplayerMode.Disabled,
                    () => { probeCalls++; return false; });

                bool passed = defaultNoProvider == MultiplayerMode.LdnMitm &&
                              noProvider == MultiplayerMode.LdnMitm &&
                              providerNoSwitch == MultiplayerMode.LdnRyu &&
                              providerSwitch == MultiplayerMode.LdnMitm &&
                              forced == MultiplayerMode.Disabled &&
                              disabled == MultiplayerMode.Disabled &&
                              explicitServer == MultiplayerMode.Disabled &&
                              probeCalls == 2;

                Console.WriteLine(
                    $"ldn-auto-mode-selection: defaultNoProvider={defaultNoProvider}, noProvider={noProvider}, providerNoSwitch={providerNoSwitch}, " +
                    $"providerSwitch={providerSwitch}, forced={forced}, disabled={disabled}, probeCalls={probeCalls}");
                return passed ? 0 : 1;
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_LDN_AUTO", oldAuto);
                Environment.SetEnvironmentVariable("S2A_LDN_MITM", oldMitm);
                Environment.SetEnvironmentVariable("S2A_LDN_SERVER", oldServer);
            }
        }
    }
}
