#include "direct_wsi_plan.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    VkSurfaceCapabilitiesKHR host = {.minImageCount=4,.maxImageCount=64,.currentExtent={2772,1240},
        .supportedUsageFlags=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
    VkSurfaceCapabilitiesKHR guest;
    assert(s2a_vi_capabilities(&host,&guest)==VK_SUCCESS);
    assert(host.minImageCount==4 && host.maxImageCount==64);
    assert(guest.minImageCount==3 && guest.maxImageCount==3 && guest.currentExtent.width==UINT32_MAX);
    host.supportedUsageFlags=0;
    assert(s2a_vi_capabilities(&host,&guest)==VK_ERROR_FORMAT_NOT_SUPPORTED);
    VkRect2D r;
    assert(s2a_vi_fit((VkExtent2D){1280,720},(VkExtent2D){2772,1240},&r));
    assert(r.offset.x==284 && r.offset.y==0 && r.extent.width==2204 && r.extent.height==1240);
    assert(s2a_vi_fit((VkExtent2D){1280,720},(VkExtent2D){1080,1920},&r));
    assert(r.offset.x==0 && r.offset.y==656 && r.extent.width==1080 && r.extent.height==607);
    assert(s2a_vi_fit((VkExtent2D){1280,720},(VkExtent2D){1280,720},&r));
    assert(!r.offset.x && !r.offset.y && r.extent.width==1280 && r.extent.height==720);
    assert(!s2a_vi_fit((VkExtent2D){0,720},(VkExtent2D){1280,720},&r));
    assert(!s2a_vi_fit((VkExtent2D){1,1},(VkExtent2D){UINT32_MAX,1},&r));
    assert(s2a_vi_layout(VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)==VK_IMAGE_LAYOUT_GENERAL);
    assert(s2a_vi_layout(VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)==VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    puts("PASS VI logical/host image count, aspect fit and layout plan");
}
