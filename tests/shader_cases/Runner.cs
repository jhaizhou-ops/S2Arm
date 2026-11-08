// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.IO;
using System.Runtime.InteropServices;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
namespace Ryujinx.Common { static class EmbeddedResources { public static string ReadAllText(string name) => throw new InvalidOperationException(name); } }
sealed class Accessor(byte[] code, bool clamp=false) : IGpuAccessor
{
    public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte,ulong>(code.AsSpan(checked((int)address)));
    public SetBindingPair CreateConstantBufferBinding(int index) => new(0,index+1);
    public SetBindingPair CreateStorageBufferBinding(int index) => new(1,index);
    public SetBindingPair CreateImageBinding(int count,bool isBuffer) => new(3,0);
    public SetBindingPair CreateTextureBinding(int count,bool isBuffer) => new(2,0);
    public int CreateExtraSet()=>4;
    public int QuerySamplerArrayLengthFromPool()=>8;
    public int QueryTextureArrayLengthFromBuffer(int slot)=>8;
    public int QueryTextureArrayLengthFromPool()=>8;
    public GpuGraphicsState QueryGraphicsState()=>new(false,InputTopology.Triangles,false,TessPatchType.Triangles,TessSpacing.EqualSpacing,false,false,false,true,false,1f,AlphaTestOp.Always,0f,default,false,default,false,false,true,false);
    public bool QueryHostStorageWindowClamp()=>clamp;
    public bool QueryS2ARuntimeState()=>false;
    public bool QueryHostSupportsShaderFloat64()=>false;
    // The harness logical VkDevice never enables VK_EXT_fragment_shader_interlock.
    // These eight fixtures do not need it; physical-device support is not enough.
    public bool QueryHostSupportsFragmentShaderInterlock()=>false;
}
class Runner
{
    static int Main(string[] args)
    {
        var manifest=System.Text.Json.JsonDocument.Parse(File.ReadAllText(args[0]));
        foreach(var item in manifest.RootElement.EnumerateArray()) {
            foreach(bool clamp in args.Length>2 && args[2]=="--probe-clamp" && item.GetProperty("stage").GetString()=="compute"?new[]{false,true}:new[]{false}) {
                IrEvidence.Reset(item.GetProperty("id").GetString(),clamp);
                var gpu=new Accessor(File.ReadAllBytes(item.GetProperty("binary").GetString()),clamp);
                var flags=item.GetProperty("stage").GetString()=="compute"?TranslationFlags.Compute:TranslationFlags.None;
                var context=Translator.CreateContext(0,gpu,new(TargetLanguage.Spirv,TargetApi.Vulkan,flags));
                ShaderProgram program;
                try { program=context.Translate(); }
                catch {
                    File.WriteAllText(args[1]+".final",System.Text.Json.JsonSerializer.Serialize(IrEvidence.Final));
                    throw;
                }
                File.WriteAllBytes(item.GetProperty("spirv").GetString()+(clamp?".clamped":""),program.BinaryCode);
            }
        }
        File.WriteAllText(args[1],System.Text.Json.JsonSerializer.Serialize(IrEvidence.Events));
        File.WriteAllText(args[1]+".final",System.Text.Json.JsonSerializer.Serialize(IrEvidence.Final));
        return 0;
    }
}
