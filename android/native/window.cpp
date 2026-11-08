#include "window.h"
#include "game_touch.h"
#include "host_android.h"
#include <android/log.h>
#include <android/set_abort_message.h>
#include <chrono>
#include <cstdlib>
#include <stdexcept>
#include <vector>

namespace {
constexpr int kDeadlineMs = 1000;

// The render thread missed a deadline inside the driver and may still touch the window or the
// device, so this process cannot go on (Android implementation plan §4.2 / §7.3: no return with
// a thread still on the old surface). abort() leaves a tombstone with every thread's stack,
// including the driver call that did not return; the reason is its abort message.
[[noreturn]] void give_up(const std::string &why) {
    __android_log_print(ANDROID_LOG_FATAL, "S2Arm", "%s", why.c_str());
    android_set_abort_message(why.c_str());
    abort();
}

void retain_window(void *window) { ANativeWindow_acquire(static_cast<ANativeWindow *>(window)); }
void release_window(void *window) { ANativeWindow_release(static_cast<ANativeWindow *>(window)); }
const s2a_wsi_window_ops kWindowOps = {retain_window, release_window};

// Display rotation (Surface.ROTATION_*) as the Vulkan surface transform it implies.
uint32_t transform_of(int rotation) {
    static const uint32_t bits[4] = {VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR, VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR,
                                     VK_SURFACE_TRANSFORM_ROTATE_180_BIT_KHR, VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR};
    return bits[rotation & 3];
}
}

// 直接后端（nvn_vk）的窗口撤销发布标记：surfaceCreated 交出新 generation 后清掉，下一次
// present 才会重新 take/attach；没有直接后端时该弱符号为 null。
extern "C" void s2a_direct_vk_on_window_offered(void) __attribute__((weak));

AndroidWindow::AndroidWindow(bool game_runtime) : game_runtime_(game_runtime) {
    lease_ = s2a_wsi_create(1, &kWindowOps);   // one guest session per process (plan §4.2)
    if (!lease_) throw std::runtime_error("window lease allocation failed");
    s2a_wsi_api_fill(lease_, &api_);
    s2a_android_host_set_lease(lease_);          // HostApi display reads its current revision
    if (game_runtime_) {
        description_ = "Game window: waiting for the service renderer";
        return;   // 游戏只由服务层 Vulkan renderer 消费这个 lease。
    }
    const char *extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME};
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "S2Arm Android";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo create{};
    create.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create.pApplicationInfo = &app;
    create.enabledExtensionCount = 2;
    create.ppEnabledExtensionNames = extensions;
    VkResult result = vkCreateInstance(&create, nullptr, &instance_);
    if (result != VK_SUCCESS) {
        instance_ = VK_NULL_HANDLE;
        description_ = "Vulkan 1.1 unavailable (" + std::to_string(result) + ")"; return;
    }
    uint32_t count = 0;
    result = vkEnumeratePhysicalDevices(instance_, &count, nullptr);
    if (result != VK_SUCCESS || !count) { description_ = "No Vulkan GPU available"; return; }
    std::vector<VkPhysicalDevice> devices(count);
    result = vkEnumeratePhysicalDevices(instance_, &count, devices.data());
    if (result != VK_SUCCESS) { description_ = "Vulkan GPU enumeration failed"; return; }
    description_ = "Vulkan:";
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceProperties properties{};
        vkGetPhysicalDeviceProperties(devices[i], &properties);
        description_ += "\n" + std::string(properties.deviceName) + " ("
            + std::to_string(VK_VERSION_MAJOR(properties.apiVersion)) + "."
            + std::to_string(VK_VERSION_MINOR(properties.apiVersion)) + ")";
    }
}

AndroidWindow::~AndroidWindow() {
    // The render thread finishes (device included) before the instance goes away.
    if (presenter_ && !presenter_->stop(kDeadlineMs))
        give_up("Vulkan presenter did not stop within " + std::to_string(kDeadlineMs) + " ms (render thread stuck)");
    presenter_.reset();
    s2a_android_host_unset_lease(lease_);
    s2a_wsi_destroy(lease_);
    if (instance_) vkDestroyInstance(instance_, nullptr);
}

