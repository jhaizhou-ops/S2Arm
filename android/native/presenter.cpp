#include "presenter.h"
#include <algorithm>
#include <cerrno>
#include <android/log.h>
#include <chrono>
#include <cmath>
#include <cstdio>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)

namespace {
constexpr uint64_t kAcquireTimeoutNs = 50'000'000;   // the loop notices lifecycle changes within one wait

int64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
}

Presenter::Presenter(VkInstance instance, s2a_wsi_lease *lease)
    : instance_(instance), lease_(lease), thread_(&Presenter::run, this) {}

Presenter::~Presenter() {
    s2a_wsi_stop(lease_);
    if (thread_.joinable()) thread_.join();   // AndroidWindow calls stop() first, with a deadline
}

bool Presenter::stop(int timeout_ms) {
    s2a_wsi_stop(lease_);
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!exited_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return exited_; })) return false;
    }
    thread_.join();   // past its last statement already
    return true;
}

void Presenter::set_release_stall(int ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    release_stall_ms_ = ms;
}

void Presenter::set_stop_stall(int ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_stall_ms_ = ms;
}

std::string Presenter::summary() {
    std::lock_guard<std::mutex> lock(mutex_);
    return summary_;
}

void Presenter::run() {
    s2a_wsi_state seen{}, cur{};
    uint64_t held = 0;   // generation whose window this thread holds (window_)
    for (;;) {
        // Idle (background, no swapchain) means sleeping in the lease, not spinning; while
        // presenting, only look whether something changed before the next frame.
        bool busy = seen.foreground && swapchain_;
        if (!s2a_wsi_wait(lease_, &seen, busy ? 0 : -1)) {
            if (busy) frame();
            continue;
        }
        bool busy_take = s2a_wsi_take(lease_, &cur) == EBUSY;   // a newer window while we hold the old one
        if (held && (busy_take || cur.stopping || !cur.window || cur.generation != held)) {   // revoked or replaced
            int stall_ms;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stall_ms = release_stall_ms_;
            }
            if (stall_ms > 0 && !cur.stopping) {
                LOG("Vulkan present: debug stall of %d ms before releasing the surface", stall_ms);
                std::this_thread::sleep_for(std::chrono::milliseconds(stall_ms));
            }
            destroy_surface();
            s2a_wsi_released(lease_, held);
            held = 0;
            std::lock_guard<std::mutex> lock(mutex_);
            summary_ = "Vulkan presenter: no surface (" + std::to_string(presented_) + " frames presented so far)";
            LOG("%s", summary_.c_str());
        }
        if (busy_take) s2a_wsi_take(lease_, &cur);   // the old generation is released now
        if (cur.stopping) {
            if (cur.window) s2a_wsi_release_window(lease_, cur.window);
            break;
        }
        if (cur.window && cur.generation != held) {   // a new window: new surface and swapchain
            if (open_surface(static_cast<ANativeWindow *>(cur.window))) {
                held = cur.generation;
                LOG("Vulkan present: surface generation %llu", (unsigned long long)held);
            } else {
                s2a_wsi_released(lease_, cur.generation);   // nothing of it is kept
            }
        } else if (cur.window && cur.revision != seen.revision) {   // same window, new size / rotation / insets
            if (swapchain_) dirty_ = true;
            else if (surface_ && create_swapchain() != VK_SUCCESS) destroy_swapchain();
        }
        if (cur.window) s2a_wsi_release_window(lease_, cur.window);   // open_surface keeps its own reference
        seen = cur;
        if (seen.foreground && swapchain_) frame();
    }
    int stop_stall;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stop_stall = stop_stall_ms_;
    }
    if (stop_stall > 0) {
        LOG("Vulkan present: debug stall of %d ms before teardown", stop_stall);
        std::this_thread::sleep_for(std::chrono::milliseconds(stop_stall));
    }
    if (device_) vkDeviceWaitIdle(device_);
    destroy_surface();
    if (device_) {
        for (Frame &f : frames_) {
            if (f.done) vkDestroyFence(device_, f.done, nullptr);
            if (f.acquired) vkDestroySemaphore(device_, f.acquired, nullptr);
        }
        if (pool_) vkDestroyCommandPool(device_, pool_, nullptr);
        if (marker_buffer_) vkDestroyBuffer(device_, marker_buffer_, nullptr);
        if (marker_memory_) vkFreeMemory(device_, marker_memory_, nullptr);
        vkDestroyDevice(device_, nullptr);
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        exited_ = true;
    }
    exited_cv_.notify_all();
}

