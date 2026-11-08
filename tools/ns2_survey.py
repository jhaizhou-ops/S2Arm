#!/usr/bin/env python3
"""ns2_survey.py：新 Switch 2 游戏的系统服务 / 系统调用缺口普查（静态，不起局、不要真机）。

  python3 tools/ns2_survey.py <解包目录或其 exefs/> [--out <目录>] [--src <compat/tree/src>] [--eden <外部对照表.tsv>]

输入：解包产物的 exefs（main、subsdk*、sdk、main.npdm）。输出 <目录>/ns2_survey.tsv（游戏 sdk 能发出的每条命令一行：
服务 / 接口 / 命令号 / SDK 名 / 游戏可达 / 我方 / 优先级 [/ Eden]）和 <目录>/ns2_survey.md（可达且未实现的命令、未实现的系统调用、
我方没注册的服务、映射表要补的接口、射程）。缺省输出到当前目录。

做法与射程见 docs/研究/Switch2新游戏系统库普查.md。要点：
  1. main.npdm 的 ACI0：许可的服务（SAC）与系统调用（KAC）。
  2. sdk 里每个 CmifProxy 客户端代理的虚表：槽 → 命令号（代理方法体里最后一次调用前写给 w1..w7 的立即数；参数多时命令号经栈传 [sp,#k]，取最高栈位）。
  3. 以 main / subsdk* 导入的 sdk 函数（+ sdk 自己的初始化入口）为根，沿 bl / b（含 PLT 跳板）求静态可达；可达函数里的虚调用
     （ldr vt,[obj]; ldr f,[vt,#off]; blr f）按槽偏移 → 命令号（命令 = 代理虚表[off/8 − 4]），候选接口限调用者命名空间；
     多候选用调用者函数名对命令名（我方方法名，给了 --eden 再加 Eden 名）消歧，仍多候选记「槽位歧义」。
  4. 我方命令表从 compat/tree/src 现抽（Ryujinx.HLE 的 [CommandCmif] / [CommandTipc]、Ryujinx.Horizon 的 [CmifCommand]），
     SDK 接口 → 服务 / 我方类走本文件的 MAP 表；系统调用对 Syscall.cs 的 [Svc(n)]。
--eden：外部 TSV「SDK 接口<TAB>命令号<TAB>实|空<TAB>命令名」（Eden 是 GPL 项目，表不进仓库，按需自备）；给了才多出 Eden 列。
依赖 capstone、lz4（tools/rewriter-requirements.txt），c++filt。只读输入，不写游戏数据。
"""
import argparse
import bisect
import collections
import os
import re
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nso_sym  # noqa: E402  NSO0 解段（LZ4 / ZBIC 同一份）

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

