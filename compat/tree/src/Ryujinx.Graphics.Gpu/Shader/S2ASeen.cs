using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// S2A：双轨直连的覆盖率就绪（docs/设计_直连架构.md §12.3）——通用模式下把见过的着色器换成直连库的键，追加写 seen_shaders.tsv（一行一个键、跨局去重）。
    /// 键表 = 双轨包 shaders/direct/guest_key.tsv（客体代码 sha256 前 16 位 → 直连键，pack/stage_direct.sh 出；同一客体代码配不同控制段时多行，全写）；
    /// 表里没有的写 code:&lt;客体哈希16&gt;（永不就绪）。graphics/loop/ShaderPack 装包时 Open；不 Open（通用包没有键表）就什么都不做。
    /// 只在 ShaderCache 建出新的程序时调（每个地址组合一次，不在每帧路径上）；同一客体代码只查表一次。
    /// </summary>
    public static class S2ASeen
    {
        private static readonly object _lock = new();
        private static Dictionary<ulong, string[]> _map;
        private static HashSet<ulong> _codes;
        private static HashSet<string> _written;
        private static StreamWriter _out;
        private static int _keys, _misses;

        public static void Close()
        {
            lock (_lock)
            {
                _out?.Dispose(); _out = null;
                _map = null; _codes = null; _written = null;
                _keys = 0; _misses = 0;
            }
        }

        /// <summary>开始记：table = guest_key.tsv，seenPath = Documents/wire/&lt;程序号&gt;/seen_shaders.tsv（已有行读进来去重）。返回错误说明，成功返回 null</summary>
        public static string Open(string table, string seenPath)
        {
            lock (_lock)
            {
                _out?.Dispose(); _out = null;
                try
                {
                    var map = new Dictionary<ulong, List<string>>();
                    foreach (string l in File.ReadLines(table))
                    {
                        if (l.Length == 0 || l[0] == '#') continue;
                        if (l.Length < 33 || l[16] != '\t') throw new FormatException($"键表坏行：{l}");
                        ulong h = Convert.ToUInt64(l[..16], 16);
                        if (!map.TryGetValue(h, out List<string> ks)) map[h] = ks = new List<string>(1);
                        ks.Add(l.Substring(17, 16));
                    }
                    _map = new Dictionary<ulong, string[]>(map.Count);
                    foreach (var kv in map) _map[kv.Key] = kv.Value.ToArray();
                    Directory.CreateDirectory(Path.GetDirectoryName(seenPath));
                    _written = File.Exists(seenPath) ? new HashSet<string>(File.ReadLines(seenPath), StringComparer.Ordinal) : new HashSet<string>(StringComparer.Ordinal);
                    _codes = new HashSet<ulong>();
                    _out = new StreamWriter(new FileStream(seenPath, FileMode.Append, FileAccess.Write, FileShare.Read)) { AutoFlush = true };
                    return null;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException)
                {
                    _map = null; _out = null;
                    return e.Message;
                }
            }
        }

        /// <summary>键表条数（日志用）</summary>
        public static int TableCount => _map?.Count ?? 0;

        /// <summary>本进程写进 seen 的行数：键 / code: 兜底</summary>
        public static (int Keys, int Misses) Counts => (_keys, _misses);

        internal static void Note(CachedShaderProgram program)
        {
            if (_out == null || program?.Shaders == null) return;
            lock (_lock)
            {
                foreach (CachedShaderStage s in program.Shaders) NoteCode(s?.Code);
            }
        }

        /// <summary>记一段客体代码（调用方持 _lock；单测直接喂字节）</summary>
        internal static void NoteCode(byte[] code)
        {
            if (_out == null || code == null || code.Length == 0) return;
            Span<byte> d = stackalloc byte[32];
            SHA256.HashData(code, d);
            ulong h = BinaryPrimitives.ReadUInt64BigEndian(d);
            if (!_codes.Add(h)) return;
            if (_map.TryGetValue(h, out string[] ks))
            {
                foreach (string k in ks) if (_written.Add(k)) { _out.WriteLine(k); _keys++; }
            }
            else
            {
                string c = $"code:{h:x16}";
                if (_written.Add(c)) { _out.WriteLine(c); _misses++; }
            }
        }
    }
}
