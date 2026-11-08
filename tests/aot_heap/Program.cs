using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

sealed class AuditNode
{
    public byte[] Payload = new byte[1000];
    public AuditNode Next;
}

sealed class AuditTarget { }

[StructLayout(LayoutKind.Sequential)]
struct AuditMixed
{
    public AuditTarget First;
    public long Gap;
    public AuditTarget Last;
}

struct AuditAllReferences
{
    public AuditTarget First;
    public AuditTarget Last;
}

[StructLayout(LayoutKind.Sequential)]
sealed class AuditFields
{
    public AuditTarget First;
    public long Gap;
    public AuditTarget Last;
}

sealed class AuditReferences
{
    // Ten reference fields, regardless of which values are null.
    public AuditTarget[] References = new AuditTarget[3];
    public AuditTarget[] OtherReferences = new AuditTarget[6];
    public AuditTarget[] EmptyReferences = new AuditTarget[0];
    public AuditMixed[] Mixed = new AuditMixed[5];
    public AuditAllReferences[] AllReferences = new AuditAllReferences[7];
    public int[] Values = new int[11];
    public string Text = new string('x', 13);
    public object Boxed = new AuditMixed();
    public AuditMixed[,] Matrix = new AuditMixed[2, 3];
    public AuditFields Fields = new AuditFields();
}

static class Program
{
    private static AuditNode Root;
    private static AuditReferences References;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void PopulateReferences()
    {
        References = new AuditReferences();
        var target = new AuditTarget();
        References.References[0] = target;
        References.OtherReferences[0] = target;
        References.Mixed[0].First = target;
        References.AllReferences[0].Last = target;
        References.Fields.Last = target;
        References.Matrix[0, 0].First = target;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Populate(int count)
    {
        for (int i = 0; i < count; i++)
        {
            Root = new AuditNode { Next = Root };
        }
    }

    private static void Main()
    {
        PopulateReferences();
        Populate(100);
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        Console.WriteLine("retained nodes: 100");
        Populate(50);
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        Console.WriteLine("retained nodes: 150");
        Root = null;
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        Console.WriteLine("retained nodes: 0");
        GC.KeepAlive(References);
    }
}