# SDK 接口 → (服务名, 我方 [(文件尾, 类)])；我方列表空 = 我方没有这个接口。新游戏出现表里没有的接口，md 的「映射表要补」一节会列出来。
MAP = {
    'nn::am::service::IApplicationProxyService': ('appletOE', [('IApplicationProxyService.cs', 'IApplicationProxyService')]),
    'nn::am::service::IApplicationProxy': ('appletOE', [('IApplicationProxy.cs', 'IApplicationProxy')]),
    'nn::am::service::ICommonStateGetter': ('appletOE', [('ICommonStateGetter.cs', 'ICommonStateGetter')]),
    'nn::am::service::ISelfController': ('appletOE', [('ISelfController.cs', 'ISelfController')]),
    'nn::am::service::IWindowController': ('appletOE', [('IWindowController.cs', 'IWindowController')]),
    'nn::am::service::IAudioController': ('appletOE', [('IAudioController.cs', 'IAudioController')]),
    'nn::am::service::IDisplayController': ('appletOE', [('IDisplayController.cs', 'IDisplayController')]),
    'nn::am::service::IDebugFunctions': ('appletOE', []),
    'nn::am::service::ILibraryAppletCreator': ('appletOE', [('ILibraryAppletCreator.cs', 'ILibraryAppletCreator')]),
    'nn::am::service::ILibraryAppletAccessor': ('appletOE', [('ILibraryAppletAccessor.cs', 'ILibraryAppletAccessor')]),
    'nn::am::service::IApplicationFunctions': ('appletOE', [('IApplicationFunctions.cs', 'IApplicationFunctions')]),
    'nn::am::service::IPerformanceFunctions': ('appletOE', [('IPerformanceFunctions.cs', 'IPerformanceFunctions')]),
    'nn::am::service::IGraphicsScalingParametersFunctions': ('appletOE', [('IGraphicsScalingParametersFunctions.cs', 'IGraphicsScalingParametersFunctions')]),
    'nn::am::service::IStorage': ('appletOE', [('Am/AppletAE/IStorage.cs', 'IStorage')]),
    'nn::am::service::IStorageAccessor': ('appletOE', [('IStorageAccessor.cs', 'IStorageAccessor')]),
    'nn::am::service::ITransferStorageAccessor': ('appletOE', []),
    'nn::am::service::ILockAccessor': ('appletOE', []),
    'nn::am::service::IProcessWindingController': ('appletOE', [('IProcessWindingController.cs', 'IProcessWindingController')]),
    'nn::account::IAccountServiceForApplication': ('acc:u0', [('IAccountServiceForApplication.cs', 'IAccountServiceForApplication')]),
    'nn::account::baas::IManagerForApplication': ('acc:u0', [('IManagerForApplication.cs', 'IManagerForApplication')]),
    'nn::account::profile::IProfile': ('acc:u0', [('AccountService/IProfile.cs', 'IProfile')]),
    'nn::account::detail::IAsyncContext': ('acc:u0', [('Acc/IAsyncContext.cs', 'IAsyncContext')]),
    'nn::account::detail::ISessionObject': ('acc:u0', []),
    'nn::account::detail::INotifier': ('acc:u0', []),
    'nn::account::baas::IAsyncContextForLoginForOnlinePlay': ('acc:u0', []),
    'nn::aocsrv::detail::IAddOnContentManager': ('aoc:u', [('IAddOnContentManager.cs', 'IAddOnContentManager')]),
    'nn::ec::IPurchaseEventManager': ('aoc:u', [('IPurchaseEventManager.cs', 'IPurchaseEventManager')]),
    'nn::ec::IContentsServiceManager': ('aoc:u', []),
    'nn::ec::detail::IAsyncData': ('aoc:u', []),
    'nn::audio::IUserClientSession': ('aud:u', [('NativeAudioManager.cs', 'NativeAudioManager')]),
    'nn::audio::detail::IAudioRendererManager': ('aud:u', [('AudioRendererManager.cs', 'AudioRendererManager')]),
    'nn::audio::detail::IAudioRenderer': ('aud:u', [('AudioRenderer.cs', 'AudioRenderer')]),
    'nn::audio::detail::IAudioDevice': ('aud:u', [('AudioDevice.cs', 'AudioDevice')]),
    'nn::audio::detail::IAudioOutManager': ('aud:u', [('AudioOutManager.cs', 'AudioOutManager')]),
    'nn::audio::detail::IAudioOut': ('aud:u', [('AudioOut.cs', 'AudioOut')]),
    'nn::audio::detail::IAudioInManager': ('aud:u', [('AudioInManager.cs', 'AudioInManager')]),
    'nn::audio::detail::IAudioIn': ('aud:u', [('AudioIn.cs', 'AudioIn')]),
    'nn::audio::devmgr::IUserSessionManager': ('auddmg:u', [('AudioDeviceManager.cs', 'AudioDeviceManagerUserSessionManager')]),
    'nn::audio::devmgr::IUserSession': ('auddmg:u', [('AudioDeviceManager.cs', 'AudioDeviceManagerUserSession')]),
    'nn::audio::sysmix::IUserSessionManager': ('audsmx:u', [('AudioSystemMixer.cs', 'AudioSystemMixerUserSessionManager')]),
    'nn::audio::sysmix::IUserSession': ('audsmx:u', [('AudioSystemMixer.cs', 'AudioSystemMixerUserSession')]),
    'nn::audio::sysmix::IExternalStreamSession': ('audsmx:u', [('AudioSystemMixer.cs', 'AudioSystemMixerExternalStreamSession')]),
    'nn::bcat::ipc::IServiceCreator': ('bcat:u', [('Bcat/Ipc/ServiceCreator.cs', 'ServiceCreator')]),
    'nn::bcat::ipc::IBcatService': ('bcat:u', [('BcatService.cs', 'BcatService')]),
    'nn::bcat::ipc::IDeliveryCacheStorageService': ('bcat:u', [('DeliveryCacheStorageService.cs', 'DeliveryCacheStorageService')]),
    'nn::bcat::ipc::IDeliveryCacheFileService': ('bcat:u', [('DeliveryCacheFileService.cs', 'DeliveryCacheFileService')]),
    'nn::bcat::ipc::IDeliveryCacheDirectoryService': ('bcat:u', [('DeliveryCacheDirectoryService.cs', 'DeliveryCacheDirectoryService')]),
    'nn::bcat::ipc::IDeliveryCacheProgressService': ('bcat:u', [('DeliveryCacheProgressService.cs', 'DeliveryCacheProgressService')]),
    'nn::bcat::ipc::INotifierService': ('bcat:u', []),
    'nn::bcat::ipc::IDeliveryTaskSuspensionService': ('bcat:u', []),
    'nn::socket::sf::IClient': ('bsd:u', [('Bsd/IClient.cs', 'IClient')]),
    'nn::capsrv::sf::IScreenShotApplicationService': ('caps:su', [('IScreenShotApplicationService.cs', 'IScreenShotApplicationService')]),
    'nn::capsrv::sf::IAlbumApplicationService': ('caps:u', [('IAlbumApplicationService.cs', 'IAlbumApplicationService')]),
    'nn::capsrv::sf::IAlbumAccessorApplicationSession': ('caps:u', []),
    'nn::chat::IUserService': ('chat:u', [('Chat/IUserService.cs', 'IUserService')]),
    'nn::chat::IUserShimScopedObject': ('chat:u', [('Chat/IUserService.cs', 'IUserShimScopedObject')]),
    'nn::chat::IVirtualCameraShimScopedObject': ('chat:u', []),
    'nn::chat::IUserLayoutCustomizationShimScopedObject': ('chat:u', []),
    'nn::chat::IUserSelectiveTalkShimScopedObject': ('chat:u', []),
    'nn::spl::detail::IRandomInterface': ('csrng', [('IRandomInterface.cs', 'IRandomInterface')]),
    'nn::err::context::IWriterForApplication': ('ectx:aw', [('IWriterForApplication.cs', 'IWriterForApplication')]),
    'nn::err::context::IContextRegistrar': ('ectx:aw', [('IContextRegistrar.cs', 'IContextRegistrar')]),
    'nn::friends::detail::ipc::IServiceCreator': ('friend:u', [('Friends/Detail/Ipc/ServiceCreator.cs', 'ServiceCreator')]),
    'nn::friends::detail::ipc::IFriendService': ('friend:u', [('FriendService.cs', 'FriendService')]),
    'nn::friends::detail::ipc::INotificationService': ('friend:u', [('Friends/Detail/Ipc/NotificationService.cs', 'NotificationService')]),
    'nn::fssrv::sf::IFileSystemProxy': ('fsp-srv', [('Fs/IFileSystemProxy.cs', 'IFileSystemProxy')]),
    'nn::fssrv::sf::IFileSystem': ('fsp-srv', [('IFileSystem.cs', 'IFileSystem')]),
    'nn::fssrv::sf::IFile': ('fsp-srv', [('FileSystemProxy/IFile.cs', 'IFile')]),
    'nn::fssrv::sf::IDirectory': ('fsp-srv', [('IDirectory.cs', 'IDirectory')]),
    'nn::fssrv::sf::IStorage': ('fsp-srv', [('FileSystemProxy/IStorage.cs', 'IStorage')]),
    'nn::fssrv::sf::ISaveDataInfoReader': ('fsp-srv', [('ISaveDataInfoReader.cs', 'ISaveDataInfoReader')]),
    'nn::fssrv::sf::IMultiCommitManager': ('fsp-srv', []),
    'nn::fssrv::sf::IDeviceOperator': ('fsp-srv', [('IDeviceOperator.cs', 'IDeviceOperator')]),
    'nn::fssrv::sf::IEventNotifier': ('fsp-srv', []),
    'nn::hid::IHidServer': ('hid', [('IHidServer.cs', 'IHidServer')]),
    'nn::hid::IAppletResource': ('hid', [('IAppletResource.cs', 'IAppletResource')]),
    'nn::hid::IActiveVibrationDeviceList': ('hid', [('IActiveVibrationDeviceList.cs', 'IActiveApplicationDeviceList')]),
    'nn::tma::IHtcManager': ('htc', []),
    'nn::tma::IHtcsManager': ('htcs', []),
    'nn::tma::ISocket': ('htcs', []),
    'nn::htc::tenv::IServiceManager': ('htc:tenv', []),
    'nn::htc::tenv::IService': ('htc:tenv', []),
    'nn::codec::detail::IHardwareOpusDecoderManager': ('hwopus', [('HardwareOpusDecoderManager.cs', 'HardwareOpusDecoderManager')]),
    'nn::codec::detail::IHardwareOpusDecoder': ('hwopus', [('Codec/Detail/HardwareOpusDecoder.cs', 'NativeDecoder')]),
    'nn::imf::IClientService': ('imf', []),
    'nn::imf::ISession': ('imf', []),
    'nn::irsensor::IIrSensorServer': ('irs', [('IIrSensorServer.cs', 'IIrSensorServer')]),
    'nn::ldn::detail::IUserServiceCreator': ('ldn:u', [('IUserServiceCreator.cs', 'IUserServiceCreator')]),
    'nn::ldn::detail::IUserLocalCommunicationService': ('ldn:u', [('IUserLocalCommunicationService.cs', 'IUserLocalCommunicationService')]),
    'nn::ldn::detail::IClientProcessMonitor': ('ldn:u', [('IClientProcessMonitor.cs', 'IClientProcessMonitor')]),
    'nn::ro::detail::IRoInterface': ('ldr:ro', [('Ro/IRoInterface.cs', 'IRoInterface')]),
    'nn::lm::ILogService': ('lm', [('LogManager/Ipc/LogService.cs', 'LogService')]),
    'nn::lm::ILogger': ('lm', [('LogManager/Ipc/LmLogger.cs', 'LmLogger')]),
    'nn::mii::detail::IStaticService': ('mii:u', [('Mii/IStaticService.cs', 'IStaticService')]),
    'nn::mii::detail::IDatabaseService': ('mii:u', [('IDatabaseService.cs', 'IDatabaseService')]),
    'nn::nfc::detail::IUserManager': ('nfc:user', [('Nfc/IUserManager.cs', 'IUserManager')]),
    'nn::nfc::detail::IUser': ('nfc:user', [('NfcManager/INfc.cs', 'INfc')]),
    'nn::nfp::detail::IUserManager': ('nfp:user', [('Nfp/IUserManager.cs', 'IUserManager')]),
    'nn::nfp::detail::IUser': ('nfp:user', [('NfpManager/INfp.cs', 'INfp')]),
    'nn::ngc::detail::IService': ('ngc:u', [('Ngc/Ipc/Service.cs', 'Service')]),
    'nn::nifm::detail::IStaticService': ('nifm:u', [('Nifm/IStaticService.cs', 'IStaticService')]),
    'nn::nifm::detail::IGeneralService': ('nifm:u', [('IGeneralService.cs', 'IGeneralService')]),
    'nn::nifm::detail::IRequest': ('nifm:u', [('Nifm/StaticService/IRequest.cs', 'IRequest')]),
    'nn::nifm::detail::IScanRequest': ('nifm:u', []),
    'nn::nifm::detail::INetworkProfile': ('nifm:u', []),
    'nn::nim::detail::IShopServiceAccessServerInterface': ('nim:eca', [('IShopServiceAccessServerInterface.cs', 'IShopServiceAccessServerInterface')]),
    'nn::nim::detail::IShopServiceAccessServer': ('nim:eca', [('IShopServiceAccessServer.cs', 'IShopServiceAccessServer')]),
    'nn::nim::detail::IShopServiceAccessor': ('nim:eca', [('IShopServiceAccessor.cs', 'IShopServiceAccessor')]),
    'nn::nim::detail::IShopServiceAsync': ('nim:eca', []),
    'nn::notification::server::INotificationServicesForApplication': ('notif:a', [('INotificationServicesForApplication.cs', 'INotificationServicesForApplication')]),
    'nn::nsd::detail::IManager': ('nsd:u', [('Nsd/IManager.cs', 'IManager')]),
    'nn::ntc::detail::service::IStaticService': ('ntc', [('Ntc/IStaticService.cs', 'IStaticService')]),
    'nn::ntc::detail::service::IEnsureNetworkClockAvailabilityService': ('ntc', [('IEnsureNetworkClockAvailabilityService.cs', 'IEnsureNetworkClockAvailabilityService')]),
    'nn::pctl::detail::ipc::IParentalControlServiceFactory': ('pctl', [('IParentalControlServiceFactory.cs', 'IParentalControlServiceFactory')]),
    'nn::pctl::detail::ipc::IParentalControlService': ('pctl', [('IParentalControlService.cs', 'IParentalControlService')]),
    'nn::pl::sharedresource::detail::IPlatformSharedResourceManager': ('pl:u', [('Pl/ISharedFontManager.cs', 'ISharedFontManager')]),
    'nn::pl::sharedresource::detail::IFontService': ('pl:u', [('Pl/IFontService.cs', 'IFontService')]),
    'nn::prepo::detail::ipc::IPrepoService': ('prepo:u', [('Prepo/Ipc/PrepoService.cs', 'PrepoService')]),
    'nn::prepo::detail::ipc::IAsyncContext': ('prepo:u', [('Prepo/Ipc/AsyncContext.cs', 'AsyncContext')]),
    'nn::settings::ISettingsServer': ('set', [('ISettingsServer.cs', 'ISettingsServer')]),
    'nn::socket::resolver::IResolver': ('sfdnsres', [('Sfdnsres/IResolver.cs', 'IResolver')]),
    'nn::ssl::sf::ISslService': ('ssl', [('Ssl/ISslService.cs', 'ISslService')]),
    'nn::ssl::sf::ISslContext': ('ssl', [('SslService/ISslContext.cs', 'ISslContext')]),
    'nn::ssl::sf::ISslConnection': ('ssl', [('SslService/ISslConnection.cs', 'ISslConnection')]),
    'nn::streamplay::IUserService': ('stpl:u', [('StreamPlay/IUserService.cs', 'IUserService')]),
    'nn::streamplay::IUserShimScopedObject': ('stpl:u', [('StreamPlay/IUserService.cs', 'IUserShimScopedObject')]),
    'nn::timesrv::detail::service::IStaticService': ('time:u', [('IStaticServiceForGlue.cs', 'IStaticServiceForGlue')]),
    'nn::timesrv::detail::service::ISystemClock': ('time:u', [('StaticService/ISystemClock.cs', 'ISystemClock')]),
    'nn::timesrv::detail::service::ISteadyClock': ('time:u', [('StaticService/ISteadyClock.cs', 'ISteadyClock')]),
    'nn::timesrv::detail::service::ITimeZoneService': ('time:u', [('ITimeZoneServiceForGlue.cs', 'ITimeZoneServiceForGlue')]),
}

