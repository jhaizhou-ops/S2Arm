using S2A.Services;

// Fail on a real filesystem operation before Boot consumes its renderer/audio.
// No native hooks, device drivers or service implementations are replaced.
string root = Path.Combine(Path.GetTempPath(), $"s2a_boot_failure_{Guid.NewGuid():N}");
Directory.CreateDirectory(root);
string blocked = Path.Combine(root, "file");
File.WriteAllText(blocked, "This path is a file, not a state directory.");
int failed = 0;
try
{
    for (int attempt = 1; attempt <= 2; attempt++)
    {
        bool reachedFilesystem = false;
        try
        {
            Host.Boot(null, null, blocked);
        }
        catch (IOException)
        {
            reachedFilesystem = true;
        }
        catch (InvalidOperationException e)
        {
            Console.WriteLine($"attempt {attempt}: {e.Message}");
        }
        bool ok = reachedFilesystem && !SaveTransfer.HostStarted && Host.Device == null;
        Console.WriteLine($"attempt {attempt}: filesystem failure={reachedFilesystem}, startup gate released={!SaveTransfer.HostStarted}, device absent={Host.Device == null}: {(ok ? "PASS" : "FAIL")}");
        if (!ok) failed++;
    }
}
finally
{
    MemDiag.Stop();
    File.Delete(blocked);
    Directory.Delete(root);
}
Console.WriteLine($"Host.Boot failure admission: {2 - failed}/2 passed");
return failed == 0 ? 0 : 1;