Presenter *AndroidWindow::presenter() {
    if (game_runtime_) return nullptr;
    if (!presenter_ && instance_) presenter_ = std::make_unique<Presenter>(instance_, lease_);
    return presenter_.get();
}
std::string AndroidWindow::describe() const { return description_; }

bool AndroidWindow::ready_for_game() const {
    s2a_wsi_state state{};
    s2a_wsi_peek(lease_, &state);
    return game_runtime_ && surface_offered_ && generation_ && state.generation == generation_ && state.revision
        && state.width > 0 && state.height > 0 && state.foreground && !state.stopping;
}

std::string AndroidWindow::offer(ANativeWindow *window) {
    if (!window) return "Android surface unavailable";
    if (!game_runtime_ && !instance_) { ANativeWindow_release(window); return "Vulkan surface unavailable"; }
    presenter();
    std::string size = std::to_string(ANativeWindow_getWidth(window)) + " × " + std::to_string(ANativeWindow_getHeight(window));
    generation_ = s2a_wsi_offer(lease_, window);
    surface_offered_ = generation_ != 0;
    if (surface_offered_) s2a_android_game_touch_offer(generation_);
    if (surface_offered_ && s2a_direct_vk_on_window_offered) s2a_direct_vk_on_window_offered();
    ANativeWindow_release(window);
    return "Vulkan surface generation " + std::to_string(generation_) + " offered to the render thread: " + size;
}

std::string AndroidWindow::update(int width, int height, int rotation, const int32_t insets[4], float refresh_hz) {
    s2a_wsi_update(lease_, width, height, transform_of(rotation), insets, refresh_hz);
    return "Vulkan surface generation " + std::to_string(generation_) + ": " + std::to_string(width) + " × "
        + std::to_string(height) + ", rotation " + std::to_string(rotation * 90) + "°, "
        + std::to_string(static_cast<int>(refresh_hz + 0.5f)) + " Hz";
}

void AndroidWindow::set_foreground(bool foreground) {
    if (!game_runtime_ && !presenter()) return;   // onResume comes before the first surface
    s2a_wsi_set_foreground(lease_, foreground);
}

// 直接后端（nvn_vk）在 activate 时拿走窗口租约并持有到窗口撤销；窗口撤销前必须先拆交换链、
// 观察最后一帧的 present fence，再归还租约。没有直接后端时这两个弱符号为 null。
extern "C" void s2a_direct_vk_release_window(void) __attribute__((weak));
// 后端保留窗口租约（呈现退休没有证明）时的具体原因；用于 surfaceDestroyed 的 tombstone。
extern "C" const char *s2a_direct_vk_window_error(void) __attribute__((weak));


std::string AndroidWindow::release() {
    // Android: once surfaceDestroyed returns, no thread may use the surface; holding an
    // ANativeWindow reference does not extend that. The render thread waits at most one
    // bounded acquire, so this rarely takes more than a frame.
    auto start = std::chrono::steady_clock::now();
    surface_offered_ = false;
    if (s2a_direct_vk_release_window) s2a_direct_vk_release_window();
    int rc = s2a_wsi_revoke(lease_, kDeadlineMs);
    long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    if (rc) {
        std::string why = "surfaceDestroyed: render thread still on the surface after " + std::to_string(ms) + " ms";
        if (s2a_direct_vk_window_error && s2a_direct_vk_window_error()[0])
            why += std::string(" (") + s2a_direct_vk_window_error() + ")";
        give_up(why);
    }
    return "Surface generation " + std::to_string(generation_) + " detached in " + std::to_string(ms) + " ms";
}

void AndroidWindow::set_release_stall(int ms) {
    if (Presenter *p = presenter()) p->set_release_stall(ms);
}

void AndroidWindow::set_stop_stall(int ms) {
    if (Presenter *p = presenter()) p->set_stop_stall(ms);
}
