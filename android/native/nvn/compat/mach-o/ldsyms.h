#pragma once
static const int _mh_execute_header = 0;
static inline const void *_dyld_get_image_header(unsigned i) { (void)i; return 0; }
static inline intptr_t _dyld_get_image_vmaddr_slide(unsigned i) { (void)i; return 0; }
