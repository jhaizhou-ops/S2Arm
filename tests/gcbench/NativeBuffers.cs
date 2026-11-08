using System.Runtime.InteropServices;

// No managed wrapper allocation on the measured burst/replacement path.
internal sealed unsafe class NativeBuffers : IDisposable
{
    private readonly nint[] _longLived;
    private nint _transient;
    private int _transientSize;
    private long _live;
    public long Allocated { get; private set; }
    public long Peak { get; private set; }

    public NativeBuffers(int count)
    {
        _longLived = new nint[count];
        try { for (int i = 0; i < count; i++) _longLived[i] = Allocate(1 << 20); }
        catch { Dispose(); throw; }
    }

    private nint Allocate(int size)
    {
        byte* p = (byte*)NativeMemory.Alloc((nuint)size);
        if (p == null) throw new OutOfMemoryException("Native buffer allocation failed");
        for (int i = 0; i < size; i += 4096) p[i] = 1;
        p[size - 1] = 1;
        _live += size;
        Allocated += size;
        Peak = Math.Max(Peak, _live);
        return (nint)p;
    }

    public void ReleaseTransient()
    {
        if (_transient == 0) return;
        NativeMemory.Free((void*)_transient);
        _live -= _transientSize;
        _transient = 0;
    }

    public void ReplaceTransient(int size)
    {
        nint next = Allocate(size);
        ReleaseTransient();
        _transient = next;
        _transientSize = size;
    }

    public void Replace(int index)
    {
        nint next = Allocate(1 << 20);
        NativeMemory.Free((void*)_longLived[index]);
        _live -= 1 << 20;
        _longLived[index] = next;
    }

    public void Dispose()
    {
        ReleaseTransient();
        for (int i = 0; i < _longLived.Length; i++)
        {
            if (_longLived[i] == 0) continue;
            NativeMemory.Free((void*)_longLived[i]);
            _live -= 1 << 20;
            _longLived[i] = 0;
        }
        if (_live != 0) throw new InvalidOperationException("Native buffer accounting mismatch");
    }
}
