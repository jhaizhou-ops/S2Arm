#import "input_guide.h"
#import "controller_view.h"

static NSString *guide_text(NSString *zh, NSString *en) {
    NSString *language = getenv("S2A_UI_LANGUAGE") ? @(getenv("S2A_UI_LANGUAGE")) : NSLocale.preferredLanguages.firstObject;
    return [language hasPrefix:@"zh"] ? zh : en;
}

static NSString *guide_key_name(NSDictionary *binding) {
    if (!binding) return @"—";
    NSDictionary *names = @{@0:@"A", @1:@"S", @2:@"D", @3:@"F", @4:@"H", @5:@"G", @6:@"Z", @7:@"X", @8:@"C", @9:@"V",
        @11:@"B", @12:@"Q", @13:@"W", @14:@"E", @15:@"R", @16:@"Y", @17:@"T", @18:@"1", @19:@"2", @20:@"3", @21:@"4", @22:@"6", @23:@"5",
        @24:@"=", @25:@"9", @26:@"7", @27:@"-", @28:@"8", @29:@"0", @30:@"]", @31:@"O", @32:@"U", @33:@"[", @34:@"I", @35:@"P",
        @36:@"Return", @37:@"L", @38:@"J", @39:@"'", @40:@"K", @41:@";", @42:@"\\", @43:@",", @44:@"/", @45:@"N", @46:@"M", @47:@".",
        @48:@"Tab", @49:guide_text(@"空格", @"Space"), @50:@"`", @51:@"Delete", @53:@"Esc", @56:@"Shift", @58:@"Option", @59:@"Control",
        @96:@"F5", @97:@"F6", @98:@"F7", @99:@"F3", @100:@"F8", @101:@"F9", @103:@"F11", @109:@"F10", @111:@"F12",
        @115:@"Home", @116:@"Page Up", @117:@"Forward Delete", @118:@"F4", @119:@"End", @120:@"F2", @121:@"Page Down", @122:@"F1", @123:@"←", @124:@"→", @125:@"↓", @126:@"↑"};
    NSInteger mods = [binding[@"modifiers"] integerValue];
    NSString *key = names[binding[@"code"]] ?: [NSString stringWithFormat:@"Key %@", binding[@"code"]];
    return [NSString stringWithFormat:@"%@%@%@%@", (mods & 1) ? @"Shift + " : @"", (mods & 2) ? @"Control + " : @"", (mods & 4) ? @"Option + " : @"", key];
}

