using NetCoreServer;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace S2A.Services
{
    // 原生层（局域网 Bonjour 选举）改中继地址：UTF-8 的 IPv4 文本
    static unsafe class LdnExports
    {
        [System.Runtime.InteropServices.UnmanagedCallersOnly(EntryPoint = "S2A_LdnSetServer")]
        public static void SetServer(byte* utf8)
        {
            try
            {
                Host.SetLdnServer(utf8 == null ? null : System.Runtime.InteropServices.Marshal.PtrToStringUTF8((nint)utf8));
            }
            catch (Exception)
            {
                // 不让托管异常穿过 C 接口
            }
        }

        /// <summary>局域网发现起不来的原因（审计 P1-59，值见 Host.LanUnavailable）：0 = 没出过问题；1 宿主没有局域网发现；2 发现启动失败。
        /// 任意线程随时可调、不阻塞、不分配；游戏第一次初始化本地联机后才有意义，界面按需轮询，值只增不减。
        /// C 侧声明：int S2A_LanState(void)（未链服务层时按 dlsym 判空）</summary>
        [System.Runtime.InteropServices.UnmanagedCallersOnly(EntryPoint = "S2A_LanState")]
        public static int LanState() => Host.LanUnavailable;
    }

    // 本地无线联机中继（ldn:u 的 RyuLdn 后端的服务端）：协议与报文结构全部复用 Ryujinx 客户端那一份（RyuLdnProtocol / LdnRyu.Types），
    //   服务端语义按 Switch 本地通信写——建房的是接入点（节点 0），扫描按 ScanFilter 过滤，进房分节点号与虚拟 IP，房内状态变化向全员同步，
    //   游戏 socket 的数据（ProxyConnect / ProxyData / ProxyDisconnect）按虚拟 IP 在同一房间内转发，房间之间互不可见。
    // 一个中继服务所有连上来的游戏：Mac 多开时第一个起来的进程托管（回环口），之后手机局域网 / 中继服务器用同一份代码。
    sealed class LdnRelay : TcpServer
    {
        // 虚拟网 10.114.0.0/16（与 Ryujinx 客户端建房前先发的占位节点 10.114.0.1 同网段）；IP 全局不重复，路由只在房间内
        private const uint VirtualNet = 0x0A720000;
        private const uint VirtualMask = 0xFFFF0000;

        private readonly object _lock = new();
        private readonly List<Room> _rooms = new();
        private uint _nextHost = 1;
        private readonly HashSet<uint> _ipsInUse = new();   // 在房间里的会话占着的虚拟 IP（进房登记、离开 / 被解散归还），中继锁内读写

        public LdnRelay(IPAddress address, int port) : base(address, port)
        {
            OptionNoDelay = true;
            OptionReuseAddress = false;       // 端口已被别的进程托管时要拿到 AddressAlreadyInUse，改当客户端
            OptionExclusiveAddressUse = true;  // .NET 在 Unix 上缺省给监听口开 SO_REUSEPORT，两个进程能同时绑上同一端口
        }

        // 能托管就托管（起服务返回 true）；端口已被占（别的进程已托管）返回 false
        public static LdnRelay TryHost(IPAddress address, int port)
        {
            LdnRelay relay = new(address, port);

            try
            {
                if (relay.Start())
                {
                    return relay;
                }
            }
            catch (SocketException e) when (e.SocketErrorCode == SocketError.AddressAlreadyInUse)
            {
            }

            relay.Dispose();
            return null;
        }

        protected override TcpSession CreateSession() => new Session(this);

        // 连接建立 / 断开与服务端出错都留一行（少见事件，带时刻与当前连接数）：排查「扫到房间后再也连不上中继」要分清是中继不收新连接还是客户端的事
        protected override void OnError(SocketError error) => Console.Error.WriteLine($"[S2A 联机] {Now()} 中继出错：{error}");

        private static string Now() => DateTime.Now.ToString("HH:mm:ss.fff");

        public int RoomCount
        {
            get
            {
                lock (_lock)
                {
                    return _rooms.Count;
                }
            }
        }

        // 房间数变了（建房 / 解散）：局域网模式下宿主据此在 Bonjour 发布名上加 / 去「有房间」标记，让各设备的选举优先选有房间的中继
        public Action<int> RoomCountChanged;
        private int _roomCountReported;
        private readonly object _notifyLock = new();   // 只串行化发布，不是中继锁

        // 每个可能改房间数的入口在放掉中继锁之后调一次；没变不回调。回调要进原生层（dispatch 到主线程），不在中继锁里做。
        //   读当前数、比已发布、发布整段在发布锁里：两个入口并发通知时后进来的等前一次发布完再读，最后发布的总是当前房间数
        //   （审计 #814：原先锁外读改写，后完成的一次把已发布值写回自己的旧快照，「有房间」标记停在旧值）
        private void NotifyRoomCount()
        {
            lock (_notifyLock)
            {
                int n = RoomCount;

                if (n == _roomCountReported)
                {
                    return;
                }

                _roomCountReported = n;

                try
                {
                    RoomCountChanged?.Invoke(n);
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine($"[S2A 联机] 房间数回调出错：{e.Message}");
                }
            }
        }

        // 从游标往后找第一个没人占的地址并登记，中继锁内调；全网段用尽回 0 并报红（调用方按加入失败处理）。
        //   审计 #859：原先游标在 /16 里只管递增，第 65025 次回到 10.114.0.1，不看它是否仍被房里的节点占着
        private uint AllocateIp()
        {
            // 跳过 .0 / .255 结尾，避开子网号与广播的样子；游标走满一圈（65536 步）还没找到就是用尽
            for (int step = 0; step <= (int)~VirtualMask; step++)
            {
                uint ip = VirtualNet | (_nextHost++ & ~VirtualMask);

                if ((ip & 0xFF) == 0 || (ip & 0xFF) == 0xFF || _ipsInUse.Contains(ip))
                {
                    continue;
                }

                _ipsInUse.Add(ip);
                return ip;
            }

            Red.Report("联机中继：虚拟 IP 用尽，这次建房 / 进房失败", $"10.114.0.0/16 在用 {_ipsInUse.Count} 个");
            return 0;
        }

        sealed class Room
        {
            public Session Owner;
            public NetworkInfo Info;
            public readonly Session[] Members = new Session[8];   // 下标 = 节点号；0 是接入点
            public string Passphrase;
        }

        sealed class Session : TcpSession
        {
            private readonly LdnRelay _relay;
            public readonly RyuLdnProtocol Protocol = new();
            public Array6<byte> Mac;
            public string Passphrase = string.Empty;
            public Room Room;
            public uint Ip;
            public int NodeId = -1;
            public long Forwarded;   // 本连接发出、经中继转给房内别人的游戏数据包数（ProxyData）

            public Session(LdnRelay relay) : base(relay)
            {
                _relay = relay;

                Protocol.Initialize += (_, m) => _relay.OnInitialize(this, m);
                Protocol.Passphrase += (_, m) => Passphrase = PassphraseText(m);
                Protocol.CreateAccessPoint += (_, r, adv) => _relay.OnCreate(this, r.SecurityConfig, r.UserConfig, r.NetworkConfig, r.RyuNetworkConfig, adv);
                Protocol.CreateAccessPointPrivate += (_, r, adv) => _relay.OnCreate(this, r.SecurityConfig, r.UserConfig, r.NetworkConfig, r.RyuNetworkConfig, adv);
                Protocol.Scan += (_, f) => _relay.OnScan(this, f);
                Protocol.Connect += (_, r) => _relay.OnConnect(this, r);
                Protocol.Disconnected += (_, _) => _relay.Leave(this, notifySelf: false);
                Protocol.SetAdvertiseData += (_, d) => _relay.OnAdvertise(this, d);
                Protocol.SetAcceptPolicy += (_, p) => _relay.OnAcceptPolicy(this, p.StationAcceptPolicy);
                Protocol.Reject += (_, r) => _relay.OnReject(this, r);
                Protocol.ProxyConnect += (_, m) => _relay.Route(this, ref m.Info, s => s.Send(PacketId.ProxyConnect, m));
                Protocol.ProxyConnectReply += (_, m) => _relay.Route(this, ref m.Info, s => s.Send(PacketId.ProxyConnectReply, m));
                Protocol.ProxyDisconnect += (_, m) => _relay.Route(this, ref m.Info, s => s.Send(PacketId.ProxyDisconnect, m));
                Protocol.ProxyData += (_, h, d) =>
                {
                    _relay.Route(this, ref h.Info, s => s.SendAsync(s.Protocol.Encode(PacketId.ProxyData, h, d)));

                    // 游戏数据通没通的直接读数：每条连接第 1 个包与之后每满 1000 个各一行
                    if (++Forwarded == 1 || Forwarded % 1000 == 0)
                    {
                        Console.Error.WriteLine($"[S2A 联机] {Now()} 数据：节点 {NodeId}（{IpText(Ip)}）已发 {Forwarded} 个包，本包 {h.Info.Protocol} {IpText(h.Info.SourceIpV4)}:{h.Info.SourcePort} → {IpText(h.Info.DestIpV4)}:{h.Info.DestPort}，{d.Length} 字节");
                    }
                };
            }

            public void Send<T>(PacketId id, T packet) where T : unmanaged => SendAsync(Protocol.Encode(id, packet));

            public void Send(PacketId id) => SendAsync(Protocol.Encode(id));

            protected override void OnReceived(byte[] buffer, long offset, long size)
            {
                try
                {
                    Protocol.Read(buffer, (int)offset, (int)size);
                }
                catch (Exception e)   // 外来包：任何异常都只断这一条连接（11-01 全量审计 P0-7：原先只接 InvalidOperationException，截断的扫描包 / 超长 SSID 抛别的异常，同网段一个包就让整个进程退出）
                {
                    Red.Report("联机中继：报文不合协议，断开该连接", $"{e.GetType().Name}：{e.Message}");
                    Disconnect();
                }
            }

            protected override void OnConnected() => Console.Error.WriteLine($"[S2A 联机] {Now()} 连接建立：{Socket?.RemoteEndPoint}，当前 {_relay.ConnectedSessions} 个连接");

            protected override void OnDisconnected()
            {
                Console.Error.WriteLine($"[S2A 联机] {Now()} 连接断开：节点 {NodeId}，当前 {_relay.ConnectedSessions} 个连接");
                _relay.Leave(this, notifySelf: false);
            }

            protected override void OnError(SocketError error) => Console.Error.WriteLine($"[S2A 联机] {Now()} 连接出错：{error}");
        }

        private static string PassphraseText(PassphraseMessage m)
        {
            ReadOnlySpan<byte> s = m.Passphrase.AsSpan();
            int n = s.IndexOf((byte)0);
            return System.Text.Encoding.UTF8.GetString(n < 0 ? s : s[..n]);
        }

        private void OnInitialize(Session s, InitializeMessage m)
        {
            // 客户端带着上次分到的号来则沿用 MAC（同一台机重连认得出），否则发一个本地管理的单播 MAC（首字节 0x02）
            InitializeMessage reply = m;

            if (m.MacAddress.AsSpan().IndexOfAnyExcept((byte)0) < 0)
            {
                RandomNumberGenerator.Fill(reply.MacAddress.AsSpan());
                reply.MacAddress[0] = 0x02;
            }

            if (m.Id.AsSpan().IndexOfAnyExcept((byte)0) < 0)
            {
                RandomNumberGenerator.Fill(reply.Id.AsSpan());
            }

            s.Mac = reply.MacAddress;
            s.Send(PacketId.Initialize, reply);
        }

        private void OnCreate(Session s, SecurityConfig security, UserConfig user, NetworkConfig network, RyuNetworkConfig ryu, byte[] advertise)
        {
            lock (_lock)
            {
                LeaveLocked(s, notifySelf: false);

                Room room = new() { Owner = s, Passphrase = s.Passphrase };
                ref NetworkInfo info = ref room.Info;

                info.NetworkId.IntentId = network.IntentId;
                RandomNumberGenerator.Fill(info.NetworkId.SessionId.AsSpan());

                info.Common.MacAddress = s.Mac;
                info.Common.Channel = network.Channel == 0 ? (ushort)6 : network.Channel;   // 缺省信道：Switch 2.4 GHz 自动选时落 1 / 6 / 11
                info.Common.LinkLevel = 3;
                info.Common.NetworkType = 2;   // 本地通信网
                info.Common.Ssid.Length = 32;
                Span<byte> ssid = stackalloc byte[16];
                RandomNumberGenerator.Fill(ssid);
                System.Text.Encoding.ASCII.GetBytes(Convert.ToHexStringLower(ssid)).CopyTo(info.Common.Ssid.Name.AsSpan());

                info.Ldn.SecurityMode = (ushort)security.SecurityMode;
                info.Ldn.StationAcceptPolicy = AcceptPolicy.AcceptAll;
                info.Ldn.NodeCountMax = Math.Clamp(network.NodeCountMax, (byte)1, (byte)8);
                SetAdvertise(ref info, advertise);

                s.Ip = AllocateIp();

                if (s.Ip == 0)
                {
                    // 建房没有专门的失败回包：不回 Connected，客户端等满 FailureTimeout 判建房失败；错误码先送到（客户端记为最近一次错误）
                    s.Send(PacketId.NetworkError, new NetworkErrorMessage { Error = NetworkError.ConnectFailure });
                }
                else
                {
                    s.Room = room;
                    Join(room, s, 0, user, network.LocalCommunicationVersion);
                    _rooms.Add(room);

                    s.Send(PacketId.ProxyConfig, new ProxyConfig { ProxyIp = s.Ip, ProxySubnetMask = VirtualMask });
                    s.Send(PacketId.Connected, room.Info);
                }
            }

            Console.Error.WriteLine($"[S2A 联机] {Now()} 建房：本地通信号 {network.IntentId.LocalCommunicationId:x16} 场景 {network.IntentId.SceneId}，最多 {network.NodeCountMax} 人，{(s.Ip == 0 ? "失败（虚拟 IP 用尽）" : $"接入点 {IpText(s.Ip)}")}");
            NotifyRoomCount();   // 建房前先离开原房间：建房失败时原房间也可能已解散
        }

        private static void SetAdvertise(ref NetworkInfo info, byte[] advertise)
        {
            int n = Math.Min(advertise.Length, info.Ldn.AdvertiseData.Length);
            info.Ldn.AdvertiseData.AsSpan().Clear();
            advertise.AsSpan(0, n).CopyTo(info.Ldn.AdvertiseData.AsSpan());
            info.Ldn.AdvertiseDataSize = (ushort)n;
        }

        private static void Join(Room room, Session s, int nodeId, UserConfig user, ushort version)
        {
            room.Members[nodeId] = s;
            s.NodeId = nodeId;

            ref NodeInfo node = ref room.Info.Ldn.Nodes[nodeId];
            node = new NodeInfo
            {
                Ipv4Address = s.Ip,
                MacAddress = s.Mac,
                NodeId = (byte)nodeId,
                IsConnected = 1,
                UserName = user.UserName,
                LocalCommunicationVersion = version,
            };

            room.Info.Ldn.NodeCount++;
        }

        private static bool Matches(in NetworkInfo info, in ScanFilter f)
        {
            // 过滤项按 nn::ldn::ScanFilterFlag 逐位比
            if (f.Flag.HasFlag(ScanFilterFlag.LocalCommunicationId) && info.NetworkId.IntentId.LocalCommunicationId != f.NetworkId.IntentId.LocalCommunicationId)
            {
                return false;
            }

            if (f.Flag.HasFlag(ScanFilterFlag.SceneId) && info.NetworkId.IntentId.SceneId != f.NetworkId.IntentId.SceneId)
            {
                return false;
            }

            if (f.Flag.HasFlag(ScanFilterFlag.SessionId) && !info.NetworkId.SessionId.AsSpan().SequenceEqual(f.NetworkId.SessionId.AsSpan()))
            {
                return false;
            }

            if (f.Flag.HasFlag(ScanFilterFlag.NetworkType) && ((int)f.NetworkType & info.Common.NetworkType) == 0)
            {
                return false;
            }

            if (f.Flag.HasFlag(ScanFilterFlag.MacAddress) && !info.Common.MacAddress.AsSpan().SequenceEqual(f.MacAddress.AsSpan()))
            {
                return false;
            }

            // SSID 长度来自外来包（审计 P0-7）：超过上限 32 的过滤器不合法、什么都不匹配；比较只按钳过的长度切片，不越界
            if (f.Flag.HasFlag(ScanFilterFlag.Ssid))
            {
                int fl = f.Ssid.Length, il = Math.Min((int)info.Common.Ssid.Length, 32);

                if (fl > 32 || il != fl || !info.Common.Ssid.Name.AsSpan()[..il].SequenceEqual(f.Ssid.Name.AsSpan()[..fl]))
                {
                    return false;
                }
            }

            return true;
        }

        private void OnScan(Session s, ScanFilter filter)
        {
            int found = 0;

            lock (_lock)
            {
                foreach (Room room in _rooms)
                {
                    // 同一密码组的房间才看得见；自己的房间不回；拒绝一切加入的房间（游戏开局后锁房）不回，与 Ryubing/LdnServer 一致
                    if (room.Owner == s || room.Passphrase != s.Passphrase || room.Info.Ldn.StationAcceptPolicy == AcceptPolicy.RejectAll || !Matches(room.Info, filter))
                    {
                        continue;
                    }

                    s.Send(PacketId.ScanReply, room.Info);
                    found++;
                }
            }

            s.Send(PacketId.ScanReplyEnd);
            Console.Error.WriteLine($"[S2A 联机] {Now()} 扫描：本地通信号 {filter.NetworkId.IntentId.LocalCommunicationId:x16} 过滤 {filter.Flag}，回 {found} 个房间");
        }

        private void OnConnect(Session s, ConnectRequest request)
        {
            NetworkError error;

            lock (_lock)
            {
                LeaveLocked(s, notifySelf: false);

                Room room = _rooms.Find(r => r.Info.NetworkId.SessionId.AsSpan().SequenceEqual(request.NetworkInfo.NetworkId.SessionId.AsSpan()) &&
                                             r.Info.Common.MacAddress.AsSpan().SequenceEqual(request.NetworkInfo.Common.MacAddress.AsSpan()));
                ushort hostVersion = room?.Info.Ldn.Nodes[0].LocalCommunicationVersion ?? 0;
                int free = room == null ? -1 : Array.FindIndex(room.Members, 1, m => m == null);

                if (room == null || room.Passphrase != s.Passphrase)
                {
                    error = NetworkError.ConnectNotFound;
                }
                else if (room.Info.Ldn.StationAcceptPolicy == AcceptPolicy.RejectAll)
                {
                    error = NetworkError.ConnectRejected;
                }
                else if (free < 0 || free >= room.Info.Ldn.NodeCountMax || room.Info.Ldn.NodeCount >= room.Info.Ldn.NodeCountMax)
                {
                    error = NetworkError.TooManyPlayers;
                }
                else if (request.LocalCommunicationVersion != hostVersion)
                {
                    error = request.LocalCommunicationVersion < hostVersion ? NetworkError.VersionTooLow : NetworkError.VersionTooHigh;
                }
                else if ((s.Ip = AllocateIp()) == 0)
                {
                    error = NetworkError.ConnectFailure;
                }
                else
                {
                    s.Room = room;
                    Join(room, s, free, request.UserConfig, (ushort)request.LocalCommunicationVersion);

                    s.Send(PacketId.ProxyConfig, new ProxyConfig { ProxyIp = s.Ip, ProxySubnetMask = VirtualMask });
                    s.Send(PacketId.Connected, room.Info);
                    SyncLocked(room, except: s);
                    error = NetworkError.None;
                }
            }

            if (error != NetworkError.None)
            {
                s.Send(PacketId.NetworkError, new NetworkErrorMessage { Error = error });
            }

            Console.Error.WriteLine($"[S2A 联机] {Now()} 进房：{(error == NetworkError.None ? $"节点 {s.NodeId} 虚拟 IP {IpText(s.Ip)}" : $"拒绝 {error}")}");
            NotifyRoomCount();   // 进房前先离开原房间：若它是接入点，房间已解散
        }

        private void OnAdvertise(Session s, byte[] data)
        {
            lock (_lock)
            {
                if (s.Room?.Owner == s)
                {
                    SetAdvertise(ref s.Room.Info, data);
                    SyncLocked(s.Room, except: null);
                }
            }
        }

        private void OnAcceptPolicy(Session s, AcceptPolicy policy)
        {
            lock (_lock)
            {
                if (s.Room?.Owner == s)
                {
                    s.Room.Info.Ldn.StationAcceptPolicy = policy;
                    SyncLocked(s.Room, except: null);
                }
            }
        }

        private void OnReject(Session s, RejectRequest request)
        {
            lock (_lock)
            {
                Room room = s.Room;

                if (room?.Owner == s && request.NodeId is > 0 and < 8 && room.Members[request.NodeId] is Session target)
                {
                    target.Send(PacketId.Reject, request);
                    LeaveLocked(target, notifySelf: true);
                }
                else
                {
                    s.Send(PacketId.NetworkError, new NetworkErrorMessage { Error = NetworkError.RejectFailed });
                }

                s.Send(PacketId.RejectReply);
            }

            NotifyRoomCount();
        }

        private void Leave(Session s, bool notifySelf)
        {
            lock (_lock)
            {
                LeaveLocked(s, notifySelf);
            }

            NotifyRoomCount();
        }

        private void LeaveLocked(Session s, bool notifySelf)
        {
            Room room = s.Room;

            if (room == null)
            {
                return;
            }

            if (notifySelf)
            {
                s.Send(PacketId.Disconnect, new DisconnectMessage { DisconnectIP = s.Ip });
            }

            if (room.Owner == s)
            {
                // 接入点走了，房间解散：其余节点都被断开（Switch 上主机关网后站点收到 DisconnectReason 断开）
                _rooms.Remove(room);

                for (int i = 1; i < room.Members.Length; i++)
                {
                    if (room.Members[i] is Session m)
                    {
                        m.Send(PacketId.Disconnect, new DisconnectMessage { DisconnectIP = s.Ip });
                        m.Room = null;
                        m.NodeId = -1;
                        _ipsInUse.Remove(m.Ip);
                    }
                }
            }
            else
            {
                room.Members[s.NodeId] = null;
                room.Info.Ldn.Nodes[s.NodeId] = default;
                room.Info.Ldn.NodeCount--;
                SyncLocked(room, except: null);
            }

            s.Room = null;
            s.NodeId = -1;
            _ipsInUse.Remove(s.Ip);
        }

        private static void SyncLocked(Room room, Session except)
        {
            foreach (Session m in room.Members)
            {
                if (m != null && m != except)
                {
                    m.Send(PacketId.SyncNetwork, room.Info);
                }
            }
        }

        // 游戏 socket 数据：源地址只能是自己（0.0.0.0 绑定的替换成自己），目的是房内某节点或广播
        private void Route(Session sender, ref ProxyInfo info, Action<Session> deliver)
        {
            if (info.SourceIpV4 == 0)
            {
                info.SourceIpV4 = sender.Ip;
            }
            else if (info.SourceIpV4 != sender.Ip)
            {
                return;
            }

            uint dest = info.DestIpV4;
            uint broadcast = VirtualNet | ~VirtualMask;
            // 广播含发送者自己（与 Ryujinx P2pProxyServer 一致：BSD 上绑了该端口的发送方也收到自己的广播）
            bool isBroadcast = dest == broadcast || dest == 0xFFFFFFFF || dest == 0xC0A800FF;

            lock (_lock)
            {
                Room room = sender.Room;

                if (room == null)
                {
                    return;
                }

                foreach (Session m in room.Members)
                {
                    if (m != null && (isBroadcast || m.Ip == dest))
                    {
                        deliver(m);
                    }
                }
            }
        }

        private static string IpText(uint ip) => $"{ip >> 24}.{(ip >> 16) & 0xFF}.{(ip >> 8) & 0xFF}.{ip & 0xFF}";
    }
}
