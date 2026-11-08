using System.Text.Json;
using LibHac;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Fs.Shim;
using LibHac.FsSrv;
using LibHac.FsSystem;
using Path = System.IO.Path;

Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();

if (args.Length == 1 && args[0] == "--describe")   // 审计 P2-11：失败原因转人话的映射，interop.py 按手算期望逐条比
{
    foreach (var ex in new Exception[] { new IOException("disk", 28), new IOException("quota", 69), new UnauthorizedAccessException("no"), new IOException("perm", 13),
                                         new InvalidDataException("bad"), new JsonException("bad"), new IOException("other", 5), new ArgumentException("arg") })
    {
        var (code, message) = S2A.Services.SaveTransfer.Describe(ex);
        Console.WriteLine(JsonSerializer.Serialize(new { type = ex.GetType().Name, code, message }));
    }
    return;
}
if (args.Length == 3 && args[0] == "--copytree")   // 审计 P2-24：恢复用的数据根复制（跳过存档三处、其余克隆），interop.py 核内容与耗时
{
    var watch = System.Diagnostics.Stopwatch.StartNew();
    S2A.Services.SaveTransfer.CopyTree(args[1], args[2], skipSaves: true);
    Console.WriteLine(JsonSerializer.Serialize(new { ms = watch.ElapsedMilliseconds }));
    return;
}
if (args.Length == 2 && args[0] == "--request")
{
    Console.WriteLine(S2A.Services.SaveTransfer.Execute(File.ReadAllText(args[1])));
    return;
}
if (args.Length != 4 || args[0] != "--create") throw new ArgumentException("--create root repository user-id");
string root = args[1], repository = args[2], userText = args[3];
Directory.CreateDirectory(root);
var horizon = new Horizon(new HorizonConfiguration());
using var serverClient = horizon.CreatePrivilegedHorizonClient();
var server = new FileSystemServer(serverClient);
using var baseFs = new LocalFileSystem(root);
var keys = KeySet.CreateDefaultKeySet();
RandomDataGenerator random = Random.Shared.NextBytes;
var objects = DefaultFsServerObjects.GetDefaultEmulatedCreators(baseFs, keys, server, random);
FileSystemServerInitializer.InitializeWithConfig(serverClient, server, new FileSystemServerConfig
{
    ExternalKeySet = keys.ExternalKeySet,
    FsCreators = objects.FsCreators,
    StorageDeviceManagerFactory = objects.StorageDeviceManagerFactory,
    RandomGenerator = random,
});
using var client = horizon.CreatePrivilegedHorizonClient();
var application = new LibHac.Ncm.ApplicationId(0x0100000000000000);
var user = new UserId(Convert.ToUInt64(userText[..16], 16), Convert.ToUInt64(userText[16..], 16));
Check(client.Fs.CreateSaveData(application, user, application.Value, 0x100000, 0x100000, SaveDataFlags.None));
Check(client.Fs.CreateDeviceSaveData(application, application.Value, 0x100000, 0x100000, SaveDataFlags.None));
Check(client.Fs.MountSaveData("account"u8, application, user));
Check(client.Fs.MountDeviceSaveData("device"u8, application));
Write("account:/contributing.md"u8, File.ReadAllBytes(Path.Combine(repository, "CONTRIBUTING.md")));
Check(client.Fs.CreateDirectory("account:/empty"u8));
Check(client.Fs.CreateDirectory("account:/nested"u8));
Write("account:/nested/readme.md"u8, File.ReadAllBytes(Path.Combine(repository, "README.md")));
Write("device:/contributing.md"u8, File.ReadAllBytes(Path.Combine(repository, "CONTRIBUTING.md")));
Check(client.Fs.Commit("account"u8));
Check(client.Fs.Commit("device"u8));
client.Fs.Unmount("account"u8);
client.Fs.Unmount("device"u8);
Directory.CreateDirectory(Path.Combine(root, "system"));
File.WriteAllText(Path.Combine(root, "system/Profiles.json"), JsonSerializer.Serialize(new
{
    last_opened = userText,
    profiles = new[] { new { user_id = userText, name = "Public-file interop account" } },
}));
Console.WriteLine("Created and committed account/device saves through LibHac; payloads are repository CONTRIBUTING.md and README.md.");

void Check(Result result) { if (result.IsFailure()) throw new InvalidOperationException("LibHac: " + result); }
void Write(LibHac.Common.U8Span path, byte[] bytes)
{
    Check(client.Fs.CreateFile(path, bytes.Length));
    Check(client.Fs.OpenFile(out FileHandle handle, path, OpenMode.Write));
    try { Check(client.Fs.WriteFile(handle, 0, bytes, WriteOption.Flush)); }
    finally { client.Fs.CloseFile(handle); }
}