NSArray<NSArray<NSString *> *> *s2a_mac_guide_rows(NSDictionary *mapping) {
    NSArray *targets = s2a_mac_controller_targets();
    NSDictionary *labels = @{@"PLUS":@"＋", @"MINUS":@"－",
        @"LS":guide_text(@"左摇杆按下",@"Left stick press"), @"RS":guide_text(@"右摇杆按下",@"Right stick press"),
        @"LEFT":guide_text(@"十字键左",@"D-pad left"), @"UP":guide_text(@"十字键上",@"D-pad up"),
        @"RIGHT":guide_text(@"十字键右",@"D-pad right"), @"DOWN":guide_text(@"十字键下",@"D-pad down"),
        @"LS_UP":guide_text(@"左摇杆上",@"Left stick up"), @"LS_DOWN":guide_text(@"左摇杆下",@"Left stick down"),
        @"LS_LEFT":guide_text(@"左摇杆左",@"Left stick left"), @"LS_RIGHT":guide_text(@"左摇杆右",@"Left stick right"),
        @"RS_UP":guide_text(@"右摇杆上",@"Right stick up"), @"RS_DOWN":guide_text(@"右摇杆下",@"Right stick down"),
        @"RS_LEFT":guide_text(@"右摇杆左",@"Right stick left"), @"RS_RIGHT":guide_text(@"右摇杆右",@"Right stick right")};
    NSDictionary *pads = @{@"east":guide_text(@"右侧按钮", @"Right face button"), @"south":guide_text(@"下侧按钮", @"Bottom face button"),
        @"north":guide_text(@"上侧按钮", @"Top face button"), @"west":guide_text(@"左侧按钮", @"Left face button"),
        @"leftStick":guide_text(@"左摇杆按下", @"Left stick press"), @"rightStick":guide_text(@"右摇杆按下", @"Right stick press"),
        @"leftShoulder":guide_text(@"左肩键", @"Left shoulder"), @"rightShoulder":guide_text(@"右肩键", @"Right shoulder"),
        @"leftTrigger":guide_text(@"左扳机", @"Left trigger"), @"rightTrigger":guide_text(@"右扳机", @"Right trigger"),
        @"menu":guide_text(@"菜单（＋）", @"Menu (+)"), @"options":guide_text(@"选项（－）", @"Options (-)"),
        @"dpadLeft":@"←", @"dpadUp":@"↑", @"dpadRight":@"→", @"dpadDown":@"↓"};
    NSArray *mouseNames = @[guide_text(@"鼠标左键", @"Left click"), guide_text(@"鼠标右键", @"Right click"), guide_text(@"鼠标中键", @"Middle click"), guide_text(@"鼠标侧键 1", @"Mouse 4"), guide_text(@"鼠标侧键 2", @"Mouse 5")];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSString *target in targets) {
        NSNumber *mouse = mapping[@"mouse"][target];
        NSString *mouseName = mouse && mouse.unsignedIntegerValue < mouseNames.count ? mouseNames[mouse.unsignedIntegerValue] : @"—";
        NSString *pad = pads[mapping[@"gamepad"][target]] ?: @"—";
        [rows addObject:@[labels[target] ?: target, guide_key_name(mapping[@"keyboard"][target]), mouseName, pad]];
    }
    for (NSString *axis in @[@"LX", @"LY", @"RX", @"RY"]) {
        NSDictionary *binding = mapping[@"axes"][axis];
        NSDictionary *sources = @{@"leftX":guide_text(@"左摇杆 X", @"Left stick X"), @"leftY":guide_text(@"左摇杆 Y", @"Left stick Y"), @"rightX":guide_text(@"右摇杆 X", @"Right stick X"), @"rightY":guide_text(@"右摇杆 Y", @"Right stick Y")};
        NSString *source = sources[binding[@"source"]] ?: @"—";
        if ([binding[@"invert"] boolValue]) source = [source stringByAppendingString:guide_text(@"（反转）", @" (inverted)")];
        [rows addObject:@[axis, @"—", @"—", source]];
    }
    return rows;
}

NSString *s2a_mac_guide_preference_key(NSString *gameID) {
    if (gameID.length != 16 || [gameID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"] invertedSet]].location != NSNotFound) return nil;
    return [@"S2Arm.InputGuide.Hidden." stringByAppendingString:gameID.uppercaseString];
}

NSDictionary *s2a_mac_guide_identity(void) {
    NSDictionary *manifest = @{};
    const char *root = getenv("S2A_GAME_DATA");
    if (root) {
        NSData *data = [NSData dataWithContentsOfFile:[@(root) stringByAppendingPathComponent:@"manifest.json"]];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([parsed isKindOfClass:NSDictionary.class]) manifest = parsed;
    }
    NSString *gameID = getenv("S2A_GAME_ID") ? @(getenv("S2A_GAME_ID")) : manifest[@"gameId"];
    NSString *name = getenv("S2A_GAME_NAME") ? @(getenv("S2A_GAME_NAME")) : manifest[@"gameName"];
    if (![name isKindOfClass:NSString.class] || !name.length) name = @"S2Arm Game";
    if (![gameID isKindOfClass:NSString.class] || !s2a_mac_guide_preference_key(gameID)) gameID = @"";
    return @{@"gameId":gameID, @"name":name};
}

BOOL s2a_mac_guide_show_again(NSString *gameID, NSString *path) {
    if (path.length && s2a_mac_guide_preference_key(gameID)) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([value isKindOfClass:NSDictionary.class] && [value[@"gameId"] isEqual:gameID] && [value[@"show"] isKindOfClass:NSNumber.class]) return [value[@"show"] boolValue];
        return YES;
    }
    NSString *key = s2a_mac_guide_preference_key(gameID);
    return !key || ![NSUserDefaults.standardUserDefaults boolForKey:key];
}

static NSColor *guide_surface_color(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua] ? NSColor.blackColor : NSColor.whiteColor;
    }];
}
@interface S2AGuideSurface : NSView
@property(nonatomic) BOOL border;
@end
@implementation S2AGuideSurface
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:self.border ? 10 : 0 yRadius:self.border ? 10 : 0];
    [guide_surface_color() setFill]; [shape fill];
    if (self.border) { [[NSColor.labelColor colorWithAlphaComponent:.10] setStroke]; shape.lineWidth=1; [shape stroke]; }
}
@end
@interface S2AGuideBackButton : NSButton
@end
@implementation S2AGuideBackButton
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [[NSColor colorWithSRGBRed:.17 green:.18 blue:.20 alpha:self.highlighted ? .7 : 1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:5 yRadius:5] fill];
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont boldSystemFontOfSize:13],NSForegroundColorAttributeName:NSColor.whiteColor};
    NSSize size=[self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint((NSWidth(self.bounds)-size.width)/2,(NSHeight(self.bounds)-size.height)/2) withAttributes:attributes];
}
@end
static NSTextField *guide_label(NSString *text, CGFloat size, BOOL bold) {
    NSTextField *label=[NSTextField wrappingLabelWithString:text];
    label.font=bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    label.selectable=YES; label.editable=NO; label.drawsBackground=NO; label.textColor=NSColor.labelColor;
    return label;
}
static NSTextField *guide_add_label(NSView *parent, NSString *text, NSRect frame, CGFloat size, BOOL bold, BOOL secondary) {
    NSTextField *label=guide_label(text,size,bold); label.frame=frame;
    if (secondary) label.textColor=NSColor.secondaryLabelColor;
    [parent addSubview:label]; return label;
}
static void guide_separator(NSView *parent, NSRect frame) {
    NSBox *line=[[NSBox alloc] initWithFrame:frame]; line.boxType=NSBoxSeparator; [parent addSubview:line];
}

