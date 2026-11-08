#pragma once
#import <Foundation/Foundation.h>
// 把 root 目录下所有文件按相对路径写成 dest.zip（deflate、文件名 UTF-8 标记、条目在根上）；成功返回 YES
BOOL s2a_write_zip(NSString *root, NSString *dest);
#define write_zip s2a_write_zip
