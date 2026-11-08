#import "controller_view.h"
#import "input_guide.h"

static NSString *controller_text(NSString *zh, NSString *en) {
    NSString *language = getenv("S2A_UI_LANGUAGE") ? @(getenv("S2A_UI_LANGUAGE")) : NSLocale.preferredLanguages.firstObject;
    return [language hasPrefix:@"zh"] ? zh : en;
}
static NSColor *controller_ink(void) { return [NSColor colorWithSRGBRed:.17 green:.18 blue:.20 alpha:1]; }
static NSColor *controller_blue(void) { return [NSColor colorWithSRGBRed:0 green:.765 blue:.890 alpha:1]; }
static NSColor *controller_red(void) { return [NSColor colorWithSRGBRed:1 green:.271 blue:.329 alpha:1]; }
static NSBezierPath *controller_shell(NSRect rect, BOOL right) {
    CGFloat x = rect.origin.x, y = rect.origin.y, w = rect.size.width, h = rect.size.height;
    CGFloat radius = w * .61, corner = w * 9 / (414 * 35.9 / 102);
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x+w-corner,y)];
    [p lineToPoint:NSMakePoint(x+radius,y)];
    [p curveToPoint:NSMakePoint(x,y+radius) controlPoint1:NSMakePoint(x+radius*.45,y) controlPoint2:NSMakePoint(x,y+radius*.45)];
    [p lineToPoint:NSMakePoint(x,y+h-radius)];
    [p curveToPoint:NSMakePoint(x+radius,y+h) controlPoint1:NSMakePoint(x,y+h-radius*.45) controlPoint2:NSMakePoint(x+radius*.45,y+h)];
    [p lineToPoint:NSMakePoint(x+w-corner,y+h)];
    [p curveToPoint:NSMakePoint(x+w,y+h-corner) controlPoint1:NSMakePoint(x+w,y+h) controlPoint2:NSMakePoint(x+w,y+h)];
    [p lineToPoint:NSMakePoint(x+w,y+corner)];
    [p curveToPoint:NSMakePoint(x+w-corner,y) controlPoint1:NSMakePoint(x+w,y) controlPoint2:NSMakePoint(x+w,y)];
    [p closePath];
    if (right) {
        NSAffineTransform *mirror = [NSAffineTransform transform];
        mirror.transformStruct = (NSAffineTransformStruct){-1,0,0,1,2*x+w,0};
        [p transformUsingAffineTransform:mirror];
    }
    return p;
}
static void controller_draw_text(NSString *text, NSRect rect, CGFloat size, NSColor *color, BOOL bold) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size],
                                         NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:paragraph}];
}
NSArray<NSString *> *s2a_mac_controller_targets(void) {
    return @[@"A",@"B",@"X",@"Y",@"PLUS",@"MINUS",@"L",@"R",@"ZL",@"ZR",@"LS",@"RS",@"LEFT",@"UP",@"RIGHT",@"DOWN",
             @"LS_UP",@"LS_DOWN",@"LS_LEFT",@"LS_RIGHT",@"RS_UP",@"RS_DOWN",@"RS_LEFT",@"RS_RIGHT"];
}
NSImage *s2a_mac_guide_status_image(void) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(22,18) flipped:NO drawingHandler:^BOOL(NSRect unused) {
        (void)unused;
        CGFloat h=16, w=h*35.9/102;
        NSBezierPath *p = controller_shell(NSMakeRect(3,1,w,h), NO);
        [p appendBezierPath:controller_shell(NSMakeRect(13,1,w,h), YES)];
        // Negative-space sticks and buttons keep the two Joy-Con silhouettes
        // legible at menu-bar size, in either system appearance.
        [p appendBezierPathWithOvalInRect:NSMakeRect(3+w/2-1,11,2,2)];
        [p appendBezierPathWithOvalInRect:NSMakeRect(13+w/2-1,5,2,2)];
        for (NSValue *point in @[[NSValue valueWithPoint:NSMakePoint(3+w/2,5)],
                                [NSValue valueWithPoint:NSMakePoint(13+w/2,12)]]) {
            NSPoint c=point.pointValue;
            for (NSValue *offset in @[[NSValue valueWithPoint:NSMakePoint(0,-1.2)],[NSValue valueWithPoint:NSMakePoint(-1.2,0)],
                                     [NSValue valueWithPoint:NSMakePoint(1.2,0)],[NSValue valueWithPoint:NSMakePoint(0,1.2)]]) {
                NSPoint d=offset.pointValue;
                [p appendBezierPathWithOvalInRect:NSMakeRect(c.x+d.x-.4,c.y+d.y-.4,.8,.8)];
            }
        }
        p.windingRule=NSWindingRuleEvenOdd; [NSColor.blackColor setFill]; [p fill]; return YES;
    }];
    image.template=YES;
    return image;
}

