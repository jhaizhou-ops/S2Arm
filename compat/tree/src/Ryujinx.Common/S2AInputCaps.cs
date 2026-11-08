using System.Text;
using System.Threading;

namespace Ryujinx.Common
{
    // S2Arm：每局游戏向 HID 服务声明的输入能力，收局时打一行机器可读摘要。
    // 摘要行格式（扫描工具按此解析）：
    //   [输入能力] styles=<逗号分隔列表或-> sixaxis_start=<n> vib_calls=<n> vib_nonzero=<n>
    public static class S2AInputCaps
    {
        private static uint _styles;       // SetSupportedNpadStyleSet 所有调用的位域并集
        private static int _sixaxisStart;  // Start{,Console,Seven}SixAxisSensor 调用次数之和
        private static int _vibCalls;      // SendVibration{Value,Values,GcErmCommand} 调用次数
        private static int _vibNonzero;    // 上述调用里幅度（或命令）非零的次数

        // ControllerType 位名（Common 不引用 HLE，硬编码与 ControllerType.cs 一致）
        private static readonly (uint Bit, string Name)[] _styleNames =
        [
            (1u << 0,  "ProController"),
            (1u << 1,  "Handheld"),
            (1u << 2,  "JoyconPair"),
            (1u << 3,  "JoyconLeft"),
            (1u << 4,  "JoyconRight"),
            (1u << 5,  "Invalid"),
            (1u << 6,  "Pokeball"),
            (1u << 29, "SystemExternal"),
            (1u << 30, "System"),
        ];

        // SetSupportedNpadStyleSet：多次调用取位域并集（CAS 循环，无 .NET 版本依赖）
        public static void RecordStyleSet(uint bits)
        {
            uint cur, next;
            do
            {
                cur = Volatile.Read(ref _styles);
                next = cur | bits;
            }
            while (Interlocked.CompareExchange(ref _styles, next, cur) != cur);
        }

        // Start{,Console,Seven}SixAxisSensor 调用次数
        public static void RecordSixAxisStart()
            => Interlocked.Increment(ref _sixaxisStart);

        // SendVibrationValue / SendVibrationValues / SendVibrationGcErmCommand：每次 IPC 调用记一次；
        // nonzero = 这次调用里有任一幅度非零（Values 取所有值；GcErm 取命令非 Stop）
        public static void RecordVibration(bool nonzero)
        {
            Interlocked.Increment(ref _vibCalls);
            if (nonzero) Interlocked.Increment(ref _vibNonzero);
        }

        // 收局摘要行（见类头格式）。崩溃收局也调这里：计数是累计的，不会因崩溃丢失前面的调用。
        public static string Summary()
        {
            uint bits = Volatile.Read(ref _styles);
            int six = Volatile.Read(ref _sixaxisStart);
            int vc = Volatile.Read(ref _vibCalls);
            int vn = Volatile.Read(ref _vibNonzero);

            StringBuilder styles = new();
            if (bits == 0)
            {
                styles.Append('-');
            }
            else
            {
                bool first = true;
                foreach (var (bit, name) in _styleNames)
                {
                    if ((bits & bit) != 0)
                    {
                        if (!first) styles.Append(',');
                        styles.Append(name);
                        first = false;
                    }
                }
            }

            return $"[输入能力] styles={styles} sixaxis_start={six} vib_calls={vc} vib_nonzero={vn}";
        }

        // 单测复位
        public static void Reset()
        {
            Volatile.Write(ref _styles, 0u);
            Volatile.Write(ref _sixaxisStart, 0);
            Volatile.Write(ref _vibCalls, 0);
            Volatile.Write(ref _vibNonzero, 0);
        }
    }
}
