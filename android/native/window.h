#pragma once
#include "presenter.h"
#include <android/native_window.h>
#include <memory>
#include <string>
#include <vulkan/vulkan.h>

// Vulkan instance + GPU description, and the §7.3 window lease (wsi_lease.h) between the
// SurfaceHolder callbacks and the Presenter's render thread.
class AndroidWindow {
public:
    explicit AndroidWindow(bool game_runtime = false);
    ~AndroidWindow();
    // surfaceCreated, main thread, non-blocking: a new window generation. Takes ownership of
    // the reference returned by ANativeWindow_fromSurface (the lease keeps its own).
    std::string offer(ANativeWindow *window);
    // surfaceChanged / insets / rotation: a new revision of the current window; non-blocking.
    std::string update(int width, int height, int rotation, const int32_t insets[4], float refresh_hz);
    void set_foreground(bool foreground);
    // surfaceDestroyed: revokes the window and returns once the render thread no longer uses
    // it. Revoke and teardown each have a deadline; missing one ends the process (it never returns).
    std::string release();
    // Debug (intent extra s2arm.release_stall_ms): delays the render thread's release.
    void set_release_stall(int ms);
    // Debug (s2arm.stop_stall_ms): delays the render thread's teardown.
    void set_stop_stall(int ms);
    std::string describe() const;
    const s2a_wsi_api *runtime_api() const { return &api_; }
    bool ready_for_game() const;
private:
    Presenter *presenter();   // created on first use: a render thread, asleep until there is work
    VkInstance instance_ = VK_NULL_HANDLE;
    s2a_wsi_lease *lease_ = nullptr;
    s2a_wsi_api api_{};
    const bool game_runtime_;
    uint64_t generation_ = 0;   // last offered, for the status line
    bool surface_offered_ = false;
    std::unique_ptr<Presenter> presenter_;
    std::string description_;
};
