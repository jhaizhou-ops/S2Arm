using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Buffer = Silk.NET.Vulkan.Buffer;

// CPU-only API boundary recorder. It does not implement Auto/reference counting.
internal unsafe sealed class Dispatch : INativeContext
{
    public static readonly List<object> Events = new();
    public static readonly HashSet<ulong> LiveBuffers = new();
    public static readonly Dictionary<ulong, bool> Fences = new();
    public static readonly Dictionary<ulong, nint> FenceCommands = new();
    public static readonly Dictionary<nint, string> CommandStates = new();
    public static readonly Dictionary<nint, HashSet<ulong>> CommandBuffers = new();
    public static readonly Dictionary<ulong, Dictionary<uint, ulong>> Sets = new();
    public static readonly Dictionary<ulong, Dictionary<uint, ulong>> ImageSets = new();
    public static readonly HashSet<ulong> LiveBufferViews = new();
    public static readonly Dictionary<nint, HashSet<uint>> ActiveSets = new();
    private static readonly Dictionary<nint, Dictionary<uint, ulong>> BoundSets = new();
    private static readonly Dictionary<ulong, DescriptorUpdateTemplateEntry[]> Templates = new();
    public static readonly List<string> Violations = new();
    private static ulong _next = 100;
    private static ulong New() => ++_next;
    public static void Complete(ulong fence)
    {
        Fences[fence] = true;
        if (FenceCommands.TryGetValue(fence, out nint cb)) CommandStates[cb] = "complete";
        Events.Add(new { op = "controlled_fence_complete", fence });
    }
    public static void CompleteAll() { foreach (ulong f in Fences.Keys.ToArray()) Complete(f); }
    [UnmanagedCallersOnly] private static Result CreateBuffer(Device d, BufferCreateInfo* i, AllocationCallbacks* a, Buffer* b)
    { *b = new Buffer(New()); LiveBuffers.Add(b->Handle); Events.Add(new { op="CreateBuffer", buffer=b->Handle, size=i->Size }); return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyBuffer(Device d, Buffer b, AllocationCallbacks* a)
    {
        var refs=CommandBuffers.Where(x=>x.Value.Contains(b.Handle) && CommandStates[x.Key] is "recording" or "pending").Select(x=>new { cb=(long)x.Key, state=CommandStates[x.Key] }).ToArray();
        Events.Add(new { op="DestroyBuffer", buffer=b.Handle, active_references=refs });
        if(refs.Length!=0) Violations.Add($"DestroyBuffer {b.Handle} while recorded/bound by {string.Join(',',refs.Select(x=>x.cb+":"+x.state))}");
        if(!LiveBuffers.Remove(b.Handle)) Violations.Add("DestroyBuffer double/unknown "+b.Handle);
    }
    [UnmanagedCallersOnly] private static void DestroyImageView(Device d, ImageView v, AllocationCallbacks* a)
    { Events.Add(new { op="DestroyImageView", image_view=v.Handle }); }
    [UnmanagedCallersOnly] private static Result CreateBufferView(Device d, BufferViewCreateInfo* i, AllocationCallbacks* a, BufferView* v)
    { *v=new BufferView(New());LiveBufferViews.Add(v->Handle);Events.Add(new { op="CreateBufferView", view=v->Handle, buffer=i->Buffer.Handle, format=(int)i->Format, offset=i->Offset, range=i->Range });return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyBufferView(Device d, BufferView v, AllocationCallbacks* a)
    { LiveBufferViews.Remove(v.Handle);Events.Add(new { op="DestroyBufferView", view=v.Handle }); }
    [UnmanagedCallersOnly] private static Result AllocateMemory(Device d, MemoryAllocateInfo* i, AllocationCallbacks* a, DeviceMemory* m)
    { *m=new DeviceMemory(New()); Events.Add(new { op="AllocateMemory", memory=m->Handle, size=i->AllocationSize }); return Result.Success; }
    [UnmanagedCallersOnly] private static void FreeMemory(Device d, DeviceMemory m, AllocationCallbacks* a) { Events.Add(new { op="FreeMemory", memory=m.Handle }); }
    [UnmanagedCallersOnly] private static Result BindBufferMemory(Device d,Buffer b,DeviceMemory m,ulong o) { Events.Add(new { op="BindBufferMemory", buffer=b.Handle,memory=m.Handle,offset=o });return Result.Success; }
    [UnmanagedCallersOnly] private static Result CreatePool(Device d,CommandPoolCreateInfo* i,AllocationCallbacks* a,CommandPool* p) { *p=new CommandPool(New());return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyPool(Device d,CommandPool p,AllocationCallbacks* a) { Events.Add(new {op="DestroyCommandPool",pool=p.Handle}); }
    [UnmanagedCallersOnly] private static Result AllocateCommands(Device d,CommandBufferAllocateInfo* i,CommandBuffer* b)
    { for(int k=0;k<i->CommandBufferCount;k++){ b[k]=new CommandBuffer((nint)New());CommandStates[b[k].Handle]="initial";CommandBuffers[b[k].Handle]=new();BoundSets[b[k].Handle]=new();}return Result.Success; }
    [UnmanagedCallersOnly] private static Result Begin(CommandBuffer b,CommandBufferBeginInfo* i)
    { CommandStates[b.Handle]="recording";CommandBuffers[b.Handle].Clear();BoundSets[b.Handle].Clear();Events.Add(new {op="BeginCommandBuffer",cb=(long)b.Handle});return Result.Success; }
    [UnmanagedCallersOnly] private static Result End(CommandBuffer b) {Events.Add(new {op="EndCommandBuffer",cb=(long)b.Handle});return Result.Success;}
    [UnmanagedCallersOnly] private static Result Submit(Queue q,uint n,SubmitInfo* s,Fence f)
    {for(int j=0;j<n;j++)for(int k=0;k<s[j].CommandBufferCount;k++){nint cb=s[j].PCommandBuffers[k].Handle;CommandStates[cb]="pending";FenceCommands[f.Handle]=cb;Events.Add(new {op="QueueSubmit",cb=(long)cb,fence=f.Handle});}return Result.Success;}
    [UnmanagedCallersOnly] private static Result CreateFence(Device d,FenceCreateInfo* i,AllocationCallbacks* a,Fence* f) { *f=new Fence(New());Fences[f->Handle]=false;return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyFence(Device d,Fence f,AllocationCallbacks* a) {Fences.Remove(f.Handle);FenceCommands.Remove(f.Handle);}
    [UnmanagedCallersOnly] private static Result Wait(Device d,uint n,Fence* fs,uint all,ulong timeout)
    { bool ready=true;for(int i=0;i<n;i++)ready&=Fences[fs[i].Handle];Events.Add(new {op="WaitForFences",fence=n==1?fs[0].Handle:0,ready,timeout});return ready?Result.Success:Result.Timeout; }
    [UnmanagedCallersOnly] private static Result Layout(Device d,DescriptorSetLayoutCreateInfo* i,AllocationCallbacks* a,DescriptorSetLayout* l) { *l=new DescriptorSetLayout(New());Events.Add(new {op="CreateDescriptorSetLayout",layout=l->Handle,flags=(uint)i->Flags,has_binding_flags_chain=i->PNext!=null});return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyLayout(Device d,DescriptorSetLayout l,AllocationCallbacks* a) { }
    [UnmanagedCallersOnly] private static Result PipelineLayout(Device d,PipelineLayoutCreateInfo* i,AllocationCallbacks* a,Silk.NET.Vulkan.PipelineLayout* l) { *l=new Silk.NET.Vulkan.PipelineLayout(New());return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyPipelineLayout(Device d,Silk.NET.Vulkan.PipelineLayout l,AllocationCallbacks* a) { }
    [UnmanagedCallersOnly] private static Result DescriptorPool(Device d,DescriptorPoolCreateInfo* i,AllocationCallbacks* a,Silk.NET.Vulkan.DescriptorPool* p) { *p=new Silk.NET.Vulkan.DescriptorPool(New());return Result.Success; }
    [UnmanagedCallersOnly] private static void DestroyDescriptorPool(Device d,Silk.NET.Vulkan.DescriptorPool p,AllocationCallbacks* a) { }
    [UnmanagedCallersOnly] private static Result AllocateSets(Device d,DescriptorSetAllocateInfo* i,DescriptorSet* s)
    {for(int k=0;k<i->DescriptorSetCount;k++){s[k]=new DescriptorSet(New());Sets[s[k].Handle]=new();ImageSets[s[k].Handle]=new();Events.Add(new {op="AllocateDescriptorSet",set=s[k].Handle});}return Result.Success;}
    [UnmanagedCallersOnly] private static Result FreeSets(Device d,Silk.NET.Vulkan.DescriptorPool p,uint n,DescriptorSet* s) {return Result.Success;}
    [UnmanagedCallersOnly] private static Result Template(Device d,DescriptorUpdateTemplateCreateInfo* i,AllocationCallbacks* a,DescriptorUpdateTemplate* t)
    {*t=new DescriptorUpdateTemplate(New());Templates[t->Handle]=new ReadOnlySpan<DescriptorUpdateTemplateEntry>(i->PDescriptorUpdateEntries,(int)i->DescriptorUpdateEntryCount).ToArray();return Result.Success;}
    [UnmanagedCallersOnly] private static void DestroyTemplate(Device d,DescriptorUpdateTemplate t,AllocationCallbacks* a) {Templates.Remove(t.Handle);}
    private static bool IsImageType(DescriptorType type) =>
        type is DescriptorType.SampledImage or DescriptorType.CombinedImageSampler or
        DescriptorType.StorageImage or DescriptorType.InputAttachment;
    private static void WriteSet(ulong set,uint binding,DescriptorBufferInfo info)
    {Sets[set][binding]=info.Buffer.Handle;Events.Add(new {op="UpdateDescriptor",set,binding,buffer=info.Buffer.Handle,offset=info.Offset,range=info.Range});}
    private static void WriteImageSet(ulong set,uint binding,DescriptorImageInfo info)
    {ImageSets[set][binding]=info.ImageView.Handle;Events.Add(new {op="UpdateDescriptorImage",set,binding,image_view=info.ImageView.Handle,sampler=info.Sampler.Handle,layout=(int)info.ImageLayout});}
    [UnmanagedCallersOnly] private static void UpdateTemplate(Device d,DescriptorSet s,DescriptorUpdateTemplate t,void* data)
    {
        foreach(var e in Templates[t.Handle])
            for(int k=0;k<e.DescriptorCount;k++)
            {
                byte* item=(byte*)data+e.Offset+(nuint)k*e.Stride;
                if(IsImageType(e.DescriptorType))WriteImageSet(s.Handle,e.DstBinding+(uint)k,*(DescriptorImageInfo*)item);
                else WriteSet(s.Handle,e.DstBinding+(uint)k,*(DescriptorBufferInfo*)item);
            }
    }
    [UnmanagedCallersOnly] private static void Update(Device d,uint n,WriteDescriptorSet* writes,uint copyN,CopyDescriptorSet* copies)
    {
        for(int j=0;j<n;j++)
            for(int k=0;k<writes[j].DescriptorCount;k++)
            {
                if(IsImageType(writes[j].DescriptorType))WriteImageSet(writes[j].DstSet.Handle,writes[j].DstBinding+(uint)k,writes[j].PImageInfo[k]);
                else WriteSet(writes[j].DstSet.Handle,writes[j].DstBinding+(uint)k,writes[j].PBufferInfo[k]);
            }
    }
    [UnmanagedCallersOnly] private static void BindSets(CommandBuffer cb,PipelineBindPoint p,Silk.NET.Vulkan.PipelineLayout l,uint first,uint count,DescriptorSet* sets,uint dc,uint* offsets)
    {for(int i=0;i<count;i++){var state=Sets[sets[i].Handle];BoundSets[cb.Handle][first+(uint)i]=sets[i].Handle;Events.Add(new {op="BindDescriptorSet",cb=(long)cb.Handle,set=sets[i].Handle,bindings=state.ToDictionary(x=>x.Key,x=>x.Value)});}}
    [UnmanagedCallersOnly] private static void Action(CommandBuffer cb,uint x,uint y,uint z)
    {
        // Fixed VVL cc_state_tracker.cpp UpdateActiveSlotsState adds the entire ordinary
        // descriptor set on an action, not on bind alone. Active set IDs come from the
        // real ShaderCollection.BindingSegments supplied by the caller fixture.
        foreach(uint index in ActiveSets[cb.Handle])
        {
            ulong set=BoundSets[cb.Handle][index];
            foreach(ulong b in Sets[set].Values)if(b!=0)CommandBuffers[cb.Handle].Add(b);
            Events.Add(new {op="CmdDispatch_active_set",cb=(long)cb.Handle,set,index,bindings=Sets[set].ToDictionary(a=>a.Key,a=>a.Value)});
        }
    }
    public nint GetProcAddress(string n,int? slot=null)=>n switch
    {
        "vkCmdDispatch"=>(nint)(delegate* unmanaged<CommandBuffer,uint,uint,uint,void>)&Action,
        "vkCreateBuffer"=>(nint)(delegate* unmanaged<Device,BufferCreateInfo*,AllocationCallbacks*,Buffer*,Result>)&CreateBuffer,
        "vkDestroyBuffer"=>(nint)(delegate* unmanaged<Device,Buffer,AllocationCallbacks*,void>)&DestroyBuffer,
        "vkDestroyImageView"=>(nint)(delegate* unmanaged<Device,ImageView,AllocationCallbacks*,void>)&DestroyImageView,
        "vkCreateBufferView"=>(nint)(delegate* unmanaged<Device,BufferViewCreateInfo*,AllocationCallbacks*,BufferView*,Result>)&CreateBufferView,
        "vkDestroyBufferView"=>(nint)(delegate* unmanaged<Device,BufferView,AllocationCallbacks*,void>)&DestroyBufferView,
        "vkAllocateMemory"=>(nint)(delegate* unmanaged<Device,MemoryAllocateInfo*,AllocationCallbacks*,DeviceMemory*,Result>)&AllocateMemory,
        "vkFreeMemory"=>(nint)(delegate* unmanaged<Device,DeviceMemory,AllocationCallbacks*,void>)&FreeMemory,
        "vkBindBufferMemory"=>(nint)(delegate* unmanaged<Device,Buffer,DeviceMemory,ulong,Result>)&BindBufferMemory,
        "vkCreateCommandPool"=>(nint)(delegate* unmanaged<Device,CommandPoolCreateInfo*,AllocationCallbacks*,CommandPool*,Result>)&CreatePool,
        "vkDestroyCommandPool"=>(nint)(delegate* unmanaged<Device,CommandPool,AllocationCallbacks*,void>)&DestroyPool,
        "vkAllocateCommandBuffers"=>(nint)(delegate* unmanaged<Device,CommandBufferAllocateInfo*,CommandBuffer*,Result>)&AllocateCommands,
        "vkBeginCommandBuffer"=>(nint)(delegate* unmanaged<CommandBuffer,CommandBufferBeginInfo*,Result>)&Begin,
        "vkEndCommandBuffer"=>(nint)(delegate* unmanaged<CommandBuffer,Result>)&End,
        "vkQueueSubmit"=>(nint)(delegate* unmanaged<Queue,uint,SubmitInfo*,Fence,Result>)&Submit,
        "vkCreateFence"=>(nint)(delegate* unmanaged<Device,FenceCreateInfo*,AllocationCallbacks*,Fence*,Result>)&CreateFence,
        "vkDestroyFence"=>(nint)(delegate* unmanaged<Device,Fence,AllocationCallbacks*,void>)&DestroyFence,
        "vkWaitForFences"=>(nint)(delegate* unmanaged<Device,uint,Fence*,uint,ulong,Result>)&Wait,
        "vkCreateDescriptorSetLayout"=>(nint)(delegate* unmanaged<Device,DescriptorSetLayoutCreateInfo*,AllocationCallbacks*,DescriptorSetLayout*,Result>)&Layout,
        "vkDestroyDescriptorSetLayout"=>(nint)(delegate* unmanaged<Device,DescriptorSetLayout,AllocationCallbacks*,void>)&DestroyLayout,
        "vkCreatePipelineLayout"=>(nint)(delegate* unmanaged<Device,PipelineLayoutCreateInfo*,AllocationCallbacks*,Silk.NET.Vulkan.PipelineLayout*,Result>)&PipelineLayout,
        "vkDestroyPipelineLayout"=>(nint)(delegate* unmanaged<Device,Silk.NET.Vulkan.PipelineLayout,AllocationCallbacks*,void>)&DestroyPipelineLayout,
        "vkCreateDescriptorPool"=>(nint)(delegate* unmanaged<Device,DescriptorPoolCreateInfo*,AllocationCallbacks*,Silk.NET.Vulkan.DescriptorPool*,Result>)&DescriptorPool,
        "vkDestroyDescriptorPool"=>(nint)(delegate* unmanaged<Device,Silk.NET.Vulkan.DescriptorPool,AllocationCallbacks*,void>)&DestroyDescriptorPool,
        "vkAllocateDescriptorSets"=>(nint)(delegate* unmanaged<Device,DescriptorSetAllocateInfo*,DescriptorSet*,Result>)&AllocateSets,
        "vkFreeDescriptorSets"=>(nint)(delegate* unmanaged<Device,Silk.NET.Vulkan.DescriptorPool,uint,DescriptorSet*,Result>)&FreeSets,
        "vkCreateDescriptorUpdateTemplate"=>(nint)(delegate* unmanaged<Device,DescriptorUpdateTemplateCreateInfo*,AllocationCallbacks*,DescriptorUpdateTemplate*,Result>)&Template,
        "vkDestroyDescriptorUpdateTemplate"=>(nint)(delegate* unmanaged<Device,DescriptorUpdateTemplate,AllocationCallbacks*,void>)&DestroyTemplate,
        "vkUpdateDescriptorSetWithTemplate"=>(nint)(delegate* unmanaged<Device,DescriptorSet,DescriptorUpdateTemplate,void*,void>)&UpdateTemplate,
        "vkUpdateDescriptorSets"=>(nint)(delegate* unmanaged<Device,uint,WriteDescriptorSet*,uint,CopyDescriptorSet*,void>)&Update,
        "vkCmdBindDescriptorSets"=>(nint)(delegate* unmanaged<CommandBuffer,PipelineBindPoint,Silk.NET.Vulkan.PipelineLayout,uint,uint,DescriptorSet*,uint,uint*,void>)&BindSets,
        _=>0,
    };
    public bool TryGetProcAddress(string n,out nint p,int? slot=null){p=GetProcAddress(n,slot);return p!=0;}
    public void Dispose(){}
}
