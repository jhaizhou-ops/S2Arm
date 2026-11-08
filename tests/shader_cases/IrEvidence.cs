// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
// Injected only into the isolated test source copy; production source is untouched.
static class IrEvidence {
    public static string Case="";
    public static bool Clamp;
    public static List<Dictionary<string,string>> Final=new();
    public static void Reset(string name,bool clamp) { Case=name;Clamp=clamp;Ids.Clear(); }
    public static void CaptureFinal(List<Function> funcs) {
        Ids.Clear();
        string ir=string.Join("\n",funcs.SelectMany(f=>f.Blocks.SelectMany(b=>b.Operations.OfType<Operation>().Select(o=>f.Name+"/"+b.Index+":"+Snapshot(o)))));
        Final.Add(new(){{"case",Case},{"clamp",Clamp?"true":"false"},{"ir",ir},{"sha256",Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ir))).ToLowerInvariant()}});
    }
    public static List<Dictionary<string,string>> Events=new();
    static readonly Dictionary<Operand,int> Ids=new(ReferenceEqualityComparer.Instance);
    static string OperandText(Operand op) {
        if(op is null) return "null";
        if(!Ids.TryGetValue(op,out int id)) Ids[op]=id=Ids.Count;
        return $"{op.Type}:{op.Value}:id{id}";
    }
    public static string Snapshot(Operation op)=>$"{op.Inst}|{op.StorageKind}|{op.Index}|"+
        string.Join(",",Enumerable.Range(0,op.DestsCount).Select(i=>OperandText(op.GetDest(i))))+" <- "+
        string.Join(",",Enumerable.Range(0,op.SourcesCount).Select(i=>OperandText(op.GetSource(i))));
    // Block-level passes (XmadOptimizer.RunPass(block)): the block's operations in order, same operand numbering as Snapshot
    public static string BlockSnapshot(BasicBlock block)=>string.Join("\n",block.Operations.OfType<Operation>().Select(Snapshot));
    public static void RecordBlock(string name,string before,BasicBlock block)=>Record(name,before,BlockSnapshot(block));
    public static void Record(string name,string before,Operation op)=>Record(name,before,Snapshot(op));
    static void Record(string name,string before,string after) {
        string Hash(string s)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(s))).ToLowerInvariant();
        Events.Add(new(){{"case",Case},{"kind","pass"},{"name",name},
            {"source","compat/tree/src/Ryujinx.Graphics.Shader/Translation/Optimizations/"+name+".cs"},
            {"before",Hash(before)},{"after",Hash(after)},{"before_ir",before},{"after_ir",after}});
    }
}
