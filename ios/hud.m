// 开发浮层 iOS 界面（S2A_HUD=1，设置页「S2Arm 诊断浮层」，缺省关）：安全区左上角的诊断面板，每 0.5 秒刷新。
// 叠在系统界面层：不接触摸（userInteractionEnabled = NO），zPosition 抬高压过其它子视图（直连出图层 11-02 起挂在最底层，host_adapt.m）；
//   截图 / 存帧 / 自动玩家都从 Metal 贴图读回，看不到它。S2A_HUD_FLIP=<秒>（测开销用）：浮层按这个周期开关交替，每次切换 host.log 记一行
#import <UIKit/UIKit.h>
#include "../runtime/src/native.h"
#include "../runtime/include/s2a_hud.h"
uint64_t s2a_ap_frames(void);   // runtime/src/ap_host.c

static UILabel *g_hud;
static UIView *g_panel;
static NSString *g_build;
static double g_bt0 = -1, g_bl0 = -1, g_rate = NAN;   // 电量：起点时刻 / 电量，变动 ≥ 1% 后算速率（%/分）

static const char *thermal_name(void) {
    switch (NSProcessInfo.processInfo.thermalState) {
    case NSProcessInfoThermalStateNominal: return "正常";
    case NSProcessInfoThermalStateFair: return "偏热";
    case NSProcessInfoThermalStateSerious: return "热";
    case NSProcessInfoThermalStateCritical: return "过热";
    }
    return "无";
}
static void tick(void) {
    float lv = UIDevice.currentDevice.batteryLevel;   // app.m 已开 batteryMonitoringEnabled；取不到为 -1
    double now = CACurrentMediaTime();
    if (lv >= 0) {
        if (g_bl0 < 0) { g_bl0 = lv; g_bt0 = now; }
        else if (fabs(lv - g_bl0) >= 0.01 && now > g_bt0) g_rate = (lv - g_bl0) * 100.0 / ((now - g_bt0) / 60.0);
    }
    UIView *v = g_panel.superview; CGFloat s = v.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    const char *metal = getenv("MTL_HUD_ENABLED");
    int requested = (metal && !strcmp(metal, "1")) || [NSUserDefaults.standardUserDefaults boolForKey:@"MetalHUDForceEnabled"];
    s2a_hud_host h = { thermal_name(), g_build.UTF8String, g_rate, v.bounds.size.width * s, v.bounds.size.height * s, lv, requested };
    char t[4096]; s2a_hud_text(t, sizeof t, &h);
    NSString *text = [NSString stringWithUTF8String:t];
    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular], NSForegroundColorAttributeName: UIColor.whiteColor}];
    NSRange title = [text rangeOfString:@"\n"];
    if (title.location != NSNotFound) [styled addAttribute:NSFontAttributeName value:[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold] range:NSMakeRange(0, title.location)];
    g_hud.attributedText = styled;
    UIEdgeInsets in = v.safeAreaInsets;
    CGFloat width = MIN(420, MAX(20, v.bounds.size.width - in.left - in.right - 16));
    CGSize fit = [g_hud sizeThatFits:CGSizeMake(width - 20, CGFLOAT_MAX)];
    g_panel.frame = CGRectMake(in.left + 8, in.top + 8, width, ceil(fit.height) + 20);
    g_hud.frame = CGRectMake(10, 10, width - 20, ceil(fit.height));
}
void s2a_hud_attach(UIView *root) {
    if (!s2a_hud_on() || g_hud) return;
    g_build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2ABuildID"];
    if (![g_build isKindOfClass:NSString.class]) g_build = nil;
    g_panel = [UIView new]; g_panel.userInteractionEnabled = NO;
    g_panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    g_panel.layer.cornerRadius = 10; g_panel.layer.borderWidth = 0.5;
    g_panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    g_panel.layer.zPosition = 10000;
    [root addSubview:g_panel];
    g_hud = [UILabel new];
    g_hud.numberOfLines = 0; g_hud.userInteractionEnabled = NO;
    g_hud.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    g_hud.textColor = UIColor.whiteColor;
    [g_panel addSubview:g_hud];
    LOG("开发浮层：开（S2A_HUD=1，每 0.5 秒刷新，不进截图 / 存帧）");
    const char *fl = getenv("S2A_HUD_FLIP"); int flip = fl ? atoi(fl) : 0;
    __block double last = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        if (flip > 0 && CACurrentMediaTime() - last >= flip) { last = CACurrentMediaTime(); g_panel.hidden = !g_panel.hidden; LOG("开发浮层：%s（S2A_HUD_FLIP=%d，第 %llu 帧）", g_panel.hidden ? "隐藏" : "显示", flip, (unsigned long long)s2a_ap_frames()); }
        if (!g_panel.hidden) tick();
    }];
    tick();
}
