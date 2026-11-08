// 宿主提示 / 出错页的画法（ios/notice.m）。状态与时机在 app.m（s2a_ios_show_notice / s2a_ios_show_pack_help / 直连安全网页）与 pack_apply.c
#import <UIKit/UIKit.h>
UIImage *s2a_game_icon(void);   // loadpage.m：本款游戏图标（资源包 icon.jpg，没有取包里的 AppIcon）
UIColor *s2a_notice_accent(void);
// 胶囊按钮：主按钮填启动器品牌色，次按钮半透明白（同加载页「先开始玩」）
UIButton *s2a_notice_button(NSString *title, BOOL primary, void (^tap)(UIButton *b));
// 整屏提示页：symbol = 图标角上的 SF Symbol；progress < 0 = 没有进度条；caption = 进度条下一行小字（可 nil）
UIView *s2a_notice_page(CGRect frame, NSString *symbol, NSString *title, NSString *body, float progress, NSString *caption, NSArray<UIButton *> *buttons);
// 缺资源包 / 不完整的说明页：左边示意（Mac → 数据线 → 本 App、「<名>资源包」），右边标题、一句话、三步、按钮
UIView *s2a_notice_help_page(CGRect frame, NSString *title, NSString *detail, NSString *app, UIButton *recheck);