// One frame, rebuilding the swapchain first when the surface asked for it.
void Presenter::frame() {
    if (out_of_date_ || (dirty_ && surface_changed())) {
        VkResult r = create_swapchain();
        if (r != VK_SUCCESS) { LOG("Vulkan present: swapchain recreation failed (%d)", r); destroy_swapchain(); return; }
    }
    VkResult r = draw();
    if (r != VK_SUCCESS && r != VK_TIMEOUT) { LOG("Vulkan present: frame failed (%d)", r); destroy_swapchain(); }
}

// A new window: surface (holding a window reference of its own), device on first use, swapchain.
bool Presenter::open_surface(ANativeWindow *window) {
    destroy_surface();
    VkAndroidSurfaceCreateInfoKHR info{};
    info.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
    info.window = window;
    VkResult r = vkCreateAndroidSurfaceKHR(instance_, &info, nullptr, &surface_);
    if (r != VK_SUCCESS) { surface_ = VK_NULL_HANDLE; LOG("Vulkan present: surface creation failed (%d)", r); return false; }
    window_ = window;
    ANativeWindow_acquire(window_);
    if (!device_ && (r = create_device()) != VK_SUCCESS) { LOG("Vulkan present: device creation failed (%d)", r); destroy_surface(); return false; }
    VkBool32 present = VK_FALSE;
    vkGetPhysicalDeviceSurfaceSupportKHR(gpu_, family_, surface_, &present);
    if (!present) { LOG("Vulkan present: queue family %u cannot present to this surface", family_); destroy_surface(); return false; }
    r = create_swapchain();
    if (r != VK_SUCCESS) { LOG("Vulkan present: swapchain creation failed (%d)", r); destroy_surface(); return false; }
    return true;
}

VkResult Presenter::create_device() {
    uint32_t count = 0;
    VkResult r = vkEnumeratePhysicalDevices(instance_, &count, nullptr);
    if (r != VK_SUCCESS || !count) return r != VK_SUCCESS ? r : VK_ERROR_INITIALIZATION_FAILED;
    std::vector<VkPhysicalDevice> gpus(count);
    vkEnumeratePhysicalDevices(instance_, &count, gpus.data());
    for (VkPhysicalDevice gpu : gpus) {
        uint32_t n = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &n, nullptr);
        std::vector<VkQueueFamilyProperties> families(n);
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &n, families.data());
        for (uint32_t i = 0; i < n; i++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(gpu, i, surface_, &present);
            if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) { gpu_ = gpu; family_ = i; break; }
        }
        if (gpu_) break;
    }
    if (!gpu_) return VK_ERROR_INITIALIZATION_FAILED;
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue{};
    queue.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue.queueFamilyIndex = family_;
    queue.queueCount = 1;
    queue.pQueuePriorities = &priority;
    const char *extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    info.queueCreateInfoCount = 1;
    info.pQueueCreateInfos = &queue;
    info.enabledExtensionCount = 1;
    info.ppEnabledExtensionNames = extensions;
    if ((r = vkCreateDevice(gpu_, &info, nullptr, &device_)) != VK_SUCCESS) { device_ = VK_NULL_HANDLE; return r; }
    vkGetDeviceQueue(device_, family_, 0, &queue_);
    VkCommandPoolCreateInfo pool{};
    pool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = family_;
    if ((r = vkCreateCommandPool(device_, &pool, nullptr, &pool_)) != VK_SUCCESS) return r;
    for (Frame &f : frames_) {
        VkCommandBufferAllocateInfo alloc{};
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.commandPool = pool_;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = 1;
        VkSemaphoreCreateInfo sem{};
        sem.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        VkFenceCreateInfo fence{};
        fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        if ((r = vkAllocateCommandBuffers(device_, &alloc, &f.cmd)) != VK_SUCCESS
            || (r = vkCreateSemaphore(device_, &sem, nullptr, &f.acquired)) != VK_SUCCESS
            || (r = vkCreateFence(device_, &fence, nullptr, &f.done)) != VK_SUCCESS) return r;
    }
    VkPhysicalDeviceProperties props{};
    vkGetPhysicalDeviceProperties(gpu_, &props);
    LOG("Vulkan present: device %s, queue family %u", props.deviceName, family_);
    return VK_SUCCESS;
}

