// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <TargetConditionals.h>

typedef NS_ENUM(NSInteger, S2APlaySplitMode) { S2APlaySplitAuto, S2APlaySplitOn, S2APlaySplitOff };
typedef NS_ENUM(NSInteger, S2APlayOrientation) { S2APlayOrientationAuto, S2APlayOrientationLandscape, S2APlayOrientationPortrait };
extern NSString *const S2APlaySplitKey, *const S2APlayOrientationKey, *const S2APlayLayoutChanged;
typedef struct { CGRect game, controls, division; BOOL split; } S2APlayLayout;
S2APlaySplitMode S2APlayReadSplit(NSUserDefaults *defaults);
S2APlayOrientation S2APlayReadOrientation(NSUserDefaults *defaults);
BOOL S2APlaySplitEnabled(S2APlaySplitMode mode, BOOL partiallyOpen);
BOOL S2APlayPortrait(S2APlayOrientation orientation, BOOL split);
// game 是可用目标区域，不是等比放入后的画面；宽屏目标必须由这个区域算，避免循环依赖。
S2APlayLayout S2APlayLayoutMake(CGRect bounds, CGRect safe, S2APlaySplitMode mode, BOOL partiallyOpen, CGRect division);
CGRect S2APlayControlsRect(S2APlayLayout layout, CGRect bounds);
CGSize S2APlayTargetSize(CGSize area);
