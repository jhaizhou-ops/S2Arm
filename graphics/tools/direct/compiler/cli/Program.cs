// 离线直连编译入口：与 NativeAOT 调用同一个 DirectShaderCompiler.Compile。
// bundle：编译后继续打包成引擎的 .xgs（与运行时现编同一条 DirectBundle）。
// 成功才发布结果目录；失败不创建输出、不写半成品。
using S2A.DirectCompiler;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace S2A.DirectCompiler.Cli
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "identity")
            {
                Console.WriteLine(DirectIdentity.Json());
                return 0;
            }
            if (args.Length == 5 && args[0] == "profile" && args[1] == "--caps" && args[3] == "--output")
                return Profile(args[2], args[4]);
            if (args.Length == 5 && args[0] == "bundle" && args[1] == "--request" && args[3] == "--out")
                return Bundle(args[2], args[4]);
            if (args.Length != 5 || args[0] != "compile" || args[1] != "--request" || args[3] != "--output")
            {
                Console.Error.WriteLine("用法: compile  --request <request.json> --output <new-dir>");
                Console.Error.WriteLine("      bundle   --request <request.json> --out <new-dir>");
                Console.Error.WriteLine("      profile  --caps <device-caps.json> --output <new-file>");
                Console.Error.WriteLine("      identity                       # 本构建的翻译闭包身份（JSON）");
                return 2;
            }
            string requestPath = args[2], output = Path.GetFullPath(args[4]);
            if (Directory.Exists(output) || File.Exists(output))
            {
                Console.Error.WriteLine("output already exists: " + output);
                return 2;
            }
            byte[] request;
            try { request = File.ReadAllBytes(requestPath); }
            catch (Exception error) { return Error("REQUEST_IO", error.Message); }
            string staging = output + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                byte[] result = DirectShaderCompiler.Compile(request);
                Directory.CreateDirectory(staging);
                File.WriteAllBytes(Path.Combine(staging, "program.json"), result);
                Directory.Move(staging, output);
                Console.WriteLine("compiled: " + result.Length + " bytes");
                return 0;
            }
            catch (DirectCompileException error)
            {
                return Error(error.Code, error.Message);
            }
            catch (Exception error)
            {
                return Error("INTERNAL", error.GetType().Name + ": " + error.Message);
            }
            finally
            {
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
            }
        }

        // 从设备 caps 合成 enabled profile（与设备端 NativeAOT 的 s2a_direct_profile_json_v1 同一实现）。
        // 出包侧用它生成/核对 graphics.v1.json 里的 profileHash；运行时侧用的是同一函数与同一 caps。
        private static int Profile(string capsPath, string output)
        {
            output = Path.GetFullPath(output);
            if (Directory.Exists(output) || File.Exists(output))
            {
                Console.Error.WriteLine("output already exists: " + output);
                return 2;
            }
            byte[] caps;
            try { caps = File.ReadAllBytes(capsPath); }
            catch (Exception error) { return Error("CAPS_IO", error.Message); }
            string staging = output + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                byte[] profile = DirectProfileComposer.Compose(caps, DirectIdentity.TranslatorClosure);
                File.WriteAllBytes(staging, profile);
                File.Move(staging, output);
                Console.WriteLine("profile: " + profile.Length + " bytes");
                return 0;
            }
            catch (DirectCompileException error)
            {
                return Error(error.Code, error.Message);
            }
            catch (Exception error)
            {
                return Error("INTERNAL", error.GetType().Name + ": " + error.Message);
            }
            finally
            {
                if (File.Exists(staging)) File.Delete(staging);
            }
        }

        // 编译 + 打 .xgs：离线出库与运行时现编同一条 DirectBundle。control 段从请求里的 base64 取。
        private static int Bundle(string requestPath, string output)
        {
            output = Path.GetFullPath(output);
            if (Directory.Exists(output) || File.Exists(output))
            {
                Console.Error.WriteLine("output already exists: " + output);
                return 2;
            }
            byte[] request;
            try { request = File.ReadAllBytes(requestPath); }
            catch (Exception error) { return Error("REQUEST_IO", error.Message); }
            string staging = output + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                var controls = new Dictionary<string, byte[]>();
                using (JsonDocument document = JsonDocument.Parse(request))
                {
                    foreach (JsonElement stage in document.RootElement.GetProperty("program").GetProperty("stages").EnumerateArray())
                    {
                        string name = stage.GetProperty("stage").GetString();
                        if (stage.TryGetProperty("control", out JsonElement control) && control.ValueKind == JsonValueKind.String)
                            controls[name] = Convert.FromBase64String(control.GetString());
                    }
                }
                byte[] program = DirectShaderCompiler.Compile(request);
                List<DirectBundle.Bundle> bundles = DirectBundle.Build(program, controls);
                Directory.CreateDirectory(staging);
                var manifest = new List<object>();
                foreach (DirectBundle.Bundle bundle in bundles)
                {
                    File.WriteAllBytes(Path.Combine(staging, bundle.Key + ".program.json"), bundle.Program);
                    manifest.Add(new { stage = bundle.Stage, key = bundle.Key, bytes = bundle.Program.Length });
                }
                File.WriteAllText(Path.Combine(staging, "manifest.json"),
                    JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }) + "\n");
                Directory.Move(staging, output);
                Console.WriteLine($"bundles: {bundles.Count} -> {output}");
                return 0;
            }
            catch (DirectCompileException error) { return Error(error.Code, error.Message); }
            catch (Exception error) { return Error("INTERNAL", error.GetType().Name + ": " + error.Message); }
            finally
            {
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
            }
        }

        private static int Error(string code, string message)
        {
            Console.Error.WriteLine(JsonSerializer.Serialize(new { error = new { code, message } }));
            return 2;
        }
    }
}