@interface S2AControllerButton : NSButton
@property(nonatomic, copy) NSString *inputTarget, *summary, *glyph;
@property(nonatomic) CGFloat diameter;
@property(nonatomic) BOOL shoulder, direction;
@end
@implementation S2AControllerButton
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    BOOL selected=self.state==NSControlStateValueOn;
    NSRect face=self.shoulder ? NSMakeRect(1,0,66,30) :
        NSMakeRect((NSWidth(self.bounds)-self.diameter)/2,(NSHeight(self.bounds)-self.diameter)/2,self.diameter,self.diameter);
    if (self.direction) face=NSInsetRect(self.bounds,1,1);
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:face xRadius:self.shoulder ? 8 : self.direction ? 6 : self.diameter/2 yRadius:self.shoulder ? 8 : self.direction ? 6 : self.diameter/2];
    if (!self.direction || selected) {
        [(self.direction ? NSColor.whiteColor : controller_ink()) setFill]; [shape fill];
        [(selected ? (self.direction ? controller_ink() : controller_blue()) : [NSColor.blackColor colorWithAlphaComponent:.3]) setStroke];
        shape.lineWidth=selected ? 3 : 1; [shape stroke];
    }
    CGFloat font=self.shoulder ? 12 : self.direction ? 12 : self.diameter<25 ? 15 : 13;
    NSRect text=NSMakeRect(face.origin.x,NSMidY(face)-font*.65,face.size.width,font+5);
    if (self.direction && selected) text.origin.y-=5;
    controller_draw_text(self.glyph,text,font,self.direction ? controller_ink() : NSColor.whiteColor,YES);
    if (self.shoulder) controller_draw_text(self.summary,NSMakeRect(0,34,68,12),10,NSColor.secondaryLabelColor,NO);
    if (self.direction && selected) controller_draw_text(self.summary,NSMakeRect(1,25,40,11),9,controller_ink(),NO);
}
@end

