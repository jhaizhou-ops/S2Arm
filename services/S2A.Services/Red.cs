using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace S2A.Services
{
    // 报红（方案 §2 铁律 2）：未实现的服务 / 命令记服务名与命令号，绝不回成功或 0。
    // 每个（服务, 命令）首次必打一行，此后第 2^n 次再打；退出时汇总一行「【红】未实现服务：…」（一个都没有时打「未实现服务：无」，不带【红】）。
    public static class Red
    {
        // Horizon sf：未知命令号（模块 10 描述 221）。服务存在但命令没实现时回给游戏
        public const uint ResultUnknownCommand = (221u << 9) | 10u;
        // sm：服务名未注册（模块 21 描述 7）
        public const uint ResultSmNotRegistered = (7u << 9) | 21u;

        private static readonly object _lock = new();
        private static readonly Dictionary<string, long> _counts = new();

        // 严格模式（S2A_STRICT=1，Mac 冒烟 / 门禁缺省开）：首次报红即中止，带回溯
        public static bool Strict { get; set; } = Environment.GetEnvironmentVariable("S2A_STRICT") == "1";

        public static Action<string> Log { get; set; } = line => Console.Error.WriteLine(line);

        public static long Total { get { lock (_lock) { return _counts.Values.Sum(); } } }

        public static void Report(string what, string detail = null, bool allowFailFast = true)
        {
            long n;

            lock (_lock)
            {
                _counts.TryGetValue(what, out n);
                _counts[what] = ++n;
            }

            if ((n & (n - 1)) == 0)
            {
                Log($"【红】{what}（第 {n} 次）{(detail != null ? "：" + detail : "")}");
            }

            if (allowFailFast && Strict && n == 1)
            {
                Log($"【红】严格模式中止：{what}\n{Environment.StackTrace}");
                Environment.FailFast($"S2A_STRICT：{what}");
            }
        }

        private static readonly HashSet<string> _notes = new();
        private const int NoteCap = 256;

        // 不算红但要看得见的一行（如 fs 路径不存在这类游戏本该自己处理的探测结果）：同一（事由, 细节）只打首次，
        // 不同的最多 256 种，到顶打一行说明此后不再打
        public static void Note(string what, string detail)
        {
            int n;

            lock (_lock)
            {
                if (_notes.Count > NoteCap || !_notes.Add(what + "\0" + detail))
                {
                    return;
                }

                n = _notes.Count;
            }

            Log(n <= NoteCap ? $"{what}：{detail}" : $"{what}：已打 {NoteCap} 种，此后同类不再逐条打");
        }

        private static readonly Dictionary<string, long> _stubs = new();

        // Ryujinx 上游的占位实现被调到（见 Host.Boot）：不算报红，单独计数
        public static void Stub(string what)
        {
            long n;

            lock (_lock)
            {
                _stubs.TryGetValue(what, out n);
                _stubs[what] = ++n;
            }

            if (n == 1)
            {
                Log($"【桩】{what}");
            }
        }

        public static string StubSummary()
        {
            lock (_lock)
            {
                // 次数取 Logger 的计数（Logger 只在首次发事件，这里的 _stubs 只用于首次打行）；空列表打「无」：不让下游把空汇总行误当一条记录
                var hits = Ryujinx.Common.Logging.Logger.S2AStubHits();
                return hits.Count == 0
                    ? "【桩】Ryujinx 占位实现被调到：无"
                    : "【桩】Ryujinx 占位实现被调到：" + string.Join("；", hits.OrderByDescending(h => h.Count).Select(h => $"{h.Name}×{h.Count}"));
            }
        }

        public static string Summary()
        {
            lock (_lock)
            {
                // 空列表不带【红】：0 个未实现服务不是红（原先恒打「【红】未实现服务：」，被各处计成红）
                if (_counts.Count == 0)
                {
                    return "未实现服务：无";
                }

                StringBuilder sb = new("【红】未实现服务：");

                foreach (KeyValuePair<string, long> kv in _counts.OrderByDescending(kv => kv.Value))
                {
                    sb.Append(kv.Key).Append('×').Append(kv.Value).Append("；");
                }

                return sb.ToString();
            }
        }

        public static void Reset()
        {
            lock (_lock)
            {
                _counts.Clear();
                _notes.Clear();
                _stubs.Clear();
            }
        }
    }
}