# 调用者命名空间（nn::<这里>::…）→ 它能调到的接口命名空间；表里没有的按同名
ALIAS = {'oe': ['am'], 'applet': ['am'], 'ae': ['am'], 'fs': ['fssrv'], 'time': ['timesrv'], 'aoc': ['aocsrv', 'ec'], 'diag': ['lm'],
         'hid': ['hid', 'irsensor'], 'album': ['capsrv'], 'os': ['spl'], 'crypto': ['spl']}

CLOBBER_KEEP = ('str', 'stp', 'stur', 'cmp', 'tst', 'cbz', 'cbnz', 'tbz', 'tbnz', 'strb', 'strh', 'sturb', 'blr', 'br')


# ---------- 模块映像 ----------
def symbols(img, tags):
    """全部动态符号 [(名, 已定义?, 地址, 长度)]（含导入）。"""
    symtab, strtab = tags[6], tags[5]
    out = []
    for i in range((strtab - symtab) // 24):
        name, _, _, shndx, value, size = struct.unpack_from('<IBBHQQ', img, symtab + i * 24)
        out.append((img[strtab + name:img.index(b'\0', strtab + name)].decode('latin1'), shndx != 0, value, size))
    return out


def relocs(img, tags, syms):
    """重定位后的指针：地址 → 值（已定义符号 / 相对）或 ('IMP', 名)。RELA、JMPREL、RELR 三种。"""
    r = {}
    for off_t, sz_t in ((7, 8), (0x17, 2)):
        if off_t not in tags:
            continue
        base, sz = tags[off_t], tags[sz_t]
        for k in range(0, sz, 24):
            off, info, add = struct.unpack_from('<QQq', img, base + k)
            typ, si = info & 0xffffffff, info >> 32
            if typ == 0x403:
                r[off] = add
            elif typ in (0x101, 0x401, 0x402):
                s = syms[si]
                r[off] = (s[2] + add) if s[1] else ('IMP', s[0])
    if 0x24 in tags:
        base, sz, where = tags[0x24], tags[0x23], 0
        for k in range(0, sz, 8):
            e = struct.unpack_from('<Q', img, base + k)[0]
            if e & 1 == 0:
                where = e
                r[where] = struct.unpack_from('<Q', img, where)[0]
                where += 8
            else:
                for j in range(63):
                    if (e >> 1) >> j & 1:
                        a = where + j * 8
                        r[a] = struct.unpack_from('<Q', img, a)[0]
                where += 63 * 8
    return r


class Module:
    def __init__(self, img):
        self.img = img
        self.tags = nso_sym.dynamic(img)
        self.syms = symbols(img, self.tags)
        self._rel = None

    @property
    def rel(self):
        if self._rel is None:
            self._rel = relocs(self.img, self.tags, self.syms)
        return self._rel

    def imports(self):
        return {n for n, d, _, _ in self.syms if not d and n}


def demangle(names):
    names = list(names)
    if not names:
        return {}
    p = subprocess.run(['c++filt'], input='\n'.join(names), capture_output=True, text=True, check=True)
    return dict(zip(names, p.stdout.split('\n')))


_MD = None


def disasm(img, a, n):
    global _MD
    if _MD is None:
        from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
        _MD = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    return _MD.disasm(img[a:a + n], a)


# ---------- 代理虚表：槽 → 命令号 ----------
def cmd_of(img, a, maxn=300, depth=0):
    """代理方法 → 命令号：最后一次 bl / 尾跳之前、自上次调用以来立即数写给 w1..w7 中最高号寄存器的值；参数多于寄存器时命令号经栈传
    （立即数存到 [sp,#k]），取最高栈位，优先于寄存器；movk 拼高半字；纯转发（b 到另一方法）跟进一层。"""
    val, snap, best, last = {}, {}, None, None
    for ins in disasm(img, a, maxn * 4):
        m, o = ins.mnemonic, ins.op_str
        mm = re.match(r'[wx](\d+), (?:#(0x[0-9a-f]+|\d+)|[wx]zr)$', o) if m in ('mov', 'movz', 'orr') else None
        mk = re.match(r'[wx](\d+), #(0x[0-9a-f]+|\d+), lsl #(\d+)$', o) if m == 'movk' else None
        ms = re.match(r'w(\d+), \[sp(?:, #(0x[0-9a-f]+|\d+))?\]$', o) if m == 'str' else None
        if mm:
            r = int(mm.group(1))
            val[r] = int(mm.group(2), 0) if mm.group(2) else 0
            if 1 <= r <= 7:
                snap[r] = val[r]
        elif mk and int(mk.group(1)) in val:
            r, sh = int(mk.group(1)), int(mk.group(3))
            val[r] = (val[r] & ~(0xffff << sh)) | (int(mk.group(2), 0) << sh)
            if 1 <= r <= 7:
                snap[r] = val[r]
        elif ms and int(ms.group(1)) in val:
            snap[100 + (int(ms.group(2), 0) if ms.group(2) else 0)] = val[int(ms.group(1))]
        else:
            mr = re.match(r'[wx](\d+),', o)
            if mr and m not in CLOBBER_KEEP:
                r = int(mr.group(1))
                val.pop(r, None)
                snap.pop(r, None)
        if m == 'bl':
            last = int(o.lstrip('#'), 0)
        if m in ('bl', 'b'):
            if snap:
                best = snap[max(snap)]
            elif m == 'b' and best is None and depth < 2:
                return cmd_of(img, int(o.lstrip('#'), 0), maxn, depth + 1)
            snap, val = {}, {}
            if m == 'b':
                break
        if m in ('ret', 'retab', 'retaa', 'br'):
            break
    if best is None and last is not None and depth < 2:
        return cmd_of(img, last, maxn, depth + 1)
    return best


def is_thunk(img, a):
    ins = list(disasm(img, a, 8))
    return len(ins) == 2 and ins[1].mnemonic == 'ret' and ins[0].mnemonic in ('add', 'sub')


def _cstr(img, a):
    return img[a:img.index(b'\0', a)].decode('latin1')


def proxies(mod):
    """sdk 映像里的 CmifProxy 客户端代理：接口名 → [各接口槽的命令号]（下标 = 槽序，None = 没解出）。
    两路取并集：RTTI（typeinfo 名含 CmifProxy、偏移到顶 = 0 的主虚表）为主，导出的 ObjectImplFactory 虚表符号补缺。"""
    img, R = mod.img, mod.rel
    found = []   # (第一个虚函数槽地址, 改编名, 先跳过几槽, 槽数上限)
    tinames = {}
    for L, T in R.items():
        if not isinstance(T, int) or T + 16 > len(img):
            continue
        if T not in tinames:
            n, s = R.get(T + 8), None
            if isinstance(n, int) and n < len(img):
                try:
                    s = _cstr(img, n)
                except ValueError:
                    s = None
            tinames[T] = s if s and 'CmifProxy' in s and s.startswith('N') else None
        if tinames[T] and R.get(L - 8) is None and L >= 8 and struct.unpack_from('<q', img, L - 8)[0] == 0:
            found.append((L + 8, '_ZTS' + tinames[T], 4, 600))   # 前 4 槽：析构 ×2、引用计数 ×2
    for n, d, v, sz in mod.syms:
        if d and n.startswith('_ZTV') and 'ObjectImplFactory' in n and 'CmifProxy' in n:
            found.append((v + 16, n, 4, sz // 8 - 2))            # 符号虚表 = 偏移到顶 + typeinfo + 槽，长度按符号
    dm = demangle({f[1] for f in found})
    rtti, by_sym = {}, {}
    for va, name, skip, lim in found:
        mi = re.search(r'CmifProxy(?:Impl)?<([\w:]+),', dm.get(name, ''))
        if not mi:
            continue
        cmds, i = [], skip
        while i < lim:
            a = R.get(va + 8 * i)
            if not isinstance(a, int) or is_thunk(img, a):
                break
            cmds.append(cmd_of(img, a))
            i += 1
        tab = rtti if name.startswith('_ZTS') else by_sym
        if mi.group(1) not in tab or len(cmds) > len(tab[mi.group(1)]):
            tab[mi.group(1)] = cmds
    for k, v in by_sym.items():
        rtti.setdefault(k, v)
    return rtti


# ---------- sdk 函数扫描：直接调用边、虚调用槽、svc ----------
def scan_functions(mod):
    """每个导出函数一次反汇编：{起址: (名, 长, {调用目标函数起址}, [虚调用槽偏移])}。"""
    img, R = mod.img, mod.rel
    funcs = {}
    for f in sorted({(a, sz, n) for n, d, a, sz in mod.syms if d and sz > 0 and a < len(img)}):
        funcs[f[0]] = f            # 同起址多个符号：取最长的那个（与按起址二分查到的同一个）
    funcs = sorted(funcs.values())
    starts = [f[0] for f in funcs]

    def fn_at(a):
        i = bisect.bisect_right(starts, a) - 1
        return funcs[i] if i >= 0 and a < funcs[i][0] + funcs[i][1] else None

    def plt(a):   # adrp x16 / ldr x17,[x16,#k] / … / br x17 → GOT 里的已定义目标
        ins = list(disasm(img, a, 16))
        if len(ins) >= 2 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic == 'ldr' and any(x.mnemonic.startswith('br') for x in ins[2:]):
            try:
                v = R.get(int(ins[0].op_str.split('#')[1], 0) + int(re.search(r'#(0x[0-9a-f]+|\d+)\]', ins[1].op_str).group(1), 0))
            except (IndexError, AttributeError, ValueError):
                return None
            return v if isinstance(v, int) else None
        return None

    out, plt_cache = {}, {}
    for a0, sz, n in funcs:
        calls, voffs = set(), []
        vt, slot = set(), {}
        for ins in disasm(img, a0, sz):
            m, o = ins.mnemonic, ins.op_str
            if m in ('bl', 'b') and o.startswith('#'):
                tgt = int(o[1:], 0)
                g = fn_at(tgt)
                if not g:
                    if tgt not in plt_cache:
                        p = plt(tgt)
                        plt_cache[tgt] = fn_at(p) if p is not None else None
                    g = plt_cache[tgt]
                if g:
                    calls.add(g[0])
            mm = re.match(r'x(\d+), \[x(\d+)(?:, #(0x[0-9a-f]+|\d+))?\]$', o) if m == 'ldr' else None
            if mm:
                d, b, off = int(mm.group(1)), int(mm.group(2)), int(mm.group(3), 0) if mm.group(3) else 0
                if b in vt:
                    slot[d] = off
                    vt.discard(d)
                elif off == 0:
                    vt.add(d)
                    slot.pop(d, None)
                else:
                    vt.discard(d)
                    slot.pop(d, None)
                continue
            if m.startswith('blr') or m.startswith('br'):
                r = re.match(r'x(\d+)', o)
                if r and int(r.group(1)) in slot:
                    voffs.append(slot[int(r.group(1))])
            mr = re.match(r'[wx](\d+),', o)
            if mr and m not in CLOBBER_KEEP:
                r = int(mr.group(1))
                vt.discard(r)
                slot.pop(r, None)
        out[a0] = (n, sz, calls, voffs)
    return out


def svc_in_code(img, text_size):
    """sdk 代码段里出现过的 svc 号（按指令字 0xD4000001 | 号 << 5 扫）。svc 包装是没导出的小函数、从导出函数静态追不全（时之笛上 SendSyncRequest 0x21
    都追不到），所以只报「sdk 有没有这条指令」，不报可达。"""
    out = set()
    for at in range(0, min(text_size, len(img)) - 3, 4):
        w = struct.unpack_from('<I', img, at)[0]
        if w & 0xFFE0001F == 0xD4000001 and (w >> 5) & 0xffff <= 0xff:
            out.add((w >> 5) & 0xffff)
    return out


def reach(mod, F, root_names):
    """从根函数名（导入 + sdk 初始化入口）沿直接调用求可达的函数起址集合。"""
    byname = {}
    for n, d, a, sz in mod.syms:   # 同起址的别名都认
        if d and sz > 0:
            byname.setdefault(n, a)
    roots = {byname[n] for n in root_names if byname.get(n) in F}
    roots |= {a for n, a in byname.items() if a in F and re.match(r'^(nninit|_ZN2nn4init|nnosInitialize|__nnDetailInit)', n)}
    R, t = mod.rel, mod.tags
    inits = [R.get(t[25] + 8 * k) for k in range(t.get(27, 0) // 8)] if 25 in t else []
    inits += [t[12]] if 12 in t else []
    roots |= {a for a in inits if isinstance(a, int) and a in F}
    seen, stack = set(), list(roots)
    while stack:
        a = stack.pop()
        if a in seen:
            continue
        seen.add(a)
        stack.extend(c for c in F[a][2] if c not in seen)
    return roots, seen


# ---------- 我方 ----------
CLS = re.compile(r'\b(?:class|interface)\s+(\w+)(?:\s*:\s*([\w\s,<>.]+?))?\s*(?:\{|where|\n)')
CMD = re.compile(r'\[(CommandCmif|CmifCommand|CommandTipc)\((0x[0-9a-fA-F]+|\d+)\)\][^\n]*\n(?:\s*(?://|\[)[^\n]*\n)*\s*public\s+[\w<>\[\],. ]+?\s(\w+)\s*\(')


def ours(src):
    """我方命令表：[(相对路径, 类, {命令号: 方法名})]；注册的服务名集合；实现的系统调用号集合。"""
    classes, services = [], set()
    for sub in ('Ryujinx.HLE/HOS/Services', 'Ryujinx.Horizon'):
        for dp, _, fn in os.walk(os.path.join(src, sub)):
            for f in fn:
                if not f.endswith('.cs'):
                    continue
                p = os.path.join(dp, f)
                s = open(p, encoding='utf-8', errors='replace').read()
                services |= set(re.findall(r'\[Service\("([^"]+)"', s)) | set(re.findall(r'ServiceName\.Encode\("([^"]+)"\)', s))
                pos = [(m.start(), m.group(1)) for m in CLS.finditer(s)]
                for k, (st, name) in enumerate(pos):
                    body = s[st:pos[k + 1][0] if k + 1 < len(pos) else len(s)]
                    cmds = {}
                    for m in CMD.finditer(body):
                        cmds.setdefault(int(m.group(2), 0), m.group(3))
                    for m in re.finditer(r'\[(?:CommandCmif|CmifCommand|CommandTipc)\((0x[0-9a-fA-F]+|\d+)\)\]', body):
                        cmds.setdefault(int(m.group(1), 0), '')
                    if cmds and not s[st:st + 12].startswith('interface'):
                        classes.append((os.path.relpath(p, src), name, cmds))
    sc = os.path.join(src, 'Ryujinx.HLE/HOS/Kernel/SupervisorCall/Syscall.cs')
    svcs = {int(x, 0) for x in re.findall(r'\[Svc\((0x[0-9a-fA-F]+|\d+)\)\]', open(sc, encoding='utf-8').read())} if os.path.exists(sc) else set()
    return classes, services, svcs


# ---------- NPDM ----------
def npdm(path):
    """main.npdm → (程序号, 许可的服务名列表, 许可的系统调用号集合)。"""
    d = open(path, 'rb').read()
    aci = struct.unpack_from('<I', d, 0x70)[0]
    if d[aci:aci + 4] != b'ACI0':
        sys.exit(f'{path}：0x70 处偏移指不到 ACI0')
    tid = struct.unpack_from('<Q', d, aci + 0x10)[0]
    off, size = struct.unpack_from('<II', d, aci + 0x28)
    b, i, sac = d[aci + off:aci + off + size], 0, []
    while i < len(b):
        n = (b[i] & 7) + 1
        if not b[i] & 0x80:            # 0x80 = 服务端（注册），应用只看客户端许可
            sac.append(b[i + 1:i + 1 + n].decode())
        i += 1 + n
    off, size = struct.unpack_from('<II', d, aci + 0x30)
    svc = set()
    for c in struct.unpack_from(f'<{size // 4}I', d, aci + off):
        if c & 0x1f == 0x0f:           # 低 5 位 01111 = 系统调用掩码：高 3 位是组号，每组 24 个
            svc |= {(c >> 29) * 24 + k for k in range((24)) if (c >> 5) >> k & 1}
    return tid, sac, svc


# ---------- 汇总 ----------
def norm(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())


def base(d):
    return d.split('(')[0].split('::')[-1]


def name_match(cmdname, caller_base):
    e, b = norm(cmdname), re.sub(r'^(impl|detail)', '', norm(caller_base))
    return bool(e) and min(len(e), len(b)) >= 5 and (e in b or b in e)


def survey(exefs, src, eden_path=None):
    tid, sac, svc_ok = npdm(os.path.join(exefs, 'main.npdm'))
    sdk = Module(nso_sym.load(os.path.join(exefs, 'sdk')))
    with open(os.path.join(exefs, 'sdk'), 'rb') as f:
        text_size = struct.unpack_from('<III', f.read(0x20), 0x10)[2]   # 段 0（代码段）：文件偏移、内存地址 0、长
    root_names = set()
    game_mods = sorted(n for n in os.listdir(exefs) if n == 'main' or re.fullmatch(r'subsdk\d+', n))
    for n in game_mods:
        root_names |= Module(nso_sym.load(os.path.join(exefs, n))).imports()
    PX = proxies(sdk)
    F = scan_functions(sdk)
    roots, reached = reach(sdk, F, root_names)
    classes, our_svcs, our_svc_calls = ours(src)
    eden = {}
    if eden_path:
        for line in open(eden_path, encoding='utf-8'):
            p = line.rstrip('\n').split('\t')
            if len(p) >= 4 and p[1].isdigit():
                eden[(p[0], int(p[1]))] = (p[2], p[3])

    sac_set = set(sac)
    ifaces = [i for i in PX if i in MAP and MAP[i][0] in sac_set]
    our_cmds, map_rot = {}, []
    for i in ifaces:
        got = {}
        for tail, cls in MAP[i][1]:
            hit = [c for p, n, c in classes if p.endswith(tail) and n == cls]
            if not hit:
                map_rot.append((i, tail, cls))
            for c in hit:
                got.update(c)
        our_cmds[i] = got

    def cmdname(i, c):
        return our_cmds.get(i, {}).get(c) or eden.get((i, c), ('', ''))[1]

    def cands(caller, off):
        if not caller.startswith('nn::') or off < 0x20:
            return []
        ns = ALIAS.get(caller.split('::')[1], [caller.split('::')[1]])
        k = off // 8 - 4
        return [(i, PX[i][k]) for i in ifaces if i.split('::')[1] in ns and k < len(PX[i]) and PX[i][k] is not None]

    dm = demangle({F[a][0] for a in F if F[a][3]} | {F[a][0] for a in roots})
    hits, amb, wrap = collections.defaultdict(set), collections.defaultdict(set), collections.defaultdict(set)
    for a, (n, _, _, voffs) in F.items():
        d = dm.get(n, n)
        for off in set(voffs):
            cs = cands(d, off)
            if not cs:
                continue
            good = [x for x in cs if name_match(cmdname(*x), base(d))]
            if a in reached:
                if len(good) == 1 or (not good and len(cs) == 1):
                    hits[(good or cs)[0]].add(base(d))
                elif good or len(cs) <= 4:
                    for x in (good or cs):
                        amb[x].add(base(d))
            if len(good) == 1:
                wrap[good[0]].add((base(d), a in reached))
    imp_ns = collections.Counter()
    for a in roots:
        d = dm.get(F[a][0], F[a][0])
        if d.startswith('nn::'):
            for x in ALIAS.get(d.split('::')[1], [d.split('::')[1]]):
                imp_ns[x] += 1

    rows = []
    for i in ifaces:
        svc, mine = MAP[i]
        for c in sorted({c for c in PX[i] if c is not None}):
            h, am_, w = hits.get((i, c)), amb.get((i, c)), wrap.get((i, c), set())
            if h:
                use = '是'
            elif w:
                use = '否(SDK有封装、游戏不可达)'
            elif am_:
                use = '可能(槽位歧义)'
            elif imp_ns[i.split('::')[1]]:
                use = '接口级(命名空间有导入)'
            else:
                use = '否'
            have = c in our_cmds[i]
            if have:
                pr = '—'
            else:
                pr = {'是': 'P0', '可能(槽位歧义)': 'P1', '接口级(命名空间有导入)': 'P2'}.get(use, 'P3')
            row = dict(svc=svc, iface=i, cmd=c, name=our_cmds[i].get(c) or '/'.join(sorted(h or am_ or {x for x, _ in w})),
                       use=use, ours='已实现' if have else ('缺' if mine else '无此接口'), pr=pr)
            if eden_path:
                e = eden.get((i, c))
                row['eden'] = f'{e[0]}·{e[1]}' if e else '无'
            rows.append(row)
    order = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3, '—': 4}
    rows.sort(key=lambda r: (order[r['pr']], 0 if r.get('eden', '').startswith('实') else 1, r['svc'], r['iface'], r['cmd']))

    svc_used = svc_in_code(sdk.img, text_size)
    ns_of_map = {i.split('::')[1] for i in ifaces}
    return dict(
        tid=tid, sac=sac, rows=rows, mods=game_mods, n_px=len(PX), n_cmds=sum(len({c for c in v if c is not None}) for v in PX.values()),
        n_roots=len(roots), n_imports=len(root_names), n_reached=len(reached), n_vcalls=sum(len(F[a][3]) for a in reached),
        svc_missing=[(s, s in svc_used) for s in sorted(svc_ok - our_svc_calls)],
        n_svc_ok=len(svc_ok), sac_unregistered=[s for s in sac if s not in our_svcs],
        sac_unmapped=[s for s in sac if not any(v[0] == s for v in MAP.values())],
        map_rot=map_rot, unmapped_same_ns=sorted(i for i in PX if i not in MAP and i.split('::')[1] in ns_of_map),
        n_unmapped=sum(1 for i in PX if i not in MAP), eden=bool(eden_path))


def write(res, out, src):
    os.makedirs(out, exist_ok=True)
    cols = [('svc', '服务'), ('iface', '接口'), ('cmd', '命令号'), ('name', '名字'), ('use', '游戏可达'), ('ours', '我方'), ('pr', '优先级')]
    if res['eden']:
        cols.append(('eden', 'Eden'))
    with open(os.path.join(out, 'ns2_survey.tsv'), 'w', encoding='utf-8') as f:
        f.write('\t'.join(h for _, h in cols) + '\n')
        for r in res['rows']:
            f.write('\t'.join(str(r[k]) for k, _ in cols) + '\n')
    rev = subprocess.run(['git', '-C', src, 'log', '-1', '--format=%h %ci'], capture_output=True, text=True).stdout.strip() or '（不是 git 树）'
    rows = res['rows']
    cnt = collections.Counter(r['pr'] for r in rows)
    gap = [r for r in rows if r['pr'] != '—']
    L = [f'# 系统库普查：{res["tid"]:016X}', '',
         f'我方 = `{src}` @ {rev}；游戏模块 {"、".join(res["mods"])} 导入 {res["n_imports"]} 个符号，命中 sdk 导出函数 {res["n_roots"]} 个作根（含 sdk 初始化入口），'
         f'静态可达 {res["n_reached"]} 个函数、{res["n_vcalls"]} 个虚调用点。sdk 客户端代理 {res["n_px"]} 个接口 / {res["n_cmds"]} 条命令；'
         f'NPDM 许可 {len(res["sac"])} 个服务、{res["n_svc_ok"]} 个系统调用。', '',
         f'**表内 {len(rows)} 条命令（NPDM 许可 + 映射表覆盖的接口），我方已实现 {cnt["—"]}、缺 {len(gap)}。**', '',
         '| 优先级 | 条数 | 含义 |', '|---|---|---|',
         f'| P0 | {cnt["P0"]} | 从游戏导入静态可达到这条命令（唯一候选），我方缺 |',
         f'| P1 | {cnt["P1"]} | 可达的虚调用落在这条命令上，但同槽有 2–4 个候选接口（槽位歧义），我方缺 |',
         f'| P2 | {cnt["P2"]} | 游戏导入了该接口命名空间的函数、但没追到这条命令；静态召回约一半，P2 里混着真要补的 |',
         f'| P3 | {cnt["P3"]} | sdk 有这条命令的封装但从游戏导入走不到（静态反证），或命名空间没有导入 |', '',
         '## P0 / P1：可达且未实现', '', '| 优先级 | 服务 | 接口 | 命令 | SDK 调用者 | 我方 |' + (' Eden |' if res['eden'] else ''),
         '|---|---|---|---|---|---|' + ('---|' if res['eden'] else '')]
    for r in gap:
        if r['pr'] in ('P0', 'P1'):
            L.append(f"| {r['pr']} | {r['svc']} | {r['iface'].split('::')[-1]} | {r['cmd']} | {r['name'] or '—'} | {r['ours']} |" + (f" {r['eden']} |" if res['eden'] else ''))
    L += ['', '## 系统调用', '']
    if res['svc_missing']:
        L += ['NPDM 许可、我方 Syscall.cs 没有的系统调用（sdk 有 = sdk 代码段里有这条 svc 指令，游戏能发；否 = 只是许可）：', '',
              '| svc | sdk 有 |', '|---|---|']
        L += [f'| {s:#04x} | {"是" if u else "否"} |' for s, u in res['svc_missing']]
    else:
        L.append('NPDM 许可的系统调用我方都有。')
    L += ['', '## 服务与映射表', '',
          f'- NPDM 许可、我方没注册的服务：{"、".join(res["sac_unregistered"]) or "无"}',
          f'- NPDM 许可、映射表（tools/ns2_survey.py 的 MAP）里没有接口的服务：{"、".join(res["sac_unmapped"]) or "无"}（这些服务的命令不在表里）',
          f'- 映射表指向、我方树里找不到的类（表过期，要改 MAP）：{"、".join(f"{c}（{t}）" for _, t, c in res["map_rot"]) or "无"}',
          f'- sdk 有代理、映射表没收的接口 {res["n_unmapped"]} 个；其中与表内接口同命名空间的 {len(res["unmapped_same_ns"])} 个'
          f'（应用能不能连到要看服务入口，需要时补进 MAP）：{"、".join(res["unmapped_same_ns"]) or "无"}', '',
          '## 射程', '',
          '- 静态可达只沿导出函数之间的 bl / b 走；sdk 自己的无符号静态初始化、经虚调用链拿到的代理对象追不到。时之笛上以 26 条开局确实走到的命令作正对照，'
          '命中约一半，漏的集中在 SDK 启动阶段（见 docs/研究/Switch2新游戏系统库普查.md）。所以 **P2 不等于不会调**，P0 / P1 是下限不是全集。',
          '- P3 的「有封装、游戏不可达」是静态反证：时之笛正对照里 0 条被误判成它。',
          '- 槽位歧义靠调用者函数名对命令名消歧：命令名取我方方法名' + ('与 Eden 名' if res['eden'] else '（没给 --eden，我方没实现的命令没有名字，歧义会多）') + '。',
          '- 命令号从代理方法体解：寄存器传与栈传 [sp,#k] 两种；纯转发型代理（am 的若干访问器、IStorage）偶有一个重复的 0 号槽，真假不知道。', '',
          f'全表：同目录 `ns2_survey.tsv`（{len(rows)} 行，按优先级 → 服务 → 接口 → 命令号排序；已实现的优先级记「—」；'
          '「名字」列：已实现 = 我方方法名，未实现 = 静态追到的 SDK 调用者 / 封装函数名，歧义行是调用者名、不一定就是这条命令）。']
    with open(os.path.join(out, 'ns2_survey.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(L) + '\n')
    return cnt


def main():
    ap = argparse.ArgumentParser(description='新 Switch 2 游戏的系统服务 / 系统调用缺口普查（静态）')
    ap.add_argument('dump', help='解包目录或其 exefs/（要 main、sdk、main.npdm）')
    ap.add_argument('--out', default='.', help='输出目录（缺省当前目录）')
    ap.add_argument('--src', default=os.path.join(ROOT, 'compat', 'tree', 'src'), help='我方源码树（缺省本仓库 compat/tree/src）')
    ap.add_argument('--eden', help='外部 Eden 对照表 TSV：SDK 接口、命令号、实|空、命令名（不进仓库）')
    a = ap.parse_args()
    exefs = a.dump if os.path.exists(os.path.join(a.dump, 'main.npdm')) else os.path.join(a.dump, 'exefs')
    for n in ('main', 'sdk', 'main.npdm'):
        if not os.path.exists(os.path.join(exefs, n)):
            sys.exit(f'{exefs} 缺 {n}')
    res = survey(exefs, a.src, a.eden)
    cnt = write(res, a.out, a.src)
    print(f'{res["tid"]:016X}：P0 {cnt["P0"]}、P1 {cnt["P1"]}、P2 {cnt["P2"]}、P3 {cnt["P3"]}、已实现 {cnt["—"]}；'
          f'缺 svc {len(res["svc_missing"])}（sdk 有 {sum(1 for _, u in res["svc_missing"] if u)}）；→ {os.path.join(a.out, "ns2_survey.md")}')


if __name__ == '__main__':
    main()