// SurfaceView reports a resize, and SUBOPTIMAL fires, for more than real changes (surfaceCreated
// and surfaceChanged both arrive; rotation sends several): rebuild only for a new extent or transform.
bool Presenter::surface_changed() {
    dirty_ = false;
    VkSurfaceCapabilitiesKHR caps{};
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu_, surface_, &caps) != VK_SUCCESS) return true;
    VkExtent2D extent = identity_extent(caps);
    return extent.width != extent_.width || extent.height != extent_.height || caps.currentTransform != transform_;
}

// Android reports currentExtent in the current (rotated) orientation. With pre-rotation the
// swapchain is built in the display's natural orientation: swap for 90 / 270 degrees
// (developer.android.com, "Handle device orientation with Vulkan pre-rotation").
VkExtent2D Presenter::identity_extent(const VkSurfaceCapabilitiesKHR &caps) {
    VkExtent2D e = caps.currentExtent;
    if (e.width == UINT32_MAX) {
        e.width = (uint32_t)ANativeWindow_getWidth(window_);
        e.height = (uint32_t)ANativeWindow_getHeight(window_);
    }
    if (caps.currentTransform & (VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR | VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR))
        std::swap(e.width, e.height);
    return e;
}

// A rectangle in what the user sees (x right, y down, in the rotated display) to the
// pre-rotated swapchain image. ROTATE_90 / 270 directions are checked on devices with
// the corner markers (screenshots), not assumed.
VkRect2D Presenter::to_image(int x, int y, int w, int h) {
    int iw = (int)extent_.width, ih = (int)extent_.height;
    VkRect2D r{};
    switch (transform_) {
    case VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR:  r = {{iw - (y + h), x}, {(uint32_t)h, (uint32_t)w}}; break;
    case VK_SURFACE_TRANSFORM_ROTATE_180_BIT_KHR: r = {{iw - (x + w), ih - (y + h)}, {(uint32_t)w, (uint32_t)h}}; break;
    case VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR: r = {{y, ih - (x + w)}, {(uint32_t)h, (uint32_t)w}}; break;
    default: r = {{x, y}, {(uint32_t)w, (uint32_t)h}}; break;
    }
    return r;
}

