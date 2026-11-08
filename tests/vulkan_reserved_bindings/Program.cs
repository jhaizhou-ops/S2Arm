using System;
using System.Linq;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Graphics.Shader;
using Vk = Ryujinx.Graphics.Vulkan.Constants;

// Original synthetic resource requests; no shader/game bytes or graphics device.
var constructor = typeof(Capabilities).GetConstructors().Single();
var parameters = constructor.GetParameters().Select(p => p.HasDefaultValue ? p.DefaultValue :
    p.ParameterType.IsValueType ? Activator.CreateInstance(p.ParameterType) : null).ToArray();
void Set(string name, object value) => parameters[Array.FindIndex(constructor.GetParameters(), p => p.Name == name)] = value;
Set("api", TargetApi.Vulkan);
Set("maximumUniformBuffersPerStage", (uint)Vk.MaxUniformBuffersPerStage);
Set("maximumStorageBuffersPerStage", (uint)Vk.MaxStorageBuffersPerStage);
Set("maximumTexturesPerStage", (uint)Vk.MaxTexturesPerStage);
Set("maximumImagesPerStage", (uint)Vk.MaxImagesPerStage);
var context = new GpuContext { Capabilities = (Capabilities)constructor.Invoke(parameters) };
int failures = 0;
void Check(string label, int binding, int capacity, bool exact = false)
{
    bool pass = binding >= 0 && binding < capacity && (!exact || binding == capacity - 1);
    Console.WriteLine($"{(pass ? "PASS" : "FAIL")} {label}: binding={binding}, capacity={capacity}, exact={exact}");
    if (!pass) failures++;
    else { var slots = new byte[capacity]; slots[binding] = 1; }
}
foreach (bool tf in new[] { false, true })
foreach (bool compute in new[] { false, true })
foreach (int stage in Enumerable.Range(0, 5))
{
    var accessor = new GpuAccessorBase(context, new ResourceCounts(), stage);
    accessor.InitializeReservedCounts(tf, compute);
    string mode = $"stage={stage},tf={tf},vertexAsCompute={compute}";
    Check($"UBO {mode}", accessor.CreateConstantBufferBinding(17).Binding, Vk.MaxUniformBufferBindings,
        stage == 2 && compute);
    Check($"SSBO {mode}", accessor.CreateStorageBufferBinding(15).Binding, Vk.MaxStorageBufferBindings,
        stage == 2 && tf && compute);
    Check($"SSBO actual updater {mode}", accessor.CreateStorageBufferBinding(15).Binding,
        Capacity("_storageBufferRefs", "BufferRef"));
    // Fresh accessor below for each category: regular and buffer requests share a static counter.
    for (int i = 0; i < Vk.MaxTexturesPerStage - 1; i++) accessor.CreateTextureBinding(1, true);
    int texture = accessor.CreateTextureBinding(1, true).Binding;
    Check($"buffer texture {mode}", texture, Capacity("_textureRefs", "TextureRef"), stage == 2 && compute);
    Check($"buffer texture refs {mode}", texture, Capacity("_bufferTextureRefs", "TextureBuffer"), stage == 2 && compute);
    var regular = new GpuAccessorBase(context, new ResourceCounts(), stage);
    regular.InitializeReservedCounts(tf, compute);
    for (int i = 0; i < Vk.MaxTexturesPerStage - 1; i++) regular.CreateTextureBinding(1, false);
    Check($"regular texture {mode}", regular.CreateTextureBinding(1, false).Binding, Capacity("_textureRefs", "TextureRef"));
    for (int i = 0; i < Vk.MaxImagesPerStage - 1; i++) regular.CreateImageBinding(1, true);
    Check($"image unchanged {mode}", regular.CreateImageBinding(1, true).Binding, Vk.MaxImageBindings * 2, stage == 2);
}
Check("diagnostic SSBO slot preserved", S2AStorageOobRecord.Binding, Capacity("_storageBufferRefs", "BufferRef"), true);
Console.WriteLine($"reserved binding failures={failures}");
return failures == 0 ? 0 : 1;

// Read the actual allocation expression rather than duplicating its capacity in the test.
static int Capacity(string fieldName, string elementType)
{
    string source = System.IO.File.ReadAllText("compat/tree/src/Ryujinx.Graphics.Vulkan/DescriptorSetUpdater.cs");
    string pattern = fieldName + " = new " + elementType + @"\[(.*?)\]";
    var match = System.Text.RegularExpressions.Regex.Match(source, pattern);
    if (!match.Success) throw new Exception("Missing production allocation: " + fieldName);
    string expression = match.Groups[1].Value;
    if (expression == "StorageBufferBindings")
        expression = System.Text.RegularExpressions.Regex.Match(source, @"const int StorageBufferBindings = (.*?);").Groups[1].Value;
    expression = expression.Replace("S2AStorageOobRecord.Binding", S2AStorageOobRecord.Binding.ToString());
    foreach (var field in typeof(Vk).GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static))
        if (field.FieldType == typeof(int)) expression = expression.Replace("Constants." + field.Name, field.GetRawConstantValue().ToString());
    return Convert.ToInt32(new System.Data.DataTable().Compute(expression, ""));
}
