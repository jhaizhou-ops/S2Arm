// 打印本机 Metal 设备的 GPU 架构名（applegpu_gXXx），shader_pack.sh 出 macOS 包时给管线归档定架构用
#import <Metal/Metal.h>
#include <stdio.h>
int main(void) { @autoreleasepool { id<MTLDevice> d = MTLCreateSystemDefaultDevice(); if (!d) return 1; printf("%s\n", d.architecture.name.UTF8String); } return 0; }
