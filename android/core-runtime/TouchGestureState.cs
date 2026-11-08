using System;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2Arm.Platforms.Android;

// Single-contact recognizer over source monotonic timestamps, not dequeue time.
// Multiple contacts explicitly cancel this recognizer; raw HID remains separate.
internal sealed class TouchGestureState
{
    private readonly Action<GestureInput> _write;
    private readonly Action<string> _unsupported;
    private bool _active, _pan, _press, _blocked;
    private uint _id, _x, _y, _startX, _startY;
    private ulong _context, _startNs, _lastNs;
    internal const ulong PressNs = 500_000_000;
    internal const long SlopSquared = 100;

    public TouchGestureState(Action<GestureInput> write, Action<string> unsupported)
    {
        _write = write ?? throw new ArgumentNullException(nameof(write));
        _unsupported = unsupported ?? throw new ArgumentNullException(nameof(unsupported));
    }
    private void Emit(GestureType type, int dx = 0, int dy = 0, ulong elapsed = 0)
    {
        bool points = type is GestureType.Touch or GestureType.Press or GestureType.Pan or GestureType.Tap;
        _write(new GestureInput {
            ContextNumber = _context, Type = type, X = _x, Y = _y,
            DeltaX = dx, DeltaY = dy,
            VelocityX = elapsed == 0 ? 0 : dx * (1_000_000_000f / elapsed),
            VelocityY = elapsed == 0 ? 0 : dy * (1_000_000_000f / elapsed),
            Attributes = type == GestureType.Touch ? 1u << 4 : 0,
            Scale = 1, PointCount = points ? 1 : 0,
            Point0 = points ? new GesturePoint { X = _x, Y = _y } : default,
        });
    }
    public void Cancel()
    {
        if (_active) Emit(GestureType.Cancel);
        _active = _pan = _press = _blocked = false;
    }
    public void Feed(ReadOnlySpan<uint> raw, ulong ns)
    {
        if (raw.Length % 5 != 0 || raw.Length > 80 || ns == 0 || ns < _lastNs)
            throw new ArgumentException("Invalid gesture frame or regressing source time.");
        if (raw.Length > 5) {
            bool report = !_blocked;
            Cancel(); _blocked = true; _lastNs = ns;
            if (report) _unsupported("Multi-contact gestures (pinch/rotate) are not implemented; gesture stream cancelled.");
            return;
        }
        if (_blocked) { if (raw.IsEmpty) _blocked = false; _lastNs = ns; return; }
        if (raw.IsEmpty) {
            if (_active) {
                Tick(ns);
                if (!_pan && !_press && ns - _startNs < PressNs) Emit(GestureType.Tap);
                Emit(GestureType.Complete);
                _active = false;
            }
            _lastNs = ns;
            return;
        }
        for (int i = 1; i < 5; i++) if (raw[i] > 65535) throw new ArgumentException("Gesture coordinate out of range.");
        if (_active && raw[0] != _id) Cancel();
        uint x = (uint)((ulong)raw[1] * 1279 / 65535), y = (uint)((ulong)raw[2] * 719 / 65535);
        if (!_active) {
            _active = true; _pan = _press = false;
            _id = raw[0]; _x = _startX = x; _y = _startY = y; _startNs = ns;
            if (_context == ulong.MaxValue) throw new InvalidOperationException("Gesture context overflow.");
            _context++; Emit(GestureType.Touch);
        } else {
            long sx = (long)x - _startX, sy = (long)y - _startY;
            _pan |= sx * sx + sy * sy > SlopSquared;
            int dx = (int)x - (int)_x, dy = (int)y - (int)_y;
            _x = x; _y = y;
            if (_pan && (dx != 0 || dy != 0)) Emit(GestureType.Pan, dx, dy, ns - _lastNs);
            else Tick(ns);
        }
        _lastNs = ns;
    }
    public void Tick(ulong nowNs)
    {
        if (_active && !_pan && !_press && nowNs >= _startNs && nowNs - _startNs >= PressNs) {
            Emit(GestureType.Press); _press = true;
        }
    }
}
