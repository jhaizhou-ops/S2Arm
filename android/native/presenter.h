#pragma once
#include <android/native_window.h>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <vulkan/vulkan.h>
#include "wsi_lease.h"

// Vulkan presentation on the app's SurfaceView, owned by one render thread that takes the
// window from the §7.3 lease (wsi_lease.h): a new generation rebuilds the surface, a new
// revision of the same generation only the swapchain, and a revoked generation is released and
// acknowledged. The shell never waits for the GPU except through the lease's bounded revoke and
// the bounded stop() here; a missed deadline is the caller's to handle (AndroidWindow ends the
// process). The frame is a time-varying clear colour, enough to exercise acquire / present,
// swapchain recreation, pre-rotation and frame pacing ahead of the shared Vulkan renderer.
class Presenter {
public:
    // The lease outlives the presenter (AndroidWindow owns both).
    Presenter(VkInstance instance, s2a_wsi_lease *lease);
    ~Presenter();
    // Main thread: ends the render thread, Vulkan teardown included; false after
    // timeout_ms, when the thread is still running.
    bool stop(int timeout_ms);
    // Debug: the render thread sleeps this long before letting go of a revoked window,
    // standing in for a driver call that does not return, so the timeout path can be run on devices.
    void set_release_stall(int ms);
    // Debug: the same before the render thread's teardown in stop(), for the teardown deadline.
    void set_stop_stall(int ms);
    std::string summary();

private:
    struct Frame { VkCommandBuffer cmd = VK_NULL_HANDLE; VkSemaphore acquired = VK_NULL_HANDLE; VkFence done = VK_NULL_HANDLE; };

    void run();
    void frame();
    bool open_surface(ANativeWindow *window);
    VkResult create_device();
    VkResult create_swapchain();
    bool surface_changed();
    void destroy_swapchain();
    void destroy_surface();
    VkResult draw();
    VkResult create_markers();
    VkExtent2D identity_extent(const VkSurfaceCapabilitiesKHR &caps);
    VkRect2D to_image(int x, int y, int w, int h);
    void log_stats(bool force);

    VkInstance instance_;
    s2a_wsi_lease *lease_;
    // Shared with the main thread, under mutex_.
    std::mutex mutex_;
    std::condition_variable exited_cv_;
    bool exited_ = false;
    int release_stall_ms_ = 0, stop_stall_ms_ = 0;
    std::string summary_ = "Vulkan presenter idle";

    // Render thread only.
    ANativeWindow *window_ = nullptr;
    VkSurfaceKHR surface_ = VK_NULL_HANDLE;
    VkPhysicalDevice gpu_ = VK_NULL_HANDLE;
    VkDevice device_ = VK_NULL_HANDLE;
    uint32_t family_ = 0;
    VkQueue queue_ = VK_NULL_HANDLE;
    VkCommandPool pool_ = VK_NULL_HANDLE;
    Frame frames_[2];
    unsigned frame_ = 0;
    VkSwapchainKHR swapchain_ = VK_NULL_HANDLE;
    std::vector<VkImage> images_;
    std::vector<VkSemaphore> finished_;   // per swapchain image
    VkExtent2D extent_{};   // swapchain images: the display's natural orientation (pre-rotation)
    VkBuffer marker_buffer_ = VK_NULL_HANDLE;
    VkDeviceMemory marker_memory_ = VK_NULL_HANDLE;
    VkFormat marker_format_ = VK_FORMAT_UNDEFINED;
    VkSurfaceTransformFlagBitsKHR transform_ = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    VkFormat format_ = VK_FORMAT_UNDEFINED;
    bool dirty_ = false;          // resize / SUBOPTIMAL: rebuild only if the surface changed
    bool out_of_date_ = false;    // OUT_OF_DATE: rebuild regardless
    uint64_t presented_ = 0, recreated_ = 0, timeouts_ = 0;
    int64_t last_present_ns_ = 0, interval_sum_ns_ = 0, interval_max_ns_ = 0, last_log_ns_ = 0;
    uint64_t intervals_ = 0;
    std::thread thread_;
};
