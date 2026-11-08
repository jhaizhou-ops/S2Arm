// C2：NativeAOT 侧的 enabled profile 合成入口（native 在 Prepare 阶段调用）。
// 入参是 native 实测的 s2a-device-caps-v1 JSON 与包描述符里的 translatorClosure；
// 出参是完整 s2a-direct-profile-v1，由 native 原样放进编译请求，不在 native 侧重算哈希。
using S2A.DirectCompiler;
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Android.Aot
{
    public static unsafe class DirectProfileNative
    {
        private const int MaxClosureBytes = 127;

        // 本构建编译器的 translatorClosure（runtime.c 用它校正导入时写死、换引擎后过期的描述文件）。
        // 写入以 NUL 结尾的 UTF-8；返回字节数（不含 NUL），缓冲不够返回 0。
        [UnmanagedCallersOnly(EntryPoint = "s2a_direct_compiler_closure_v1")]
        public static int CompilerClosure(byte* output, int capacity)
        {
            byte[] text = Encoding.UTF8.GetBytes(DirectBuildIdentity.TranslatorClosure);
            if (output == null || capacity <= text.Length) return 0;
            for (int i = 0; i < text.Length; i++) output[i] = text[i];
            output[text.Length] = 0;
            return text.Length;
        }

        // 与 direct/s2a_direct.h 的 s2a_direct_profile_json_v1 同签名：
        //   int32_t s2a_direct_profile_json_v1(s2a_direct_bytes caps, const char *closure,
        //                                      s2a_direct_emit_fn emit, void *sink);
        [UnmanagedCallersOnly(EntryPoint = "s2a_direct_profile_json_v1")]
        public static int Compose(DirectBytes caps, nint closure, nint emit, nint sink)
        {
            if (caps.Data == 0 || caps.Bytes == 0 || caps.Bytes > DirectDeviceCaps.MaxBytes ||
                closure == 0 || emit == 0)
                return DirectAbi.Argument;
            string text;
            byte[] input;
            try
            {
                var span = new ReadOnlySpan<byte>((void*)caps.Data, checked((int)caps.Bytes));
                input = span.ToArray();
                byte* c = (byte*)closure;
                int length = 0;
                while (length <= MaxClosureBytes && c[length] != 0) length++;
                if (length == 0 || length > MaxClosureBytes) return DirectAbi.Argument;
                text = Encoding.UTF8.GetString(new ReadOnlySpan<byte>(c, length));
            }
            catch (Exception) { return DirectAbi.Argument; }

            // 启动准备阶段就核对“包描述符声明的 closure”与“本机编译器的 closure”。
            // 旧行为是照单全收包里的 closure，直到真正补编才在编译器里失败（进世界后才崩，
            // 而且只剩 rc=-1）。这里提前拒绝，并把双方实际值写进错误，界面能明确提示版本不匹配。
            string actual = DirectIdentity.TranslatorClosure;
            if (!string.Equals(text, actual, StringComparison.Ordinal))
            {
                Console.Error.WriteLine($"[s2a] direct profile identity mismatch: package={text} compiler={actual}");
                EmitError(emit, sink, "IDENTITY",
                          "包与编译器版本不匹配：packageClosure=" + text + " compilerClosure=" + actual);
                return DirectAbi.Identity;
            }

            byte[] output;
            try
            {
                output = DirectProfileComposer.Compose(input, actual);
            }
            catch (DirectCompileException error)
            {
                Console.Error.WriteLine($"[s2a] direct profile rejected ({error.Code}): {error.Message}");
                return error.Code is "INVALID_JSON" or "DUPLICATE_KEY" or "INVALID_BASE64" or "RESOURCE_LIMIT"
                    or "UNSUPPORTED_PROFILE" or "UNSUPPORTED_VERSION"
                    ? DirectAbi.Argument : DirectAbi.Internal;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("[s2a] direct profile internal error: " + error);
                return DirectAbi.Internal;
            }

            var callback = (delegate* unmanaged<nint, DirectBytes, int>)emit;
            fixed (byte* data = output)
            {
                var bytes = new DirectBytes { Data = (nint)data, Bytes = (ulong)output.Length };
                int result = callback(sink, bytes);
                return result == 0 ? DirectAbi.Ok : DirectAbi.Internal;
            }
        }

        // 与 DirectCompileNative 相同的错误通道：ABI 只有状态码，原因必须走 emit 才能被 native 记录/展示。
        private static void EmitError(nint emit, nint sink, string code, string message)
        {
            if (emit == 0) return;
            string json = "{\"schema\":\"s2a-direct-error-v1\",\"code\":\"" + code +
                          "\",\"message\":\"" + Json(message) + "\"}";
            byte[] bytesIn = Encoding.UTF8.GetBytes(json);
            var callback = (delegate* unmanaged<nint, DirectBytes, int>)emit;
            fixed (byte* data = bytesIn)
                callback(sink, new DirectBytes { Data = (nint)data, Bytes = (ulong)bytesIn.Length });
        }

        private static string Json(string text)
        {
            if (string.IsNullOrEmpty(text)) return "";
            var sb = new StringBuilder(text.Length + 8);
            foreach (char c in text)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c < 0x20) sb.Append(' ');
                else sb.Append(c);
            }
            return sb.ToString();
        }
    }
}
