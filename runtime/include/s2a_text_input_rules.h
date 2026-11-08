// 系统键盘输入框的文字规则（iOS / Mac 两端共用一份）：长度按 UTF-16 码元计（同 Switch 软键盘的 StringLengthMin / Max），
//   数字模式只收 0–9，半角模式只收可见 ASCII 与空格；超长的粘贴截到上限
#pragma once
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "s2a_unattended.h"
// 弹不弹系统输入框：玩家的局弹；无人值守局（S2A_AUTOPLAY）不弹、服务层退回自动应答（普查 / 自动玩家不卡在输入框上）。
//   验收开关 S2A_TEXT_INPUT_UI=1：无人值守局也照弹（真机验收由 XCTest tools/xcui 往输入框打字，执行器起局总带 S2A_AUTOPLAY）
static inline int s2a_text_input_interactive(void) {
    const char *f = getenv("S2A_TEXT_INPUT_UI");
    return (f && strcmp(f, "1") == 0) || !s2a_unattended();
}
static inline NSString *s2a_text_input_filter(NSString *s, NSString *mode) {
    if ([mode isEqualToString:@"numeric"] || [mode isEqualToString:@"ascii"]) {
        BOOL digits = [mode isEqualToString:@"numeric"];
        NSMutableString *o = [NSMutableString stringWithCapacity:s.length];
        for (NSUInteger i = 0; i < s.length; i++) {
            unichar c = [s characterAtIndex:i];
            if (digits ? (c >= '0' && c <= '9') : (c >= 0x20 && c < 0x7f)) [o appendFormat:@"%C", c];
        }
        return o;
    }
    return s;
}
// 把 text 收进 [0, max]（max 0 = 不限）：截断不切开代理对 / 组合字符
static inline NSString *s2a_text_input_clip(NSString *text, NSInteger max) {
    if (max <= 0 || (NSInteger)text.length <= max) return text;
    // 第 max 个码元所在的字符序列从哪开始，就截到哪：序列正好从 max 开始 = 截在 max；被切开 = 整个序列不要
    return [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:(NSUInteger)max].location];
}