@implementation S2AReadOnlyControllerView {
    NSDictionary *_mapping;
    NSMutableDictionary<NSString *,S2AControllerButton *> *_buttons;
    NSString *_selectedTarget;
}
- (BOOL)isFlipped { return YES; }
- (NSString *)selectedTarget { return _selectedTarget; }
- (instancetype)initWithMapping:(NSDictionary *)mapping {
    if (!(self=[super initWithFrame:NSMakeRect(0,0,558,560)])) return nil;
    _mapping=CFBridgingRelease(CFPropertyListCreateDeepCopy(NULL,(__bridge CFPropertyListRef)mapping,kCFPropertyListImmutable));
    _buttons=[NSMutableDictionary new];
    CGFloat h=414, w=h*35.9/102, left=(558-2*w-58)/2, top=104;
    for (NSNumber *side in @[@NO,@YES]) {
        BOOL right=side.boolValue; CGFloat x=left+(right ? w+58 : 0), center=x+w/2;
        [self addKey:right ? @"R" : @"ZL" glyph:right ? @"R" : @"ZL" center:NSMakePoint(center-38,73) diameter:30 shoulder:YES direction:NO];
        [self addKey:right ? @"ZR" : @"L" glyph:right ? @"ZR" : @"L" center:NSMakePoint(center+38,73) diameter:30 shoulder:YES direction:NO];
        [self addKey:right ? @"PLUS" : @"MINUS" glyph:right ? @"+" : @"−" center:NSMakePoint(x+w*(right ? .22 : .78),top+h*.10) diameter:20 shoulder:NO direction:NO];
        CGFloat stickY=top+h*(right ? .535 : .255), clusterY=top+h*(right ? .255 : .535), step=h*.075;
        NSString *prefix=right ? @"RS" : @"LS";
        [self addKey:prefix glyph:right ? @"R3" : @"L3" center:NSMakePoint(center,stickY) diameter:h*.156 shoulder:NO direction:NO];
        NSArray *suffixes=@[@"UP",@"LEFT",@"RIGHT",@"DOWN"], *arrows=@[@"↑",@"←",@"→",@"↓"];
        NSArray *offsets=@[[NSValue valueWithPoint:NSMakePoint(0,-1)],[NSValue valueWithPoint:NSMakePoint(-1,0)],
                          [NSValue valueWithPoint:NSMakePoint(1,0)],[NSValue valueWithPoint:NSMakePoint(0,1)]];
        NSArray *faces=@[@"X",@"Y",@"A",@"B"];
        for (NSUInteger i=0;i<4;i++) {
            NSPoint d=[offsets[i] pointValue];
            [self addKey:[NSString stringWithFormat:@"%@_%@",prefix,suffixes[i]] glyph:arrows[i] center:NSMakePoint(center+d.x*46,stickY+d.y*46) diameter:0 shoulder:NO direction:YES];
            [self addKey:right ? faces[i] : suffixes[i] glyph:right ? faces[i] : arrows[i] center:NSMakePoint(center+d.x*step,clusterY+d.y*step) diameter:h*.076 shoulder:NO direction:NO];
        }
    }
    [self selectTarget:@"A"];
    return self;
}
- (void)addKey:(NSString *)target glyph:(NSString *)glyph center:(NSPoint)center diameter:(CGFloat)diameter shoulder:(BOOL)shoulder direction:(BOOL)direction {
    NSSize size=shoulder ? NSMakeSize(68,46) : direction ? NSMakeSize(42,38) : NSMakeSize(MAX(44,diameter),MAX(44,diameter));
    S2AControllerButton *button=[[S2AControllerButton alloc] initWithFrame:NSMakeRect(center.x-size.width/2,center.y-size.height/2,size.width,size.height)];
    button.inputTarget=target; button.glyph=glyph; button.diameter=diameter; button.shoulder=shoulder; button.direction=direction;
    NSUInteger index=[s2a_mac_controller_targets() indexOfObject:target];
    NSArray *row=s2a_mac_guide_rows(_mapping)[index];
    button.summary=![row[1] isEqual:@"—"] ? row[1] : ![row[2] isEqual:@"—"] ? row[2] : _mapping[@"gamepad"][target] ? controller_text(@"手柄",@"Controller") : @"—";
    button.title=glyph; button.bordered=NO; button.target=self; button.action=@selector(pick:);
    button.accessibilityLabel=[controller_text(@"查看按键 ",@"View button ") stringByAppendingString:row[0]];
    button.accessibilityValue=button.summary; button.toolTip=[row componentsJoinedByString:@" · "];
    [self addSubview:button]; _buttons[target]=button;
}
- (void)pick:(S2AControllerButton *)sender { [self selectTarget:sender.inputTarget]; if (self.onSelect) self.onSelect(sender.inputTarget); }
- (void)selectTarget:(NSString *)target {
    if (!_buttons[target]) return;
    _selectedTarget=[target copy];
    for (NSString *key in _buttons) { _buttons[key].state=[key isEqual:target] ? NSControlStateValueOn : NSControlStateValueOff; _buttons[key].needsDisplay=YES; }
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CGFloat h=414,w=h*35.9/102,left=(558-2*w-58)/2,top=104;
    controller_draw_text(controller_text(@"Switch 按键位置",@"Switch button layout"),NSMakeRect(20,20,230,22),14,NSColor.labelColor,YES);
    controller_draw_text(controller_text(@"点击查看对应输入",@"Select a button to inspect"),NSMakeRect(300,22,238,18),11,NSColor.secondaryLabelColor,NO);
    for (NSNumber *side in @[@NO,@YES]) {
        BOOL right=side.boolValue; CGFloat x=left+(right ? w+58 : 0);
        NSBezierPath *body=controller_shell(NSMakeRect(x,top,w,h),right);
        [(right ? controller_red() : controller_blue()) setFill]; [body fill];
        [[NSColor.blackColor colorWithAlphaComponent:.2] setStroke]; body.lineWidth=1.5; [body stroke];
        [[controller_ink() colorWithAlphaComponent:.28] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x+(right ? 1 : w-5),top+h*.03,4,h*.94) xRadius:2 yRadius:2] fill];
        NSRect auxiliary=NSMakeRect(x+w*(right ? .35 : .65)-11.5,top+h*.72-11.5,23,23);
        [controller_ink() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:auxiliary xRadius:right ? 11.5 : 4 yRadius:right ? 11.5 : 4] fill];
        NSImage *symbol=[NSImage imageWithSystemSymbolName:right ? @"house.fill" : @"record.circle" accessibilityDescription:nil];
        NSImageSymbolConfiguration *configuration=[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]];
        [[symbol imageWithSymbolConfiguration:configuration] drawInRect:NSInsetRect(auxiliary,5,5)];
    }
    controller_draw_text(controller_text(@"摇杆外侧箭头表示推杆方向。HOME / 截图键仅作示意。",@"Arrows indicate stick directions. HOME / Capture are illustrative only."),
                         NSMakeRect(16,532,526,26),10,NSColor.secondaryLabelColor,NO);
}
@end
