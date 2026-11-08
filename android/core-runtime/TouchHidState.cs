using System;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;

namespace S2Arm.Platforms.Android;

// A whole-contact-set transport becomes the existing Switch HID point stream.
// No gesture recognition, game identity, heap allocation or wall clock here.
internal sealed class TouchHidState
{
    private readonly TouchPoint[] _held = new TouchPoint[16], _output = new TouchPoint[16];
    private readonly uint[] _ids = new uint[16], _outputIds = new uint[16];
    private int _count, _outputCount;
    public ReadOnlySpan<TouchPoint> Points => _output.AsSpan(0, _outputCount);
    public ReadOnlySpan<uint> Ids => _outputIds.AsSpan(0, _outputCount);
    public bool SameContacts(ReadOnlySpan<uint> raw)
    {
        if (raw.Length != _count * 5) return false;
        for (int i = 0; i < raw.Length; i += 5) if (Find(raw[i]) < 0) return false;
        return true;
    }

    private int Find(uint id)
    {
        for (int i = 0; i < _count; i++) if (_ids[i] == id) return i;
        return -1;
    }
    private static bool Contains(ReadOnlySpan<uint> raw, uint id)
    {
        for (int i = 0; i < raw.Length; i += 5) if (raw[i] == id) return true;
        return false;
    }
    public void Cancel() => Apply(ReadOnlySpan<uint>.Empty);
    public void Held()
    {
        _outputCount = _count;
        Array.Copy(_held, _output, _count);
        Array.Copy(_ids, _outputIds, _count);
    }
    public bool Apply(ReadOnlySpan<uint> raw)
    {
        if (raw.Length % 5 != 0 || raw.Length > 80) throw new ArgumentException("Invalid touch frame.");
        for (int i = 0; i < raw.Length; i += 5)
        {
            for (int j = 0; j < i; j += 5)
                if (raw[i] == raw[j]) throw new ArgumentException("Duplicate contact ID.");
            for (int j = 1; j < 5; j++)
                if (raw[i + j] > 65535) throw new ArgumentException("Touch coordinate out of range.");
        }
        _outputCount = 0;
        int ends = 0;
        for (int i = 0; i < _count; i++) if (!Contains(raw, _ids[i])) ends++;
        // HID has only 16 slots, including End records. End the removed set
        // first, then retry this same (uncommitted) frame on the next sample.
        bool defer = ends + raw.Length / 5 > 16;
        if (!defer)
            for (int i = 0; i < raw.Length; i += 5)
            {
                uint id = raw[i];
                _outputIds[_outputCount] = id;
                _output[_outputCount++] = new TouchPoint {
                    Attribute = Find(id) < 0 ? TouchAttribute.Start : TouchAttribute.None,
                    X = (uint)((ulong)raw[i + 1] * 1279 / 65535),
                    Y = (uint)((ulong)raw[i + 2] * 719 / 65535),
                    DiameterX = (uint)((ulong)raw[i + 3] * 1280 / 65535),
                    DiameterY = (uint)((ulong)raw[i + 4] * 720 / 65535),
                };
            }
        else
            for (int i = 0; i < _count; i++) if (Contains(raw, _ids[i])) {
                _outputIds[_outputCount] = _ids[i]; _output[_outputCount++] = _held[i];
            }
        for (int i = 0; i < _count; i++) if (!Contains(raw, _ids[i])) {
            TouchPoint end = _held[i]; end.Attribute = TouchAttribute.End;
            _outputIds[_outputCount] = _ids[i]; _output[_outputCount++] = end;
        }
        if (defer)
        {
            int held = 0;
            for (int i = 0; i < _count; i++) if (Contains(raw, _ids[i])) {
                _held[held] = _held[i]; _ids[held++] = _ids[i];
            }
            _count = held;
        }
        else
        {
            _count = raw.Length / 5;
            for (int i = 0; i < _count; i++) {
                _held[i] = _output[i]; _held[i].Attribute = TouchAttribute.None;
                _ids[i] = _outputIds[i];
            }
        }
        return !defer;
    }
}
