using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using S2A.Services;
using Switch = Ryujinx.HLE.Switch;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2Arm.Platforms.Android;

internal static unsafe class AndroidTouchInput
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Frame
    {
        public uint Size, Version;
        public ulong Sequence, Timestamp;
        public uint Flags, Count;
        public fixed uint Points[80];
    }
    [DllImport("s2a_native")]
    private static extern int s2a_android_game_touch_read(ulong after, Frame* frame);
    [DllImport("s2a_native")]
    private static extern int s2a_android_game_touch_trace();
    [DllImport("s2a_native")]
    private static extern ulong s2a_android_game_touch_now();
    private static readonly TouchHidState State = new();
    private static ulong _cursor;
    private static bool _active;
    private static ulong _gestureCursor;
    private static GestureDevice _gestureDevice;
    private static TouchGestureState _gesture;
    private static Switch _gestureOwner;

    private static void WriteGesture(GestureInput input)
    {
        _gestureDevice.Update(input);
        if (s2a_android_game_touch_trace() != 0)
            Console.Error.WriteLine("[Android gesture] " + InputPump.DescribeGesture(_gestureOwner));
    }

    private static void UnsupportedGesture(string detail) =>
        Console.Error.WriteLine("[Android gesture] UNSUPPORTED: " + detail);

    [ModuleInitializer]
    internal static void Install() => InputPump.TouchHook = Pump;

    private static void Clear(Switch device)
    {
        if (_active) { State.Cancel(); device.Hid.Touchscreen.UpdateWithIds(State.Points, State.Ids); _active = false; }
        _gesture?.Cancel();
        _gestureDevice?.Clear();
    }

    private static int Read(ulong cursor, Frame* frame)
    {
        *frame = default;
        frame->Size = (uint)sizeof(Frame);
        int error = s2a_android_game_touch_read(cursor, frame);
        if (error == -4) return error;
        if (error != 0 && error != -3)
            throw new InvalidOperationException($"Android touch transport failed: {error}.");
        if (frame->Size != sizeof(Frame) || frame->Version != 1 || frame->Count > 16 ||
            (frame->Flags & ~1u) != 0 || (frame->Flags != 0 && frame->Count != 0) || frame->Sequence < cursor)
            throw new InvalidOperationException("Invalid Android touch frame ABI.");
        return error;
    }

    private static void Pump(Switch device)
    {
        if (Host.Docked) { Clear(device); return; }
        Frame frame;
        int error = Read(_cursor, &frame);
        if (error == -4) { Clear(device); return; }
        _active = true;
        bool changed = frame.Sequence != _cursor;
        // Coalesce position-only history to the newest available move, while
        // preserving contact-set boundaries for at least one HID sample. A
        // 180 ms stationary MotionEvent must not become 40 x 16 ms of latency.
        if (changed && error == 0 && frame.Flags == 0 &&
            State.SameContacts(new ReadOnlySpan<uint>(frame.Points, (int)frame.Count * 5)))
        {
            for (int i = 0; i < 63; i++) {
                Frame next;
                int nextError = Read(frame.Sequence, &next);
                if (nextError == -4) { Clear(device); return; }
                if (next.Sequence == frame.Sequence) break;
                if (nextError == -3 || next.Flags != 0) { frame = next; error = nextError; break; }
                if (!State.SameContacts(new ReadOnlySpan<uint>(next.Points, (int)next.Count * 5))) break;
                frame = next;
            }
        }
        bool commit = true;
        if (error == -3 || frame.Flags != 0) State.Cancel();
        else if (frame.Sequence == _cursor) State.Held();
        else commit = State.Apply(new ReadOnlySpan<uint>(frame.Points, (int)frame.Count * 5));
        device.Hid.Touchscreen.UpdateWithIds(State.Points, State.Ids);
        if (error == -3 || frame.Flags != 0)
            Console.Error.WriteLine($"[Android touch] transport cancel source #{frame.Sequence} error={error} flags={frame.Flags}; {InputPump.DescribeTouch(device)}");
        if (changed && s2a_android_game_touch_trace() != 0)
            Console.Error.WriteLine($"[Android touch] source #{frame.Sequence} flags={frame.Flags} committed={commit}; {InputPump.DescribeTouch(device)}");
        if (commit) _cursor = frame.Sequence;
        PumpGestures(device);
    }

    private static void PumpGestures(Switch device)
    {
        // Independent cursor: recognize historical events using source time,
        // then write the existing HID ring. Guest reads never consume history.
        bool caughtUp = false;
        for (int i = 0; i < 64; i++) {
            Frame frame;
            int error = Read(_gestureCursor, &frame);
            if (error == -4) { Clear(device); return; }
            if (frame.Sequence == _gestureCursor) { caughtUp = true; break; }
            // Tap/Pan must not precede the corresponding raw HID coordinates.
            // Do not classify Press from dequeue time while known source events
            // are still waiting for their contact-boundary HID commit.
            if (frame.Sequence > _cursor) break;
            if (error == -3 || frame.Flags != 0) {
                _gestureDevice?.Clear();
                _gesture?.Cancel();
            } else if (frame.Count != 0 || _gesture != null) {
                if (_gesture == null) {
                    _gestureDevice = new GestureDevice(device);
                    _gestureOwner = device;
                    _gesture = new TouchGestureState(WriteGesture, UnsupportedGesture);
                    Console.Error.WriteLine("[Android gesture] Experimental single-contact Touch/Tap/Press/Pan; double-tap/swipe/pinch/rotation recognition is NOT implemented.");
                }
                _gesture.Feed(new ReadOnlySpan<uint>(frame.Points, (int)frame.Count * 5), frame.Timestamp);
            }
            _gestureCursor = frame.Sequence;
        }
        if (_gesture != null && caughtUp) {
            ulong now = s2a_android_game_touch_now();
            if (now == 0) throw new InvalidOperationException("Android gesture monotonic clock failed.");
            _gesture.Tick(now);
        }
    }
}