// Two solid blocks copied each frame: red square at the user's top-left, wider green
// bar at the user's top-right. Different shapes, so rotation and mirroring both show.
VkResult Presenter::create_markers() {
    if (marker_buffer_ && marker_format_ == format_) return VK_SUCCESS;
    if (format_ != VK_FORMAT_R8G8B8A8_UNORM && format_ != VK_FORMAT_B8G8R8A8_UNORM) return VK_SUCCESS;   // no markers
    if (marker_buffer_) { vkDestroyBuffer(device_, marker_buffer_, nullptr); vkFreeMemory(device_, marker_memory_, nullptr); }
    const VkDeviceSize pixels = 2 * 240 * 240;
    VkBufferCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = pixels * 4;
    info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    VkResult r = vkCreateBuffer(device_, &info, nullptr, &marker_buffer_);
    if (r != VK_SUCCESS) { marker_buffer_ = VK_NULL_HANDLE; return r; }
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device_, marker_buffer_, &req);
    VkPhysicalDeviceMemoryProperties mem;
    vkGetPhysicalDeviceMemoryProperties(gpu_, &mem);
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < mem.memoryTypeCount && type == UINT32_MAX; i++)
        if ((req.memoryTypeBits & (1u << i)) && (mem.memoryTypes[i].propertyFlags
            & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
                == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) type = i;
    VkMemoryAllocateInfo alloc{};
    alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = type;
    if (type == UINT32_MAX || (r = vkAllocateMemory(device_, &alloc, nullptr, &marker_memory_)) != VK_SUCCESS
        || (r = vkBindBufferMemory(device_, marker_buffer_, marker_memory_, 0)) != VK_SUCCESS) {
        vkDestroyBuffer(device_, marker_buffer_, nullptr);
        marker_buffer_ = VK_NULL_HANDLE;
        return r != VK_SUCCESS ? r : VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    uint8_t *p = nullptr;
    vkMapMemory(device_, marker_memory_, 0, VK_WHOLE_SIZE, 0, (void **)&p);
    bool bgra = format_ == VK_FORMAT_B8G8R8A8_UNORM;
    for (VkDeviceSize i = 0; i < pixels; i++) {
        bool red = i < pixels / 2;
        uint8_t r8 = red ? 255 : 0, g8 = red ? 0 : 255;
        p[4 * i + 0] = bgra ? 0 : r8;
        p[4 * i + 1] = g8;
        p[4 * i + 2] = bgra ? r8 : 0;
        p[4 * i + 3] = 255;
    }
    vkUnmapMemory(device_, marker_memory_);
    marker_format_ = format_;
    return VK_SUCCESS;
}

// (Re)create the swapchain for surface_, handing the old one over (oldSwapchain).
VkResult Presenter::create_swapchain() {
    vkDeviceWaitIdle(device_);
    VkSurfaceCapabilitiesKHR caps{};
    VkResult r = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu_, surface_, &caps);
    if (r != VK_SUCCESS) return r;
    uint32_t n = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(gpu_, surface_, &n, nullptr);
    std::vector<VkSurfaceFormatKHR> formats(n);
    vkGetPhysicalDeviceSurfaceFormatsKHR(gpu_, surface_, &n, formats.data());
    if (!n || !(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    VkSurfaceFormatKHR format = formats[0];
    for (const VkSurfaceFormatKHR &f : formats)
        if (f.format == VK_FORMAT_R8G8B8A8_UNORM || f.format == VK_FORMAT_B8G8R8A8_UNORM) { format = f; break; }
    // Pre-rotation: present in the display's orientation so the compositor does not rotate
    // every frame, and SUBOPTIMAL does not fire for the transform.
    transform_ = (caps.supportedTransforms & caps.currentTransform) ? caps.currentTransform : VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    extent_ = identity_extent(caps);
    VkSwapchainCreateInfoKHR info{};
    info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    info.surface = surface_;
    info.minImageCount = std::max(3u, caps.minImageCount);
    if (caps.maxImageCount) info.minImageCount = std::min(info.minImageCount, caps.maxImageCount);
    info.imageFormat = format.format;
    info.imageColorSpace = format.colorSpace;
    info.imageExtent = extent_;
    info.imageArrayLayers = 1;
    info.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = transform_;
    info.compositeAlpha = (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    info.clipped = VK_TRUE;
    info.oldSwapchain = swapchain_;
    VkSwapchainKHR fresh = VK_NULL_HANDLE;
    r = vkCreateSwapchainKHR(device_, &info, nullptr, &fresh);
    destroy_swapchain();   // the retired one, handed over as oldSwapchain
    if (r != VK_SUCCESS) return r;
    swapchain_ = fresh;
    format_ = format.format;
    if (create_markers() != VK_SUCCESS) LOG("Vulkan present: orientation markers unavailable");
    vkGetSwapchainImagesKHR(device_, swapchain_, &n, nullptr);
    images_.resize(n);
    vkGetSwapchainImagesKHR(device_, swapchain_, &n, images_.data());
    finished_.assign(n, VK_NULL_HANDLE);
    for (VkSemaphore &s : finished_) {
        VkSemaphoreCreateInfo sem{};
        sem.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if ((r = vkCreateSemaphore(device_, &sem, nullptr, &s)) != VK_SUCCESS) return r;
    }
    dirty_ = out_of_date_ = false;
    ++recreated_;
    last_present_ns_ = 0;
    char line[256];
    snprintf(line, sizeof line, "Vulkan present: swapchain %ux%u, format %d, %u images, FIFO, transform 0x%x (window %dx%d), build %llu",
             extent_.width, extent_.height, (int)format_, n, (unsigned)transform_, ANativeWindow_getWidth(window_),
             ANativeWindow_getHeight(window_), (unsigned long long)recreated_);
    LOG("%s", line);
    std::lock_guard<std::mutex> lock(mutex_);
    summary_ = line;
    return VK_SUCCESS;
}

void Presenter::destroy_swapchain() {
    if (!device_) return;
    vkDeviceWaitIdle(device_);
    for (VkSemaphore s : finished_) if (s) vkDestroySemaphore(device_, s, nullptr);
    finished_.clear();
    images_.clear();
    if (swapchain_) vkDestroySwapchainKHR(device_, swapchain_, nullptr);
    swapchain_ = VK_NULL_HANDLE;
}

void Presenter::destroy_surface() {
    destroy_swapchain();
    if (surface_) vkDestroySurfaceKHR(instance_, surface_, nullptr);
    surface_ = VK_NULL_HANDLE;
    if (window_) ANativeWindow_release(window_);
    window_ = nullptr;
    dirty_ = out_of_date_ = false;
}

VkResult Presenter::draw() {
    Frame &f = frames_[frame_];
    VkResult r = vkWaitForFences(device_, 1, &f.done, VK_TRUE, UINT64_MAX);
    if (r != VK_SUCCESS) return r;
    uint32_t index = 0;
    r = vkAcquireNextImageKHR(device_, swapchain_, kAcquireTimeoutNs, f.acquired, VK_NULL_HANDLE, &index);
    if (r == VK_TIMEOUT || r == VK_NOT_READY) { ++timeouts_; return VK_TIMEOUT; }
    if (r == VK_ERROR_OUT_OF_DATE_KHR) { out_of_date_ = true; return VK_SUCCESS; }
    if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) return r;
    if (r == VK_SUBOPTIMAL_KHR) dirty_ = true;   // after this frame
    vkResetFences(device_, 1, &f.done);
    vkResetCommandBuffer(f.cmd, 0);
    VkCommandBufferBeginInfo begin{};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(f.cmd, &begin);
    VkImageMemoryBarrier barrier{};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = images_[index];
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdPipelineBarrier(f.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    double t = now_ns() / 1e9;
    VkClearColorValue colour{};
    colour.float32[0] = (float)(0.5 + 0.5 * std::sin(t));
    colour.float32[1] = (float)(0.5 + 0.5 * std::sin(t + 2.1));
    colour.float32[2] = (float)(0.5 + 0.5 * std::sin(t + 4.2));
    colour.float32[3] = 1.0f;
    vkCmdClearColorImage(f.cmd, images_[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &barrier.subresourceRange);
    if (marker_buffer_ && marker_format_ == format_) {
        bool sideways = transform_ & (VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR | VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR);
        int dw = (int)(sideways ? extent_.height : extent_.width);   // what the user sees
        VkRect2D marks[2] = {to_image(40, 40, 240, 240), to_image(dw - 40 - 240 * 2, 40, 240 * 2, 120)};
        VkBufferImageCopy copies[2]{};
        for (int i = 0; i < 2; i++) {
            copies[i].bufferOffset = i ? 240 * 240 * 4 : 0;   // red, then green
            copies[i].imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
            copies[i].imageOffset = {marks[i].offset.x, marks[i].offset.y, 0};
            copies[i].imageExtent = {marks[i].extent.width, marks[i].extent.height, 1};
        }
        VkMemoryBarrier order{};   // the clear and the copies write the same image
        order.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        order.srcAccessMask = order.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(f.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &order, 0, nullptr, 0, nullptr);
        vkCmdCopyBufferToImage(f.cmd, marker_buffer_, images_[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, copies);
    }
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(f.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    vkEndCommandBuffer(f.cmd);
    VkPipelineStageFlags wait = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit{};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &f.acquired;
    submit.pWaitDstStageMask = &wait;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &f.cmd;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &finished_[index];
    if ((r = vkQueueSubmit(queue_, 1, &submit, f.done)) != VK_SUCCESS) return r;
    VkPresentInfoKHR present{};
    present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &finished_[index];
    present.swapchainCount = 1;
    present.pSwapchains = &swapchain_;
    present.pImageIndices = &index;
    r = vkQueuePresentKHR(queue_, &present);
    frame_ ^= 1;
    if (r == VK_ERROR_OUT_OF_DATE_KHR) out_of_date_ = true;
    else if (r == VK_SUBOPTIMAL_KHR) dirty_ = true;
    else if (r != VK_SUCCESS) return r;
    int64_t now = now_ns();
    if (last_present_ns_) {
        int64_t interval = now - last_present_ns_;
        interval_sum_ns_ += interval;
        interval_max_ns_ = std::max(interval_max_ns_, interval);
        ++intervals_;
    }
    last_present_ns_ = now;
    ++presented_;
    log_stats(false);
    return VK_SUCCESS;
}

// Every 2 s while presenting: frame pacing since the last report.
void Presenter::log_stats(bool force) {
    int64_t now = now_ns();
    if (!force && now - last_log_ns_ < 2'000'000'000) return;
    last_log_ns_ = now;
    char line[256];
    snprintf(line, sizeof line, "Vulkan present: %llu frames, interval avg %.2f ms max %.2f ms over %llu, %ux%u transform 0x%x, %llu builds, %llu acquire timeouts",
             (unsigned long long)presented_, intervals_ ? interval_sum_ns_ / 1e6 / intervals_ : 0.0, interval_max_ns_ / 1e6,
             (unsigned long long)intervals_, extent_.width, extent_.height, (unsigned)transform_,
             (unsigned long long)recreated_, (unsigned long long)timeouts_);
    LOG("%s", line);
    interval_sum_ns_ = interval_max_ns_ = 0;
    intervals_ = 0;
    std::lock_guard<std::mutex> lock(mutex_);
    summary_ = line;
}
