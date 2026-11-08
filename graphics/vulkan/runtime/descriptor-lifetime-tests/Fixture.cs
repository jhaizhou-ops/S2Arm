using System;
using System.Linq;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using Ryujinx.Graphics.GAL;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;
using Buffer=Silk.NET.Vulkan.Buffer;
using GalFormat=Ryujinx.Graphics.GAL.Format;

internal unsafe static class Proof
{
    private static int _checks;
    private static void Check(bool b,string message){_checks++;if(!b)throw new Exception(message);}
    private static void Set(object obj,string name,object value)=>obj.GetType().GetField(name,BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic)!.SetValue(obj,value);
    private static VulkanRenderer Renderer(Vk api,CommandBufferPool pool)
    {
        var r=(VulkanRenderer)RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
        Set(r,"<Api>k__BackingField",api);Set(r,"<CommandBufferPool>k__BackingField",pool);
        Set(r,"<PipelineLayoutCache>k__BackingField",new PipelineLayoutCache());Set(r,"<Shaders>k__BackingField",new HashSet<ShaderCollection>());
        return r;
    }
    private static BufferHolder NewBuffer(VulkanRenderer r,Device device,MemoryAllocatorBlockList allocator)
    {
        BufferCreateInfo info=new(){SType=StructureType.BufferCreateInfo,Size=4096,Usage=BufferUsageFlags.StorageBufferBit|BufferUsageFlags.UniformBufferBit};
        r.Api.CreateBuffer(device,in info,null,out Buffer buffer).ThrowOnError();
        var allocation=allocator.Allocate(4096,256,false);
        r.Api.BindBufferMemory(device,buffer,allocation.Memory,allocation.Offset).ThrowOnError();
        return new BufferHolder(r,device,buffer,allocation,4096,BufferAllocationType.DeviceLocal,BufferAllocationType.DeviceLocal);
    }
    private static void Basic()
    {
        using Vk api=new(new Dispatch());var device=new Device(1);
        using var pool=new CommandBufferPool(api,device,new Queue(2),new Lock(),0,false);
        using var allocator=new MemoryAllocatorBlockList(api,device,0,4096,true);
        var renderer=Renderer(api,pool);var holder=NewBuffer(renderer,device,allocator);
        ulong handle=holder.GetBuffer().GetUnsafe().Value.Handle;
        var first=pool.Rent();var second=pool.Rent();
        Check(first.CommandBufferIndex!=second.CommandBufferIndex,"two recording CB indices differ");
        holder.GetBuffer().Get(first,0,64);holder.GetBuffer().Get(first,0,64);holder.GetBuffer().Get(second,64,64);
        pool.Return(first);holder.Dispose();
        Check(Dispatch.LiveBuffers.Contains(handle),"owner delete cannot destroy while recording+inflight dependencies remain");
        Check(!pool.CollectCompleted(),"inflight fence remains uncompleted");
        Dispatch.Complete(first.GetFence().GetUnsafe().Handle);Check(pool.CollectCompleted(),"first completion collected");
        Check(Dispatch.LiveBuffers.Contains(handle),"recording second CB still retains buffer");
        pool.Return(second);Check(!pool.CollectCompleted(),"second remains pending");
        Dispatch.Complete(second.GetFence().GetUnsafe().Handle);Check(pool.CollectCompleted(),"second completion collected");
        Check(!Dispatch.LiveBuffers.Contains(handle),"real Auto final ref destroys buffer after both CBs complete");
        Check(Dispatch.Violations.Count==0,"no recorded-bound lifetime violation");
    }
    private static DescriptorSetUpdater Updater(VulkanRenderer r,Device d,BufferHolder dummy)
    {
        // Setup-only metadata: omit unrelated dummy image/sampler allocation. All methods under
        // test, templates, descriptor allocation/caching and resource reference counting are real.
        var u=(DescriptorSetUpdater)RuntimeHelpers.GetUninitializedObject(typeof(DescriptorSetUpdater));
        Set(u,"_gd",r);Set(u,"_device",d);Set(u,"_dummyBuffer",dummy);Set(u,"_templateUpdater",new DescriptorSetTemplateUpdater());
        foreach(var f in typeof(DescriptorSetUpdater).GetFields(BindingFlags.NonPublic|BindingFlags.Instance))
        {
            if(f.FieldType.IsArray)
            {
                int n=f.Name.StartsWith("_uniform")?Constants.MaxUniformBufferBindings
                    :f.Name.StartsWith("_storage")?Constants.MaxStorageBufferBindings
                    :f.Name.StartsWith("_image")||f.Name.StartsWith("_bufferImage")?Constants.MaxImageBindings*2
                    :f.Name.StartsWith("_texture")||f.Name.StartsWith("_bufferTexture")?Constants.MaxTextureBindings*2+Constants.ReservedTextureBindings:0;
                f.SetValue(u,Array.CreateInstance(f.FieldType.GetElementType()!,n));
            }
        }
        return u;
    }
    private static ShaderCollection Program(VulkanRenderer r,Device d,int[] used,bool uniform=false)
    {
        var sets=new ResourceDescriptorCollection[4];var usages=new ResourceUsageCollection[4];
        for(int i=0;i<4;i++)
        {
            var ds=i==(uniform?0:1)?new[]{new ResourceDescriptor(0,1,uniform?ResourceType.UniformBuffer:ResourceType.StorageBuffer,ResourceStages.Compute),new ResourceDescriptor(1,1,uniform?ResourceType.UniformBuffer:ResourceType.StorageBuffer,ResourceStages.Compute)}:Array.Empty<ResourceDescriptor>();
            var us=i==(uniform?0:1)?used.Select(b=>new ResourceUsage(b,1,uniform?ResourceType.UniformBuffer:ResourceType.StorageBuffer,ResourceStages.Compute,!uniform)).ToArray():Array.Empty<ResourceUsage>();
            sets[i]=new ResourceDescriptorCollection(Array.AsReadOnly(ds));usages[i]=new ResourceUsageCollection(Array.AsReadOnly(us));
        }
        // No shader module or pipeline is executed. Real ShaderCollection builds descriptor
        // usages/clear segments/templates and shares layouts from the actual resource metadata.
        return new ShaderCollection(r,d,Array.Empty<ShaderSource>(),new ResourceLayout(Array.AsReadOnly(sets),Array.AsReadOnly(usages)));
    }
    private static void Bind(DescriptorSetUpdater u,CommandBufferScoped cb,ShaderCollection p,params Auto<DisposableBuffer>[] buffers)
    {
        u.SetProgram(cb,p,false);
        if(p.BindingSegments[0].Length!=0)SeedUniform(u,buffers);else u.SetStorageBuffers(cb.CommandBuffer,0,buffers);
        u.UpdateAndBindDescriptorSets(cb,PipelineBindPoint.Compute);
        Action(u,cb,p);
    }
    private static void SeedUniform(DescriptorSetUpdater updater,Auto<DisposableBuffer>[] buffers)
    {
        // Setup actual private buffer reference/descriptor metadata; the production
        // updater, template writes and Auto.Get/CB dependencies are not replaced.
        var field=typeof(DescriptorSetUpdater).GetField("_uniformBufferRefs",BindingFlags.NonPublic|BindingFlags.Instance)!;
        Array refs=(Array)field.GetValue(updater)!;
        var infos=(DescriptorBufferInfo[])typeof(DescriptorSetUpdater).GetField("_uniformBuffers",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!;
        for(int i=0;i<buffers.Length;i++)
        {
            object reference=Activator.CreateInstance(field.FieldType.GetElementType()!)!;
            Set(reference,"Buffer",buffers[i]);Set(reference,"Offset",0);Set(reference,"Write",false);refs.SetValue(reference,i);infos[i]=new(){Range=4096};
        }
    }
    private static void Action(DescriptorSetUpdater u,CommandBufferScoped cb,ShaderCollection p)
    {
        Dispatch.ActiveSets[cb.CommandBuffer.Handle]=p.BindingSegments.Select((segments,i)=>(segments,i)).Where(x=>x.segments.Length!=0).Select(x=>(uint)x.i).ToHashSet();
        var r=(VulkanRenderer)typeof(DescriptorSetUpdater).GetField("_gd",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(u)!;
        r.Api.CmdDispatch(cb.CommandBuffer,1,1,1);
    }
    private static void Descriptors(string mode,bool uniform=false)
    {
        using Vk api=new(new Dispatch());var device=new Device(1);
        using var pool=new CommandBufferPool(api,device,new Queue(2),new Lock(),0,false);
        using var allocator=new MemoryAllocatorBlockList(api,device,0,4096,true);
        var renderer=Renderer(api,pool);var dummy=NewBuffer(renderer,device,allocator);
        var a=NewBuffer(renderer,device,allocator);var b=NewBuffer(renderer,device,allocator);
        ulong ah=a.GetBuffer().GetUnsafe().Value.Handle,bh=b.GetBuffer().GetUnsafe().Value.Handle;
        var updater=Updater(renderer,device,dummy);
        using var all=Program(renderer,device,new[]{0,1},uniform);using var one=Program(renderer,device,new[]{1},uniform);
        var first=pool.Rent();updater.SignalCommandBufferChange();Bind(updater,first,all,a.GetBuffer(),b.GetBuffer());
        Check(Dispatch.Sets.Values.Any(x=>x.GetValueOrDefault(0u)==ah&&x.GetValueOrDefault(1u)==bh),"actual template writes both real buffer handles");
        ulong set=Dispatch.Sets.Single(x=>x.Value.GetValueOrDefault(0u)==ah&&x.Value.GetValueOrDefault(1u)==bh).Key;
        if(mode=="rotate")
        {
            var cbs=new List<CommandBufferScoped>{first};
            for(int i=1;i<CommandBufferPool.MaxCommandBuffers;i++){var cb=pool.Rent();updater.SignalCommandBufferChange();Bind(updater,cb,all,a.GetBuffer(),b.GetBuffer());cbs.Add(cb);}
            Check(cbs.Select(x=>x.CommandBufferIndex).Distinct().Count()==16,"all 16 real CB indices used");
            foreach(var cb in cbs)pool.Return(cb);
            foreach(var cb in cbs){Dispatch.Complete(cb.GetFence().GetUnsafe().Handle);pool.CollectCompleted();}
            cbs.Clear();
            for(int i=0;i<16;i++){var cb=pool.Rent();updater.SignalCommandBufferChange();Bind(updater,cb,all,a.GetBuffer(),b.GetBuffer());cbs.Add(cb);}
            Check(Dispatch.Sets.Count==16,"same 16 cached sets reused on second rotation");
            a.Dispose();b.Dispose();
            foreach(var cb in cbs)pool.Return(cb);
            for(int i=0;i<cbs.Count;i++){Dispatch.Complete(cbs[i].GetFence().GetUnsafe().Handle);pool.CollectCompleted();Check(Dispatch.LiveBuffers.Contains(ah)==(i<15),"owner lifetime follows last of 16 dependencies");}
        }
        else if(mode=="descriptor-basic")
        {
            var second=pool.Rent();updater.SignalCommandBufferChange();Bind(updater,second,all,a.GetBuffer(),b.GetBuffer());
            pool.Return(first);a.Dispose();b.Dispose();Check(Dispatch.LiveBuffers.Contains(ah)&&Dispatch.LiveBuffers.Contains(bh),"descriptor owner deletion protected by both CBs");
            Dispatch.Complete(first.GetFence().GetUnsafe().Handle);pool.CollectCompleted();Check(Dispatch.LiveBuffers.Contains(ah),"second recording descriptor retains source");
            pool.Return(second);Dispatch.Complete(second.GetFence().GetUnsafe().Handle);pool.CollectCompleted();Check(!Dispatch.LiveBuffers.Contains(ah)&&!Dispatch.LiveBuffers.Contains(bh),"last descriptor reference releases real buffers");
        }
        else
        {
            pool.Return(first);Dispatch.Complete(first.GetFence().GetUnsafe().Handle);pool.CollectCompleted();
            var next=pool.Rent();Check(next.CommandBufferIndex==first.CommandBufferIndex,"same CB index reused after completed submission");
            updater.SignalCommandBufferChange();
            if(mode=="cache-no-action"){updater.SetProgram(next,one,false);updater.SetStorageBuffers(next.CommandBuffer,0,new[]{a.GetBuffer(),b.GetBuffer()});updater.UpdateAndBindDescriptorSets(next,PipelineBindPoint.Compute);}
            else Bind(updater,next,mode=="cache-all"?all:one,a.GetBuffer(),b.GetBuffer());
            bool separated = Environment.GetEnvironmentVariable("EXPECT_COVERAGE_ISOLATION") == "1" && mode != "cache-all";
            Check(Dispatch.Sets.Count==(separated?2:1)&&Dispatch.Sets.ContainsKey(set),"physical set count follows actual usage identity");
            ulong currentSet = separated ? Dispatch.Sets.Keys.Single(x=>x!=set) : set;
            Check(Dispatch.Sets[currentSet][0]==(separated?dummy.GetBuffer().GetUnsafe().Value.Handle:ah)&&Dispatch.Sets[currentSet][1]==bh,"current physical set contains only expected source or dummy");
            bool dep=a.GetBuffer().HasCommandBufferDependency(next);
            Dispatch.Events.Add(new {op="source_dependency_observed",buffer=ah,cb=(long)next.CommandBuffer.Handle,has_real_auto_dependency=dep,current_program_uses_binding0=mode=="cache-all"});
            Check(dep==(mode=="cache-all"),"buffer Auto dependency matches the current program's declared usage");
            if(mode=="cache-pending")pool.Return(next);
            a.Dispose();
            if(mode=="cache-all")Check(Dispatch.LiveBuffers.Contains(ah),"used cached descriptor gets a new lifetime dependency");
            else Check(!Dispatch.LiveBuffers.Contains(ah),"unused stale descriptor has no current Auto reference");
            if(mode!="cache-pending")pool.Return(next);
            Dispatch.Complete(next.GetFence().GetUnsafe().Handle);pool.CollectCompleted();b.Dispose();
        }
        dummy.Dispose();renderer.PipelineLayoutCache.Dispose();
        ((DescriptorSetTemplateUpdater)typeof(DescriptorSetUpdater).GetField("_templateUpdater",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!).Dispose();
        Check(Dispatch.LiveBuffers.Count==0,"all explicitly owned buffers eventually destroyed");
        Check(Dispatch.Violations.Count==0,"no buffer destroyed while still recorded in bound descriptor set");
    }
    private static void Mirror()
    {
        using Vk api=new(new Dispatch());var device=new Device(1);
        using var pool=new CommandBufferPool(api,device,new Queue(2),new Lock(),0,false);
        using var allocator=new MemoryAllocatorBlockList(api,device,0,4096,true);
        var renderer=Renderer(api,pool);var dummy=NewBuffer(renderer,device,allocator);
        var original=NewBuffer(renderer,device,allocator);var mirror=NewBuffer(renderer,device,allocator);
        ulong source=original.GetBuffer().GetUnsafe().Value.Handle,target=mirror.GetBuffer().GetUnsafe().Value.Handle;
        // Supply a previously reserved staging range as fixture state. Do not mock
        // GetMirrorable/TryGetMirror/Get/AddDependant/Dispose or their identities.
        BufferMirrorRangeList pending=new();pending.Add(0,64);
        Set(original,"_pendingData",new byte[4096]);Set(original,"_pendingDataRanges",pending);
        Set(original,"_mirrors",new Dictionary<ulong,StagingBufferReserved>{{64,new StagingBufferReserved(mirror,128,64)}});
        var updater=Updater(renderer,device,dummy);using var program=Program(renderer,device,new[]{0});
        var field=typeof(DescriptorSetUpdater).GetField("_storageBufferRefs",BindingFlags.NonPublic|BindingFlags.Instance)!;
        Array refs=(Array)field.GetValue(updater)!;object reference=Activator.CreateInstance(field.FieldType.GetElementType()!)!;
        Set(reference,"Buffer",original.GetBuffer());Set(reference,"Offset",0);Set(reference,"Write",false);refs.SetValue(reference,0);
        var infos=(DescriptorBufferInfo[])typeof(DescriptorSetUpdater).GetField("_storageBuffers",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!;infos[0]=new(){Range=64};
        var cb=pool.Rent();updater.SignalCommandBufferChange();updater.SetProgram(cb,program,false);updater.UpdateAndBindDescriptorSets(cb,PipelineBindPoint.Compute);Action(updater,cb,program);
        Check(infos[0].Buffer.Handle==target&&infos[0].Offset==128,"real GetMirrorable returns reserved mirror identity/offset");
        Check(!original.GetBuffer().HasCommandBufferDependency(cb)&&mirror.GetBuffer().HasCommandBufferDependency(cb),"actual written mirror Auto, not original, owns CB dependency");
        original.Dispose();Check(!Dispatch.LiveBuffers.Contains(source),"original unused VkBuffer may be destroyed independently");
        mirror.Dispose();Check(Dispatch.LiveBuffers.Contains(target),"recording descriptor retains mirror after owner deletion");
        pool.Return(cb);Check(!pool.CollectCompleted(),"mirror remains live while fence pending");
        Dispatch.Complete(cb.GetFence().GetUnsafe().Handle);pool.CollectCompleted();Check(!Dispatch.LiveBuffers.Contains(target),"mirror destroyed only after completion");
        dummy.Dispose();renderer.PipelineLayoutCache.Dispose();
        ((DescriptorSetTemplateUpdater)typeof(DescriptorSetUpdater).GetField("_templateUpdater",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!).Dispose();
        Check(Dispatch.LiveBuffers.Count==0&&Dispatch.Violations.Count==0,"mirror identity path has no active raw-buffer violation/leak");
    }
    private static ShaderCollection ProgramImage(VulkanRenderer r,Device d,int binding)
    {
        var sets=new ResourceDescriptorCollection[4];var usages=new ResourceUsageCollection[4];
        for(int i=0;i<4;i++)
        {
            var ds=i==PipelineBase.ImageSetIndex?new[]{new ResourceDescriptor(binding,1,ResourceType.Image,ResourceStages.Compute)}:Array.Empty<ResourceDescriptor>();
            var us=i==PipelineBase.ImageSetIndex?new[]{new ResourceUsage(binding,1,ResourceType.Image,ResourceStages.Compute,true)}:Array.Empty<ResourceUsage>();
            sets[i]=new(Array.AsReadOnly(ds));usages[i]=new(Array.AsReadOnly(us));
        }
        return new ShaderCollection(r,d,Array.Empty<ShaderSource>(),new ResourceLayout(Array.AsReadOnly(sets),Array.AsReadOnly(usages)));
    }
    private static void NullImage()
    {
        using Vk api=new(new Dispatch());var device=new Device(1);
        using var pool=new CommandBufferPool(api,device,new Queue(2),new Lock(),0,false);
        using var allocator=new MemoryAllocatorBlockList(api,device,0,4096,true);
        var renderer=Renderer(api,pool);var dummyBuffer=NewBuffer(renderer,device,allocator);
        var dummyView=(TextureView)RuntimeHelpers.GetUninitializedObject(typeof(TextureView));
        var dummyImageView=new Auto<DisposableImageView>(new DisposableImageView(api,device,new ImageView(0x9001)));
        Set(dummyView,"_imageView",dummyImageView);
        var updater=Updater(renderer,device,dummyBuffer);Set(updater,"_dummyTexture",dummyView);
        using var program=ProgramImage(renderer,device,0);
        var cb=pool.Rent();updater.SignalCommandBufferChange();updater.SetProgram(cb,program,false);
        ITexture noImage=null;updater.SetImage(cb,Ryujinx.Graphics.Shader.ShaderStage.Compute,0,noImage);
        updater.UpdateAndBindDescriptorSets(cb,PipelineBindPoint.Compute);
        Check(Dispatch.ImageSets.Values.Any(x=>x.GetValueOrDefault(0u)==0x9001),"null storage image falls back to dummy image view");
        Check(Dispatch.ImageSets.Values.All(x=>x.GetValueOrDefault(0u)!=0),"no zero image view is written to a storage image descriptor");
        Check(renderer.S2ANullImageFallbacks==1,"null image fallback counted once");
        pool.Return(cb);Dispatch.Complete(cb.GetFence().GetUnsafe().Handle);pool.CollectCompleted();
        dummyBuffer.Dispose();renderer.PipelineLayoutCache.Dispose();
        ((DescriptorSetTemplateUpdater)typeof(DescriptorSetUpdater).GetField("_templateUpdater",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!).Dispose();
        Check(Dispatch.LiveBuffers.Count==0&&Dispatch.Violations.Count==0,"null image fallback leaves no raw buffer violation");
    }
    private static ShaderCollection ProgramBufferTexture(VulkanRenderer r,Device d,int binding)
    {
        var sets=new ResourceDescriptorCollection[4];var usages=new ResourceUsageCollection[4];
        for(int i=0;i<4;i++)
        {
            var ds=i==PipelineBase.TextureSetIndex?new[]{new ResourceDescriptor(binding,1,ResourceType.BufferTexture,ResourceStages.Compute)}:Array.Empty<ResourceDescriptor>();
            var us=i==PipelineBase.TextureSetIndex?new[]{new ResourceUsage(binding,1,ResourceType.BufferTexture,ResourceStages.Compute,false)}:Array.Empty<ResourceUsage>();
            sets[i]=new(Array.AsReadOnly(ds));usages[i]=new(Array.AsReadOnly(us));
        }
        return new ShaderCollection(r,d,Array.Empty<ShaderSource>(),new ResourceLayout(Array.AsReadOnly(sets),Array.AsReadOnly(usages)));
    }
    private static void NullBufferTexture()
    {
        // #1456 规避后 9000 崩因：无 nullDescriptor 时把空 texel buffer view 写进描述符违反
        // VUID-02995/01685，Mali 在 vkUpdateDescriptorSetWithTemplate 内解引用 → NULL+0x20。
        // 断言空槽写入 R32_UINT dummy view、计数 +1，且先销毁 view 再销毁 buffer；负控
        // dummyBuffer=null（= 有 nullDescriptor）写 0、不回退、不建 view。
        using Vk api=new(new Dispatch());var device=new Device(1);
        using var pool=new CommandBufferPool(api,device,new Queue(2),new Lock(),0,false);
        using var allocator=new MemoryAllocatorBlockList(api,device,0,4096,true);
        var renderer=Renderer(api,pool);var dummyBuffer=NewBuffer(renderer,device,allocator);
        ulong dummyHandle=dummyBuffer.GetBuffer().GetUnsafe().Value.Handle;
        using var program=ProgramBufferTexture(renderer,device,1);
        var updater=Updater(renderer,device,dummyBuffer);
        var cb=pool.Rent();updater.SignalCommandBufferChange();updater.SetProgram(cb,program,false);
        updater.UpdateAndBindDescriptorSets(cb,PipelineBindPoint.Compute);
        var created=Dispatch.Events.Select(x=>JsonSerializer.SerializeToElement(x)).Where(x=>x.GetProperty("op").GetString()=="CreateBufferView").ToArray();
        Check(created.Length==1,"null texel buffer view lazily creates exactly one dummy view");
        Check(created[0].GetProperty("buffer").GetUInt64()==dummyHandle&&created[0].GetProperty("format").GetInt32()==(int)Silk.NET.Vulkan.Format.R32Uint&&created[0].GetProperty("range").GetUInt64()==16,"dummy view is R32_UINT range 16 over the dummy buffer");
        ulong dummyView=created[0].GetProperty("view").GetUInt64();
        Check(Dispatch.Sets.Values.Any(x=>x.GetValueOrDefault(1u)==dummyView),"null texel slot writes the dummy view handle");
        Check(Dispatch.Sets.Values.All(x=>x.GetValueOrDefault(1u)!=0),"no zero buffer view is written to a texel descriptor");
        Check(renderer.S2ANullTexelFallbacks==1,"null texel fallback counted once");
        pool.Return(cb);Dispatch.Complete(cb.GetFence().GetUnsafe().Handle);pool.CollectCompleted();
        var ctrl=Updater(renderer,device,null);var cb2=pool.Rent();
        ctrl.SignalCommandBufferChange();ctrl.SetProgram(cb2,program,false);
        ctrl.UpdateAndBindDescriptorSets(cb2,PipelineBindPoint.Compute);
        Check(Dispatch.Events.Select(x=>JsonSerializer.SerializeToElement(x)).Count(x=>x.GetProperty("op").GetString()=="CreateBufferView")==1,"nullDescriptor-capable control creates no extra view");
        Check(Dispatch.Sets.Values.Where(x=>!x.ContainsValue(dummyView)).All(x=>x.GetValueOrDefault(1u)==0),"control without dummy buffer writes zero view");
        Check(renderer.S2ANullTexelFallbacks==1,"control performs no fallback");
        pool.Return(cb2);Dispatch.Complete(cb2.GetFence().GetUnsafe().Handle);pool.CollectCompleted();
        ((Auto<DisposableBufferView>)typeof(DescriptorSetUpdater).GetField("_dummyBufferView",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!).Dispose();
        Check(Dispatch.LiveBufferViews.Count==0,"dummy view destroyed before its dummy buffer");
        dummyBuffer.Dispose();
        renderer.PipelineLayoutCache.Dispose();
        ((DescriptorSetTemplateUpdater)typeof(DescriptorSetUpdater).GetField("_templateUpdater",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(updater)!).Dispose();
        ((DescriptorSetTemplateUpdater)typeof(DescriptorSetUpdater).GetField("_templateUpdater",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(ctrl)!).Dispose();
        Check(Dispatch.LiveBuffers.Count==0&&Dispatch.Violations.Count==0,"null texel fallback leaves no raw buffer violation");
    }
    private static ShaderCollection LayoutProgram(VulkanRenderer r,Device d,int set,ResourceDescriptor[] descriptors,ResourceUsage[] usage)
    {
        var sets=new ResourceDescriptorCollection[4];var usages=new ResourceUsageCollection[4];
        for(int i=0;i<4;i++){sets[i]=new(Array.AsReadOnly(i==set?descriptors:Array.Empty<ResourceDescriptor>()));usages[i]=new(Array.AsReadOnly(i==set?usage:Array.Empty<ResourceUsage>()));}
        return new ShaderCollection(r,d,Array.Empty<ShaderSource>(),new ResourceLayout(Array.AsReadOnly(sets),Array.AsReadOnly(usages)));
    }
    private static void CoverageIdentity()
    {
        using Vk api=new(new Dispatch());var device=new Device(1);
        using var pool=new CommandBufferPool(api,device,new Queue(2),new Lock(),0,false);
        var r=Renderer(api,pool);
        using var all=Program(r,device,new[]{0,1});using var reverse=Program(r,device,new[]{1,0});using var one=Program(r,device,new[]{1});using var zero=Program(r,device,new[]{0});
        Check(all.HasSameLayout(reverse),"normalized reordered/split equal coverage shares actual PLCE");
        Check(!all.HasSameLayout(one)&&!all.HasSameLayout(zero)&&!one.HasSameLayout(zero),"subset/superset and disjoint coverage isolate actual PLCE");
        var byProgram=new Dictionary<string,ulong>();
        foreach(var pair in new[]{("all",all),("one",one),("all",reverse),("zero",zero),("one",one),("all",all)})
        {
            var cb=pool.Rent();pair.Item2.UpdateDescriptorCacheCommandBufferIndex(cb.CommandBufferIndex);ulong set=pair.Item2.GetNewDescriptorSetCollection(1,out _).Get(cb).GetSets()[0].Handle;
            if(byProgram.TryGetValue(pair.Item1,out ulong before))Check(before==set,"same coverage reuses original physical set after submission");else byProgram.Add(pair.Item1,set);
            pool.Return(cb);Dispatch.Complete(cb.GetFence().GetUnsafe().Handle);pool.CollectCompleted();
        }
        Check(byProgram.Values.Distinct().Count()==3&&Dispatch.Sets.Count==3,"three distinct coverage groups allocate exactly three physical sets");
        Check(Dispatch.Events.Count(x=>JsonSerializer.SerializeToElement(x).GetProperty("op").GetString()=="CreateDescriptorSetLayout")==12,"three PLCE groups create three times four layout objects; no fourth group for equal coverage");
        ResourceBindingSegment saved=all.BindingSegments[1][0];all.BindingSegments[1][0]=new(7,1,ResourceType.StorageBuffer,ResourceStages.Compute,false);
        using var allAgain=Program(r,device,new[]{0,1});Check(allAgain.HasSameLayout(reverse),"key owns immutable coverage despite caller mutation");all.BindingSegments[1][0]=saved;
        using var uniform=Program(r,device,new[]{0,1},true);Check(!uniform.HasSameLayout(all),"UBO set/type distinct from SSBO");
        ResourceDescriptor[] ds={new(0,4,ResourceType.BufferTexture,ResourceStages.Compute)};
        using var array2=LayoutProgram(r,device,2,ds,new[]{new ResourceUsage(0,2,ResourceType.BufferTexture,ResourceStages.Compute,false)});
        using var array3=LayoutProgram(r,device,2,ds,new[]{new ResourceUsage(0,3,ResourceType.BufferTexture,ResourceStages.Compute,false)});
        using var scalar=LayoutProgram(r,device,2,ds,new[]{new ResourceUsage(0,1,ResourceType.BufferTexture,ResourceStages.Compute,false)});
        using var array2Again=LayoutProgram(r,device,2,ds,new[]{new ResourceUsage(0,2,ResourceType.BufferTexture,ResourceStages.Compute,false)});
        Check(!array2.HasSameLayout(array3)&&!array2.HasSameLayout(scalar),"same layout distinguishes actual descriptor array lengths and scalar/array coverage");
        Check(array2.HasSameLayout(array2Again),"equal array coverage shares PLCE");
        ds[0]=new(0,4,ResourceType.BufferImage,ResourceStages.Compute);
        using var typeChanged=LayoutProgram(r,device,2,ds,new[]{new ResourceUsage(0,2,ResourceType.BufferImage,ResourceStages.Compute,true)});
        using var array2Fresh=LayoutProgram(r,device,2,new[]{new ResourceDescriptor(0,4,ResourceType.BufferTexture,ResourceStages.Compute)},new[]{new ResourceUsage(0,2,ResourceType.BufferTexture,ResourceStages.Compute,false)});
        Check(!typeChanged.HasSameLayout(array2)&&array2.HasSameLayout(array2Fresh),"type change isolates and caller mutation cannot rewrite frozen layout key");
        r.PipelineLayoutCache.Dispose();Check(Dispatch.Violations.Count==0,"metadata/cache-only controls create no raw lifetime violation");
    }
    private static void TexelFormatFallback()
    {
        // #1456 潜在 VUID-08778 违规的门控逻辑（决策点）：9000 上
        // R16Sfloat/R16Sint/A2B10G10R10SintPack32 的 bufferFeatures 无
        // UNIFORM_TEXEL_BUFFER。断言：命中不支持集合的格式解析为同位宽整型
        // 替代 view 并标记 shader 解码；受支持格式与索引/拓扑格式原样返回；
        // 无解码表项的不支持格式显式失败而非静默放行。
        var unsupported = Array.AsReadOnly(new[] { GalFormat.R16Float, GalFormat.R16Sint, GalFormat.R10G10B10A2Sint });
        Check(VertexTexelFormats.TryResolveViewFormat(GalFormat.R16Float, unsupported, out GalFormat v1, out bool d1) && v1 == GalFormat.R16Uint && d1,
            "R16Float falls back to same-width R16Uint marked for decode");
        Check(VertexTexelFormats.TryResolveViewFormat(GalFormat.R16Sint, unsupported, out GalFormat v2, out bool d2) && v2 == GalFormat.R16Uint && d2,
            "R16Sint falls back to same-width R16Uint marked for decode");
        Check(VertexTexelFormats.TryResolveViewFormat(GalFormat.R10G10B10A2Sint, unsupported, out GalFormat v3, out bool d3) && v3 == GalFormat.R32Uint && d3,
            "A2B10G10R10Sint falls back to same-width R32Uint marked for decode");
        Check(VertexTexelFormats.TryResolveViewFormat(GalFormat.R32Float, unsupported, out GalFormat v4, out bool d4) && v4 == GalFormat.R32Float && !d4,
            "supported R32Float stays on the intended view without decode");
        Check(VertexTexelFormats.TryResolveViewFormat(GalFormat.R32Uint, unsupported, out GalFormat v5, out bool d5) && v5 == GalFormat.R32Uint && !d5,
            "index/topology R32Uint view is never substituted");
        Check(VertexTexelFormats.TryResolveViewFormat(GalFormat.R16Float, null, out GalFormat v6, out bool d6) && v6 == GalFormat.R16Float && !d6,
            "device with full texel support keeps the intended view");
        Check(!VertexTexelFormats.TryResolveViewFormat(GalFormat.R11G11B10Float, Array.AsReadOnly(new[] { GalFormat.R11G11B10Float }), out _, out _),
            "unsupported format without a decode map entry fails explicitly");
        const Ryujinx.Graphics.Shader.AttributeType flagged =
            Ryujinx.Graphics.Shader.AttributeType.Sint | Ryujinx.Graphics.Shader.AttributeType.TexelDecode;
        Check((flagged & Ryujinx.Graphics.Shader.AttributeType.BaseTypeMask) == Ryujinx.Graphics.Shader.AttributeType.Sint,
            "TexelDecode flag does not change the attribute base type");
    }
    private static int Main(string[] args)
    {
        try{if(args[0]=="basic")Basic();else if(args[0]=="mirror")Mirror();else if(args[0]=="null-image")NullImage();else if(args[0]=="null-buffer-texture")NullBufferTexture();else if(args[0]=="texel-format-fallback")TexelFormatFallback();else if(args[0]=="coverage-identity")CoverageIdentity();else if(args[0].StartsWith("ubo-"))Descriptors(args[0][4..],true);else Descriptors(args[0]);Console.WriteLine(JsonSerializer.Serialize(new{status="PASS",checks=_checks,events=Dispatch.Events,violations=Dispatch.Violations}));return 0;}
        catch(Exception e){Console.Error.WriteLine(e);Console.WriteLine(JsonSerializer.Serialize(new{status="FAIL",checks=_checks,error=e.ToString(),events=Dispatch.Events,violations=Dispatch.Violations}));return 1;}
    }
}
