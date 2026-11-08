using System.Runtime.InteropServices;
using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Fs.Shim;
using LibHac.FsSystem;
using LibHac.Kvdb;

internal static class OwnershipVariant
{
    internal static void Change(string root)
    {
        static void Check(Result r) { if (!r.IsSuccess()) throw new InvalidOperationException("LibHac mutation failed: " + r); }
        using var client = new Horizon(new HorizonConfiguration()).CreatePrivilegedHorizonClient();
        using var fs = new UniqueRef<IFileSystem>(new LocalFileSystem(System.IO.Path.Combine(root, "bis/system/save/8000000000000000/0")));
        Check(client.Fs.Register("actual"u8, ref fs.Ref));
        using var store = new FlatMapKeyValueStore<SaveDataAttribute>();
        var memory = new ArrayPoolMemoryResource();
        Check(store.Initialize(client.Fs, "actual:/"u8, 0x1080, memory, memory));
        Check(store.Load());
        var iterator = store.GetBeginIterator();
        while (!iterator.IsEnd() && iterator.Get().Key.Type != SaveDataType.Account) iterator.Next();
        if (iterator.IsEnd()) throw new InvalidOperationException("Need actual account savedata.");
        var old = iterator.Get().Key;
        byte[] value = iterator.GetValue().ToArray();
        var changed = old;
        changed.UserId = new UserId(old.UserId.Id.High ^ 0x40, old.UserId.Id.Low);
        Check(store.Delete(in old)); Check(store.Set(in changed, value)); Check(store.Save());
    }
}
