using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using S2Arm.Backends.Vulkan.ProgramCache;
using Silk.NET.Shaderc;
using Silk.NET.Vulkan;
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Ryujinx.Graphics.Vulkan
{
    class Shader : IDisposable
    {
        private static readonly nint _ptrMainEntryPointName = Marshal.StringToHGlobalAnsi("main");
        private static readonly bool S2ATimingDiagnostics = Environment.GetEnvironmentVariable("S2A_SHADER_CACHE_DIAG") == "1";
        private static long _s2aModCount, _s2aModMs, _s2aModMax, _s2aModSlow, _s2aModReported;

        // S2A：启动期 GPU 线程纯用户态 CPU；统计 vkCreateShaderModule 实际耗时（驱动编译）。
        private static void S2AReportModuleTime(long start)
        {
            if (!S2ATimingDiagnostics) return;
            double ms = (System.Diagnostics.Stopwatch.GetTimestamp() - start) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
            _s2aModCount++;
            _s2aModMs += (long)ms;
            if ((long)ms > _s2aModMax) _s2aModMax = (long)ms;
            if (ms > 50) _s2aModSlow++;
            long now = Environment.TickCount64;
            if (now - _s2aModReported >= 5000)
            {
                _s2aModReported = now;
                Console.Error.WriteLine($"[vkpb] 着色器模块：{_s2aModCount} 个、总 {_s2aModMs} ms、max {_s2aModMax} ms、>50ms {_s2aModSlow}");
                _s2aModCount = _s2aModMs = _s2aModMax = _s2aModSlow = 0;
            }
        }

        // GLSL is compiled for the device's own Vulkan version: SPIR-V 1.5 is not valid on a
        // Vulkan 1.1 device, and Adreno's 1.1 driver rejects it at vkCreateShaderModule time.
        internal static uint TargetVulkanVersion = Vk.Version12.Value;

        private readonly Vk _api;
        private readonly Device _device;
        private readonly ShaderStageFlags _stage;
        private readonly CompileWorker _s2aWorker;

        private bool _disposed;
        private ShaderModule _module;

        public ShaderStageFlags StageFlags => _stage;

        public ProgramLinkStatus CompileStatus { private set; get; }

        public readonly Task CompileTask;

        public Shader(VulkanRenderer gd, Device device, ShaderSource shaderSource)
        {
            _api = gd.Api;
            _device = device;
            _s2aWorker = gd.S2ACompileWorker;

            CompileStatus = ProgramLinkStatus.Incomplete;

            _stage = shaderSource.Stage.Convert();

            CompileTask = _s2aWorker == null
                ? Task.Run(() => CreateModule(shaderSource))
                : _s2aWorker.Run(() => { CreateModule(shaderSource); return true; });
        }

        private unsafe void CreateModule(ShaderSource shaderSource)
        {
            byte[] spirv = shaderSource.BinaryCode;

            if (spirv == null)
            {
                spirv = GlslToSpirv(shaderSource.Code, shaderSource.Stage);

                if (spirv == null)
                {
                    CompileStatus = ProgramLinkStatus.Failure;

                    return;
                }
            }

            fixed (byte* pCode = spirv)
            {
                ShaderModuleCreateInfo shaderModuleCreateInfo = new()
                {
                    SType = StructureType.ShaderModuleCreateInfo,
                    CodeSize = (uint)spirv.Length,
                    PCode = (uint*)pCode,
                };

                long s2aModuleStart = S2ATimingDiagnostics ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
                _api.CreateShaderModule(_device, in shaderModuleCreateInfo, null, out _module).ThrowOnError();
                S2AReportModuleTime(s2aModuleStart);
            }

            CompileStatus = ProgramLinkStatus.Success;
        }

        private unsafe static byte[] GlslToSpirv(string glsl, ShaderStage stage)
        {
            Shaderc api = Shaderc.GetApi();
            Compiler* compiler = api.CompilerInitialize();
            CompileOptions* options = api.CompileOptionsInitialize();

            api.CompileOptionsSetSourceLanguage(options, SourceLanguage.Glsl);
            api.CompileOptionsSetTargetSpirv(options,
                TargetVulkanVersion >= Vk.Version12.Value ? SpirvVersion.Shaderc15 : SpirvVersion.Shaderc13);
            api.CompileOptionsSetTargetEnv(options, TargetEnv.Vulkan, TargetVulkanVersion);

            CompilationResult* scr = api.CompileIntoSpv(compiler, glsl, (nuint)glsl.Length, GetShaderCShaderStage(stage), "Ryu", "main", options);

            CompilationStatus status = api.ResultGetCompilationStatus(scr);

            if (status != CompilationStatus.Success)
            {
                Logger.Error?.Print(LogClass.Gpu, $"Shader compilation error: {status} {api.ResultGetErrorMessageS(scr)}");

                return null;
            }

            Span<byte> spirvBytes = new(api.ResultGetBytes(scr), (int)api.ResultGetLength(scr));

            byte[] code = new byte[(spirvBytes.Length + 3) & ~3];

            spirvBytes.CopyTo(code.AsSpan()[..spirvBytes.Length]);

            api.CompilerRelease(compiler);
            api.CompileOptionsRelease(options);

            return code;
        }

        private static ShaderKind GetShaderCShaderStage(ShaderStage stage)
        {
            switch (stage)
            {
                case ShaderStage.Vertex:
                    return ShaderKind.GlslVertexShader;
                case ShaderStage.Geometry:
                    return ShaderKind.GlslGeometryShader;
                case ShaderStage.TessellationControl:
                    return ShaderKind.GlslTessControlShader;
                case ShaderStage.TessellationEvaluation:
                    return ShaderKind.GlslTessEvaluationShader;
                case ShaderStage.Fragment:
                    return ShaderKind.GlslFragmentShader;
                case ShaderStage.Compute:
                    return ShaderKind.GlslComputeShader;
            }

            Logger.Debug?.Print(LogClass.Gpu, $"Invalid {nameof(ShaderStage)} enum value: {stage}.");

            return ShaderKind.GlslVertexShader;
        }

        public unsafe PipelineShaderStageCreateInfo GetInfo()
        {
            return new PipelineShaderStageCreateInfo
            {
                SType = StructureType.PipelineShaderStageCreateInfo,
                Stage = _stage,
                Module = _module,
                PName = (byte*)_ptrMainEntryPointName,
            };
        }

        public void WaitForCompile(Action pump)
        {
            if (_s2aWorker == null)
            {
                CompileTask.Wait();
                return;
            }

            _s2aWorker.Wait(CompileTask, pump);
        }

        public unsafe void Dispose()
        {
            if (!_disposed)
            {
                _api.DestroyShaderModule(_device, _module, null);
                _disposed = true;
            }
        }
    }
}