@implementation S2AMacInputGuide {
    NSWindow *_window;
    __weak NSWindow *_gameWindow;
    NSStatusItem *_status;
    S2AReadOnlyControllerView *_controller;
    NSArray<NSArray<NSString *> *> *_rows;
    NSArray<NSTextField *> *_values;
    NSTextField *_targetLabel, *_axisLabel;
}
- (NSWindow *)window { return _window; }
- (NSString *)selectedTarget { return _controller.selectedTarget; }
- (instancetype)initWithName:(NSString *)name gameID:(NSString *)gameID mapping:(NSDictionary *)mapping gameWindow:(NSWindow *)gameWindow {
    if (!(self=[super init])) return nil;
    (void)gameID;
    _gameWindow=gameWindow;
    NSDictionary *snapshot=CFBridgingRelease(CFPropertyListCreateDeepCopy(NULL,(__bridge CFPropertyListRef)mapping,kCFPropertyListImmutable));
    _rows=s2a_mac_guide_rows(snapshot);
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1040,790) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _window.title=[name stringByAppendingString:guide_text(@" · 查看键位（只读）",@" · Controls (read-only)")];
    _window.releasedWhenClosed=NO; _window.delegate=self;
    _window.titlebarAppearsTransparent=YES; _window.backgroundColor=guide_surface_color();
    S2AGuideSurface *root=[[S2AGuideSurface alloc] initWithFrame:NSMakeRect(0,0,1040,790)]; _window.contentView=root;
    NSImageView *icon=[[NSImageView alloc] initWithFrame:NSMakeRect(24,26,32,30)]; icon.image=s2a_mac_guide_status_image(); icon.imageScaling=NSImageScaleProportionallyUpOrDown; [root addSubview:icon];
    NSTextField *nameLabel=guide_add_label(root,name,NSMakeRect(68,22,948,32),23,YES,NO);
    nameLabel.maximumNumberOfLines=1; nameLabel.lineBreakMode=NSLineBreakByTruncatingTail; nameLabel.toolTip=name;
    guide_add_label(root,guide_text(@"本局键位 · 只读。点选手柄上的按键查看对应输入。",@"This run’s controls · Read-only. Select a controller button to inspect its inputs."),NSMakeRect(24,66,992,24),13,NO,YES);
    S2AGuideSurface *left=[[S2AGuideSurface alloc] initWithFrame:NSMakeRect(24,100,558,560)]; left.border=YES; [root addSubview:left];
    _controller=[[S2AReadOnlyControllerView alloc] initWithMapping:snapshot]; [left addSubview:_controller];
    __weak S2AMacInputGuide *weakSelf=self;
    _controller.onSelect=^(NSString *target) { [weakSelf selectTarget:target]; };
    S2AGuideSurface *detail=[[S2AGuideSurface alloc] initWithFrame:NSMakeRect(600,100,416,560)]; detail.border=YES; [root addSubview:detail];
    guide_add_label(detail,guide_text(@"游戏中的提示",@"In-game prompt"),NSMakeRect(22,20,372,20),12,NO,YES);
    _targetLabel=guide_add_label(detail,@"",NSMakeRect(22,48,372,32),22,YES,NO);
    guide_separator(detail,NSMakeRect(22,88,372,1));
    NSArray *titles=@[guide_text(@"键盘",@"Keyboard"),guide_text(@"鼠标",@"Mouse"),guide_text(@"手柄物理位置",@"Controller position")];
    NSMutableArray *values=[NSMutableArray new];
    for (NSUInteger i=0;i<titles.count;i++) {
        CGFloat y=120+i*92;
        guide_add_label(detail,titles[i],NSMakeRect(22,y,372,20),12,NO,YES);
        NSTextField *value=guide_add_label(detail,@"",NSMakeRect(22,y+27,372,48),18,YES,NO);
        value.font=[NSFont monospacedSystemFontOfSize:18 weight:NSFontWeightMedium]; [values addObject:value];
    }
    _values=values;
    _axisLabel=guide_add_label(detail,@"",NSMakeRect(22,402,372,65),12,NO,YES);
    guide_add_label(detail,guide_text(@"只显示本次运行已加载的映射。\n需要改键请回启动器，下次启动生效。",@"Shows only the mapping loaded for this run.\nEdit in the launcher; changes apply next launch."),NSMakeRect(22,490,372,52),12,NO,YES);
    BOOL camera=[snapshot[@"mouseOptions"][@"mode"] isEqual:@"camera"];
    guide_add_label(root,camera ? guide_text(@"鼠标移动 → 右摇杆；鼠标按键模拟手柄，不是按位置直接点击菜单。",@"Mouse movement → right stick. Mouse buttons emulate a controller, not point-and-click menus.") :
                    guide_text(@"鼠标移动不驱动摇杆。鼠标按键仍是手柄映射，不是按位置直接点击菜单。",@"Mouse movement is disabled. Mouse buttons still emulate a controller, not point-and-click menus."),
                    NSMakeRect(24,676,992,32),12,NO,YES);
    guide_separator(root,NSMakeRect(24,724,992,1));
    guide_add_label(root,guide_text(@"查看键位不会暂停游戏。",@"Viewing controls does not pause the game."),NSMakeRect(24,750,750,22),12,NO,YES);
    S2AGuideBackButton *back=[[S2AGuideBackButton alloc] initWithFrame:NSMakeRect(866,742,150,34)];
    back.title=guide_text(@"返回游戏",@"Return to game"); back.bordered=NO; back.target=self; back.action=@selector(returnToGame); [root addSubview:back];
    _status=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _status.button.image=s2a_mac_guide_status_image();
    _status.button.accessibilityLabel=[name stringByAppendingString:guide_text(@" · 查看键位",@" · Controls")];
    _status.button.toolTip=_window.title; _status.button.target=self; _status.button.action=@selector(show);
    [self selectTarget:@"A"]; [_window center];
    return self;
}
- (void)selectTarget:(NSString *)target {
    NSUInteger index=[s2a_mac_controller_targets() indexOfObject:target];
    if (index==NSNotFound) return;
    [_controller selectTarget:target];
    NSArray *row=_rows[index]; _targetLabel.stringValue=row[0];
    for (NSUInteger i=0;i<_values.count;i++) _values[i].stringValue=row[i+1];
    if ([target hasPrefix:@"LS"] || [target hasPrefix:@"RS"]) {
        NSUInteger axis=[target hasPrefix:@"LS"] ? 24 : 26;
        _axisLabel.stringValue=[NSString stringWithFormat:@"%@ → %@\n%@ → %@",_rows[axis][0],_rows[axis][3],_rows[axis+1][0],_rows[axis+1][3]];
    } else _axisLabel.stringValue=@"";
}
- (void)show { [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)returnToGame { [_window orderOut:nil]; [_gameWindow makeKeyAndOrderFront:nil]; [_gameWindow makeFirstResponder:_gameWindow.contentView]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self returnToGame]; return NO; }
- (void)dealloc { if (_status) [NSStatusBar.systemStatusBar removeStatusItem:_status]; }
@end
