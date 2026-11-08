using Ryujinx.HLE.HOS.Applets;
using System;

namespace Ryujinx.HLE.UI
{
    /// <summary>
    /// S2Arm: the host shows the platform's own text input (system keyboard) without blocking the caller.
    /// The software keyboard applet uses it for both the foreground applet and the inline keyboard;
    /// the service / game threads never wait for the player.
    /// </summary>
    public interface IAsyncTextInput
    {
        /// <summary>
        /// Shows a text input. <paramref name="done"/> is called at most once, later and on any thread except the caller's:
        /// (true, text) when the player confirms, (false, null) when the player or the host cancels.
        /// Returns null when the host has no interactive input right now (unattended run); the caller then answers
        /// through <see cref="IHostUIHandler.DisplayInputDialog"/>. Disposing the handle dismisses the input; a late
        /// <paramref name="done"/> may still arrive and must be ignored by the caller.
        /// </summary>
        IDisposable BeginTextInput(SoftwareKeyboardUIArgs args, Action<bool, string> done);
    }
}
